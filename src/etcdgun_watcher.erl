%% @private
%% @doc One watch of an etcd client, as a state machine.
%%
%% ```
%%  connecting --(open the stream, create request)--> creating --(created)--> watching
%%       ^                                               |                       |
%%       |                                               +---- stream lost ------+
%%       +------------ paused (retry after 1 s) <--------+
%%       +------------ refreshing_auth (the token was refused) <---- refused ----+
%% '''
%%
%% - `connecting': there is no stream, a new one is opened after a pause;
%% - `creating': the stream is open and the create request is sent, the response is awaited;
%% - `watching': the watch is created, the events are given to the handler;
%% - `refreshing_auth': the token was refused and is being refreshed by a process of its own.
%%
%% A stream which is lost is opened again by the picker of the channel (another endpoint) and the
%% watch is created after the last revision which was handled, so that no event is lost and none is
%% given twice. A compacted revision, or a refusal which will not change, stops the watcher.
-module(etcdgun_watcher).

-feature(maybe_expr, enable).

-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/5
]).

%% The handler of the events is a `gen_event' handler module (or `{Module, Id}'), whose callbacks
%% `init/1', `handle_event/2' and `terminate/2' are called by the watcher itself.
-type handler() :: module() | {module(), term()}.

-export([
    init/1,
    callback_mode/0,
    handle_event/4,
    terminate/3
]).

%% The fields of the stream are `undefined' while the watcher is not connected, it retries.
-record(data, {
    client :: atom(),
    watcher_name :: atom(),
    %% The create request, without the revision to resume from.
    request :: map(),
    stream = undefined :: undefined | egrpc:stream(),
    stream_ref = undefined :: undefined | term(),
    monitor_ref = undefined :: undefined | reference(),
    conn_pid = undefined :: undefined | pid(),
    %% The module of the handler, `undefined' when it was terminated (it crashed too often).
    handler = undefined :: undefined | module(),
    handler_state :: term(),
    %% The revision of the last response which was handled, the watch resumes after it when the
    %% connection is lost. `undefined' until the watch is created.
    last_revision = undefined :: undefined | integer(),
    %% The handler was told that the watch is paused, and is not told again until it is resumed.
    paused = false :: boolean(),
    %% The consecutive refusals of the token, the watcher gives up when it keeps being refused.
    auth_failures = 0 :: non_neg_integer(),
    refresh = undefined :: undefined | {pid(), reference()},
    buf = <<>> :: binary()
}).

-type state() :: connecting | creating | watching | refreshing_auth.

-define(WATCH_EVENT_EVENTS(Events), {watch_events, Events}).
-define(WATCH_EVENT_PAUSED(Reason, LastRevision), {watch_paused, Reason, LastRevision}).
-define(WATCH_EVENT_RESUMED(LastRevision), {watch_resumed, LastRevision}).
-define(WATCH_EVENT_STOPPED(Reason, LastRevision), {watch_stopped, Reason, LastRevision}).

-define(CONNECT_RETRY_INTERVAL, 1000).
%% The response to the create request, the server answers at once.
-define(CREATE_TIMEOUT, 5000).
%% A token which is refused this many times in a row, although it was refreshed, is not going to
%% be accepted: the credentials were changed or removed.
-define(MAX_AUTH_FAILURES, 3).
%% A watcher has one watch, with this id.
-define(WATCH_ID, 1).

-spec start_link(atom(), atom(), handler(), term(), map()) -> gen_statem:start_ret().
start_link(Client, WatcherName, Handler, HandlerArgs, Request) ->
    Args = {Client, WatcherName, Handler, HandlerArgs, Request},
    gen_statem:start_link({local, WatcherName}, ?MODULE, Args, []).

%%-------------------------------------------------------------------
%% gen_statem callbacks
%%-------------------------------------------------------------------

callback_mode() -> handle_event_function.

init({Client, WatcherName, Handler, HandlerArgs, Request}) ->
    ?LOG_INFO("Starting watcher ~p for client ~p", [WatcherName, Client]),
    process_flag(trap_exit, true),
    Module = handler_module(Handler),
    case init_handler(Module, HandlerArgs) of
        {ok, HandlerState} ->
            Data = #data{
                client = Client,
                watcher_name = WatcherName,
                request = Request#{watch_id => ?WATCH_ID},
                handler = Module,
                handler_state = HandlerState
            },
            %% The first attempt is made here, so that the watch is created when
            %% `etcdgun:watch/5' returns, as a put right after it is expected to be seen. When it
            %% fails the watcher stays and retries, as a failed start would be restarted at once by
            %% the supervisor, again and again.
            case connect(Data) of
                {next_state, State, Data1, Actions} ->
                    {ok, State, Data1, Actions};
                {stop, Reason, Data1} ->
                    %% terminate/3 is not called when init/1 does not return a state.
                    ok = stop_handler(Reason, Data1),
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, {handler_init, Reason}}
    end.

%% The retry after a pause.
handle_event(state_timeout, connect, connecting, Data) ->
    result(connect(Data));

%% The server did not answer the create request.
handle_event(state_timeout, create_timeout, creating, Data) ->
    result(pause({create_error, timeout}, Data));

%% The token was refreshed, or not: connect after a pause either way.
handle_event(info, {refreshed, Pid, _Result}, refreshing_auth, #data{refresh = {Pid, MRef}} = Data) ->
    erlang:demonitor(MRef, [flush]),
    {next_state, connecting, Data#data{refresh = undefined}, [connect_after()]};
handle_event(info, {'DOWN', MRef, process, Pid, Reason}, refreshing_auth,
             #data{refresh = {Pid, MRef}} = Data) ->
    ?LOG_WARNING("The refresh of the token crashed: ~p", [Reason]),
    {next_state, connecting, Data#data{refresh = undefined}, [connect_after()]};

%% What the stream receives. The stream is the one of the data, the messages of a stream or a
%% connection which was left are of no interest.
handle_event(info, {gun_data, _ConnPid, StreamRef, nofin, Chunk}, State,
             #data{stream_ref = StreamRef, buf = Buf} = Data)
  when State =:= creating; State =:= watching ->
    {keep_state, Data#data{buf = <<Buf/binary, Chunk/binary>>}, [{next_event, internal, process_data}]};
handle_event(info, {gun_data, _ConnPid, StreamRef, fin, _Chunk}, State, #data{stream_ref = StreamRef} = Data)
  when State =:= creating; State =:= watching ->
    result(pause({grpc_error, eos}, Data));
handle_event(info, {gun_trailers, _ConnPid, StreamRef, Trailers}, State, #data{stream_ref = StreamRef} = Data)
  when State =:= creating; State =:= watching ->
    result(on_error(trailers_error(Trailers), Data));
handle_event(info, {gun_error, _ConnPid, StreamRef, Reason}, State, #data{stream_ref = StreamRef} = Data)
  when State =:= creating; State =:= watching ->
    result(pause({stream_error, Reason}, Data));
handle_event(info, {gun_error, ConnPid, Reason}, State, #data{conn_pid = ConnPid} = Data)
  when State =:= creating; State =:= watching ->
    result(pause({connection_error, Reason}, Data));
handle_event(info, {'DOWN', MRef, process, ConnPid, Reason}, State, #data{monitor_ref = MRef} = Data)
  when State =:= creating; State =:= watching ->
    ?LOG_WARNING("Connection ~p down: ~p", [ConnPid, Reason]),
    result(pause({down, Reason}, Data));

handle_event(internal, process_data, State, Data) when State =:= creating; State =:= watching ->
    result(process_data(State, Data, fun egrpc_stream:parse_msg/2));
handle_event(internal, process_data, _State, _Data) ->
    keep_state_and_data;

handle_event(info, Info, _State, _Data)
  when is_tuple(Info), element(1, Info) =:= gun_data;
       is_tuple(Info), element(1, Info) =:= gun_trailers;
       is_tuple(Info), element(1, Info) =:= gun_error;
       is_tuple(Info), element(1, Info) =:= gun_response;
       is_tuple(Info), element(1, Info) =:= gun_inform ->
    keep_state_and_data;

%% Something which is linked ended normally, which is not a reason to stop the watch.
handle_event(info, {'EXIT', Pid, normal}, _State, #data{watcher_name = WatcherName}) ->
    ?LOG_DEBUG("Watcher ~p: ~p exited normally", [WatcherName, Pid]),
    keep_state_and_data;
handle_event(info, {'EXIT', Pid, Reason}, _State, _Data) ->
    ?LOG_WARNING("Got exit message from ~p: ~p", [Pid, Reason]),
    {stop, Reason};

handle_event({call, From}, _Request, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, unexpected_call}}]};

handle_event(info, Info, _State, _Data) ->
    ?LOG_WARNING("Unexpected info: ~p", [Info]),
    keep_state_and_data;
handle_event(_Type, _Msg, _State, _Data) ->
    keep_state_and_data.

terminate(Reason, _State, #data{monitor_ref = MRef} = Data) ->
    case is_normal(Reason) of
        true -> ?LOG_INFO("Watcher terminating: ~p", [Reason]);
        false -> ?LOG_WARNING("Watcher terminating: ~p", [Reason])
    end,
    case MRef of
        M when is_reference(M) -> erlang:demonitor(M, [flush]);
        _ -> ok
    end,
    cancel_stream(Data),
    stop_handler(Reason, Data).

%%-------------------------------------------------------------------
%% Steps
%%-------------------------------------------------------------------

%% What a step gives: the next state (with the actions) or the stop.
-type step() ::
    {next_state, state(), #data{}, [gen_statem:action()]}
  | {stop, term(), #data{}}.

-spec result(step() | {keep_state, #data{}}) ->
    gen_statem:event_handler_result(state()).
result({next_state, State, Data, Actions}) -> {next_state, State, Data, Actions};
result({keep_state, _Data} = Keep) -> Keep;
result({stop, Reason, Data}) -> {stop, Reason, Data}.

connect_after() ->
    {state_timeout, ?CONNECT_RETRY_INTERVAL, connect}.

%% Open the watch stream and send the create request, when it fails the watcher is paused, or it
%% stops when the reason is not going to go away.
connect(Data) ->
    case open(Data) of
        {ok, Stream} ->
            %% Monitor the gun connection pid.
            ConnPid = egrpc_stream:conn_pid(Stream),
            MRef = erlang:monitor(process, ConnPid),
            {next_state, creating,
             Data#data{
                 stream = Stream,
                 stream_ref = egrpc_stream:stream_ref(Stream),
                 monitor_ref = MRef,
                 conn_pid = ConnPid,
                 buf = <<>>
             },
             [{state_timeout, ?CREATE_TIMEOUT, create_timeout}]};
        {error, Reason} ->
            on_error(Reason, Data)
    end.

open(#data{client = Client} = Data) ->
    maybe
        {ok, Stream} ?= etcdgun_etcdserverpb_watch_stub:watch(Client),
        %% After a lost connection the watch resumes after the last revision which was handled.
        case create_watch(Stream, resume_request(Data)) of
            {ok, _} = Ok ->
                Ok;
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

%% Handle the next response of the buffer. Every clause of the handling of a response continues
%% with this, or the responses which are in the buffer wait for the next data.
process_data(State, #data{buf = Buf, stream = Stream} = Data, ParseMsg) ->
    case ParseMsg(Stream, Buf) of
        more -> {keep_state, Data};
        {error, Reason} -> pause({grpc_error, Reason}, Data);
        {ok, Stream1, Msg, Rest} ->
            process_response(Msg, State, Data#data{stream = Stream1, buf = Rest})
    end.

%% The next response, if there is another.
continue(State, Data) ->
    {next_state, State, Data, [{next_event, internal, process_data}]}.

%% The connection or the stream is lost, or the server refused the token. The watcher stays, with
%% what the handler knows, and connects again, it resumes after the last revision which was
%% handled, so that no event is lost. The handler is told once, until the watch is created again.
pause(Reason, Data) ->
    pause(Reason, connecting, Data).

pause(Reason, Next, #data{watcher_name = WatcherName, paused = Paused} = Data) ->
    ?LOG_WARNING("Watcher ~p is paused: ~p, connect again", [WatcherName, Reason]),
    Data1 = disconnect(Data),
    Result = case Paused of
                 true -> {ok, Data1};
                 false ->
                     dispatch(?WATCH_EVENT_PAUSED(Reason, Data1#data.last_revision),
                              Data1#data{paused = true})
             end,
    case Result of
        {ok, Data2} when Next =:= connecting ->
            {next_state, connecting, Data2, [connect_after()]};
        {ok, Data2} ->
            Next(Data2);
        {stop, StopReason, Data2} ->
            {stop, StopReason, Data2}
    end.

resumed(#data{paused = false} = Data) ->
    {ok, Data};
resumed(#data{last_revision = LastRevision} = Data) ->
    dispatch(?WATCH_EVENT_RESUMED(LastRevision), Data#data{paused = false}).

%% Forget the stream and the connection of it, whatever arrives for them later is ignored.
disconnect(#data{monitor_ref = MRef} = Data) ->
    cancel_stream(Data),
    is_reference(MRef) andalso erlang:demonitor(MRef, [flush]),
    Data#data{stream = undefined, stream_ref = undefined, monitor_ref = undefined,
              conn_pid = undefined, buf = <<>>}.

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
%%   handled before (see `process_response/3'), to watch again from after it: the events it
%%   crashed at are given again. How much of them it did is not known to the watcher.
-spec dispatch(term(), #data{}) -> {ok, #data{}} | {stop, term(), #data{}}.
dispatch(_Event, #data{handler = undefined} = Data) ->
    {ok, Data};
dispatch(Event, #data{handler = Module, handler_state = HandlerState} = Data) ->
    try Module:handle_event(Event, HandlerState) of
        {ok, HandlerState1} ->
            {ok, Data#data{handler_state = HandlerState1}};
        {ok, HandlerState1, hibernate} ->
            {ok, Data#data{handler_state = HandlerState1}};
        {cancel_watch, HandlerState1} ->
            {stop, shutdown, Data#data{handler_state = HandlerState1}};
        Other ->
            handler_crashed({bad_return_value, Other}, Data)
    catch
        Class:Reason:Stacktrace ->
            handler_crashed({Class, Reason, Stacktrace}, Data)
    end.

handler_crashed(Reason, #data{handler = Module, handler_state = HandlerState,
                              last_revision = LastRevision} = Data) ->
    ?LOG_ERROR("Watcher ~p: the handler ~p crashed: ~p, stop",
               [Data#data.watcher_name, Module, Reason]),
    catch_terminate(Module, {error, Reason}, HandlerState),
    %% It is not told that the watcher stops, it is terminated. The revision is in the reason to
    %% watch again from, as the events which it crashed at were not handled.
    {stop, {handler_failed, Reason, LastRevision}, Data#data{handler = undefined}}.

%% The watcher stops: the handler is told, and terminated. It does not have to be there anymore,
%% and whatever it does is not of interest for the way the watcher stops.
stop_handler(_Reason, #data{handler = undefined}) ->
    ok;
stop_handler(Reason, #data{handler = Module, handler_state = HandlerState} = Data) ->
    HandlerState1 =
        try Module:handle_event(?WATCH_EVENT_STOPPED(Reason, Data#data.last_revision),
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
                 creating, #data{} = Data) ->
    ?LOG_INFO("Watcher ~p created the watch, revision ~p", [Data#data.watcher_name, Rev]),
    LastRevision = created_revision(Rev, Data),
    Data1 = Data#data{last_revision = LastRevision, auth_failures = 0},
    case resumed(Data1) of
        {ok, Data2} -> continue(watching, Data2);
        {stop, Reason, Data2} -> {stop, Reason, Data2}
    end;
process_response(#{created := true, canceled := false} = Response, State, Data) ->
    ?LOG_WARNING("Watcher ~p received unexpected create response: ~p",
                 [Data#data.watcher_name, Response]),
    continue(State, Data);
process_response(#{canceled := true} = Response, _State, Data) ->
    canceled(Response, Data);
%% A progress notification which is for all the watches of the stream has no id of the watch.
process_response(#{created := false, canceled := false} = Response, watching, Data) ->
    %% A progress notification has no events, there is nothing to tell the handler.
    %% The revision is of what the handler has handled, it is set when it returned: when it
    %% crashes the watcher stops with the one before, and watching from after it gives the events
    %% again (they are given at least once). When the handler asks to cancel the watch it has
    %% handled them.
    LastRevision = last_revision(Response, Data#data.last_revision),
    Result = case new_events(Response, Data#data.last_revision) of
                 [] -> {ok, Data};
                 Events -> dispatch(?WATCH_EVENT_EVENTS(Events), Data)
             end,
    case Result of
        {ok, Data1} ->
            continue(watching, Data1#data{last_revision = LastRevision});
        {stop, shutdown, Data1} ->
            {stop, shutdown, Data1#data{last_revision = LastRevision}};
        {stop, Reason, Data1} ->
            {stop, Reason, Data1}
    end;
process_response(Response, State, Data) ->
    %% Whatever else, e.g. a response of a watch which was not created, must not stall the
    %% messages which are in the buffer.
    ?LOG_WARNING("Watcher ~p received unexpected response: ~p",
                 [Data#data.watcher_name, Response]),
    continue(State, Data).

%% The server cancels the watch: when it is not allowed, or the revision to start from is
%% compacted; when the token is not valid (e.g. after a restart of the members) it is refreshed
%% and the watch is created again. The others are not going to change by trying again: the
%% watcher stops, with what the server said, and the revisions in the last event (a watch which
%% is compacted can be created again from the revision of the compaction).
canceled(#{cancel_reason := Reason} = Response, Data) when is_binary(Reason), Reason =/= <<>> ->
    case is_auth_error(Reason) of
        true -> auth_error(Reason, Data);
        false -> canceled_by_server(Response, Data)
    end;
canceled(Response, Data) ->
    canceled_by_server(Response, Data).

canceled_by_server(Response, Data) ->
    Reason = case maps:get(compact_revision, Response, 0) of
                 Compacted when is_integer(Compacted), Compacted > 0 -> {compacted, Compacted};
                 _ -> maps:get(cancel_reason, Response, <<>>)
             end,
    {stop, {shutdown, {canceled, Reason}}, Data}.

%% The token was refused: refresh it and connect again, until it keeps being refused.
auth_error(Reason, #data{client = Client, auth_failures = Failures} = Data) ->
    case Failures + 1 > ?MAX_AUTH_FAILURES of
        true ->
            {stop, {auth_failed, Reason}, Data};
        false ->
            ?LOG_WARNING("Watcher ~p was refused: ~s, refresh the token and connect again",
                         [Data#data.watcher_name, Reason]),
            pause({auth, Reason}, fun(Data1) -> refresh(Client, Data1) end,
                  Data#data{auth_failures = Failures + 1})
    end.

%% In a process of its own, a refresh waits for the network and the handler is not to wait for it.
refresh(Client, Data) ->
    Self = self(),
    {Pid, MRef} = spawn_monitor(fun() -> Self ! {refreshed, self(), refresh_token(Client)} end),
    {next_state, refreshing_auth, Data#data{refresh = {Pid, MRef}}, []}.

%% What to do with the error of a connection or of a stream: it is the network or the server
%% which is not available (the watch is paused and connected again), or it is a refusal which is
%% not going to change (the watcher stops).
on_error({grpc_error, Status, Message} = Error, Data) when is_atom(Status) ->
    case Status of
        unauthenticated -> auth_error(grpc_message(Message), Data);
        _ ->
            case lists:member(Status, [unavailable, deadline_exceeded, internal]) of
                true -> pause(Error, Data);
                false ->
                    case is_binary(Message) andalso is_auth_error(Message) of
                        true -> auth_error(Message, Data);
                        false -> {stop, {grpc_error, Status}, Data}
                    end
            end
    end;
on_error(Reason, Data) ->
    pause(Reason, Data).

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
    lists:any(fun(Text) -> binary:match(Reason, Text) =/= nomatch end,
              [<<"invalid auth token">>, <<"user name is empty">>,
               <<"revision of auth store is old">>]).

refresh_token(Client) ->
    try
        etcdgun_client:refresh_token(Client)
    catch
        exit:_ -> {error, client_not_running}
    end.

%% The events of a response which were not given yet. The watch is created after the last
%% revision, so the server does not send the older ones; this is for a stream which sends them
%% again anyway: the revisions only go forward.
-spec new_events(map(), undefined | integer()) -> [map()].
new_events(Response, undefined) ->
    maps:get(events, Response, []);
new_events(Response, LastRevision) ->
    [Event || Event <- maps:get(events, Response, []), event_revision(Event) > LastRevision].

event_revision(#{kv := #{mod_revision := Revision}}) -> Revision;
event_revision(_) -> 0.

%% The revision to resume from, after the one which is returned. The header of a response of a
%% watch which catches up (is not synced yet) has the current revision of the store, which is
%% greater than the events in it, so it must not be used with events: the events in between would
%% be skipped. The header of a response without events (a progress notification) says that
%% everything up to it was sent. It does not go back.
-spec last_revision(map(), undefined | integer()) -> integer().
last_revision(Response, Last) ->
    New = last_revision(Response),
    case Last of
        undefined -> New;
        _ -> max(Last, New)
    end.

-spec last_revision(map()) -> integer().
last_revision(#{events := [_ | _] = Events}) ->
    lists:max([maps:get(mod_revision, Kv, 0) || #{kv := Kv} <- Events]);
last_revision(#{header := #{revision := Revision}}) ->
    Revision.

cancel_stream(#data{stream = undefined}) ->
    ok;
cancel_stream(#data{stream = Stream}) ->
    egrpc_stream:cancel_stream(Stream).

%% The request to create the watch with: the watch resumes after the last revision which was
%% handled, when there is one.
resume_request(#data{request = Request, last_revision = undefined}) ->
    Request;
resume_request(#data{request = Request, last_revision = LastRevision}) ->
    Request#{start_revision => LastRevision + 1}.

%% The last revision of a watch which was just created, as no response was handled yet. The
%% header of the response is the current revision of the store, which is where the watch starts,
%% unless the request says to start at an older (or newer) revision: the events from it on are to
%% come, so that the one before it is the last handled.
created_revision(_HeaderRevision, #data{last_revision = LastRevision}) when LastRevision =/= undefined ->
    LastRevision;
created_revision(HeaderRevision, #data{request = Request}) ->
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

%% The responses of one data chunk are all handled: the handling of a response ends with the
%% next one, until the buffer has no complete message.
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
    Drain = fun Drain(St, D) ->
        case process_data(St, D, Parse) of
            {next_state, St1, D1, [{next_event, internal, process_data}]} -> Drain(St1, D1);
            {keep_state, D1} -> {St, D1}
        end
    end,
    FakeStream = #{},
    % eqwalizer:ignore
    Data = #data{client = c, watcher_name = w, request = #{}, stream = FakeStream},
    %% every response of the chunk is handled, even when a create response is repeated
    Buf = iolist_to_binary([Frame(Created), Frame(Created), Frame(Created)]),
    {State, Final} = Drain(creating, Data#data{buf = Buf}),
    ?assertEqual(watching, State),
    ?assertEqual(<<>>, Final#data.buf),
    %% a response which is not understood does not stall the ones after it
    Odd = iolist_to_binary([Frame(#{something => other}), Frame(Created)]),
    {State1, Final1} = Drain(creating, Data#data{buf = Odd}),
    ?assertEqual(watching, State1),
    ?assertEqual(<<>>, Final1#data.buf).

last_revision_test() ->
    Kv = fun(R) -> #{kv => #{key => <<"k">>, mod_revision => R}} end,
    %% a watch which catches up: the header is the current revision of the store, not the one of
    %% the events
    ?assertEqual(12, last_revision(#{header => #{revision => 100}, events => [Kv(10), Kv(12)]})),
    %% the events of a response are in order, but the greatest is the one which counts
    ?assertEqual(12, last_revision(#{header => #{revision => 100}, events => [Kv(12), Kv(10)]})),
    %% a progress notification: everything up to the header was sent
    ?assertEqual(100, last_revision(#{header => #{revision => 100}, events => []})),
    ?assertEqual(100, last_revision(#{header => #{revision => 100}})),
    %% the revision does not go back
    ?assertEqual(20, last_revision(#{header => #{revision => 100}, events => [Kv(10)]}, 20)),
    ?assertEqual(30, last_revision(#{header => #{revision => 100}, events => [Kv(30)]}, 20)),
    ?assertEqual(10, last_revision(#{header => #{revision => 100}, events => [Kv(10)]}, undefined)).

new_events_test() ->
    Ev = fun(R) -> #{type => 'PUT', kv => #{key => <<"k">>, mod_revision => R}} end,
    Response = #{events => [Ev(5), Ev(6), Ev(7)]},
    ?assertEqual([Ev(5), Ev(6), Ev(7)], new_events(Response, undefined)),
    %% the events which were given are not given again
    ?assertEqual([Ev(6), Ev(7)], new_events(Response, 5)),
    ?assertEqual([], new_events(Response, 7)),
    ?assertEqual([], new_events(#{header => #{revision => 9}}, 5)).

resume_request_test() ->
    Data = #data{request = #{key => <<"k">>, start_revision => 5}},
    %% nothing was handled: what the request says
    ?assertEqual(#{key => <<"k">>, start_revision => 5},
                 resume_request(Data#data{last_revision = undefined})),
    %% after the last revision which was handled
    ?assertEqual(#{key => <<"k">>, start_revision => 21},
                 resume_request(Data#data{last_revision = 20})).

created_revision_test() ->
    Data = #data{request = #{key => <<"k">>}},
    %% a watch from now: the event after the header is the first one
    ?assertEqual(100, created_revision(100, Data)),
    %% a watch from a revision: the one before it, not the current revision of the store, or the
    %% events from it to the current one would be skipped after a reconnection
    ?assertEqual(49, created_revision(100, Data#data{request = #{start_revision => 50}})),
    ?assertEqual(100, created_revision(100, Data#data{request = #{start_revision => 0}})),
    %% created again after a lost connection: what was handled stays
    ?assertEqual(70, created_revision(100, Data#data{last_revision = 70})).

on_error_test() ->
    % eqwalizer:ignore
    Data = #data{watcher_name = w, client = c}, %% ignore other fields
    %% the server or the network is not there: paused, connected again
    ?assertMatch({next_state, connecting, #data{paused = true}, [{state_timeout, _, connect}]},
                 on_error({grpc_error, unavailable, <<"no leader">>}, Data)),
    ?assertMatch({next_state, connecting, _, _}, on_error({grpc_error, internal, <<>>}, Data)),
    ?assertMatch({next_state, connecting, _, _}, on_error(no_available_connection, Data)),
    ?assertMatch({next_state, connecting, _, _}, on_error({grpc_error, eos}, Data)),
    %% a refusal which is not going to change
    ?assertMatch({stop, {grpc_error, permission_denied}, _},
                 on_error({grpc_error, permission_denied, <<"nope">>}, Data)),
    ?assertMatch({stop, {grpc_error, unimplemented}, _},
                 on_error({grpc_error, unimplemented, <<>>}, Data)),
    %% a token which is refused: paused, refreshed
    ?assertMatch({next_state, refreshing_auth, #data{paused = true, auth_failures = 1}, []},
                 on_error({grpc_error, unauthenticated, <<"invalid auth token">>}, Data)),
    %% a token which is refused for ever
    ?assertMatch({stop, {auth_failed, <<"invalid auth token">>}, _},
                 on_error({grpc_error, unauthenticated, <<"invalid auth token">>},
                          Data#data{auth_failures = ?MAX_AUTH_FAILURES})).

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
    Data = #data{watcher_name = w, client = c},  %% ignore other fields
    %% a start revision which was compacted can be told from the others
    ?assertMatch({stop, {shutdown, {canceled, {compacted, 7}}}, _},
                 canceled(#{canceled => true, compact_revision => 7,
                            cancel_reason => <<"mvcc: required revision has been compacted">>},
                          Data)),
    ?assertMatch({stop, {shutdown, {canceled, <<"etcdserver: permission denied">>}}, _},
                 canceled(#{canceled => true, cancel_reason => <<"etcdserver: permission denied">>},
                          Data)),
    ?assertMatch({stop, {shutdown, {canceled, <<>>}}, _}, canceled(#{canceled => true}, Data)).
-endif.
