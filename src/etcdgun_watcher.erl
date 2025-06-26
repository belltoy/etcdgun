-module(etcdgun_watcher).

-feature(maybe_expr, enable).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    create_watch_cache_table/0,
    start_link/4
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
    create_ref = undefined :: undefined | reference(),
    creatings = [] :: [WatchId :: integer()],
    watches = #{} :: #{WatchId :: integer() => Revision :: integer()},
    buf = <<>> :: binary()
}).

-define(WATCH_EVENT_EVENTS(Events), {watch_events, Events}).
-define(WATCH_EVENT_CANCELED, watch_canceled).
-define(WATCH_EVENT_STOPPED(Reason), {watch_stopped, Reason}).

-define(WATCH_CACHE_TABLE, etcdgun_watcher_cache).

-record(watcher_cache, {
    watcher_name :: atom(),
    last_revisions :: #{WatchId :: integer() => Revision :: integer()}
}).

%% TODO: Timeout, invalid auth token, reconnect, etc.

create_watch_cache_table() ->
    case ets:info(?WATCH_CACHE_TABLE) of
        undefined ->
            ets:new(?WATCH_CACHE_TABLE,
                [set, named_table, public,
                 {keypos, #watcher_cache.watcher_name},
                 {read_concurrency, true}]);
        _Info -> ok
    end.

start_link(Client, WatcherName, EventMgr, WatchRequests) ->
    Args = {Client, WatcherName, EventMgr, WatchRequests},
    gen_server:start_link({local, WatcherName}, ?MODULE, Args, []).

%%-------------------------------------------------------------------
%% gen_server callbacks
%%-------------------------------------------------------------------

init({Client, WatcherName, EventMgr, WatchRequests}) ->
    ?LOG_INFO("Starting watcher ~p for client ~p", [WatcherName, Client]),
    process_flag(trap_exit, true),
    maybe
        {ok, Channel} ?= etcdgun_client:pick_channel(Client),
        {ok, Stream} ?= etcdgun_etcdserverpb_watch_client:watch(Channel),

        %% Monitor the gun connection pid.
        ConnPid = egrpc_stub:conn_pid(Stream),
        MRef = erlang:monitor(process, ConnPid),

        WatchRequests1 = assign_watch_id(WatchRequests),
        %% Try to load last revision if the watcher is being restarted.
        WatchRequests2 = load_lasst_revision(WatcherName, WatchRequests1),
        %% Send the create request.
        % Stream1 = egrpc_stream:send_msg(Stream, WatchRequests1, nofin),
        Stream1 = send_watch_requests(Stream, WatchRequests2),

        %% Receive the response header
        {ok, Stream2} ?= recv_response_header(Stream1, 5000),

        TRef = erlang:start_timer(5000, self(), create_watch_timeout),
        WatchIds = [I || #{request_union := {create_request, #{watch_id := I}}} <- WatchRequests1],
        State = #state{
            client = Client,
            watcher_name = WatcherName,
            stream = Stream2,
            stream_ref = egrpc_stream:stream_ref(Stream2),
            monitor_ref = MRef,
            conn_pid = ConnPid,
            event_manager_pid = EventMgr,
            create_ref = TRef,
            creatings = WatchIds,
            buf = <<>>
        },
        {ok, State}
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

handle_info({timeout, TRef, create_watch_timeout},
            #state{create_ref = TRef, creatings = []} = State) ->
    {noreply, State#state{create_ref = undefined}};
handle_info({timeout, TRef, create_watch_timeout},
            #state{create_ref = TRef} = State) ->
    {stop, {create_error, timeout}, State#state{create_ref = undefined}};

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

handle_continue(process_data, #state{buf = Buf, stream = Stream} = State) ->
    case egrpc_stream:parse_msg(Stream, Buf) of
        more -> {noreply, State};
        {ok, Stream1, Msg, Rest} ->
            process_response(Msg, update_stream(Stream1, State#state{buf = Rest}))
    end.

terminate(Reason, State) ->
    case is_normal(Reason) of
        true -> ?LOG_INFO("Watcher terminating: ~p", [Reason]);
        false -> ?LOG_WARNING("Watcher terminating: ~p", [Reason])
    end,
    % is_normal(Reason) andalso cancel_watches(State),
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

send_watch_requests(Stream, []) -> Stream;
send_watch_requests(Stream, [Req | Rest]) ->
    %% Send the create request.
    ?LOG_DEBUG("Sending watch request: ~p", [Req]),
    Stream1 = egrpc_stream:send_msg(Stream, Req, nofin),
    send_watch_requests(Stream1, Rest).

recv_response_header(Stream, Timeout) ->
    Res = egrpc_stream:recv_header(Stream, Timeout),
    case Res of
        {error, _Reason} ->
            egrpc_stream:cancel_stream(Stream);
        _  -> ok
    end,
    Res.

process_response(#{created := true,
                   canceled := false,
                   watch_id := WatchId, header := #{revision := Rev}} = Response,
                 #state{creatings = Creatings, watches = Watches} = State) ->
    maybe
        true ?= lists:member(WatchId, State#state.creatings),
        ?LOG_INFO("Watcher ~p created watch with ID ~p, revision ~p",
                  [State#state.watcher_name, WatchId, Rev]),
        Rest = Creatings -- [WatchId],
        length(Rest) =:= 0 andalso ?LOG_INFO("All watches created for watcher ~p",
                                             [State#state.watcher_name]),
        {noreply, State#state{creatings = Rest, watches = Watches#{WatchId => Rev}}}
    else
        _ ->
            ?LOG_WARNING("Watcher ~p received unexpected create response: ~p",
                      [State#state.watcher_name, Response]),
            {noreply, State}
    end;
process_response(#{created := false, canceled := false, events := Events} = Response, State) ->
    #{watch_id := WatchId, header := #{revision := LastRev}} = Response,
    notify(?WATCH_EVENT_EVENTS(Events), State),
    update_last_revision(State#state.watcher_name, WatchId, LastRev),
    {noreply, State, {continue, process_data}};
process_response(#{created := false, canceled := true, watch_id := WatchId}, State) ->
    notify({?WATCH_EVENT_CANCELED, WatchId}, State),
    {stop, {shutdown, canceled}, State}.

notify(Event, #state{event_manager_pid = Pid}) when is_pid(Pid) ->
    gen_event:notify(Pid, Event).

cancel_stream(State) ->
    gun:cancel(State#state.conn_pid, State#state.stream_ref).

update_stream(Stream, #state{} = State) ->
    State#state{stream = Stream, stream_ref = egrpc_stream:stream_ref(Stream)}.

assign_watch_id(WatchRequests) ->
    lists:map(
        fun({WatchId, #{request_union := {create_request, Req}}}) when is_map(Req) ->
                Req1 = Req#{watch_id => WatchId},
                #{request_union => {create_request, Req1}}
        end, lists:enumerate(WatchRequests)).

% If the watcher was previously registered, we can start from the last revision.
% This is useful for resuming watches after a disconnect.
load_lasst_revision(WatcherName, WatchRequests) ->
    LastRevisions = case ets:lookup(?WATCH_CACHE_TABLE, WatcherName) of
                        [] -> #{};
                        [#watcher_cache{last_revisions = LastRevisions0}] -> LastRevisions0
                    end,
    lists:map(
        fun(#{request_union := {create_request, #{watch_id := WatchId} = Req}} = Req0) ->
                case maps:get(WatchId, LastRevisions, undefined) of
                    undefined -> Req0;
                    LastRevision ->
                        Req1 = Req#{start_revision => LastRevision + 1},
                        #{request_union => {create_request, Req1}}
                end
        end, WatchRequests).

update_last_revision(WatcherName, WatchId, LastRev) ->
    case ets:lookup(?WATCH_CACHE_TABLE, WatcherName) of
        [] ->
            Cache = #watcher_cache{watcher_name = WatcherName,
                                   last_revisions = #{WatchId => LastRev}},
            ets:insert(?WATCH_CACHE_TABLE, Cache);
        [#watcher_cache{last_revisions = LastRevisions} = Cache] ->
            NewLastRevisions = LastRevisions#{WatchId => LastRev},
            ets:insert(?WATCH_CACHE_TABLE, Cache#watcher_cache{last_revisions = NewLastRevisions})
    end,
    ok.
