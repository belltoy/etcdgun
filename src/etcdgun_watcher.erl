%% @private
-module(etcdgun_watcher).

-feature(maybe_expr, enable).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    create_watch_cache_table/0,
    delete_last_revisions/1,
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

%% The fields of the stream are `undefined' while the watcher is not connected, it retries.
-record(state, {
    client :: atom(),
    watcher_name :: atom(),
    requests :: [map()],
    connect_ref = undefined :: undefined | reference(),
    stream_ref = undefined :: undefined | reference(),
    stream = undefined :: undefined | egrpc:stream(),
    monitor_ref = undefined :: undefined | reference(),
    conn_pid = undefined :: undefined | pid(),
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
-define(CONNECT_RETRY_INTERVAL, 1000).

-record(watcher_cache, {
    watcher_name :: atom(),
    last_revisions :: #{WatchId :: integer() => Revision :: integer()}
}).

%% TODO: Timeout, invalid auth token, reconnect, etc.

%% @doc Forget the last revisions of the watcher.
-spec delete_last_revisions(atom()) -> ok.
delete_last_revisions(WatcherName) ->
    true = ets:delete(?WATCH_CACHE_TABLE, WatcherName),
    ok.

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
    State = #state{
        client = Client,
        watcher_name = WatcherName,
        requests = assign_watch_id(WatchRequests),
        event_manager_pid = EventMgr
    },
    %% The first attempt is made here, so that the watch is created when `etcdgun:watch/5'
    %% returns, as a put right after it is expected to be seen. When it fails the watcher stays
    %% and retries, as a failed start would be restarted at once by the supervisor, again and
    %% again, which is why it slept here before (blocking the supervisor).
    {ok, try_connect(State)}.

try_connect(State) ->
    case connect(State) of
        {ok, State1} ->
            State1;
        {error, Reason} ->
            ?LOG_WARNING("Watcher ~p failed to connect: ~p, retry",
                         [State#state.watcher_name, Reason]),
            TRef = erlang:start_timer(?CONNECT_RETRY_INTERVAL, self(), connect),
            State#state{connect_ref = TRef}
    end.

%% Open the watch stream and send the create requests.
connect(#state{client = Client, watcher_name = WatcherName, requests = Requests} = State) ->
    maybe
        {ok, Channel} ?= pick_channel(Client),
        {ok, Stream} ?= etcdgun_etcdserverpb_watch_client:watch(Channel),
        %% Load the last revisions if the watcher is being restarted.
        WatchRequests = load_last_revision(WatcherName, Requests),
        case create_watches(Stream, WatchRequests) of
            {ok, Stream1} ->
                %% Monitor the gun connection pid.
                ConnPid = egrpc_stub:conn_pid(Stream1),
                MRef = erlang:monitor(process, ConnPid),
                TRef = erlang:start_timer(5000, self(), create_watch_timeout),
                WatchIds =
                    [I || #{request_union := {create_request, #{watch_id := I}}} <- Requests],
                {ok, State#state{
                    stream = Stream1,
                    stream_ref = egrpc_stream:stream_ref(Stream1),
                    monitor_ref = MRef,
                    conn_pid = ConnPid,
                    create_ref = TRef,
                    creatings = WatchIds,
                    buf = <<>>
                }};
            {error, _} = Error ->
                egrpc_stream:cancel_stream(Stream),
                Error
        end
    end.

%% Send the create requests, and receive the response header.
create_watches(Stream, WatchRequests) ->
    maybe
        {ok, Stream1} ?= send_watch_requests(Stream, WatchRequests),
        egrpc_stream:recv_header(Stream1, 5000)
    end.

pick_channel(Client) ->
    try
        etcdgun_client:pick_channel(Client)
    catch
        exit:{noproc, _} -> {error, client_not_running}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unexpected_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, TRef, connect}, #state{connect_ref = TRef} = State) ->
    {noreply, try_connect(State#state{connect_ref = undefined})};

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

handle_continue(process_data, State) ->
    process_data(State, fun egrpc_stream:parse_msg/2).

%% Handle the next response of the buffer. Every clause of the handling of a response continues
%% with this, or the responses which are in the buffer with it wait for the next data.
process_data(#state{buf = Buf, stream = Stream} = State, ParseMsg) ->
    case ParseMsg(Stream, Buf) of
        more -> {noreply, State};
        {error, Reason} -> {stop, {grpc_error, Reason}, State};
        {ok, Stream1, Msg, Rest} ->
            process_response(Msg, update_stream(Stream1, State#state{buf = Rest}))
    end.

terminate(Reason, State) ->
    case is_normal(Reason) of
        true -> ?LOG_INFO("Watcher terminating: ~p", [Reason]);
        false -> ?LOG_WARNING("Watcher terminating: ~p", [Reason])
    end,
    % is_normal(Reason) andalso cancel_watches(State),
    is_reference(State#state.monitor_ref) andalso erlang:demonitor(State#state.monitor_ref, [flush]),
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

send_watch_requests(Stream, []) -> {ok, Stream};
send_watch_requests(Stream, [Req | Rest]) ->
    %% Send the create request.
    ?LOG_DEBUG("Sending watch request: ~p", [Req]),
    maybe
        {ok, Stream1} ?= egrpc_stream:send_msg(Stream, Req, nofin),
        send_watch_requests(Stream1, Rest)
    end.

process_response(#{created := true,
                   canceled := false,
                   watch_id := WatchId, header := #{revision := Rev}} = Response,
                 #state{creatings = CreatingWatches, watches = Watches} = State) ->
    maybe
        true ?= lists:member(WatchId, State#state.creatings),
        ?LOG_INFO("Watcher ~p created watch with ID ~p, revision ~p",
                  [State#state.watcher_name, WatchId, Rev]),
        Rest = CreatingWatches -- [WatchId],
        length(Rest) =:= 0 andalso ?LOG_INFO("All watches created for watcher ~p",
                                             [State#state.watcher_name]),
        {noreply, State#state{creatings = Rest, watches = Watches#{WatchId => Rev}},
         {continue, process_data}}
    else
        _ ->
            ?LOG_WARNING("Watcher ~p received unexpected create response: ~p",
                      [State#state.watcher_name, Response]),
            {noreply, State, {continue, process_data}}
    end;
process_response(#{canceled := true} = Response, State) ->
    canceled(Response, State);
process_response(#{created := false, canceled := false, watch_id := WatchId} = Response, State) ->
    %% A progress notification has no events, there is nothing to tell the handler.
    case maps:get(events, Response, []) of
        [] -> ok;
        Events -> notify(?WATCH_EVENT_EVENTS(Events), State)
    end,
    update_last_revision(State#state.watcher_name, WatchId, last_revision(Response)),
    {noreply, State, {continue, process_data}};
process_response(Response, State) ->
    %% Whatever else, e.g. a response of a watch which was not created, must not stall the
    %% messages which are in the buffer.
    ?LOG_WARNING("Watcher ~p received unexpected response: ~p",
                 [State#state.watcher_name, Response]),
    {noreply, State, {continue, process_data}}.

%% The server cancels a watch, when it was cancelled by the request, or when it is not allowed:
%% the token is not valid, e.g. after a restart of the members, for a streaming request there is
%% no interceptor which refreshes it. Refresh it and stop, the supervisor restarts the watcher,
%% which creates the watches again with the new token.
canceled(#{cancel_reason := Reason} = Response, #state{client = Client} = State)
  when is_binary(Reason), Reason =/= <<>> ->
    case is_auth_error(Reason) of
        true ->
            ?LOG_WARNING("Watcher ~p was refused: ~s, refresh the token and restart",
                         [State#state.watcher_name, Reason]),
            _ = refresh_token(Client),
            {stop, {watch_error, invalid_auth_token}, State};
        false ->
            canceled_by_request(Response, State)
    end;
canceled(Response, State) ->
    canceled_by_request(Response, State).

canceled_by_request(#{watch_id := WatchId}, State) ->
    notify({?WATCH_EVENT_CANCELED, WatchId}, State),
    {stop, {shutdown, canceled}, State}.

is_auth_error(Reason) ->
    lists:any(fun(Text) -> binary:match(Reason, Text) =/= nomatch end,
              [<<"invalid auth token">>, <<"user name is empty">>,
               <<"revision of auth store is old">>]).

refresh_token(Client) ->
    try
        etcdgun_client:refresh_token(Client)
    catch
        exit:_ -> {error, client_not_running}
    end.

%% The revision to resume from, after the one which is returned. The header of a response of a
%% watch which catches up (is not synced yet) has the current revision of the store, which is
%% greater than the events in it, so it must not be used with events: the events in between would
%% be skipped. The header of a response without events (a progress notification) says that
%% everything up to it was sent.
-spec last_revision(map()) -> integer().
last_revision(#{events := [_ | _] = Events}) ->
    lists:max([maps:get(mod_revision, Kv, 0) || #{kv := Kv} <- Events]);
last_revision(#{header := #{revision := Revision}}) ->
    Revision.

notify(Event, #state{event_manager_pid = Pid}) when is_pid(Pid) ->
    gen_event:notify(Pid, Event).

cancel_stream(#state{conn_pid = ConnPid, stream_ref = StreamRef})
  when is_pid(ConnPid), is_reference(StreamRef) ->
    gun:cancel(ConnPid, StreamRef);
cancel_stream(#state{}) ->
    ok.

%% The reference of the stream does not change, the stream is the state of the interceptors.
update_stream(Stream, #state{} = State) ->
    State#state{stream = Stream}.

assign_watch_id(WatchRequests) ->
    lists:map(
        fun({WatchId, #{request_union := {create_request, Req}}}) when is_map(Req) ->
                Req1 = Req#{watch_id => WatchId},
                #{request_union => {create_request, Req1}}
        end, lists:enumerate(WatchRequests)).

% If the watcher was previously registered, we can start from the last revision.
% This is useful for resuming watches after a disconnect.
load_last_revision(WatcherName, WatchRequests) ->
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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

is_auth_error_test() ->
    ?assert(is_auth_error(<<"rpc error: code = Unauthenticated desc = etcdserver: invalid auth token">>)),
    ?assert(is_auth_error(<<"etcdserver: user name is empty">>)),
    ?assert(is_auth_error(<<"etcdserver: revision of auth store is old">>)),
    ?assertNot(is_auth_error(<<"etcdserver: mvcc: required revision has been compacted">>)),
    ?assertNot(is_auth_error(<<>>)).

%% The responses of one data chunk are all handled: the handling of a response ends with a
%% continue, until the buffer has no complete message.
process_data_handles_all_responses_test() ->
    Created = fun(Id) ->
        #{created => true, canceled => false, watch_id => Id, header => #{revision => 10 + Id}}
    end,
    Frame = fun(Term) -> Bin = term_to_binary(Term), <<(byte_size(Bin)):32, Bin/binary>> end,
    %% The decoding is not what is tested, the messages are terms with a length.
    Parse = fun(_Stream, <<Len:32, Bin:Len/binary, Rest/binary>>) ->
                    {ok, stream, binary_to_term(Bin), Rest};
               (_Stream, _Buf) ->
                    more
            end,
    Buf = iolist_to_binary([Frame(Created(Id)) || Id <- [1, 2, 3]]),
    State = #state{
        client = c, watcher_name = w, requests = [],
        stream = stream, creatings = [1, 2, 3], buf = Buf
    },
    Drain = fun Drain(S) ->
        case process_data(S, Parse) of
            {noreply, S1, {continue, process_data}} -> Drain(S1);
            {noreply, S1} -> S1
        end
    end,
    Final = Drain(State),
    ?assertEqual([], Final#state.creatings),
    ?assertEqual(#{1 => 11, 2 => 12, 3 => 13}, Final#state.watches),
    ?assertEqual(<<>>, Final#state.buf),
    %% a response which is not understood does not stall the ones after it
    Odd = iolist_to_binary([Frame(#{something => other}), Frame(Created(1))]),
    Final1 = Drain(State#state{creatings = [1], buf = Odd}),
    ?assertEqual([], Final1#state.creatings).

last_revision_test() ->
    Kv = fun(R) -> #{kv => #{key => <<"k">>, mod_revision => R}} end,
    %% a watch which catches up: the header is the current revision of the store, not the one of
    %% the events
    ?assertEqual(12, last_revision(#{header => #{revision => 100}, events => [Kv(10), Kv(12)]})),
    %% the events of a response are in order, but the greatest is the one which counts
    ?assertEqual(12, last_revision(#{header => #{revision => 100}, events => [Kv(12), Kv(10)]})),
    %% a progress notification: everything up to the header was sent
    ?assertEqual(100, last_revision(#{header => #{revision => 100}, events => []})),
    ?assertEqual(100, last_revision(#{header => #{revision => 100}})).
-endif.
