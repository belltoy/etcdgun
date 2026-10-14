%% @private
-module(etcdgun_watcher).

-feature(maybe_expr, enable).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
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
    %% The create request, without the revision to resume from.
    request :: map(),
    connect_ref = undefined :: undefined | reference(),
    stream_ref = undefined :: undefined | reference(),
    stream = undefined :: undefined | egrpc:stream(),
    monitor_ref = undefined :: undefined | reference(),
    conn_pid = undefined :: undefined | pid(),
    event_manager_pid = undefined :: undefined | pid(),
    create_ref = undefined :: undefined | reference(),
    %% The response of the creation is not received yet.
    creating = false :: boolean(),
    %% The revision of the last response which was handled, the watch resumes after it when the
    %% connection is lost. `undefined' until the watch is created.
    last_revision = undefined :: undefined | integer(),
    buf = <<>> :: binary()
}).

-define(WATCH_EVENT_EVENTS(Events), {watch_events, Events}).
-define(WATCH_EVENT_CANCELED, watch_canceled).
-define(WATCH_EVENT_STOPPED(Reason), {watch_stopped, Reason}).

-define(CONNECT_RETRY_INTERVAL, 1000).
%% A watcher has one watch, with this id.
-define(WATCH_ID, 1).

%% TODO: Timeout, invalid auth token, reconnect, etc.

start_link(Client, WatcherName, EventMgr, Request) ->
    Args = {Client, WatcherName, EventMgr, Request},
    gen_server:start_link({local, WatcherName}, ?MODULE, Args, []).

%%-------------------------------------------------------------------
%% gen_server callbacks
%%-------------------------------------------------------------------

init({Client, WatcherName, EventMgr, Request}) ->
    ?LOG_INFO("Starting watcher ~p for client ~p", [WatcherName, Client]),
    process_flag(trap_exit, true),
    State = #state{
        client = Client,
        watcher_name = WatcherName,
        request = Request#{watch_id => ?WATCH_ID},
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
    {noreply, try_connect(State#state{connect_ref = undefined})};

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
handle_info({gun_trailers, _ConnPid, StreamRef, _Trailers},
            #state{stream_ref = StreamRef} = State) ->
    pause({grpc_error, eos}, State);
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

%% The connection or the stream is lost, or the server refused the token. The watcher stays, with
%% what the handler knows, and connects again, it resumes after the last revision which was
%% handled, so that no event is lost.
pause(Reason, #state{watcher_name = WatcherName} = State) ->
    ?LOG_WARNING("Watcher ~p is paused: ~p, connect again", [WatcherName, Reason]),
    State1 = disconnect(State),
    TRef = erlang:start_timer(?CONNECT_RETRY_INTERVAL, self(), connect),
    {noreply, State1#state{connect_ref = TRef}}.

%% Forget the stream and the connection of it, whatever arrives for them later is ignored.
disconnect(#state{monitor_ref = MRef, create_ref = CreateRef} = State) ->
    cancel_stream(State),
    is_reference(MRef) andalso erlang:demonitor(MRef, [flush]),
    is_reference(CreateRef) andalso erlang:cancel_timer(CreateRef),
    State#state{stream = undefined, stream_ref = undefined, monitor_ref = undefined,
                conn_pid = undefined, create_ref = undefined, creating = false, buf = <<>>}.

is_normal(normal) -> true;
is_normal(shutdown) -> true;
is_normal({shutdown, _}) -> true;
is_normal(_) -> false.

process_response(#{created := true,
                   canceled := false,
                   watch_id := ?WATCH_ID, header := #{revision := Rev}},
                 #state{creating = true} = State) ->
    ?LOG_INFO("Watcher ~p created the watch, revision ~p", [State#state.watcher_name, Rev]),
    {noreply, State#state{creating = false, last_revision = created_revision(Rev, State)},
     {continue, process_data}};
process_response(#{created := true} = Response, State) ->
    ?LOG_WARNING("Watcher ~p received unexpected create response: ~p",
                 [State#state.watcher_name, Response]),
    {noreply, State, {continue, process_data}};
process_response(#{canceled := true} = Response, State) ->
    canceled(Response, State);
%% A progress notification which is for all the watches of the stream has no id of the watch.
process_response(#{created := false, canceled := false} = Response, State) ->
    %% A progress notification has no events, there is nothing to tell the handler.
    case maps:get(events, Response, []) of
        [] -> ok;
        Events -> notify(?WATCH_EVENT_EVENTS(Events), State)
    end,
    {noreply, State#state{last_revision = last_revision(Response)}, {continue, process_data}};
process_response(Response, State) ->
    %% Whatever else, e.g. a response of a watch which was not created, must not stall the
    %% messages which are in the buffer.
    ?LOG_WARNING("Watcher ~p received unexpected response: ~p",
                 [State#state.watcher_name, Response]),
    {noreply, State, {continue, process_data}}.

%% The server cancels a watch, when it was cancelled by the request, or when it is not allowed:
%% the token is not valid, e.g. after a restart of the members, for a streaming request there is
%% no interceptor which refreshes it. Refresh it and connect again, which creates the watch with
%% the new token.
canceled(#{cancel_reason := Reason} = Response, #state{client = Client} = State)
  when is_binary(Reason), Reason =/= <<>> ->
    case is_auth_error(Reason) of
        true ->
            ?LOG_WARNING("Watcher ~p was refused: ~s, refresh the token and restart",
                         [State#state.watcher_name, Reason]),
            _ = refresh_token(Client),
            pause({watch_error, invalid_auth_token}, State);
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
    State = #state{client = c, watcher_name = w, request = #{}, stream = stream, creating = true},
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
-endif.
