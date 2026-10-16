%% @doc The client of an etcd cluster: one logical egrpc channel for the whole cluster.
%%
%% The channel is named after the client, so the generated stubs are called with the name
%% (`etcdgun_etcdserverpb_kv_stub:range(my_client, Request)'). Its endpoints are the members of
%% the cluster, found with `MemberList' and checked again now and then: the connections, the
%% choice of the endpoint for every call and the reconnects are those of egrpc. This process owns
%% the credentials and the token and keeps the endpoints up to date, it is not on the path of a
%% request.

-module(etcdgun_client).

-feature(maybe_expr, enable).

-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

-export([
    start_link/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    format_status/1
]).

-export([
    client_info/1,
    update_cred/3,
    unset_cred/1,
    cached_token/1,
    normalize_cred/1,
    refresh_token/1,
    refresh_token/2,
    sync_membership/2
]).

-type member() :: etcdgun_rpc_pb:'etcdserverpb.Member'().
-type member_id() :: non_neg_integer().

%% The refresh in progress. `cred' is what it authenticates with, the result is dropped when the
%% credentials changed in the meantime.
-record(refresh, {
    pid :: pid(),
    mref :: reference(),
    cred :: {binary(), binary()},
    waiters = [] :: [gen_server:from()]
}).

-record(state, {
    name :: atom(),
    %% The endpoints which were given, where the client goes back to when the members can not
    %% be found.
    seeds :: [etcdgun:endpoint()],
    %% The endpoints of the channel.
    endpoints :: [etcdgun:endpoint()],
    transport :: tcp | tls,
    members :: #{member_id() => member()},
    membership_tref = undefined :: undefined | reference(),
    membership_check_interval :: timeout(), %% 5 minutes
    token = undefined :: binary() | undefined,
    cred = undefined :: {binary(), binary()} | undefined,
    %% The token which is being refreshed, by a process of its own, so the client does not wait
    %% for the network.
    refreshing = undefined :: undefined | #refresh{},
    %% The last refresh failed: until then the requests get the same error, without asking etcd.
    refresh_failed = undefined :: undefined | {Until :: integer(), Error :: term()}
}).

-define(TOKEN_TABLE, etcdgun_client_tokens).
%% How long a failed refresh is the answer of the following ones, in milliseconds.
-define(REFRESH_BACKOFF, 1000).
%% Longer than a refresh takes: `Authenticate' waits for 5 seconds for a message of the response.
-define(REFRESH_CALL_TIMEOUT, 15000).
%% How long to wait for the first endpoint to be connected.
-define(CONNECT_TIMEOUT, 5000).
-define(MEMBERSHIP_CHECK_INTERVAL, 300_000). % 5 minutes

client_info(Client) ->
    gen_server:call(Client, client_info).

%% @doc Update the credentials of the client and authenticate with them.
%%
%% On success, the new credentials and the new token replace the old ones, and the new token is
%% used by the following requests.
%%
%% If the etcd server does not enable authentication, the credentials are updated and the token is
%% unset, `ok' is returned.
%%
%% On failure, for example a wrong password or no available connection, the old credentials and
%% the old token are kept, and `{error, Reason}' is returned.
%%
%% The username and the password are a binary or a string, neither of them is empty, otherwise
%% `{error, invalid_cred}' is returned.
-spec update_cred(etcdgun:client(), Username, Password) -> ok | {error, term()} when
    Username :: binary() | string(),
    Password :: binary() | string().
update_cred(Client, Username, Password) ->
    case normalize_cred({Username, Password}) of
        {ok, Cred} ->
            % eqwalizer:ignore
            gen_server:call(Client, {update_cred, Cred});
        {error, _} = Error ->
            Error
    end.

%% @doc The credentials as the binaries of the username and the password.
%%
%% Each of them is a binary or a string (unicode characters), and not empty. The reason does not
%% have the credentials in it, as it goes to logs and crash reports.
-spec normalize_cred(term()) -> {ok, {binary(), binary()}} | {error, invalid_cred}.
normalize_cred({Username, Password}) ->
    case {to_binary(Username), to_binary(Password)} of
        {Username1, Password1} when is_binary(Username1), is_binary(Password1),
                                    Username1 =/= <<>>, Password1 =/= <<>> ->
            {ok, {Username1, Password1}};
        _ ->
            {error, invalid_cred}
    end;
normalize_cred(_) ->
    {error, invalid_cred}.

to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(List) when is_list(List) ->
    try unicode:characters_to_binary(List) of
        Bin when is_binary(Bin) -> Bin;
        _ -> error
    catch
        error:badarg -> error
    end;
to_binary(_) ->
    error.

-spec unset_cred(etcdgun:client()) -> ok.
unset_cred(Client) ->
    % eqwalizer:ignore
    gen_server:call(Client, {update_cred, undefined}).

%% @doc Refresh the token, whatever the current one is. See `refresh_token/2'.
-spec refresh_token(etcdgun:client()) ->
    {ok, NewToken :: binary()} | {error, no_credentials | auth_not_enabled | term()}.
refresh_token(Client) ->
    refresh_token(Client, undefined).

%% @doc Refresh the token which was refused.
%%
%% `Stale' is the token which was refused, or `undefined' to refresh whatever the current one is.
%% When the current token is not the refused one, someone has refreshed it already, and it is
%% returned without authenticating again.
%%
%% The requests which come while a refresh is in progress wait for it and get its result, so
%% many requests which are refused at the same time authenticate once. After a refresh failed,
%% the requests of the next second get the same error without asking etcd.
-spec refresh_token(etcdgun:client(), Stale :: binary() | undefined) ->
    {ok, NewToken :: binary()} | {error, no_credentials | auth_not_enabled | term()}.
refresh_token(Client, Stale) ->
    %% The interceptor may call this from the client process itself, e.g. when checking the members
    %% while connecting. Calling itself would crash with `calling_self'.
    case Client =:= self() orelse (is_atom(Client) andalso whereis(Client) =:= self()) of
        true -> {error, in_client_process};
        false ->
            try
                % eqwalizer:ignore
                gen_server:call(Client, {refresh_token, Stale}, ?REFRESH_CALL_TIMEOUT)
            catch
                exit:{timeout, _} -> {error, timeout}
            end
    end.

%% @doc The current token of the client, read from the ETS table the client writes whenever its
%% token changes, so the callers do not go through the client process.
-spec cached_token(etcdgun:client()) -> {ok, binary()} | undefined.
cached_token(Client) ->
    case ets:lookup(?TOKEN_TABLE, Client) of
        [{_, Token}] -> {ok, Token};
        [] -> undefined
    end.

-spec sync_membership(etcdgun:client() | pid(), [etcdgun_rpc_pb:'etcdserverpb.Member'()]) -> ok.
sync_membership(Client, Members) ->
    gen_server:cast(Client, {sync_membership, Members}).

-spec start_link(etcdgun:client(), [Endpoint], Opts) -> gen_server:start_ret() when
    Endpoint :: {string(), inet:port_number()},
    Opts :: map(). %% TODO:
start_link(Client, Endpoints, Options) ->
    gen_server:start_link({local, Client}, ?MODULE, {Client, Endpoints, Options}, []).

%%-------------------------------------------------------------------
%% gen_server callbacks
%%-------------------------------------------------------------------

init({Client, Endpoints, Opts0}) ->
    process_flag(trap_exit, true),
    logger:update_process_metadata(#{etcdgun_client => Client}),
    case parse_cred(maps:get(cred, Opts0, undefined)) of
        {ok, Cred} ->
            do_init(Client, Endpoints, Opts0, Cred);
        {error, invalid_cred} ->
            ?LOG_ERROR("Invalid credentials, a username and a password, both not empty"),
            {stop, invalid_cred}
    end.

parse_cred(undefined) -> {ok, undefined};
%% From `etcdgun_client_sup:start_child/3', the credentials are hidden in a fun there, so that
%% they are not in the child spec, which is printed in the reports of the supervisor.
parse_cred(Fun) when is_function(Fun, 0) -> parse_cred(Fun());
parse_cred(Cred) -> normalize_cred(Cred).

username({Username, _Password}) -> Username;
username(undefined) -> undefined.

do_init(Client, Endpoints, Opts0, Cred) ->
    case maps:get(transport, Opts0, tcp) of
        Transport when Transport =:= tcp; Transport =:= tls ->
            do_init(Client, Endpoints, Opts0, Cred, Transport);
        Other ->
            ?LOG_ERROR("Invalid transport: ~p, tcp or tls", [Other]),
            {stop, {invalid_transport, Other}}
    end.

do_init(Client, Endpoints, Opts0, Cred, Transport) ->
    MembershipCheckInterval =
        case maps:get(membership_check_interval, Opts0, ?MEMBERSHIP_CHECK_INTERVAL) of
            I when is_integer(I) andalso I >= 0 -> I;
            infinity -> infinity;
            _ -> ?MEMBERSHIP_CHECK_INTERVAL
        end,
    %% The authentication is the first interceptor, the ones of the user see the requests as they
    %% are made.
    ChannelOpts = with_transport(#{
        target => Endpoints,
        retry => etcdgun_retry:policy(),
        call_credentials => fun etcdgun_interceptor_auth:call_credentials/1,
        interceptors => [etcdgun_interceptor_auth | maps:get(interceptors, Opts0, [])],
        gun_opts => maps:get(gun_opts, Opts0, #{}),
        info => #{client => Client}
    }, Transport),
    %% A channel which was left by a client which was killed.
    _ = egrpc_channel:stop(Client),
    ok = egrpc_channel:start(Client, ChannelOpts),
    State0 = #state{
        name = Client,
        seeds = Endpoints,
        endpoints = Endpoints,
        transport = Transport,
        members = #{},
        membership_check_interval = MembershipCheckInterval,
        cred = Cred
    },
    maybe
        ok ?= wait_ready(Client),
        %% Authenticate first, the RPCs of getting the members require the token in etcd 3.6 and
        %% 3.7 when authentication is enabled.
        {ok, Token} ?= authenticate_bootstrap(Client, Cred),
        State1 = publish_token(State0#state{token = Token}),
        {ok, Members} ?= get_member_list(Client, Token),
        ok ?= check_leader(Client, Token),
        State2 = apply_members(Members, State1),
        ?LOG_INFO(#{msg => "Connected to etcd", members => Members}),
        {ok, start_membership_timer(State2)}
    else
        {error, Reason} ->
            ?LOG_ERROR("Failed to connect to etcd endpoints: ~p, reason: ~p", [Endpoints, Reason]),
            _ = egrpc_channel:stop(Client),
            ets:delete(?TOKEN_TABLE, Client),
            {stop, Reason}
    end.

wait_ready(Client) ->
    case egrpc_channel:await_ready(Client, ?CONNECT_TIMEOUT) of
        ok -> ok;
        {error, timeout} -> {error, no_available_endpoints}
    end.

handle_call(client_info, _From, State) ->
    {Actives, Connectings} = subchannels(State#state.name),
    Reply = #{
        name => State#state.name,
        pid => self(),
        actives => Actives,
        connectings => Connectings,
        members => maps:values(State#state.members),
        %% Neither the password nor the token, this is what `etcdgun:clients/0' returns and what
        %% ends up in logs.
        username => username(State#state.cred),
        authenticated => State#state.token =/= undefined
    },
    {reply, {ok, Reply}, State};

handle_call({refresh_token, _Stale}, _From, #state{cred = undefined} = State) ->
    {reply, {error, no_credentials}, State};

%% Refreshed by someone else since the caller was refused.
handle_call({refresh_token, Stale}, _From, #state{token = Token} = State)
  when Stale =/= undefined, Token =/= undefined, Token =/= Stale ->
    {reply, {ok, Token}, State};

handle_call({refresh_token, _Stale}, From, #state{refreshing = #refresh{} = Refresh} = State) ->
    {noreply, State#state{refreshing = Refresh#refresh{waiters = [From | Refresh#refresh.waiters]}}};

handle_call({refresh_token, _Stale}, From, #state{refresh_failed = {Until, Error}} = State) ->
    case erlang:monotonic_time(millisecond) < Until of
        true ->
            {reply, {error, Error}, State};
        false ->
            {noreply, start_refresh(From, State#state{refresh_failed = undefined})}
    end;

handle_call({refresh_token, _Stale}, From, State) ->
    {noreply, start_refresh(From, State)};

handle_call({update_cred, undefined}, _From, #state{cred = _Cred0} = State) ->
    ?LOG_INFO("Unset credentials for client ~p", [State#state.name]),
    {reply, ok, publish_token(State#state{cred = undefined, token = undefined,
                                          refresh_failed = undefined})};
handle_call({update_cred, {Username, _Password} = Cred}, _From, #state{cred = _Cred0} = State) ->
    case authenticate(State#state.name, Cred) of
        {ok, NewToken} ->
            ?LOG_INFO("Updated credentials for client ~p: ~p", [State#state.name, Username]),
            {reply, ok, publish_token(State#state{cred = Cred, token = NewToken,
                                                  refresh_failed = undefined})};
        {error, {etcd_error, auth_not_enabled}} ->
            ?LOG_WARNING("Authentication is not enabled on the etcd server, "
                         "updated credentials and unset token"),
            {reply, ok, publish_token(State#state{cred = Cred, token = undefined,
                                                  refresh_failed = undefined})};
        {error, Reason} ->
            ?LOG_ERROR("Failed to update credentials for client ~p: ~p",
                      [State#state.name, Reason]),
            {reply, {error, Reason}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast({sync_membership, NewMembers}, #state{} = State) ->
    {noreply, apply_members(NewMembers, State)};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, TRef, check_membership}, #state{membership_tref = TRef} = State) ->
    #state{name = Client} = State,
    Self = self(),
    spawn(
        fun() ->
            case get_member_list(Client, undefined) of
                {ok, Members} ->
                    Self ! {sync_membership, Members};
                {error, Reason} ->
                    ?LOG_WARNING("Failed to check membership for client ~p: ~p", [Client, Reason]),
                    Self ! {sync_failed, Reason}
            end
        end),
    {noreply, start_membership_timer(State#state{membership_tref = undefined})};

handle_info({sync_membership, NewMembers}, State) ->
    {noreply, apply_members(NewMembers, State)};

%% No member can be found and no endpoint is connected: the members may have all moved, the
%% endpoints which were given are tried again as well.
handle_info({sync_failed, _Reason}, #state{name = Client, seeds = Seeds, endpoints = Endpoints} = State) ->
    case egrpc_channel:connectivity(Client) of
        ready ->
            {noreply, State};
        _ ->
            All = lists:usort(Seeds ++ Endpoints),
            ok = egrpc_channel:update_endpoints(Client, All),
            {noreply, State#state{endpoints = All}}
    end;

handle_info({refreshed, Pid, Result}, #state{refreshing = #refresh{pid = Pid} = Refresh} = State) ->
    erlang:demonitor(Refresh#refresh.mref, [flush]),
    {noreply, finish_refresh(Result, State)};
handle_info({'DOWN', MRef, process, Pid, Reason},
            #state{refreshing = #refresh{pid = Pid, mref = MRef}} = State) ->
    ?LOG_ERROR("The refresh of the token of client ~p crashed: ~p", [State#state.name, Reason]),
    {noreply, finish_refresh({error, {refresh_crashed, Reason}}, State)};

handle_info(Info, State) ->
    ?LOG_WARNING("Received unexpected info message: ~p", [Info]),
    {noreply, State}.

%% The state is in the crash reports and the output of `sys:get_status/1', without the secrets.
format_status(#{state := #state{} = State} = Status) ->
    Status#{state := State#state{cred = redact(State#state.cred), token = redact(State#state.token)}};
format_status(Status) ->
    Status.

redact(undefined) -> undefined;
redact(_Secret) -> '<redacted>'.

terminate(_Reason, #state{name = Name}) ->
    ?LOG_NOTICE("Terminating etcdgun client, reason: ~p", [_Reason]),
    _ = egrpc_channel:stop(Name),
    ets:delete(?TOKEN_TABLE, Name),
    ok.

%%-------------------------------------------------------------------
%% Private functions
%%-------------------------------------------------------------------
publish_token(#state{name = Name, token = undefined} = State) ->
    ets:delete(?TOKEN_TABLE, Name),
    State;
publish_token(#state{name = Name, token = Token} = State) ->
    ets:insert(?TOKEN_TABLE, {Name, Token}),
    State.

%% Authenticates in a process of its own, the waiters get the result from `finish_refresh/2'.
start_refresh(From, #state{name = Name, cred = Cred} = State) ->
    Self = self(),
    {Pid, MRef} = spawn_monitor(fun() -> Self ! {refreshed, self(), authenticate(Name, Cred)} end),
    State#state{refreshing = #refresh{pid = Pid, mref = MRef, cred = Cred, waiters = [From]}}.

finish_refresh(Result, #state{refreshing = #refresh{cred = Cred, waiters = Waiters}} = State0) ->
    State = State0#state{refreshing = undefined},
    {Reply, State1} = refresh_result(Result, Cred, State),
    [gen_server:reply(Waiter, Reply) || Waiter <- lists:reverse(Waiters)],
    State1.

%% The credentials were changed (and the token with them) while authenticating.
refresh_result(_Result, Cred, #state{cred = Current, token = Token} = State) when Current =/= Cred ->
    case Token of
        undefined -> {{error, cred_changed}, State};
        _ -> {{ok, Token}, State}
    end;
refresh_result({ok, Token}, _Cred, State) when is_binary(Token) ->
    {{ok, Token}, publish_token(State#state{token = Token, refresh_failed = undefined})};
refresh_result({error, {etcd_error, auth_not_enabled}}, _Cred, State) ->
    ?LOG_WARNING("Authentication is not enabled on the etcd server, unsetting token"),
    {{error, auth_not_enabled}, publish_token(State#state{token = undefined})};
refresh_result({error, Reason}, _Cred, State) ->
    ?LOG_ERROR("Failed to refresh token for client ~p: ~p", [State#state.name, Reason]),
    Until = erlang:monotonic_time(millisecond) + ?REFRESH_BACKOFF,
    {{error, Reason}, State#state{refresh_failed = {Until, Reason}}}.

%% `infinity' first: as a term, the atom is greater than any integer.
start_membership_timer(#state{membership_check_interval = infinity} = State) ->
    State;
start_membership_timer(#state{membership_check_interval = 0} = State) ->
    State;
start_membership_timer(#state{membership_check_interval = Interval} = State)
  when is_integer(Interval), Interval > 0 ->
    TRef = erlang:start_timer(Interval, self(), check_membership),
    State#state{membership_tref = TRef}.

authenticate(_Client, undefined) -> {ok, undefined};
authenticate(Client, {Username, Password}) ->
    maybe
        Req = #{name => Username, password => Password},
        {ok, #{token := Token}} ?= etcdgun_etcdserverpb_auth_stub:authenticate(Client, Req),
        {ok, Token}
    end.

authenticate_bootstrap(Client, Cred) ->
    case authenticate(Client, Cred) of
        {error, {etcd_error, auth_not_enabled}} ->
            ?LOG_WARNING("Authentication is not enabled on the etcd server, skipping"),
            {ok, undefined};
        Result -> Result
    end.

%% The members, `Token' is the one the request is made with: none and a server which requires one
%% is that there are no credentials.
get_member_list(Client, Token) ->
    Opts = etcdgun_retry:opts(etcdgun_etcdserverpb_cluster_stub, member_list),
    case etcdgun_etcdserverpb_cluster_stub:member_list(Client, #{}, Opts) of
        {ok, #{members := Members}} -> {ok, usable_members(Members)};
        {error, Reason} ->
            case is_auth_required(Token, Reason) of
                true -> {error, no_credentials};
                false -> {error, Reason}
            end
    end.

%% Etcd 3.6 and later require the token for the status of a member, 3.5 only for the keys, and a
%% cluster without a leader can not serve the requests: both are better told at the start.
check_leader(Client, Token) ->
    Opts = etcdgun_retry:opts(etcdgun_etcdserverpb_maintenance_stub, status),
    case etcdgun_etcdserverpb_maintenance_stub:status(Client, #{}, Opts) of
        {ok, #{leader := 0}} -> {error, no_leader};
        {ok, _} -> ok;
        {error, Reason} ->
            case is_auth_required(Token, Reason) of
                true -> {error, no_credentials};
                false -> {error, Reason}
            end
    end.

%% Learners do not serve normal requests, and members that were added but not started yet have no
%% client URLs, so none of them can be connected to.
usable_members(Members) ->
    [M || #{clientURLs := [_|_]} = M <- Members, not is_learner(M)].

is_learner(#{isLearner := IsLearner}) -> IsLearner =:= true orelse IsLearner =:= 1;
is_learner(#{}) -> false.

%% The server requires the token, but there is no one, i.e. no credentials configured.
is_auth_required(undefined, {grpc_error, _, _} = Reason) ->
    is_auth_required(undefined, etcdgun_error:from_grpc_error(Reason));
is_auth_required(undefined, Reason) -> Reason =:= {etcd_error, user_empty};
is_auth_required(_Token, _Reason) -> false.

%% The members are the endpoints of the channel. Nothing is changed when there are none (the
%% answer of a cluster which is starting, ...), nor when they are the same.
apply_members([], State) ->
    State;
apply_members(Members, #state{name = Name, transport = Transport, endpoints = Old} = State) ->
    Endpoints = member_endpoints(Members, Transport),
    case Endpoints of
        [] ->
            ?LOG_WARNING("No member with a client URL of the transport ~p: ~p", [Transport, Members]),
            State;
        Old ->
            State#state{members = members_map(Members)};
        _ ->
            ?LOG_INFO("Endpoints of etcd members: ~p, were ~p", [Endpoints, Old]),
            ok = egrpc_channel:update_endpoints(Name, Endpoints),
            State#state{members = members_map(Members), endpoints = Endpoints}
    end.

%% elp:ignore W0036
members_map(Members) -> maps:from_list([{Id, M} || #{'ID' := Id} = M <- Members]).

%% The first client URL of every member. The transport is a setting of the channel, so a member
%% which is at the other one is not connected to.
member_endpoints(Members, Transport) ->
    lists:usort(lists:flatmap(fun(#{clientURLs := Urls}) -> member_endpoint(Urls, Transport) end, Members)).

member_endpoint(Urls, Transport) ->
    case [{Host, Port} || Url <- Urls, {ok, Host, Port, T} <- [parse_client_url(Url)], T =:= Transport] of
        [Endpoint | _] -> [Endpoint];
        [] -> []
    end.

%% The subchannels which can take calls, and the others.
subchannels(Name) ->
    case egrpc_channel:describe(Name) of
        #{subchannels := Subs} ->
            {Ready, Other} = lists:partition(fun(#{state := S}) -> S =:= ready end, Subs),
            {length(Ready), length(Other)};
        {error, _} ->
            {0, 0}
    end.

scheme_transport("http") -> {ok, tcp};
scheme_transport("https") -> {ok, tls};
scheme_transport(_) -> error.

%% `gun_opts' of the user (e.g. `tls_opts') are kept, only the transport is added for TLS.
with_transport(Opts, tcp) ->
    Opts;
with_transport(Opts, tls) ->
    GunOpts = maps:get(gun_opts, Opts, #{}),
    Opts#{gun_opts => GunOpts#{transport => tls}}.

parse_client_url(ClientUrl) when is_binary(ClientUrl) ->
    parse_client_url(binary_to_list(ClientUrl));
parse_client_url(ClientUrl) ->
    maybe
        #{host := Host, port := Port, scheme := Scheme} ?= uri_string:parse(ClientUrl),
        {ok, Transport} ?= scheme_transport(Scheme),
        {ok, Host, Port, Transport}
    else
        _ -> {error, invalid_client_url}
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

usable_members_test() ->
    Started = #{'ID' => 1, clientURLs => [<<"http://127.0.0.1:2379">>], isLearner => false},
    Learner = #{'ID' => 2, clientURLs => [<<"http://127.0.0.1:2479">>], isLearner => true},
    Unstarted = #{'ID' => 3, clientURLs => [], isLearner => false},
    NoLearnerKey = #{'ID' => 4, clientURLs => [<<"http://127.0.0.1:2579">>]},
    ?assertEqual([Started, NoLearnerKey],
                 usable_members([Started, Learner, Unstarted, NoLearnerKey])),
    ?assertEqual([], usable_members([])),
    ok.

publish_token_test() ->
    ets:new(?TOKEN_TABLE, [set, named_table, public]),
    try
        State = #state{name = foo, token = <<"t1">>},
        ?assertEqual(undefined, cached_token(foo)),
        ?assertEqual(State, publish_token(State)),
        ?assertEqual({ok, <<"t1">>}, cached_token(foo)),
        publish_token(State#state{token = <<"t2">>}),
        ?assertEqual({ok, <<"t2">>}, cached_token(foo)),
        publish_token(State#state{token = undefined}),
        ?assertEqual(undefined, cached_token(foo))
    after
        ets:delete(?TOKEN_TABLE)
    end.

finish_refresh_test() ->
    Ref = make_ref(),
    From = {self(), Ref},
    Cred = {<<"root">>, <<"pw">>},
    Refresh = #refresh{pid = self(), mref = make_ref(), cred = Cred, waiters = [From]},
    ets:new(?TOKEN_TABLE, [set, named_table, public]),
    try
        State = #state{name = foo, cred = Cred, token = <<"old">>, refreshing = Refresh},
        %% A token: published, the waiters get it
        S1 = finish_refresh({ok, <<"new">>}, State),
        ?assertMatch(#state{token = <<"new">>, refreshing = undefined, refresh_failed = undefined}, S1),
        ?assertEqual({ok, <<"new">>}, cached_token(foo)),
        receive {Ref, R1} -> ?assertEqual({ok, <<"new">>}, R1) after 0 -> ?assert(false) end,
        %% An error: the token is kept, the error is remembered
        S2 = finish_refresh({error, nope}, State),
        ?assertMatch(#state{token = <<"old">>, refreshing = undefined,
                            refresh_failed = {_, nope}}, S2),
        receive {Ref, R2} -> ?assertEqual({error, nope}, R2) after 0 -> ?assert(false) end,
        %% The credentials were changed meanwhile: the result is dropped, the current token is given
        S3 = finish_refresh({ok, <<"new">>}, State#state{cred = {<<"root">>, <<"pw2">>}}),
        ?assertMatch(#state{token = <<"old">>, refreshing = undefined}, S3),
        receive {Ref, R3} -> ?assertEqual({ok, <<"old">>}, R3) after 0 -> ?assert(false) end,
        S4 = finish_refresh({ok, <<"new">>},
                            State#state{cred = undefined, token = undefined}),
        ?assertMatch(#state{token = undefined}, S4),
        receive {Ref, R4} -> ?assertEqual({error, cred_changed}, R4) after 0 -> ?assert(false) end
    after
        ets:delete(?TOKEN_TABLE)
    end.

format_status_test() ->
    State = #state{name = foo, cred = {<<"root">>, <<"secret">>}, token = <<"token">>},
    #{state := Redacted} = format_status(#{state => State}),
    ?assertEqual('<redacted>', Redacted#state.cred),
    ?assertEqual('<redacted>', Redacted#state.token),
    ?assertEqual(foo, Redacted#state.name),
    NoCred = #state{name = foo, cred = undefined, token = undefined},
    ?assertMatch(#{state := #state{cred = undefined, token = undefined}},
                 format_status(#{state => NoCred})),
    ?assertEqual(#{reason => x}, format_status(#{reason => x})).

member_endpoints_test() ->
    M = fun(Id, Urls) -> #{'ID' => Id, clientURLs => Urls} end,
    Members = [M(1, [<<"http://127.0.0.1:2379">>]), M(2, [<<"https://h:2379">>, <<"http://h:2479">>]),
               M(3, [<<"https://h:2579">>])],
    %% the transport is the one of the channel, the first URL of it is the endpoint
    ?assertEqual([{"127.0.0.1", 2379}, {"h", 2479}], member_endpoints(Members, tcp)),
    ?assertEqual([{"h", 2379}, {"h", 2579}], member_endpoints(Members, tls)),
    ?assertEqual([], member_endpoints([M(4, [<<"unix://x">>])], tcp)).

parse_client_url_test() ->
    ?assertEqual({ok, "127.0.0.1", 2379, tcp}, parse_client_url(<<"http://127.0.0.1:2379">>)),
    ?assertEqual({ok, "etcd.local", 2379, tls}, parse_client_url("https://etcd.local:2379")),
    ?assertEqual({error, invalid_client_url}, parse_client_url(<<"unix://127.0.0.1:2379">>)),
    ?assertEqual({error, invalid_client_url}, parse_client_url(<<"127.0.0.1:2379">>)),
    ok.

with_transport_test() ->
    Opts = #{interceptors => [], gun_opts => #{tls_opts => [{verify, verify_none}]}},
    ?assertEqual(Opts, with_transport(Opts, tcp)),
    ?assertEqual(Opts#{gun_opts := #{tls_opts => [{verify, verify_none}], transport => tls}},
                 with_transport(Opts, tls)),
    ?assertEqual(#{gun_opts => #{transport => tls}}, with_transport(#{}, tls)).

normalize_cred_test() ->
    ?assertEqual({ok, {<<"root">>, <<"123456">>}}, normalize_cred({"root", "123456"})),
    ?assertEqual({ok, {<<"root">>, <<"123456">>}}, normalize_cred({<<"root">>, <<"123456">>})),
    ?assertEqual({ok, {<<"root">>, <<"123456">>}}, normalize_cred({<<"root">>, "123456"})),
    %% unicode characters of a string are utf-8 encoded
    ?assertEqual({ok, {<<"用户"/utf8>>, <<"p">>}}, normalize_cred({[29992, 25143], "p"})),
    %% the reason has no credentials in it
    Invalid = [
        {"", "p"}, {"u", ""}, {<<>>, <<"p">>}, {<<"u">>, <<>>}, {u, "p"}, {"u", 1},
        {[a], "p"}, {"u"}, {"u", "p", "x"}, "up", undefined, #{name => "u"}
    ],
    [?assertEqual({error, invalid_cred}, normalize_cred(C)) || C <- Invalid],
    ok.

is_auth_required_test() ->
    UserEmpty = {grpc_error, invalid_argument, <<"etcdserver: user name is empty">>},
    ?assert(is_auth_required(undefined, {etcd_error, user_empty})),
    ?assert(is_auth_required(undefined, UserEmpty)),
    %% Has the token, or other errors.
    ?assertNot(is_auth_required(<<"token">>, {etcd_error, user_empty})),
    ?assertNot(is_auth_required(undefined, {etcd_error, invalid_auth_token})),
    ?assertNot(is_auth_required(undefined, {grpc_error, unavailable, <<"etcdserver: no leader">>})),
    ?assertNot(is_auth_required(undefined, timeout)),
    ok.
-endif.
