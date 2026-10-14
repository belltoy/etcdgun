%% @doc Connect to all etcd servers in a cluster, implementing the clientv3-grpc1.23
%% [https://etcd.io/docs/v3.5/learning/design-client/#clientv3-grpc123-balancer-overview
%% Balancer Overview]

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
    handle_continue/2,
    terminate/2,
    format_status/1
]).

-export([
    client_info/1,
    update_cred/3,
    unset_cred/1,
    pick_channel/1,
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
    members :: #{member_id() => member()},
    actives :: [{member_id(), egrpc:channel(), MonitorRef ::reference()}],
    connectings = [] :: [{member_id(), egrpc:channel(), MonitorRef ::reference()}],
    retry_tref = undefined :: undefined | reference(),
    membership_tref = undefined :: undefined | reference(),
    membership_check_interval :: timeout(), %% 5 minutes
    opts = #{} :: map(), %% Options (interceptors) used to open every channel
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
-define(RETRY_INTERVAL, 5000).
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

-spec pick_channel(etcdgun:client() | pid()) ->
    {ok, egrpc:channel()} |
    {error, no_available_connection | term()}.
pick_channel(Client) ->
    %% eqwalizer:ignore
    gen_server:call(Client, pick_channel).

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
    %% The options of every channel. The transport of the members is the scheme of their client
    %% URLs, and `Transport' is the one of the endpoints which are given to connect to.
    Opts = (maps:with([interceptors, gun_opts], Opts0))#{
        call_credentials => fun etcdgun_interceptor_auth:call_credentials/1
    },
    maybe
        %% Authenticate first, the RPCs of getting the members and checking them require the token
        %% in etcd 3.6 and 3.7 when authentication is enabled.
        {ok, Members, Token} ?=
            get_member_list(Client, shuffle(Endpoints), Cred, with_transport(Opts, Transport)),
        {ok, Actives, Errors} ?= open_and_wait_members(Client, Members, Token, Opts, [], []),
        % {ok, _Pid} ?= etcdgun_membership:start_link(Client),
        ?LOG_INFO(#{
            msg =>"Connected to etcd",
            members => Members,
            actives => length(Actives),
            retryings => length(Errors)
        }),
        State = #state{
            name = Client,
            %% elp:ignore W0036
            members = maps:from_list([{Id, M} || #{'ID' := Id} = M <- Members]),
            actives = shuffle(Actives),
            membership_check_interval = MembershipCheckInterval,
            opts = Opts,
            membership_tref = undefined,
            token = Token,
            cred = Cred
        },
        {ok, start_membership_timer(start_retry_timer(publish_token(State)))}
    else
        {error, Reason} ->
            ?LOG_ERROR("Failed to connect to etcd endpoints: ~p, reason: ~p",
                       [Endpoints, Reason]),
            {stop, Reason}
    end.

handle_call(client_info, _From, State) ->
    Reply = #{
        name => State#state.name,
        pid => self(),
        actives => length(State#state.actives),
        connectings => length(State#state.connectings),
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

handle_call(pick_channel, _From, #state{actives = []} = State) ->
    {reply, {error, no_available_connection}, State};

handle_call(pick_channel, _From, #state{actives = [{_M, Channel, _MRef} = P | Rest]} = State) ->
    %% The token is not in the channel, the call credentials read the current one of the client.
    {reply, {ok, Channel}, State#state{actives = Rest ++ [P]}};

handle_call({update_cred, undefined}, _From, #state{cred = _Cred0} = State) ->
    ?LOG_INFO("Unset credentials for client ~p", [State#state.name]),
    {reply, ok, publish_token(State#state{cred = undefined, token = undefined,
                                          refresh_failed = undefined})};
handle_call({update_cred, {Username, _Password} = Cred}, _From, #state{cred = _Cred0} = State) ->
    case auth(State#state.actives, Cred) of
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
    {noreply, State, {continue, {do_sync_membership, NewMembers}}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, TRef, check_membership}, #state{membership_tref = TRef} = State) ->
    #state{name = Client} = State,
    Self = self(),
    spawn(
        fun() ->
            maybe
                {ok, Channel} ?= pick_channel(Self),
                {ok, Members} ?= do_get_member_list(Channel),
                Self ! {sync_membership, Members}
            else
                {error, Reason} ->
                    ?LOG_WARNING("Failed to check membership for client ~p: ~p", [Client, Reason])
            end
        end),
    {noreply, start_membership_timer(State#state{membership_tref = undefined})};
handle_info({timeout, TRef, retry}, #state{retry_tref = TRef} = State) ->
    {noreply, State#state{retry_tref = undefined}, {continue, do_retry}};

handle_info({gun_up, GunPid, http2}, State) ->
    %% TODO: check if the connected node is healthy
    {noreply, handle_gun_up(GunPid, State)};
handle_info({gun_down, GunPid, http2, Reason, _Streams}, State) ->
    {noreply, handle_gun_down(GunPid, Reason, State)};
handle_info({refreshed, Pid, Result}, #state{refreshing = #refresh{pid = Pid} = Refresh} = State) ->
    erlang:demonitor(Refresh#refresh.mref, [flush]),
    {noreply, finish_refresh(Result, State)};
handle_info({'DOWN', MRef, process, Pid, Reason},
            #state{refreshing = #refresh{pid = Pid, mref = MRef}} = State) ->
    ?LOG_ERROR("The refresh of the token of client ~p crashed: ~p", [State#state.name, Reason]),
    {noreply, finish_refresh({error, {refresh_crashed, Reason}}, State)};
handle_info({'DOWN', MRef, process, GunPid, Reason}, State) ->
    erlang:demonitor(MRef, [flush]),
    {noreply, handle_gun_down(GunPid, Reason, State)};

handle_info({token_renewed, Token}, State) ->
    {noreply, publish_token(State#state{token = Token})};

handle_info({check, Result, Elem}, State) ->
    {noreply, handle_check_result(Result, Elem, State)};

handle_info({sync_membership, NewMembers}, State) ->
    {noreply, State, {continue, {do_sync_membership, NewMembers}}};

handle_info(Info, State) ->
    ?LOG_WARNING("Received unexpected info message: ~p", [Info]),
    {noreply, State}.

handle_continue({do_sync_membership, NewMembers}, #state{members = OldMembers} = State) ->
    ?LOG_DEBUG("Syncing membership for client ~p with members: ~p",
               [State#state.name, NewMembers]),
    %% Remove channels that are no longer in the membership
    %% Add channels for new members
    {Unchanged, ToRemoves} = lists:partition(
        fun({Id0, #{clientURLs := Urls0} = _M}) ->
                lists:any(fun(#{'ID' := Id, clientURLs := Urls}) ->
                                  Id0 =:= Id andalso Urls0 =:= Urls
                          end, NewMembers)
        end, maps:to_list(OldMembers)),
    ToRemovesMap = maps:from_list(ToRemoves),
    Unchanged1 = maps:from_list(Unchanged),
    %% elp:ignore W0036
    NewMembersMap = maps:from_list([{Id, M} || #{'ID' := Id} = M <- NewMembers]),
    ToAdds = maps:without(maps:keys(Unchanged1), NewMembersMap),

    {ToRemoveActives, Actives1} = lists:partition(
        fun({Id, _Channel, _MRef}) -> is_map_key(Id, ToRemovesMap) end, State#state.actives),
    {ToRemoveConnectings, Connectings1} = lists:partition(
        fun({Id, _Channel, _MRef}) -> is_map_key(Id, ToRemovesMap) end, State#state.connectings),

    length(ToRemoves) > 0 andalso ?LOG_INFO("Removing etcd members: ~p",
                                              [maps:values(ToRemovesMap)]),
    maps:size(ToAdds) > 0 andalso ?LOG_INFO("Adding etcd members: ~p", [maps:values(ToAdds)]),

    [egrpc_stub:close(Channel) || {_, Channel, _} <- ToRemoveActives ++ ToRemoveConnectings],

    NewState = State#state{
        members = NewMembersMap,
        actives = Actives1,
        connectings = Connectings1
    },
    {noreply, NewState, {continue, do_retry}};

handle_continue(do_retry, #state{connectings = OldConnectings} = State) ->
    cancel_retry_timer(State),
    Retries0 = maps:keys(State#state.members) -- [Id || {Id, _, _MRef} <- State#state.actives],
    Retries = Retries0 -- [Id || {Id, _, _MRef} <- State#state.connectings],

    Connectings =
        case length(Retries) > 0 of
            true ->
                ?LOG_INFO("Retrying to connect to etcd members..."),
                RetriesMembers = maps:values(maps:with(Retries, State#state.members)),
                open_members(State#state.name, RetriesMembers, State#state.opts, []);
            false ->
                []
        end,
    State1 = State#state{connectings = OldConnectings ++ Connectings},
    {noreply, start_retry_timer(State1)}.

%% The state is in the crash reports and the output of `sys:get_status/1', without the secrets.
format_status(#{state := #state{} = State} = Status) ->
    Status#{state := State#state{cred = redact(State#state.cred), token = redact(State#state.token)}};
format_status(Status) ->
    Status.

redact(undefined) -> undefined;
redact(_Secret) -> '<redacted>'.

terminate(_Reason, #state{actives = Actives, connectings = Connectings} = State) ->
    ?LOG_NOTICE("Terminating etcdgun client, reason: ~p", [_Reason]),
    [ensure_close(Conn) || {_Id, _Channel, _MRef} = Conn <- Actives ++ Connectings],
    ets:delete(?TOKEN_TABLE, State#state.name),
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
start_refresh(From, #state{cred = Cred, actives = Actives} = State) ->
    Self = self(),
    {Pid, MRef} = spawn_monitor(fun() -> Self ! {refreshed, self(), auth(Actives, Cred)} end),
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

ensure_close({_Id, Channel, MRef}) ->
    erlang:demonitor(MRef, [flush]),
    egrpc_stub:close(Channel).

shuffle(List) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- List])].

start_retry_timer(State) ->
    TRef = erlang:start_timer(?RETRY_INTERVAL, self(), retry),
    State#state{retry_tref = TRef}.

%% `infinity' first: as a term, the atom is greater than any integer.
start_membership_timer(#state{membership_check_interval = infinity} = State) ->
    State;
start_membership_timer(#state{membership_check_interval = 0} = State) ->
    State;
start_membership_timer(#state{membership_check_interval = Interval} = State)
  when is_integer(Interval), Interval > 0 ->
    TRef = erlang:start_timer(Interval, self(), check_membership),
    State#state{membership_tref = TRef}.

cancel_retry_timer(#state{retry_tref = undefined}) -> ok;
cancel_retry_timer(#state{retry_tref = TRef}) -> erlang:cancel_timer(TRef).

%% Authenticate with the credentials and get the member list, return the token too.
get_member_list(_Client, [], _Cred, _Opts) -> {error, no_available_endpoints};
get_member_list(Client, [{Host, Port} | Rest], Cred, Opts) ->
    with_channel(Host, Port, Opts, fun(Channel) ->
        case authenticate_bootstrap(Channel, Cred) of
            {ok, Token} ->
                case do_get_member_list(with_token(Channel, Token)) of
                    {ok, []} ->
                        ?LOG_WARNING("No members found in etcd cluster at ~s:~p", [Host, Port]),
                        get_member_list(Client, Rest, Cred, Opts);
                    {ok, Members} -> {ok, Members, Token};
                    {error, Reason} ->
                        case is_auth_required(Token, Reason) of
                            true ->
                                {error, no_credentials};
                            false ->
                                ?LOG_WARNING("Failed to connect to etcd endpoint: ~s:~p, "
                                             "reason: ~p", [Host, Port, Reason]),
                                get_member_list(Client, Rest, Cred, Opts)
                        end
                end;
            {error, {etcd_error, _}} = Error ->
                %% Rejected by the server, e.g. wrong password, other endpoints will do the same.
                Error;
            {error, Reason} ->
                ?LOG_WARNING("Failed to authenticate on etcd endpoint: ~s:~p, reason: ~p",
                             [Host, Port, Reason]),
                get_member_list(Client, Rest, Cred, Opts)
        end
    end).

authenticate_bootstrap(Channel, Cred) ->
    case authenticate(Channel, Cred) of
        {error, {etcd_error, auth_not_enabled}} ->
            ?LOG_WARNING("Authentication is not enabled on the etcd server, skipping"),
            {ok, undefined};
        Result -> Result
    end.

%% Put the token into the channel info for a channel which is not the one of the client yet, the
%% call credentials send it with the requests.
with_token(Channel, undefined) -> Channel;
with_token(Channel, Token) ->
    OldInfo = egrpc_stub:info(Channel, #{}),
    %% eqwalizer:ignore
    NewInfo = OldInfo#{token => Token},
    egrpc_stub:derive(Channel, #{info => NewInfo}).

with_channel(Host, Port, Opts, Fun) ->
    maybe
        {ok, Channel} ?= open_and_wait(Host, Port, Opts),
        Result = Fun(Channel),
        egrpc_stub:close(Channel),
        Result
    end.

do_get_member_list(Channel) ->
    maybe
        {ok, #{members := Members}} ?= etcdgun_etcdserverpb_cluster_client:member_list(Channel, #{}),
        {ok, usable_members(Members)}
    end.

%% Learners do not serve normal requests, and members that were added but not started yet have no
%% client URLs, so none of them can be connected to.
usable_members(Members) ->
    [M || #{clientURLs := [_|_]} = M <- Members, not is_learner(M)].

is_learner(#{isLearner := IsLearner}) -> IsLearner =:= true orelse IsLearner =:= 1;
is_learner(#{}) -> false.

open_and_wait_members(_Client, [], _Token, _Opts, [], _Errors) ->
    {error, no_available_endpoints};
open_and_wait_members(_Client, [], _Token, _Opts, Success, Errors) -> {ok, Success, Errors};
open_and_wait_members(Client, [#{'ID' := Id} = Member | Rest], Token, Opts, Success, Errors) ->
    maybe
        #{clientURLs := [ClientUrl | _]} = Member,
        {ok, Host, Port, Transport} ?= parse_client_url(ClientUrl),
        ChannelOpts = (with_transport(Opts, Transport))#{info => #{client => Client}},
        {ok, Channel} ?= open_and_wait(Host, Port, ChannelOpts),
        ok ?= close_on_error(Channel, check_endpoint(with_token(Channel, Token))),
        GunPid = egrpc_stub:conn_pid(Channel),
        MRef = erlang:monitor(process, GunPid),
        open_and_wait_members(Client, Rest, Token, Opts, [{Id, Channel, MRef} | Success], Errors)
    else
        {error, Reason} ->
            case is_auth_required(Token, Reason) of
                true ->
                    %% The other members are the same, give up.
                    [ensure_close(Elem) || Elem <- Success],
                    {error, no_credentials};
                false ->
                    ?LOG_WARNING(#{msg =>"Failed to connect to etcd member",
                                   member => Member,
                                   reason => Reason}),
                    open_and_wait_members(Client, Rest, Token, Opts, Success, [Id | Errors])
            end
    end.

close_on_error(_Channel, ok) -> ok;
close_on_error(Channel, {error, _} = Error) ->
    egrpc_stub:close(Channel),
    Error.

%% The server requires the token, but there is no one, i.e. no credentials configured.
is_auth_required(undefined, {grpc_error, _, _} = Reason) ->
    is_auth_required(undefined, etcdgun_error:from_grpc_error(Reason));
is_auth_required(undefined, Reason) -> Reason =:= {etcd_error, user_empty};
is_auth_required(_Token, _Reason) -> false.

open_and_wait(Host, Port, Opts) ->
    maybe
        {ok, Channel} ?= egrpc_stub:open(Host, Port, Opts#{}),
        egrpc_stub:await_up(Channel)
    end.

open_members(_Client, [], _Opts, Result) -> Result;
open_members(Client, [#{'ID' := Id} = Member | Rest], Opts, Success) ->
    #{clientURLs := [ClientUrl | _]} = Member,
    maybe
        {ok, Host, Port, Transport} ?= parse_client_url(ClientUrl),
        ChannelOpts = (with_transport(Opts, Transport))#{info => #{client => Client}},
        {ok, Channel} ?= egrpc_stub:open(Host, Port, ChannelOpts),
        MRef = erlang:monitor(process, egrpc_stub:conn_pid(Channel)),
        open_members(Client, Rest, Opts, [{Id, Channel, MRef} | Success])
    end.

auth([], _Cred) -> {error, no_available_connection};
auth([{_MemberId, Channel, _MRef} | _], Cred) ->
    authenticate(Channel, Cred).

authenticate(_Channel, undefined) -> {ok, undefined};
authenticate(Channel, {Username, Password}) ->
    maybe
        Req = #{name => Username, password => Password},
        {ok, #{token := Token}} ?= etcdgun_etcdserverpb_auth_client:authenticate(Channel, Req),
        {ok, Token}
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

handle_check_result(Result, {MemberId, Channel, MRef} = Elem,
                    #state{connectings = Connectings} = State) ->
    maybe
        {value, {MemberId, Channel, MRef}, Rest} ?= lists:keytake(MemberId, 1, Connectings),
        State1 = State#state{connectings = Rest},
        {ok, _} ?= {Result, State1},
        ?LOG_INFO("Connection established for etcd member (~s) ~s:~p",
                  [hex(MemberId), egrpc_stub:host(Channel), egrpc_stub:port(Channel)]),
        State1#state{actives = [Elem | State#state.actives]}
    else
        {{error, Reason}, State2} ->
            ?LOG_WARNING("Failed to check endpoint for member (~s) ~s:~p, reason: ~p",
                         [hex(MemberId), egrpc_stub:host(Channel), egrpc_stub:port(Channel),
                          Reason]),
            %% It is not in any list anymore, so close it, or the connection is leaked and
            %% a new one is opened on the next retry.
            ensure_close(Elem),
            State2;
        false ->
            ?LOG_WARNING("Received check result for unknown connection: ~p", [Elem]),
            State
    end.

handle_gun_up(GunPid, #state{connectings = Connectings} = State) ->
    case lists:search(fun({_M, C, _MRef}) -> egrpc_stub:conn_pid(C) =:= GunPid end, Connectings) of
        {value, {_MemberId, Channel, _MRef} = Elem} ->
            Self = self(),
            #state{token = Token, cred = Cred} = State,
            spawn(fun() -> Self ! {check, check_connecting(Self, Channel, Token, Cred), Elem} end),
            State;
        false ->
            ?LOG_WARNING("Received gun_up for unknown connection: ~p", [GunPid]),
            State
    end.

handle_gun_down(GunPid, Reason, #state{actives = Actives, connectings = Connectings} = State) ->
    IsGun = fun({_M, C, _MRef}) -> egrpc_stub:conn_pid(C) =:= GunPid end,
    %% A connecting one may be down too, e.g. the member is down and gun gives up connecting.
    %% Drop it, or it stays in `connectings' and the member is never retried.
    case {lists:search(IsGun, Actives), lists:search(IsGun, Connectings)} of
        {{value, {_MemberId, Channel, _MRef} = Elem}, _} ->
            ?LOG_WARNING("Connection down for member ~s:~p, reason: ~p",
                         [egrpc_stub:host(Channel), egrpc_stub:port(Channel), Reason]),
            ensure_close(Elem),
            %% eqwalizer:ignore
            State#state{actives = lists:delete(Elem, Actives)};
        {false, {value, {_MemberId, Channel, _MRef} = Elem}} ->
            ?LOG_WARNING("Failed to connect to member ~s:~p, reason: ~p, will retry",
                         [egrpc_stub:host(Channel), egrpc_stub:port(Channel), Reason]),
            ensure_close(Elem),
            %% eqwalizer:ignore
            State#state{connectings = lists:delete(Elem, Connectings)};
        {false, false} ->
            State
    end.

%% Check a connecting channel with the token. If it fails, the token may be invalid, e.g. the member
%% was restarted and lost the token. Refreshing the token through the active channels does not work
%% when this is the only member, so authenticate on this channel and check again.
check_connecting(Client, Channel, Token, Cred) ->
    case check_endpoint(with_token(Channel, Token)) of
        {error, _} = Error when Cred =/= undefined ->
            maybe
                {ok, NewToken} ?= authenticate(Channel, Cred),
                ok ?= check_endpoint(with_token(Channel, NewToken)),
                Client ! {token_renewed, NewToken},
                ok
            else
                _ -> Error
            end;
        Result -> Result
    end.

check_endpoint(Channel) ->
    maybe
        ok ?= check_health(Channel),
        ok ?= check_leader(Channel),
        ok
    end.

check_health(Channel) ->
    case egrpc_grpc_health_v1_health_client:check(Channel, #{}) of
        {ok, #{status := 'SERVING'}} -> ok;
        {ok, #{status := 1}} -> ok;
        {ok, #{status := 'UNKNOWN'}} -> ok;
        {ok, #{status := 0}} -> ok;
        {ok, #{status := Status}} -> {error, {unhealthy, Status}};
        {error, Reason} -> {error, Reason}
    end.

check_leader(Channel) ->
    case etcdgun_etcdserverpb_maintenance_client:status(Channel, #{}) of
        {ok, #{leader := 0}} -> {error, no_leader};
        {ok, #{leader := LeaderId, errors := Errors}} when LeaderId > 0 ->
            case Errors of
                [] -> ok;
                _ ->
                    ?LOG_WARNING("Errors reported by etcd server: ~s", [lists:join("; ", Errors)])
            end,
            ok;
        {error, Reason} -> {error, Reason}
    end.

hex(I) when is_integer(I) ->
    binary:encode_hex(<<I:64>>, lowercase).

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
