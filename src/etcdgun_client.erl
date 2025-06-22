%% Connect to all etcd servers in a cluster, implementing the clientv3-grpc1.23
%% https://etcd.io/docs/v3.5/learning/design-client/#clientv3-grpc123-balancer-overview

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
    terminate/2
]).

-export([
    client_info/1,
    update_cred/3,
    unset_cred/1,
    pick_channel/1,
    refresh_token/1,
    sync_membership/2
]).

-type member() :: etcdgun_rpc_pb:'etcdserverpb.Member'().
-type member_id() :: non_neg_integer().

-record(state, {
    name :: atom(),
    members :: #{member_id() => member()},
    actives :: [{member_id(), egrpc:channel()}],
    connectings = [] :: [{member_id(), egrpc:channel()}],
    retry_tref = undefined :: undefined | reference(),
    token = undefined :: binary() | undefined,
    cred = undefined :: {binary(), binary()} | undefined
}).

-define(RETRY_INTERVAL, 5000).

client_info(Client) ->
    gen_server:call(Client, client_info).

-spec update_cred(etcdgun:client(), Username, Password) -> ok | {error, term()} when
    Username :: binary(),
    Password :: binary().
update_cred(Client, Username, Password) ->
    % eqwalizer:ignore
    gen_server:call(Client, {update_cred, {Username, Password}}).

-spec unset_cred(etcdgun:client()) -> ok.
unset_cred(Client) ->
    % eqwalizer:ignore
    gen_server:call(Client, {update_cred, undefined}).

-spec refresh_token(etcdgun:client()) ->
    {ok, NewToken :: binary()} | {error, no_credentials | auth_not_enabled | term()}.
refresh_token(Client) ->
    % eqwalizer:ignore
    gen_server:call(Client, refresh_token).

-spec pick_channel(etcdgun:client()) ->
    {ok, egrpc:channel()} |
    {error, no_available_connection | term()}.
pick_channel(Client) ->
    %% eqwalizer:ignore
    gen_server:call(Client, pick_channel).

-spec sync_membership(etcdgun:client(), [etcdgun_rpc_pb:'etcdserverpb.Member'()]) -> ok.
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
    logger:update_process_metadata(#{etcdgun_client => Client}),
    {Cred, Opts} = case maps:take(cred, Opts0) of
                       error -> {undefined, Opts0};
                       {Cred0, Rest} -> {Cred0, Rest}
                   end,
    maybe
        {ok, Members} ?= get_member_list(Client, shuffle(Endpoints), Opts),
        {ok, Actives, Errors} ?= open_and_wait_members(Client, Members, Opts, [], []),
        {ok, Token} ?=
            case auth(Actives, Cred) of
                {error, {etcd_error, auth_not_enabled}} ->
                    ?LOG_WARNING("Authentication is not enabled on the etcd server, skipping"),
                    {ok, undefined};
                R -> R
            end,
        {ok, _Pid} ?= etcdgun_membership:start_link(Client),
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
            actives = Actives,
            token = Token,
            cred = Cred
        },
        {ok, start_retry_timer(State)}
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
        token => State#state.token,
        cred => State#state.cred
    },
    {reply, {ok, Reply}, State};

handle_call(refresh_token, _From, #state{cred = undefined} = State) ->
    {reply, {error, no_credentials}, State};

handle_call(refresh_token, _From, #state{cred = {Username, Password}} = State) ->
    case auth(State#state.actives, {Username, Password}) of
        {ok, Token} ->
            {reply, {ok, Token}, State#state{token = Token}};
        {error, {etcd_error, auth_not_enabled}} ->
            ?LOG_WARNING("Authentication is not enabled on the etcd server, unsetting token"),
            {reply, {error, auth_not_enabled}, State#state{token = undefined}};
        {error, Reason} ->
            ?LOG_ERROR("Failed to refresh token for client ~p: ~p", [State#state.name, Reason]),
            {reply, {error, Reason}, State}
    end;

handle_call(pick_channel, _From, #state{actives = []} = State) ->
    {reply, {error, no_available_connection}, State};

handle_call(pick_channel, _From, #state{actives = [{_M, Channel} = P | Rest]} = State) ->
    Info1 = case {State#state.token, egrpc_stub:info(Channel, #{})} of
                {undefined, Info} -> Info;
                {Token, #{} = Info} -> Info#{token => Token}
            end,
    Channel1 = egrpc_stub:set_info(Channel, Info1),
    {reply, {ok, Channel1}, State#state{actives = Rest ++ [P]}};

handle_call({update_cred, undefined}, _From, #state{cred = _Cred0} = State) ->
    ?LOG_INFO("Unset credentials for client ~p", [State#state.name]),
    {reply, ok, State#state{cred = undefined, token = undefined}};
handle_call({update_cred, {Username, _Password} = Cred}, _From, #state{cred = _Cred0} = State) ->
    case auth(State#state.actives, Cred) of
        {ok, NewToken} ->
            ?LOG_INFO("Updated credentials for client ~p: ~p", [State#state.name, Username]),
            {reply, ok, State#state{cred = Cred, token = NewToken}};
        {error, {etcd_error, auth_not_enabled}} ->
            ?LOG_WARNING("Authentication is not enabled on the etcd server, "
                         "updated credentials and unset token"),
            {reply, ok, State#state{cred = Cred, token = undefined}};
        {error, Reason} ->
            ?LOG_ERROR("Failed to update credentials for client ~p: ~p",
                      [State#state.name, Reason]),
            {reply, {error, Reason}, State#state{cred = Cred, token = undefined}}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast({sync_membership, NewMembers}, #state{members = OldMembers} = State) ->
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
        fun({Id, _Channel}) -> is_map_key(Id, ToRemovesMap) end, State#state.actives),
    {ToRemoveConnectings, Connectings1} = lists:partition(
        fun({Id, _Channel}) -> is_map_key(Id, ToRemovesMap) end, State#state.connectings),

    length(ToRemoves) > 0 andalso ?LOG_INFO("Removing etcd members: ~p",
                                              [maps:values(ToRemovesMap)]),
    maps:size(ToAdds) > 0 andalso ?LOG_INFO("Adding etcd members: ~p", [maps:values(ToAdds)]),

    [egrpc_stub:close(Channel) || {_, Channel} <- ToRemoveActives ++ ToRemoveConnectings],

    NewState = State#state{
        members = NewMembersMap,
        actives = Actives1,
        connectings = Connectings1
    },
    {noreply, NewState, {continue, do_retry}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, TRef, retry}, #state{retry_tref = TRef} = State) ->
    {noreply, State#state{retry_tref = undefined}, {continue, do_retry}};

handle_info({gun_down, ConnPid, http2, Reason, _Streams},
            #state{actives = Actives} = State) ->
    case lists:search(fun({_M, C}) -> egrpc_stub:conn_pid(C) =:= ConnPid end, Actives) of
        {value, {_MemberId, Channel} = Elem} ->
            ?LOG_WARNING("Connection down for member ~s:~p, reason: ~p",
                         [egrpc_stub:host(Channel), egrpc_stub:port(Channel), Reason]),
            egrpc_stub:close(Channel),
            {noreply, State#state{
                %% eqwalizer:ignore
                actives = lists:delete(Elem, Actives)
            }};
        false ->
            {noreply, State}
    end;

handle_info({gun_up, ConnPid, http2}, #state{connectings = Connectings} = State) ->
    case lists:search(fun({_M, C}) -> egrpc_stub:conn_pid(C) =:= ConnPid end, Connectings) of
        {value, {_MemberId, Channel} = Elem} ->
            ?LOG_INFO("Connection established for etcd member ~s:~p",
                      [egrpc_stub:host(Channel), egrpc_stub:port(Channel)]),
            State1 = State#state{
                actives = [Elem | State#state.actives],
                %% eqwalizer:ignore
                connectings = lists:delete(Elem, Connectings)
            },
            {noreply, State1};
        false ->
            ?LOG_WARNING("Received gun_up for unknown connection: ~p", [ConnPid]),
            {noreply, State}
    end;

handle_info(Info, State) ->
    ?LOG_WARNING("Received unexpected info message: ~p", [Info]),
    {noreply, State}.

handle_continue(do_retry, #state{connectings = OldConnectings} = State) ->
    cancel_retry_timer(State),
    Retries0 = maps:keys(State#state.members) -- [Id || {Id, _} <- State#state.actives],
    Retries = Retries0 -- [Id || {Id, _} <- State#state.connectings],

    Connectings =
        case length(Retries) > 0 of
            true ->
                ?LOG_INFO("Retrying to connect to etcd members..."),
                RetriesMembers = maps:values(maps:with(Retries, State#state.members)),
                open_members(State#state.name, RetriesMembers, #{}, []);
            false ->
                []
        end,
    State1 = State#state{connectings = OldConnectings ++ Connectings},
    {noreply, start_retry_timer(State1)}.

terminate(_Reason, #state{actives = Actives, connectings = Connectings} = _State) ->
    ?LOG_NOTICE("Terminating etcdgun client, reason: ~p", [_Reason]),
    [egrpc_stub:close(Channel) || {_Id, Channel} <- Actives ++ Connectings],
    ok.

%%-------------------------------------------------------------------
%% Private functions
%%-------------------------------------------------------------------

shuffle(List) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- List])].

start_retry_timer(State) ->
    TRef = erlang:start_timer(?RETRY_INTERVAL, self(), retry),
    State#state{retry_tref = TRef}.

cancel_retry_timer(#state{retry_tref = undefined}) -> ok;
cancel_retry_timer(#state{retry_tref = TRef}) -> erlang:cancel_timer(TRef).

get_member_list(_Client, [], _Opts) -> {error, no_available_endpoints};
get_member_list(Client, [{Host, Port} | Rest], Opts) ->
    with_channel(Host, Port, Opts, fun(Channel) ->
        case etcdgun_membership:get_member_list(Channel) of
            {ok, []} ->
                ?LOG_WARNING("No members found in etcd cluster at ~s:~p", [Host, Port]),
                get_member_list(Client, Rest, Opts);
            {ok, Members} -> {ok, Members};
            {error, Reason} ->
                ?LOG_WARNING("Failed to connect to etcd endpoint: ~s:~p, reason: ~p",
                             [Host, Port, Reason]),
                get_member_list(Client, Rest, Opts)
        end
    end).

with_channel(Host, Port, Opts, Fun) ->
    maybe
        {ok, Channel} ?= open_and_wait(Host, Port, Opts),
        Result = Fun(Channel),
        egrpc_stub:close(Channel),
        Result
    end.

open_and_wait_members(_Client, [], _Opts, [], _Errors) -> {error, no_available_endpoints};
open_and_wait_members(_Client, [], _Opts, Success, Errors) -> {ok, Success, Errors};
open_and_wait_members(Client, [#{'ID' := Id} = Member | Rest], Opts, Success, Errors) ->
    maybe
        #{clientURLs := [ClientUrl | _]} = Member,
        {ok, Host, Port, _Transport} ?= parse_client_url(ClientUrl),
        {ok, Channel} ?= open_and_wait(Host, Port, Opts#{info => #{client => Client}}),
        open_and_wait_members(Client, Rest, Opts, [{Id, Channel} | Success], Errors)
    else
        {error, Reason} ->
            ?LOG_WARNING(#{msg =>"Failed to connect to etcd member",
                           member => Member,
                           reason => Reason}),
            open_and_wait_members(Client, Rest, Opts, Success, [Id | Errors])
    end.

open_and_wait(Host, Port, Opts) ->
    maybe
        {ok, Channel} ?= egrpc_stub:open(Host, Port, Opts),
        egrpc_stub:await_up(Channel)
    end.

open_members(_Client, [], _Opts, Result) -> Result;
open_members(Client, [#{'ID' := Id} = Member | Rest], Opts0, Success) ->
    #{clientURLs := [ClientUrl | _]} = Member,
    GunOpts0 = maps:get(gun_opts, Opts0, #{}),
    GunOpts1 = GunOpts0#{retry => 1, retry_fun => fun retry_fun/2},
    Opts = Opts0#{gun_opts => GunOpts1},
    maybe
        {ok, Host, Port, _Transport} ?= parse_client_url(ClientUrl),
        {ok, Channel} ?= egrpc_stub:open(Host, Port, Opts#{info => #{client => Client}}),
        open_members(Client, Rest, Opts, [{Id, Channel} | Success])
    end.

retry_fun(_Retries, _Opts) ->
    %% Alwasy return retries 1 means that we want gun retry to connect forever, until
    %% the member is removed from the cluster.
    #{retries => 1, timeout => 5000}.

auth(_Channels, undefined) -> {ok, undefined};
auth([{_MemberId, Channel} | _], {Username, Password}) ->
    maybe
        AuthRequest = #{name => Username, password => Password},
        {ok, #{token := Token}} ?= etcdgun_etcdserverpb_auth_service:authenticate(Channel, AuthRequest),
        {ok, Token}
    end.

parse_client_url(ClientUrl) when is_binary(ClientUrl) ->
    parse_client_url(binary_to_list(ClientUrl));
parse_client_url(ClientUrl) ->
    maybe
        #{host := Host, port := Port, scheme := Scheme} ?= uri_string:parse(ClientUrl),
        Transport ?= case Scheme of "http" -> tcp; "https" -> tls end,
        {ok, Host, Port, Transport}
    else
        _ -> {error, invalid_client_url}
    end.
