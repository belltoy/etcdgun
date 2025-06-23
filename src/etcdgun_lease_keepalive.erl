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
    handle_continue/2,
    terminate/2
]).

-record(state, {
    client :: etcdgun:client(),
    conn_pid :: pid(),
    channel :: egrpc:channel(),
    stream :: egrpc:stream(),
    stream_ref :: reference(),
    lease_id :: integer(),
    monitor_ref :: reference(),
    timer_ref :: undefined | reference(),
    retry_ref :: undefined | reference(),
    revoke_when_shutdown = false :: boolean(),
    buf = <<>> :: binary()
}).

-spec start_link(etcdgun:client(), LeaseId :: integer(), boolean()) -> gen_server:start_ret().
start_link(Client, LeaseId, RevokeWhenShutdown) ->
    gen_server:start_link(?MODULE, {Client, LeaseId, RevokeWhenShutdown}, []).

%%-------------------------------------------------------------------
%% gen_server callbacks
%%-------------------------------------------------------------------

init({Client, LeaseId, RevokeWhenShutdown}) ->
    process_flag(trap_exit, true),
    case new_request(Client, LeaseId, RevokeWhenShutdown) of
        {ok, State} -> {ok, State};
        {error, Reason} ->
            ?LOG_ERROR("Failed to start keepalive for lease ~p: ~p", [LeaseId, Reason]),
            {error, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, TRef, retry}, #state{client = Client, retry_ref = TRef} = State) ->
    case new_request(Client, State#state.lease_id, State#state.revoke_when_shutdown) of
        {ok, NewState} -> {noreply, NewState};
        {error, lease_expired} ->
            {stop, {shutdown, lease_expired}, State};
        {error, Reason} ->
            {noreply, State#state{retry_ref = undefined}, {continue, {retry, Reason}}}
    end;
handle_info({timeout, TRef, keepalive}, #state{lease_id = LeaseId, timer_ref = TRef} = State) ->
    Request = #{'ID' => LeaseId},
    Stream1 = egrpc_stream:send_msg(State#state.stream, Request, nofin),
    {noreply, State#state{timer_ref = undefined, stream = Stream1}};

%% Receive messages from the Gun connection
handle_info({gun_data, _ConnPid, StreamRef, nofin, Data},
            #state{stream_ref = StreamRef, buf = Buf} = State) ->
    {noreply, State#state{buf = <<Buf/binary, Data/binary>>}, {continue, process_data}};
handle_info({gun_data, _ConnPid, StreamRef, fin, _Data}, #state{stream_ref = StreamRef} = State) ->
    {noreply, State, {continue, {retry, {grpc_error, eos}}}};
handle_info({gun_trailers, _ConnPid, StreamRef, _Trailers},
            #state{stream_ref = StreamRef} = State) ->
    %% When there is no leader
    {noreply, State, {continue, {retry, {grpc_error, eos}}}};
handle_info({gun_error, _ConnPid, StreamRef, Reason},
            #state{stream_ref = StreamRef} = State) ->
    {noreply, State, {continue, {retry, {stream_error, Reason}}}};
handle_info({gun_error, ConnPid, Reason}, #state{conn_pid = ConnPid} = State) ->
    {noreply, State, {continue, {retry, {connection_error, Reason}}}};
handle_info({gun_down, _GunPid, http2, Reason, _Streams}, State) ->
    {noreply, State, {continue, {retry, {connection_down, Reason}}}};
handle_info({'DOWN', MRef, process, ConnPid, Reason},
            #state{conn_pid = ConnPid, monitor_ref = MRef} = State) ->
    {noreply, State, {continue, {retry, {connection_down, Reason}}}};

handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected message received in lease keepalive process: ~p", [Info]),
    {noreply, State}.

handle_continue({retry, Reason}, #state{retry_ref = undefined} = State) ->
    gun:cancel(State#state.conn_pid, State#state.stream_ref),
    ?LOG_WARNING("Lease keepalive error: ~p, retry", [Reason]),
    TRef = erlang:start_timer(1000, self(), retry),
    {noreply, cancel_scheduler(State#state{retry_ref = TRef})};
handle_continue({retry, _Reason}, State) ->
    {noreply, State};
handle_continue(process_data, #state{buf = Buf, stream = Stream} = State) ->
    case egrpc_stream:parse_msg(Stream, Buf) of
        more -> {noreply, State};
        {error, Reason} ->
            {noreply, State, {continue, {retry, {grpc_error, Reason}}}};
        {ok, Stream1, #{'ID' := _LeaseId, 'TTL' := TTL}, Rest} when TTL > 0 ->
            case schedule_keepalive(TTL) of
                {ok, TRef} ->
                    {noreply, State#state{buf = Rest, stream = Stream1, timer_ref = TRef}};
                {error, lease_expired} ->
                    {stop, {shutdown, lease_expired}, State}
            end;
        {ok, _Stream1, _Resp, _Rest} ->
            {stop, {shutdown, lease_expired}, State}
    end.

terminate(Reason, #state{stream = Stream} = State) ->
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
    Stream1 = egrpc_stream:close_send(Stream),
    egrpc_stream:cancel_stream(Stream1),
    ok.

%%-------------------------------------------------------------------
%% Private functions
%%-------------------------------------------------------------------
is_normal(normal) -> true;
is_normal(shutdown) -> true;
is_normal({shutdown, lease_expired}) -> false;
is_normal({shutdown, _}) -> true;
is_normal(_) -> false.

revoke(#state{channel = Channel, lease_id = LeaseId} = State) ->
    Req = #{'ID' => State#state.lease_id},
    Res = case etcdgun_etcdserverpb_lease_client:lease_revoke(Channel, Req) of
        {ok, _} -> ok;
        {error, {etcd_error, lease_not_found}} -> ok;
        {error, R} -> R
    end,

    case Res of
        ok -> ?LOG_NOTICE("Lease ~p revoked successfully", [LeaseId]);
        Reason -> ?LOG_ERROR("Failed to revoke lease ~p: ~p", [LeaseId, Reason])
    end.

recv_create_response(Client, LeaseId, Stream, Channel, RevokeWhenShutdown) ->
    ConnPid = egrpc_stub:conn_pid(Stream),
    MRef = monitor(process, ConnPid),
    maybe
        {ok, Stream1} ?= egrpc_stream:recv_header(Stream, 1000),
        Res = egrpc_stream:recv_msg(Stream1, 1000, <<>>),
        {ok, Stream2, #{'ID' := LeaseId, 'TTL' := TTL}, Rest} ?= Res,
        {ok, TRef} ?= schedule_keepalive(TTL),
        ?LOG_NOTICE("Lease keepalive started for lease ~p with TTL ~p", [LeaseId, TTL]),
        {ok, #state{
            client = Client,
            channel = Channel,
            conn_pid = ConnPid,
            stream_ref = egrpc_stream:stream_ref(Stream2),
            stream = Stream2,
            lease_id = LeaseId,
            monitor_ref = MRef,
            timer_ref = TRef,
            revoke_when_shutdown = RevokeWhenShutdown,
            buf = Rest
        }}
    else
        E ->
            egrpc_stream:cancel_stream(Stream),
            erlang:demonitor(MRef, [flush]),
            E
    end.

new_request(Client, LeaseId, RevokeWhenShutdown) ->
    maybe
        {ok, Channel} ?= pick_channel(Client),
        {ok, Stream} ?= etcdgun_etcdserverpb_lease_client:lease_keep_alive(Channel),
        Stream1 = egrpc_stream:send_msg(Stream, #{'ID' => LeaseId}, nofin),
        recv_create_response(Client, LeaseId, Stream1, Channel, RevokeWhenShutdown)
    end.

pick_channel(Client) ->
    try
        etcdgun_client:pick_channel(Client)
    catch
        exit:{noproc, _} ->
            {error, client_not_running}
    end.

-spec schedule_keepalive(pos_integer()) -> {ok, reference()} | {error, lease_expired}.
schedule_keepalive(TTL) when is_integer(TTL), TTL > 0 ->
    %% eqwalizer:ignore
    After = erlang:max(round(TTL / 3), 1) * 1000,
    {ok, erlang:start_timer(After, self(), keepalive)};
schedule_keepalive(_TTL) ->
    {error, lease_expired}.

cancel_scheduler(#state{timer_ref = undefined} = State) ->
    State;
cancel_scheduler(#state{timer_ref = TRef} = State) when is_reference(TRef) ->
    erlang:cancel_timer(TRef),
    State#state{timer_ref = undefined}.
