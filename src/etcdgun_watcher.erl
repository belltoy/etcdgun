%% @private
-module(etcdgun_watcher).

-feature(maybe_expr, enable).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/5
]).

%% The handler of the events is a `gen_event' handler module (or `{Module, Id}'), whose callbacks
%% `init/1', `handle_event/2' and `terminate/2' are called by the watcher itself.
-type handler() :: module() | {module(), term()}.

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
    %% The create request, without the revision to resume from.
    request :: map(),
    connect_ref = undefined :: undefined | reference(),
    stream_ref = undefined :: undefined | reference(),
    stream = undefined :: undefined | egrpc:stream(),
    monitor_ref = undefined :: undefined | reference(),
    conn_pid = undefined :: undefined | pid(),
    %% The module of the handler, `undefined' when it was terminated (it crashed too often).
    handler = undefined :: undefined | module(),
    handler_state :: term(),
    create_ref = undefined :: undefined | reference(),
    %% The response of the creation is not received yet.
    creating = false :: boolean(),
    %% The revision of the last response which was handled, the watch resumes after it when the
    %% connection is lost. `undefined' until the watch is created.
    last_revision = undefined :: undefined | integer(),
    %% The handler was told that the watch is paused, and is not told again until it is resumed.
    paused = false :: boolean(),
    %% The consecutive refusals of the token, the watcher gives up when it keeps being refused.
    auth_failures = 0 :: non_neg_integer(),
    buf = <<>> :: binary()
}).

-define(WATCH_EVENT_EVENTS(Events), {watch_events, Events}).
-define(WATCH_EVENT_PAUSED(Reason, LastRevision), {watch_paused, Reason, LastRevision}).
-define(WATCH_EVENT_RESUMED(LastRevision), {watch_resumed, LastRevision}).
-define(WATCH_EVENT_STOPPED(Reason, LastRevision), {watch_stopped, Reason, LastRevision}).

-define(CONNECT_RETRY_INTERVAL, 1000).
%% A token which is refused this many times in a row, although it was refreshed, is not going to
%% be accepted: the credentials were changed or removed.
-define(MAX_AUTH_FAILURES, 3).
%% A watcher has one watch, with this id.
-define(WATCH_ID, 1).

%% TODO: Timeout, invalid auth token, reconnect, etc.

-spec start_link(atom(), atom(), handler(), term(), map()) -> gen_server:start_ret().
start_link(Client, WatcherName, Handler, HandlerArgs, Request) ->
    Args = {Client, WatcherName, Handler, HandlerArgs, Request},
    gen_server:start_link({local, WatcherName}, ?MODULE, Args, []).

%%-------------------------------------------------------------------
%% gen_server callbacks
%%-------------------------------------------------------------------

init({Client, WatcherName, Handler, HandlerArgs, Request}) ->
    ?LOG_INFO("Starting watcher ~p for client ~p", [WatcherName, Client]),
    process_flag(trap_exit, true),
    Module = handler_module(Handler),
    case init_handler(Module, HandlerArgs) of
        {ok, HandlerState} ->
            State = #state{
                client = Client,
                watcher_name = WatcherName,
                request = Request#{watch_id => ?WATCH_ID},
                handler = Module,
                handler_state = HandlerState
            },
            %% The first attempt is made here, so that the watch is created when
            %% `etcdgun:watch/5' returns, as a put right after it is expected to be seen. When it
            %% fails the watcher stays and retries, as a failed start would be restarted at once by
            %% the supervisor, again and again, which is why it slept here before (blocking the
            %% supervisor).
            case try_connect(State) of
                {noreply, State1} -> {ok, State1};
                {stop, Reason, State1} ->
                    %% terminate/2 is not called when init/1 does not return a state.
                    ok = stop_handler(Reason, State1),
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, {handler_init, Reason}}
    end.

%% Connect and create the watch, when it fails the watcher is paused, or it stops when the reason
%% is not going to go away.
try_connect(State) ->
    case connect(State) of
        {ok, State1} ->
            {noreply, State1};
        {error, Reason} ->
            on_error(Reason, State)
    end.

%% Open the watch stream and send the create request.
connect(#state{client = Client} = State) ->
    maybe
        {ok, Channel} ?= pick_channel(Client),
        {ok, Stream} ?= etcdgun_etcdserverpb_watch_client:watch(Channel),
        %% After a lost connection the watch resumes after the last revision which was handled.
        Request1 = resume_request(State),
        case create_watch(Stream, Request1) of
            {ok, Stream1} ->
                %% Monitor the gun connection pid.
                ConnPid = egrpc_stub:conn_pid(Stream1),
                MRef = erlang:monitor(process, ConnPid),
                TRef = erlang:start_timer(5000, self(), create_watch_timeout),
                {ok, State#state{
                    stream = Stream1,
                    stream_ref = egrpc_stream:stream_ref(Stream1),
                    monitor_ref = MRef,
                    conn_pid = ConnPid,
                    create_ref = TRef,
                    creating = true,
                    buf = <<>>
                }};
            {error, _} = Error ->
                egrpc_stream:cancel_stream(Stream),
                Error
        end
    end.

%% Send the create request, and receive the response header.
create_watch(Stream, Request) ->
    maybe
        ?LOG_DEBUG("Sending watch request: ~p", [Request]),
        {ok, Stream1} ?= egrpc_stream:send_msg(
                           Stream, #{request_union => {create_request, Request}}, nofin),
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
    try_connect(State#state{connect_ref = undefined});

handle_info({timeout, TRef, create_watch_timeout},
            #state{create_ref = TRef, creating = false} = State) ->
    {noreply, State#state{create_ref = undefined}};
handle_info({timeout, TRef, create_watch_timeout},
            #state{create_ref = TRef} = State) ->
    pause({create_error, timeout}, State#state{create_ref = undefined});

handle_info({gun_data, _ConnPid, StreamRef, nofin, Data},
            #state{stream_ref = StreamRef, buf = Buf} = State) ->
    {noreply, State#state{buf = <<Buf/binary, Data/binary>>}, {continue, process_data}};
handle_info({gun_data, _ConnPid, StreamRef, fin, _Data}, #state{stream_ref = StreamRef} = State) ->
    pause({grpc_error, eos}, State);
handle_info({gun_trailers, _ConnPid, StreamRef, Trailers},
            #state{stream_ref = StreamRef} = State) ->
    on_error(trailers_error(Trailers), State);
handle_info({gun_error, _ConnPid, StreamRef, Reason},
            #state{stream_ref = StreamRef} = State) ->
    pause({stream_error, Reason}, State);
handle_info({gun_error, ConnPid, Reason}, #state{conn_pid = ConnPid} = State) ->
    pause({connection_error, Reason}, State);

handle_info({'DOWN', MRef, process, ConnPid, Reason}, #state{monitor_ref = MRef} = State) ->
    ?LOG_WARNING("Connection ~p down: ~p", [ConnPid, Reason]),
    pause({down, Reason}, State);

%% The messages of a stream or a connection which was left are of no interest.
handle_info({timeout, _TRef, create_watch_timeout}, State) ->
    {noreply, State};
handle_info(Info, State) when is_tuple(Info), element(1, Info) =:= gun_data;
                              is_tuple(Info), element(1, Info) =:= gun_trailers;
                              is_tuple(Info), element(1, Info) =:= gun_error;
                              is_tuple(Info), element(1, Info) =:= gun_response;
                              is_tuple(Info), element(1, Info) =:= gun_inform ->
    {noreply, State};

%% Something which is linked ended normally, which is not a reason to stop the watch.
handle_info({'EXIT', Pid, normal}, State) ->
    ?LOG_DEBUG("Watcher ~p: ~p exited normally", [State#state.watcher_name, Pid]),
    {noreply, State};

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
        {error, Reason} -> pause({grpc_error, Reason}, State);
        {ok, Stream1, Msg, Rest} ->
            process_response(Msg, update_stream(Stream1, State#state{buf = Rest}))
    end.

terminate(Reason, #state{monitor_ref = MRef} = State) ->
    case is_normal(Reason) of
        true -> ?LOG_INFO("Watcher terminating: ~p", [Reason]);
        false -> ?LOG_WARNING("Watcher terminating: ~p", [Reason])
    end,
    % is_normal(Reason) andalso cancel_watches(State),
    case MRef of
        M when is_reference(M) -> erlang:demonitor(M, [flush]);
        _ -> ok
    end,
    cancel_stream(State),
    stop_handler(Reason, State).

%%-------------------------------------------------------------------
%% Private functions
%%-------------------------------------------------------------------

%% The connection or the stream is lost, or the server refused the token. The watcher stays, with
%% what the handler knows, and connects again, it resumes after the last revision which was
%% handled, so that no event is lost. The handler is told once, until the watch is created again.
pause(Reason, #state{watcher_name = WatcherName, paused = Paused} = State) ->
    ?LOG_WARNING("Watcher ~p is paused: ~p, connect again", [WatcherName, Reason]),
    State1 = disconnect(State),
    Result = case Paused of
                 true -> {ok, State1};
                 false ->
                     dispatch(?WATCH_EVENT_PAUSED(Reason, State1#state.last_revision),
                              State1#state{paused = true})
             end,
    case Result of
        {ok, State2} ->
            TRef = erlang:start_timer(?CONNECT_RETRY_INTERVAL, self(), connect),
            {noreply, State2#state{connect_ref = TRef}};
        {stop, StopReason, State2} ->
            {stop, StopReason, State2}
    end.

resumed(#state{paused = false} = State) ->
    {ok, State};
resumed(#state{last_revision = LastRevision} = State) ->
    dispatch(?WATCH_EVENT_RESUMED(LastRevision), State#state{paused = false}).

%% Forget the stream and the connection of it, whatever arrives for them later is ignored.
disconnect(#state{monitor_ref = MRef, create_ref = CreateRef} = State) ->
    cancel_stream(State),
    is_reference(MRef) andalso erlang:demonitor(MRef, [flush]),
    is_reference(CreateRef) andalso erlang:cancel_timer(CreateRef),
    State#state{stream = undefined, stream_ref = undefined, monitor_ref = undefined,
                conn_pid = undefined, create_ref = undefined, creating = false, buf = <<>>}.

%% The handler is a module or `{Module, Id}', as for `gen_event'.
handler_module({Module, _Id}) when is_atom(Module) -> Module;
handler_module(Module) when is_atom(Module) -> Module.

init_handler(Module, Args) ->
    try Module:init(Args) of
        {ok, HandlerState} -> {ok, HandlerState};
        {ok, HandlerState, hibernate} -> {ok, HandlerState};
        {error, _} = Error -> Error;
        Other -> {error, {bad_return_value, Other}}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% Give an event to the handler, in this process: what it returns is what the watcher does, there
%% is no other process which could drop it silently.
%%
%% - `{ok, State}': go on.
%% - `{cancel_watch, State}': the watch is cancelled, as with `etcdgun:cancel_watch/2', the watcher
%%   stops with `shutdown' and the handler is told as it is then (`watch_stopped', `terminate').
%% - a crash (an exception, or a return which is not understood): the watcher stops with
%%   `{handler_failed, Reason, LastRevision}', where the last revision is of what the handler
%%   handled before (see `process_response/2'), to watch again from after it: the events it
%%   crashed at are given again. How much of them it did is not known to the watcher.
-spec dispatch(term(), #state{}) -> {ok, #state{}} | {stop, term(), #state{}}.
dispatch(_Event, #state{handler = undefined} = State) ->
    {ok, State};
dispatch(Event, #state{handler = Module, handler_state = HandlerState} = State) ->
    try Module:handle_event(Event, HandlerState) of
        {ok, HandlerState1} ->
            {ok, State#state{handler_state = HandlerState1}};
        {ok, HandlerState1, hibernate} ->
            {ok, State#state{handler_state = HandlerState1}};
        {cancel_watch, HandlerState1} ->
            {stop, shutdown, State#state{handler_state = HandlerState1}};
        Other ->
            handler_crashed({bad_return_value, Other}, State)
    catch
        Class:Reason:Stacktrace ->
            handler_crashed({Class, Reason, Stacktrace}, State)
    end.

handler_crashed(Reason, #state{handler = Module, handler_state = HandlerState,
                               last_revision = LastRevision} = State) ->
    ?LOG_ERROR("Watcher ~p: the handler ~p crashed: ~p, stop",
               [State#state.watcher_name, Module, Reason]),
    catch_terminate(Module, {error, Reason}, HandlerState),
    %% It is not told that the watcher stops, it is terminated. The revision is in the reason to
    %% watch again from, as the events which it crashed at were not handled.
    {stop, {handler_failed, Reason, LastRevision}, State#state{handler = undefined}}.

%% The watcher stops: the handler is told, and terminated. It does not have to be there anymore,
%% and whatever it does is not of interest for the way the watcher stops.
stop_handler(_Reason, #state{handler = undefined}) ->
    ok;
stop_handler(Reason, #state{handler = Module, handler_state = HandlerState} = State) ->
    HandlerState1 =
        try Module:handle_event(?WATCH_EVENT_STOPPED(Reason, State#state.last_revision),
                                HandlerState) of
            {ok, S} -> S;
            {ok, S, hibernate} -> S;
            _ -> HandlerState
        catch
            _:_ -> HandlerState
        end,
    catch_terminate(Module, Reason, HandlerState1).

catch_terminate(Module, Reason, HandlerState) ->
    try
        %% as for `gen_event' the callback is not required
        erlang:function_exported(Module, terminate, 2) andalso Module:terminate(Reason, HandlerState)
    catch
        Class:Error ->
            ?LOG_WARNING("The terminate of the handler ~p failed: ~p:~p", [Module, Class, Error])
    end,
    ok.

is_normal(normal) -> true;
is_normal(shutdown) -> true;
is_normal({shutdown, _}) -> true;
is_normal(_) -> false.

process_response(#{created := true,
                   canceled := false,
                   watch_id := ?WATCH_ID, header := #{revision := Rev}},
                 #state{creating = true} = State) ->
    ?LOG_INFO("Watcher ~p created the watch, revision ~p", [State#state.watcher_name, Rev]),
    LastRevision = created_revision(Rev, State),
    %% The creation did not time out.
    is_reference(State#state.create_ref) andalso erlang:cancel_timer(State#state.create_ref),
    State1 = State#state{creating = false, create_ref = undefined, last_revision = LastRevision,
                         auth_failures = 0},
    case resumed(State1) of
        {ok, State2} -> {noreply, State2, {continue, process_data}};
        {stop, Reason, State2} -> {stop, Reason, State2}
    end;
process_response(#{created := true, canceled := false} = Response, State) ->
    ?LOG_WARNING("Watcher ~p received unexpected create response: ~p",
                 [State#state.watcher_name, Response]),
    {noreply, State, {continue, process_data}};
process_response(#{canceled := true} = Response, State) ->
    canceled(Response, State);
%% A progress notification which is for all the watches of the stream has no id of the watch.
process_response(#{created := false, canceled := false} = Response, State) ->
    %% A progress notification has no events, there is nothing to tell the handler.
    %% The revision is of what the handler has handled, it is set when it returned: when it
    %% crashes the watcher stops with the one before, and watching from after it gives the events
    %% again (they are given at least once). When the handler asks to cancel the watch it has
    %% handled them.
    LastRevision = last_revision(Response),
    Result = case maps:get(events, Response, []) of
                 [] -> {ok, State};
                 Events -> dispatch(?WATCH_EVENT_EVENTS(Events), State)
             end,
    case Result of
        {ok, State1} ->
            {noreply, State1#state{last_revision = LastRevision}, {continue, process_data}};
        {stop, shutdown, State1} ->
            {stop, shutdown, State1#state{last_revision = LastRevision}};
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end;
process_response(Response, State) ->
    %% Whatever else, e.g. a response of a watch which was not created, must not stall the
    %% messages which are in the buffer.
    ?LOG_WARNING("Watcher ~p received unexpected response: ~p",
                 [State#state.watcher_name, Response]),
    {noreply, State, {continue, process_data}}.

%% The server cancels the watch: when it is not allowed, or the revision to start from is
%% compacted; when the token is not valid (e.g. after a restart of the members, for a streaming
%% request there is no interceptor which refreshes it) it is refreshed and the watch is created
%% again. The others are not going to change by trying again: the watcher stops, with what the
%% server said, and the revisions in the last event (a watch which is compacted can be created again
%% from the revision of the compaction).
canceled(#{cancel_reason := Reason} = Response, State) when is_binary(Reason), Reason =/= <<>> ->
    case is_auth_error(Reason) of
        true -> auth_error(Reason, State);
        false -> canceled_by_server(Response, State)
    end;
canceled(Response, State) ->
    canceled_by_server(Response, State).

canceled_by_server(Response, State) ->
    Reason = case maps:get(compact_revision, Response, 0) of
                 Compacted when is_integer(Compacted), Compacted > 0 -> {compacted, Compacted};
                 _ -> maps:get(cancel_reason, Response, <<>>)
             end,
    {stop, {shutdown, {canceled, Reason}}, State}.

%% The token was refused: refresh it and connect again, until it keeps being refused.
auth_error(Reason, #state{client = Client, auth_failures = Failures} = State) ->
    case Failures + 1 > ?MAX_AUTH_FAILURES of
        true ->
            {stop, {auth_failed, Reason}, State};
        false ->
            ?LOG_WARNING("Watcher ~p was refused: ~s, refresh the token and connect again",
                         [State#state.watcher_name, Reason]),
            _ = refresh_token(Client),
            pause({auth, Reason}, State#state{auth_failures = Failures + 1})
    end.

%% What to do with the error of a connection or of a stream: it is the network or the server
%% which is not available (the watch is paused and connected again), or it is a refusal which is
%% not going to change (the watcher stops).
on_error({grpc_error, Status, Message} = Error, State) when is_atom(Status) ->
    case Status of
        unauthenticated -> auth_error(grpc_message(Message), State);
        _ ->
            case lists:member(Status, [unavailable, deadline_exceeded, internal]) of
                true -> pause(Error, State);
                false ->
                    case is_binary(Message) andalso is_auth_error(Message) of
                        true -> auth_error(Message, State);
                        false -> {stop, {grpc_error, Status}, State}
                    end
            end
    end;
on_error(Reason, State) ->
    pause(Reason, State).

grpc_message(Message) when is_binary(Message) -> Message;
grpc_message(Message) -> iolist_to_binary(io_lib:format("~p", [Message])).

%% The trailers of the stream: the end of a response without a status is the end of the stream,
%% which is connected again; any other status is the one of the call.
trailers_error(Trailers) when is_list(Trailers) ->
    case lists:keyfind(<<"grpc-status">>, 1, Trailers) of
        {_, Status} when Status =/= <<"0">> ->
            Message = case lists:keyfind(<<"grpc-message">>, 1, Trailers) of
                          {_, M} -> M;
                          false -> <<>>
                      end,
            {grpc_error, grpc_status(Status), Message};
        _ ->
            {grpc_error, eos}
    end;
trailers_error(_) ->
    {grpc_error, eos}.

grpc_status(Bin) ->
    Names = {cancelled, unknown, invalid_argument, deadline_exceeded, not_found, already_exists,
             permission_denied, resource_exhausted, failed_precondition, aborted, out_of_range,
             unimplemented, internal, unavailable, data_loss, unauthenticated},
    try binary_to_integer(Bin) of
        N when N >= 1, N =< tuple_size(Names) -> element(N, Names);
        _ -> unknown
    catch
        _:_ -> unknown
    end.

is_auth_error(Reason) ->
    % eqwalizer:ignore
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
    % eqwalizer:ignore
    lists:max([maps:get(mod_revision, Kv, 0) || #{kv := Kv} <- Events]);
last_revision(#{header := #{revision := Revision}}) ->
    Revision.


cancel_stream(#state{conn_pid = ConnPid, stream_ref = StreamRef})
  when is_pid(ConnPid), is_reference(StreamRef) ->
    gun:cancel(ConnPid, StreamRef);
cancel_stream(#state{}) ->
    ok.

%% The reference of the stream does not change, the stream is the state of the interceptors.
update_stream(Stream, #state{} = State) ->
    State#state{stream = Stream}.

%% The request to create the watch with: the watch resumes after the last revision which was
%% handled, when there is one.
resume_request(#state{request = Request, last_revision = undefined}) ->
    Request;
resume_request(#state{request = Request, last_revision = LastRevision}) ->
    Request#{start_revision => LastRevision + 1}.

%% The last revision of a watch which was just created, as no response was handled yet. The
%% header of the response is the current revision of the store, which is where the watch starts,
%% unless the request says to start at an older (or newer) revision: the events from it on are to
%% come, so that the one before it is the last handled.
created_revision(_HeaderRevision, #state{last_revision = LastRevision}) when LastRevision =/= undefined ->
    LastRevision;
created_revision(HeaderRevision, #state{request = Request}) ->
    case maps:get(start_revision, Request, 0) of
        StartRevision when is_integer(StartRevision), StartRevision > 0 -> StartRevision - 1;
        _ -> HeaderRevision
    end.

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
    Created = #{created => true, canceled => false, watch_id => ?WATCH_ID,
                header => #{revision => 11}},
    Frame = fun(Term) -> Bin = term_to_binary(Term), <<(byte_size(Bin)):32, Bin/binary>> end,
    %% The decoding is not what is tested, the messages are terms with a length.
    Parse = fun(_Stream, <<Len:32, Bin:Len/binary, Rest/binary>>) ->
                    {ok, stream, binary_to_term(Bin), Rest};
               (_Stream, _Buf) ->
                    more
            end,
    Drain = fun Drain(S) ->
        case process_data(S, Parse) of
            {noreply, S1, {continue, process_data}} -> Drain(S1);
            {noreply, S1} -> S1
        end
    end,
    FakeStream = #{},
    % eqwalizer:ignore
    State = #state{client = c, watcher_name = w, request = #{}, stream = FakeStream, creating = true},
    %% every response of the chunk is handled, even when a create response is repeated
    Buf = iolist_to_binary([Frame(Created), Frame(Created), Frame(Created)]),
    Final = Drain(State#state{buf = Buf}),
    ?assertEqual(false, Final#state.creating),
    ?assertEqual(<<>>, Final#state.buf),
    %% a response which is not understood does not stall the ones after it
    Odd = iolist_to_binary([Frame(#{something => other}), Frame(Created)]),
    Final1 = Drain(State#state{buf = Odd}),
    ?assertEqual(false, Final1#state.creating),
    ?assertEqual(<<>>, Final1#state.buf).

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

resume_request_test() ->
    State = #state{request = #{key => <<"k">>, start_revision => 5}},
    %% nothing was handled: what the request says
    ?assertEqual(#{key => <<"k">>, start_revision => 5},
                 resume_request(State#state{last_revision = undefined})),
    %% after the last revision which was handled
    ?assertEqual(#{key => <<"k">>, start_revision => 21},
                 resume_request(State#state{last_revision = 20})).

created_revision_test() ->
    State = #state{request = #{key => <<"k">>}},
    %% a watch from now: the event after the header is the first one
    ?assertEqual(100, created_revision(100, State)),
    %% a watch from a revision: the one before it, not the current revision of the store, or the
    %% events from it to the current one would be skipped after a reconnection
    ?assertEqual(49, created_revision(100, State#state{request = #{start_revision => 50}})),
    ?assertEqual(100, created_revision(100, State#state{request = #{start_revision => 0}})),
    %% created again after a lost connection: what was handled stays
    ?assertEqual(70, created_revision(100, State#state{last_revision = 70})).

on_error_test() ->
    % eqwalizer:ignore
    State = #state{watcher_name = w, client = c}, %% ignore other fields
    %% the server or the network is not there: paused, connected again
    ?assertMatch({noreply, #state{paused = true}},
                 on_error({grpc_error, unavailable, <<"no leader">>}, State)),
    ?assertMatch({noreply, _}, on_error({grpc_error, internal, <<>>}, State)),
    ?assertMatch({noreply, _}, on_error(no_available_connection, State)),
    ?assertMatch({noreply, _}, on_error({grpc_error, eos}, State)),
    %% a refusal which is not going to change
    ?assertMatch({stop, {grpc_error, permission_denied}, _},
                 on_error({grpc_error, permission_denied, <<"nope">>}, State)),
    ?assertMatch({stop, {grpc_error, unimplemented}, _},
                 on_error({grpc_error, unimplemented, <<>>}, State)),
    %% a token which is refused for ever
    ?assertMatch({stop, {auth_failed, <<"invalid auth token">>}, _},
                 on_error({grpc_error, unauthenticated, <<"invalid auth token">>},
                          State#state{auth_failures = ?MAX_AUTH_FAILURES})).

trailers_error_test() ->
    ?assertEqual({grpc_error, eos}, trailers_error([])),
    ?assertEqual({grpc_error, eos}, trailers_error([{<<"grpc-status">>, <<"0">>}])),
    ?assertEqual({grpc_error, unavailable, <<"going away">>},
                 trailers_error([{<<"grpc-status">>, <<"14">>}, {<<"grpc-message">>, <<"going away">>}])),
    ?assertEqual({grpc_error, permission_denied, <<>>},
                 trailers_error([{<<"grpc-status">>, <<"7">>}])),
    ?assertEqual({grpc_error, unknown, <<>>}, trailers_error([{<<"grpc-status">>, <<"x">>}])).

canceled_test() ->
    % eqwalizer:ignore
    State = #state{watcher_name = w, client = c},  %% ignore other fields
    %% a start revision which was compacted can be told from the others
    ?assertMatch({stop, {shutdown, {canceled, {compacted, 7}}}, _},
                 canceled(#{canceled => true, compact_revision => 7,
                            cancel_reason => <<"mvcc: required revision has been compacted">>},
                          State)),
    ?assertMatch({stop, {shutdown, {canceled, <<"etcdserver: permission denied">>}}, _},
                 canceled(#{canceled => true, cancel_reason => <<"etcdserver: permission denied">>},
                          State)),
    ?assertMatch({stop, {shutdown, {canceled, <<>>}}, _}, canceled(#{canceled => true}, State)).
-endif.
