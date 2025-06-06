-module(etcdgun_watcher).

-feature(maybe_expr, enable).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/5,
    cancel/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2
]).

-record(state, {
    client :: atom(),
    watcher_name :: atom(),
    stream_ref :: reference(),
    stream :: egrpc:stream(),
    monitor_ref :: reference(),
    conn_pid :: pid(),
    event_manager_pid = undefined :: undefined | pid(),
    watch_id :: integer(),
    % retry_ref :: undefined | reference(),
    buf = <<>> :: binary()
}).

-define(WATCH_EVENT_EVENTS(Events), {watch_events, Events}).
-define(WATCH_EVENT_CANCELED, watch_canceled).
-define(WATCH_EVENT_STOPPED(Reason), {watch_stopped, Reason}).

%% TODO: Timeout, invalid auth token, reconnect, etc.

start_link(Client, WatcherName, EventHandler, EventHandlerArgs, WatchRequest) ->
    Args = {Client, WatcherName, EventHandler, EventHandlerArgs, WatchRequest},
    gen_server:start_link({local, WatcherName}, ?MODULE, Args, []).

cancel(Pid) ->
    gen_server:stop(Pid, {shutdown, cancel_watch}, infinity).

%%-------------------------------------------------------------------
%% gen_server callbacks
%%-------------------------------------------------------------------

init({Client, WatcherName, EventHandler, EventHandlerArgs, WatchRequest}) ->
    ?LOG_INFO("Starting watcher ~p for client ~p", [WatcherName, Client]),
    process_flag(trap_exit, true),
    maybe
        {ok, Channel} ?= etcdgun_client:pick_channel(Client),
        {ok, Stream} ?= etcdgun_etcdserverpb_watch_service:watch(Channel),

        %% Monitor the gun connection pid.
        ConnPid = egrpc_stub:conn_pid(Stream),
        MRef = erlang:monitor(process, ConnPid),

        %% Try to load last revision if the watcher is being restarted.
        WatchRequest1 = load_lasst_revision(WatcherName, WatchRequest),
        %% Send the create request.
        Stream1 = egrpc_stream:send(Stream, WatchRequest1, nofin),

        %% Receive the response header
        {ok, Stream2} ?= recv_response_header(Stream1, 5000),
        %% Receive the first reponse msg and check if the watcher was created successfully.
        {ok, Stream3, #{header := #{revision := Rev}, watch_id := WatchId}, Rest}
            ?= case recv_create_watch_response(Stream2, 5000, <<>>) of
                   {error, {create_error, Reason}} ->
                       {error, {create_error, Reason}};
                   Other -> Other
               end,
        ?LOG_INFO("Watcher ~p created with ID ~p, revision ~p", [WatcherName, WatchId, Rev]),
        State = #state{
            client = Client,
            watcher_name = WatcherName,
            stream = Stream3,
            stream_ref = egrpc_stream:stream_ref(Stream3),
            monitor_ref = MRef,
            conn_pid = ConnPid,
            watch_id = WatchId,
            buf = Rest
        },
        {ok, State, {continue, {register_event_manager, EventHandler, EventHandlerArgs, Rev}}}
    else
        {error, Reason3} ->
            ?LOG_ERROR("Failed to start watcher: ~p", [Reason3]),
            timer:sleep(1000), %% Give some time for the watcher to be canceled properly
            {stop, Reason3}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unexpected_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({gun_data, _ConnPid, StreamRef, nofin, Data},
            #state{stream_ref = StreamRef, buf = Buf} = State) ->
    {noreply, State#state{buf = <<Buf/binary, Data/binary>>}, {continue, process_data}};
handle_info({gun_data, _ConnPid, StreamRef, fin, _Data}, #state{stream_ref = StreamRef} = State) ->
    {stop, {grpc_error, eos}, State};
handle_info({gun_trailers, _ConnPid, StreamRef, _Trailers},
            #state{stream_ref = StreamRef} = State) ->
    {stop, {grpc_error, eos}, State};
handle_info({gun_error, _ConnPid, StreamRef, Reason},
            #state{stream_ref = StreamRef} = State) ->
    {stop, {stream_error, Reason}, State};
handle_info({gun_error, ConnPid, Reason}, #state{conn_pid = ConnPid} = State) ->
    {stop, {connection_error, Reason}, State};

handle_info({'DOWN', MRef, process, ConnPid, Reason}, #state{monitor_ref = MRef} = State) ->
    ?LOG_WARNING("Connection ~p down: ~p", [ConnPid, Reason]),
    {stop, {down, Reason}, State};

handle_info({'EXIT', Pid, Reason}, State) ->
    ?LOG_WARNING("Got exit message from ~p: ~p", [Pid, Reason]),
    {stop, Reason, State};

handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

handle_continue(
    {register_event_manager, EventHandler, EventHandlerArgs, Rev},
    #state{watcher_name = WatcherName, conn_pid = ConnPid, stream_ref = StreamRef} = State
) ->
    case register_watcher(WatcherName, ConnPid, StreamRef,
                          EventHandler, EventHandlerArgs, Rev) of
        {ok, EventManagerPid} ->
            ?LOG_INFO("Watcher ~p registered with event manager ~p",
                      [WatcherName, EventManagerPid]),
            {noreply, State#state{event_manager_pid = EventManagerPid}};
        {error, Reason} ->
            ?LOG_ERROR("Failed to register watcher ~p: ~p", [WatcherName, Reason]),
            {stop, {register_event_manager_failed, Reason}, State}
    end;
handle_continue(process_data, #state{buf = Buf, stream = Stream} = State) ->
    case egrpc_stream:parse_msg(Stream, Buf) of
        more -> {noreply, State};
        {ok, Stream1, Msg, Rest} ->
            process_response(Msg, update_stream(Stream1, State#state{buf = Rest}))
    end.

terminate(Reason, State) ->
    is_normal(Reason) andalso ?LOG_INFO("Watcher terminating: ~p", [Reason]),
    is_normal(Reason) orelse ?LOG_WARNING("Watcher terminating: ~p", [Reason]),
    is_normal(Reason) andalso cancel_watch(State),
	erlang:demonitor(State#state.monitor_ref, [flush]),
    cancel_stream(State),
    notify(?WATCH_EVENT_STOPPED(Reason), State),
    ok.

%%-------------------------------------------------------------------
%% Private functions
%%-------------------------------------------------------------------

is_normal(normal) -> true;
is_normal(shutdown) -> true;
is_normal({shutdown, _}) -> true;
is_normal(_) -> false.

recv_response_header(Stream, Timeout) ->
    Res = egrpc_stream:recv_response_header(Stream, Timeout),
    case Res of
        {error, _Reason} ->
            egrpc_stream:cancel_stream(Stream);
        _  -> ok
    end,
    Res.

recv_create_watch_response(Stream, Timeout, Acc) ->
    Res = case egrpc_stream:recv(Stream, Timeout, Acc) of
              {ok, _Stream1, _, _Rest} = R -> R;
              {error, Reason} ->
                  ?LOG_ERROR("Failed to receive response header: ~p", [Reason]),
                  {error, Reason}
          end,
    erlang:element(1, Res) =/= ok andalso egrpc_stream:cancel_stream(Stream),
    Res.

cancel_watch(#state{stream = Stream} = State) ->
    CancelRequest = #{request_union =>
                      {cancel_request, #{watch_id => State#state.watch_id}}
                     },
    Stream1 = egrpc_stream:send(Stream, CancelRequest, nofin),
    Stream2 = egrpc_stream:close_send(Stream1),
    await_cancel_response(update_stream(Stream2, State)).

await_cancel_response(#state{buf = Buf, stream = Stream} = State) ->
    maybe
        {ok, Stream1, Msg, Rest} ?= egrpc_stream:recv(Stream, 5000, Buf),
        case process_response(Msg, update_stream(Stream1, State#state{buf = Rest})) of
            {noreply, State1, {continue, process_data}} ->
                await_cancel_response(State1);
            {stop, {shutdown, canceled}, _State1} ->
                ok
        end
    end.

process_response(#{created := false, canceled := false, events := Events} = Response, State) ->
    #{header := #{revision := LastRev}} = Response,
    true = etcdgun_watcher_manager:update_last_revision(State#state.watcher_name, LastRev),
    notify(?WATCH_EVENT_EVENTS(Events), State),
    {noreply, State, {continue, process_data}};
process_response(#{created := false, canceled := true}, State) ->
    notify(?WATCH_EVENT_CANCELED, State),
    {stop, {shutdown, canceled}, State}.

notify(Event, #state{event_manager_pid = Pid}) when is_pid(Pid) ->
    gen_event:notify(Pid, Event).

cancel_stream(State) ->
    gun:cancel(State#state.conn_pid, State#state.stream_ref).

update_stream(Stream, #state{} = State) ->
    State#state{stream = Stream, stream_ref = egrpc_stream:stream_ref(Stream)}.

load_lasst_revision(WatcherName,
                    #{request_union := {create_request, WatchCreateRequest}} = WatchRequest) ->
    StartRevision0 = maps:get(start_revision, WatchCreateRequest, 0),
    StartRevision = case etcdgun_watcher_manager:last_revision(WatcherName) of
                        undefined -> StartRevision0;
                        LastRev -> LastRev + 1
                    end,
    WatchCreateRequest1 = WatchCreateRequest#{start_revision => StartRevision},
    WatchRequest#{request_union => {create_request, WatchCreateRequest1}}.

register_watcher(WatcherName, ConnPid, StreamRef, EventHandler, EventHandlerArgs, Rev) ->
    Res = etcdgun_watcher_manager:register_watcher(WatcherName, ConnPid, StreamRef,
                                                   EventHandler, EventHandlerArgs, Rev),
    case Res of
        {ok, _} = Ok -> Ok;
        {error, _Reason} = E ->
            gun:cancel(ConnPid, StreamRef),
            E
    end.
