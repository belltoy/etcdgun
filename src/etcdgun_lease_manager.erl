%% @private
%% @doc The `LeaseKeepAlive' stream of a client, and the leases which use it.
%%
%% A client has one stream for all its leases. A lease process (`etcdgun_lease_keepalive') registers
%% its lease here and asks for a keepalive when its time has come, the response goes back to it:
%%
%% - `{lease_keepalive, LeaseId, TTL}': the lease was kept alive, with this time to live;
%% - `{lease_expired, LeaseId}': the lease is gone (revoked or expired), it is not registered any more.
%%
%% When the stream is lost (the connection, the member without a leader, ...) it is opened again,
%% which picks an endpoint again, and a keepalive is sent for every lease at once: the stream is
%% etcdgun's, egrpc does not make it again. While there is no stream the keepalives which are
%% asked for are dropped, the ones of the new stream make up for them. A lease which was not kept
%% alive for its time to live is expired by the server, and told so by the first response.
-module(etcdgun_lease_manager).

-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").

-export([name/1, ensure_started/1, register_lease/3, keepalive/2, unregister_lease/2]).
-export([start_link/1, callback_mode/0, init/1, handle_event/4, terminate/3]).

-record(data, {
    client :: atom(),
    %% LeaseId => the process of the lease and its monitor
    leases = #{} :: #{integer() => {pid(), reference()}},
    %% The registrations which wait for the first response.
    waiting = #{} :: #{integer() => gen_statem:from()},
    stream = undefined :: undefined | egrpc:stream(),
    stream_ref = undefined :: undefined | term(),
    conn_pid = undefined :: undefined | pid(),
    monitor_ref = undefined :: undefined | reference(),
    buf = <<>> :: binary(),
    attempts = 0 :: non_neg_integer()
}).

%% How long a registration waits for the first response.
-define(REGISTER_TIMEOUT, 5000).
-define(RECONNECT_INTERVAL, 500).
-define(RECONNECT_MAX, 2000).

%% The registered name of the manager of a client.
-spec name(atom()) -> atom().
name(Client) ->
    binary_to_atom(<<"etcdgun_lease_manager_", (atom_to_binary(Client))/binary>>).

start_link(Client) ->
    gen_statem:start_link({local, name(Client)}, ?MODULE, Client, []).

%% @doc Register the lease, kept alive for the process `Pid'. Returns when the first response came:
%% the time to live, or `lease_expired' for a lease which does not exist.
-spec register_lease(atom(), integer(), pid()) -> {ok, pos_integer()} | {error, term()}.
register_lease(Client, LeaseId, Pid) ->
    try
        gen_statem:call(name(Client), {register, LeaseId, Pid}, ?REGISTER_TIMEOUT + 1000)
    catch
        exit:{noproc, _} -> {error, client_not_running};
        exit:{timeout, _} -> {error, timeout}
    end.

%% @doc Ask for a keepalive of the lease.
-spec keepalive(atom(), integer()) -> ok.
keepalive(Client, LeaseId) ->
    gen_statem:cast(name(Client), {keepalive, LeaseId}).

-spec unregister_lease(atom(), integer()) -> ok.
unregister_lease(Client, LeaseId) ->
    gen_statem:cast(name(Client), {unregister, LeaseId}).

%% @doc Start the manager of the client if it is not running. It is started by the supervisor, so a
%% lease process (which is started by it) can not do it in its `init/1'.
-spec ensure_started(atom()) -> ok | {error, term()}.
ensure_started(Client) ->
    case whereis(name(Client)) of
        undefined ->
            case etcdgun_lease_keepalive_sup:start_manager(Client) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok;
                {error, _} = Error -> Error
            end;
        _ ->
            ok
    end.

%%-------------------------------------------------------------------
%% gen_statem callbacks
%%-------------------------------------------------------------------

callback_mode() -> handle_event_function.

%% The states: `idle' (no lease), `connected' (the stream is open), `disconnected' (there are
%% leases and no stream, a new one is opened after a pause).
init(Client) ->
    process_flag(trap_exit, true),
    {ok, idle, #data{client = Client}}.

handle_event({call, From}, {register, LeaseId, Pid}, State, Data) ->
    register_lease(State, LeaseId, Pid, From, Data);

handle_event(cast, {unregister, LeaseId}, _State, Data) ->
    forget(LeaseId, Data);

handle_event(cast, {keepalive, LeaseId}, connected, #data{leases = Leases} = Data) ->
    case is_map_key(LeaseId, Leases) of
        true -> send(LeaseId, Data);
        false -> keep_state_and_data
    end;
handle_event(cast, {keepalive, _LeaseId}, _State, _Data) ->
    keep_state_and_data;

%% The process of a lease is gone.
handle_event(info, {'DOWN', MRef, process, Pid, _Reason}, State, #data{leases = Leases} = Data) ->
    case [Id || Id := {P, M} <- Leases, P =:= Pid, M =:= MRef] of
        [LeaseId] -> forget(LeaseId, Data);
        [] -> lost_connection_or_ignore(State, MRef, Data)
    end;

handle_event(internal, process_more, connected, Data) ->
    process_data(Data);
handle_event(internal, process_more, _State, _Data) ->
    keep_state_and_data;

handle_event(state_timeout, reconnect, disconnected, Data) ->
    reconnect(Data);

handle_event({timeout, {register, LeaseId}}, register, _State, #data{waiting = Waiting} = Data) ->
    case Waiting of
        #{LeaseId := From} ->
            Waiting1 = maps:remove(LeaseId, Waiting),
            {keep_state, Data#data{waiting = Waiting1}, [{reply, From, {error, timeout}}]};
        _ ->
            keep_state_and_data
    end;

handle_event(info, {gun_data, _ConnPid, StreamRef, nofin, Chunk}, connected,
             #data{stream_ref = StreamRef, buf = Buf} = Data) ->
    process_data(Data#data{buf = <<Buf/binary, Chunk/binary>>});
handle_event(info, {gun_data, _ConnPid, StreamRef, fin, _Chunk}, connected, #data{stream_ref = StreamRef} = Data) ->
    lost({grpc_error, eos}, Data);
handle_event(info, {gun_trailers, _ConnPid, StreamRef, _Trailers}, connected, #data{stream_ref = StreamRef} = Data) ->
    %% When there is no leader
    lost({grpc_error, eos}, Data);
handle_event(info, {gun_error, _ConnPid, StreamRef, Reason}, connected, #data{stream_ref = StreamRef} = Data) ->
    lost({stream_error, Reason}, Data);
handle_event(info, {gun_error, ConnPid, Reason}, connected, #data{conn_pid = ConnPid} = Data) ->
    lost({connection_error, Reason}, Data);

handle_event(info, Info, _State, _Data)
  when is_tuple(Info), element(1, Info) =:= gun_data;
       is_tuple(Info), element(1, Info) =:= gun_trailers;
       is_tuple(Info), element(1, Info) =:= gun_error;
       is_tuple(Info), element(1, Info) =:= gun_response;
       is_tuple(Info), element(1, Info) =:= gun_inform ->
    keep_state_and_data;
handle_event(info, {'EXIT', _Pid, _Reason}, _State, _Data) ->
    keep_state_and_data;
handle_event(_Type, Msg, _State, _Data) ->
    ?LOG_WARNING("Unexpected message in the lease manager: ~p", [Msg]),
    keep_state_and_data.

terminate(_Reason, _State, #data{stream = Stream}) ->
    stream_cancel(Stream).

%%-------------------------------------------------------------------
%% Private functions
%%-------------------------------------------------------------------

register_lease(State, LeaseId, Pid, From, #data{leases = Leases, waiting = Waiting} = Data) ->
    MRef = erlang:monitor(process, Pid),
    Data1 = Data#data{leases = Leases#{LeaseId => {Pid, MRef}}},
    Timer = {{timeout, {register, LeaseId}}, ?REGISTER_TIMEOUT, register},
    case State of
        connected ->
            case send(LeaseId, Data1#data{waiting = Waiting#{LeaseId => From}}) of
                {keep_state, Data2} -> {keep_state, Data2, [Timer]};
                Lost -> Lost %% it answered the waiting ones
            end;
        _ ->
            %% The stream is opened for the lease, a failure is the answer of the registration.
            case connect(Data1) of
                {ok, Data2} ->
                    {next_state, connected, Data2#data{waiting = Waiting#{LeaseId => From}}, [Timer]};
                {error, Reason} ->
                    erlang:demonitor(MRef, [flush]),
                    {next_state, after_failure(Data), Data, [{reply, From, {error, Reason}}] ++ retry(Data)}
            end
    end.

after_failure(#data{leases = Leases}) when map_size(Leases) =:= 0 -> idle;
after_failure(_) -> disconnected.

retry(#data{leases = Leases}) when map_size(Leases) =:= 0 -> [];
retry(#data{attempts = Attempts}) -> [{state_timeout, delay(Attempts), reconnect}].

delay(Attempts) ->
    min(?RECONNECT_MAX, ?RECONNECT_INTERVAL * max(1, Attempts)).

%% Open the stream and send a keepalive for every lease, the headers of the response tell it works.
connect(#data{client = Client, leases = Leases} = Data) ->
    case etcdgun_etcdserverpb_lease_stub:lease_keep_alive(Client) of
        {ok, Stream} ->
            case send_all(maps:keys(Leases), Stream) of
                {ok, Stream1} ->
                    case egrpc_stream:recv_header(Stream1, 5000) of
                        {ok, Stream2} ->
                            ConnPid = egrpc_stream:conn_pid(Stream2),
                            {ok, Data#data{stream = Stream2, stream_ref = egrpc_stream:stream_ref(Stream2),
                                           conn_pid = ConnPid, monitor_ref = erlang:monitor(process, ConnPid),
                                           buf = <<>>, attempts = 0}};
                        {error, _} = Error ->
                            egrpc_stream:cancel_stream(Stream1),
                            Error
                    end;
                {error, _} = Error ->
                    egrpc_stream:cancel_stream(Stream),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

send_all([], Stream) -> {ok, Stream};
send_all([LeaseId | Rest], Stream) ->
    case egrpc_stream:send_msg(Stream, #{'ID' => LeaseId}, nofin) of
        {ok, Stream1} -> send_all(Rest, Stream1);
        {error, _} = Error -> Error
    end.

send(LeaseId, #data{stream = Stream} = Data) ->
    case egrpc_stream:send_msg(Stream, #{'ID' => LeaseId}, nofin) of
        {ok, Stream1} -> {keep_state, Data#data{stream = Stream1}};
        {error, Reason} -> lost(Reason, Data)
    end.

%% The stream is lost: a new one is opened after a pause, a lease which waits for its first response
%% is answered with the reason, it asks again.
lost(Reason, #data{waiting = Waiting} = Data) ->
    ?LOG_WARNING("Lease keepalive stream lost: ~p, open it again", [Reason]),
    Data1 = disconnect(Data#data{waiting = #{}}),
    Replies = [{reply, From, {error, Reason}} || From <- maps:values(Waiting)],
    Cancels = [{{timeout, {register, Id}}, cancel} || Id <- maps:keys(Waiting)],
    Data2 = lists:foldl(fun drop/2, Data1, maps:keys(Waiting)),
    {next_state, after_failure(Data2), Data2#data{attempts = Data2#data.attempts + 1},
     Replies ++ Cancels ++ retry(Data2#data{attempts = Data2#data.attempts + 1})}.

%% A lease which is no more registered (its process is gone, or it told so).
drop(LeaseId, #data{leases = Leases} = Data) ->
    case Leases of
        #{LeaseId := {_Pid, MRef}} ->
            erlang:demonitor(MRef, [flush]),
            Data#data{leases = maps:remove(LeaseId, Leases)};
        _ ->
            Data
    end.

forget(LeaseId, #data{waiting = Waiting} = Data0) ->
    Data = drop(LeaseId, Data0#data{waiting = maps:remove(LeaseId, Waiting)}),
    case map_size(Data#data.leases) of
        0 ->
            {next_state, idle, disconnect(Data), [{state_timeout, infinity, reconnect}]};
        _ ->
            {keep_state, Data}
    end.

disconnect(#data{stream = Stream, monitor_ref = MRef} = Data) ->
    stream_cancel(Stream),
    is_reference(MRef) andalso erlang:demonitor(MRef, [flush]),
    Data#data{stream = undefined, stream_ref = undefined, conn_pid = undefined, monitor_ref = undefined,
              buf = <<>>}.

stream_cancel(undefined) -> ok;
stream_cancel(Stream) -> egrpc_stream:cancel_stream(Stream).

lost_connection_or_ignore(connected, MRef, #data{monitor_ref = MRef} = Data) ->
    lost({down, connection}, Data);
lost_connection_or_ignore(_State, _MRef, _Data) ->
    keep_state_and_data.

reconnect(Data) ->
    case connect(Data) of
        {ok, Data1} ->
            ?LOG_NOTICE("Lease keepalive stream opened again"),
            {next_state, connected, Data1};
        {error, Reason} ->
            ?LOG_WARNING("Lease keepalive stream can not be opened: ~p", [Reason]),
            Data1 = Data#data{attempts = Data#data.attempts + 1},
            {keep_state, Data1, retry(Data1)}
    end.

%% The responses of the buffer, to the leases they are for.
process_data(#data{buf = Buf, stream = Stream} = Data) ->
    case egrpc_stream:parse_msg(Stream, Buf) of
        more ->
            {keep_state, Data};
        {error, Reason} ->
            lost({grpc_error, Reason}, Data);
        {ok, Stream1, Response, Rest} ->
            handle_response(Response, Data#data{stream = Stream1, buf = Rest})
    end.

handle_response(#{'ID' := LeaseId, 'TTL' := TTL}, #data{leases = Leases, waiting = Waiting} = Data) ->
    Lease = maps:find(LeaseId, Leases),
    Reply = case TTL > 0 of
        true -> {ok, TTL};
        false -> {error, lease_expired}
    end,
    {Actions, Data1} = case {Reply, Lease} of
        {{error, lease_expired}, _} ->
            %% The lease is gone, whoever waits is answered, a running one is told.
            [Pid ! {lease_expired, LeaseId} || {ok, {Pid, _}} <- [Lease], not is_map_key(LeaseId, Waiting)],
            {answer(LeaseId, Reply, Data), drop(LeaseId, Data)};
        {{ok, _}, {ok, {Pid, _}}} ->
            case maps:is_key(LeaseId, Waiting) of
                true -> {answer(LeaseId, Reply, Data), Data};
                false -> Pid ! {lease_keepalive, LeaseId, TTL}, {[], Data}
            end;
        {_, error} ->
            %% unregistered meanwhile
            {[], Data}
    end,
    Data2 = Data1#data{waiting = maps:remove(LeaseId, Waiting)},
    case map_size(Data2#data.leases) of
        0 ->
            {next_state, idle, disconnect(Data2), Actions};
        _ ->
            continue(Actions, Data2)
    end;
handle_response(Response, Data) ->
    ?LOG_WARNING("Unexpected lease keepalive response: ~p", [Response]),
    continue([], Data).

answer(LeaseId, Reply, #data{waiting = Waiting}) ->
    case Waiting of
        #{LeaseId := From} -> [{reply, From, Reply}, {{timeout, {register, LeaseId}}, cancel}];
        _ -> []
    end.

%% The next response, if there is another.
continue(Actions, Data) ->
    {keep_state, Data, Actions ++ [{next_event, internal, process_more}]}.
