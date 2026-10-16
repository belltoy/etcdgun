%% @private
%% @doc The keepalive of one lease: the process which keeps it, and tells how it ends.
%%
%% The stream is the one of the client (`etcdgun_lease_manager'), this process asks for a keepalive
%% at a third of the time to live, and ends with `{shutdown, lease_expired}' when the lease is gone.
-module(etcdgun_lease_keepalive).

-feature(maybe_expr, enable).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/3,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-record(state, {
    client :: etcdgun:client(),
    lease_id :: integer(),
    ttl :: undefined | pos_integer(),
    manager :: undefined | reference(),
    timer_ref :: undefined | reference(),
    %% The manager was lost, the lease is registered again.
    retry_ref :: undefined | reference(),
    revoke_when_shutdown = false :: boolean()
}).

-define(RETRY_INTERVAL, 1000).

-spec start_link(etcdgun:client(), LeaseId :: integer(), boolean()) -> gen_server:start_ret().
start_link(Client, LeaseId, RevokeWhenShutdown) ->
    gen_server:start_link(?MODULE, {Client, LeaseId, RevokeWhenShutdown}, []).

%%-------------------------------------------------------------------
%% gen_server callbacks
%%-------------------------------------------------------------------

init({Client, LeaseId, RevokeWhenShutdown}) ->
    process_flag(trap_exit, true),
    State = #state{client = Client, lease_id = LeaseId, revoke_when_shutdown = RevokeWhenShutdown},
    case register(State) of
        {ok, State1} ->
            ?LOG_NOTICE("Lease keepalive started for lease ~p with TTL ~p", [LeaseId, State1#state.ttl]),
            {ok, State1};
        {error, Reason} ->
            ?LOG_ERROR("Failed to start keepalive for lease ~p: ~p", [LeaseId, Reason]),
            %% `{error, _}' is not a return of init/1, it would hide the reason.
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% The time to live which the server says now.
handle_info({lease_keepalive, LeaseId, TTL}, #state{lease_id = LeaseId} = State) ->
    {noreply, State#state{ttl = TTL}};
handle_info({lease_expired, LeaseId}, #state{lease_id = LeaseId} = State) ->
    {stop, {shutdown, lease_expired}, State};

handle_info({timeout, TRef, keepalive}, #state{client = Client, lease_id = LeaseId, timer_ref = TRef} = State) ->
    etcdgun_lease_manager:keepalive(Client, LeaseId),
    {noreply, schedule(State)};

%% The manager is gone, with the stream: register again, a new one is started.
handle_info({'DOWN', MRef, process, _Pid, Reason}, #state{manager = MRef} = State) ->
    ?LOG_WARNING("Lease keepalive manager is gone: ~p", [Reason]),
    {noreply, retry(State)};
handle_info({timeout, TRef, retry}, #state{client = Client, retry_ref = TRef} = State) ->
    _ = etcdgun_lease_manager:ensure_started(Client),
    case register(State#state{retry_ref = undefined}) of
        {ok, State1} -> {noreply, State1};
        {error, lease_expired} -> {stop, {shutdown, lease_expired}, State};
        {error, Reason} ->
            ?LOG_WARNING("Lease keepalive can not register again: ~p", [Reason]),
            {noreply, retry(State)}
    end;

handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected message received in lease keepalive process: ~p", [Info]),
    {noreply, State}.

terminate(Reason, #state{client = Client, lease_id = LeaseId} = State) ->
    case is_normal(Reason) of
        true ->
            ?LOG_INFO("Terminating lease keepalive with reason: ~p", [Reason]),
            case State#state.revoke_when_shutdown of
                true ->
                    ?LOG_NOTICE("Revoking lease due to shutdown"),
                    revoke(State);
                false ->
                    ?LOG_NOTICE("Not revoking lease on shutdown")
            end;
        false ->
            ?LOG_ERROR("Terminating lease keepalive with reason: ~p", [Reason]),
            ok
    end,
    etcdgun_lease_manager:unregister_lease(Client, LeaseId).

%%-------------------------------------------------------------------
%% Private functions
%%-------------------------------------------------------------------
is_normal(normal) -> true;
is_normal(shutdown) -> true;
is_normal({shutdown, lease_expired}) -> false;
is_normal({shutdown, _}) -> true;
is_normal(_) -> false.

register(#state{client = Client, lease_id = LeaseId} = State) ->
    maybe
        {ok, TTL} ?= etcdgun_lease_manager:register_lease(Client, LeaseId, self()),
        MRef = erlang:monitor(process, etcdgun_lease_manager:name(Client)),
        {ok, schedule(State#state{ttl = TTL, manager = MRef})}
    end.

retry(#state{} = State) ->
    TRef = erlang:start_timer(?RETRY_INTERVAL, self(), retry),
    State#state{retry_ref = TRef}.

%% The next keepalive, at a third of the time to live.
schedule(#state{ttl = TTL, timer_ref = Old} = State) when is_integer(TTL) ->
    is_reference(Old) andalso erlang:cancel_timer(Old),
    After = erlang:max(TTL div 3, 1) * 1000,
    State#state{timer_ref = erlang:start_timer(After, self(), keepalive)}.

revoke(#state{client = Client, lease_id = LeaseId}) ->
    Req = #{'ID' => LeaseId},
    Res = case etcdgun_etcdserverpb_lease_stub:lease_revoke(Client, Req) of
        {ok, _} -> ok;
        {error, {etcd_error, lease_not_found}} -> ok;
        {error, R} -> R
    end,

    case Res of
        ok -> ?LOG_NOTICE("Lease ~p revoked successfully", [LeaseId]);
        Reason -> ?LOG_ERROR("Failed to revoke lease ~p: ~p", [LeaseId, Reason])
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

schedule_test() ->
    State = schedule(#state{ttl = 9, timer_ref = undefined}),
    ?assert(is_reference(State#state.timer_ref)),
    erlang:cancel_timer(State#state.timer_ref),
    %% a short time to live is still a second
    State1 = schedule(#state{ttl = 1, timer_ref = undefined}),
    ?assert(erlang:cancel_timer(State1#state.timer_ref) > 900).
-endif.
