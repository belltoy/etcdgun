-module(etcdgun_watcher_manager).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-export([
    start_link/0,
    last_revision/1,
    update_last_revision/2,
    register_watcher/6
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2
]).

-define(TABLE_NAME, ?MODULE).

-record(watcher, {
    name :: atom(),
    conn_pid :: pid(),
    stream_ref :: reference(),
    monitor_ref :: reference(),
    event_manager_pid :: pid(),
    last_rev :: integer()
}).

register_watcher(WatcherName, ConnPid, StreamRef, EventHandler, EventHandlerArgs, Rev) ->
    gen_server:call(?MODULE, {register_watcher, WatcherName, ConnPid, StreamRef, EventHandler, EventHandlerArgs, Rev}).

last_revision(WatcherName) ->
    case ets:lookup(?TABLE_NAME, WatcherName) of
        [] -> undefined;
        [#watcher{last_rev = Rev}] -> Rev
    end.

update_last_revision(WatcherName, NewRev) ->
    true =:= ets:update_element(?TABLE_NAME, WatcherName, {#watcher.last_rev, NewRev}).

start_link() ->
    case ets:whereis(?TABLE_NAME) of
        undefined -> ets:new(?TABLE_NAME, [named_table, public, set,
                                           {keypos, #watcher.name}]);
        _ -> ok
    end,
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%-------------------------------------------------------------------
%% gen_server callbacks
%%-------------------------------------------------------------------

init([]) ->
    erlang:process_flag(trap_exit, true), %% trap exits to handle watcher terminations
    {ok, #{}}.

handle_call({register_watcher, WatcherName, ConnPid, StreamRef, EventHandler, EventHandlerArgs, Rev}, _From, State) ->
    Result =
        case ets:lookup(?TABLE_NAME, WatcherName) of
            [] ->
                ?LOG_INFO("Registering watcher ~p", [WatcherName]),
                new_watcher(WatcherName, ConnPid, StreamRef, EventHandler, EventHandlerArgs, Rev);
            [#watcher{} = Watcher] ->
                ?LOG_WARNING(#{msg => "Watcher already registered, update",
                               watcher => Watcher#watcher.name}),
                {ok, update_watcher(Watcher, ConnPid, StreamRef, Rev)}
        end,
    case Result of
        {ok, NewWatcher} ->
            ets:insert(?TABLE_NAME, NewWatcher),
            {reply, {ok, NewWatcher#watcher.event_manager_pid}, State};
        {error, _Reason} = E ->
            {reply, E, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, WatcherPid, Reason}, State) ->
    Ms = ets:fun2ms(fun(#watcher{monitor_ref = MRef0} = W) when MRef0 =:= MRef -> W end),
    case ets:select(?TABLE_NAME, Ms) of
        [] ->
            ?LOG_WARNING("Received watcher ~p down for reason: ~p", [WatcherPid, Reason]);
        [#watcher{name = WatcherName} = Watcher] ->
            ?LOG_INFO("Watcher ~p terminated, cleaning up", [WatcherName]),
            is_normal(Reason) andalso deregister_watcher(WatcherName),
            maybe_cleanup_watcher([{Watcher#watcher.conn_pid, Watcher#watcher.stream_ref}])
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

handle_continue(_Continue, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    ?LOG_WARNING("Terminating watcher manager with reason: ~p", [Reason]),
    maybe_cleanup_watcher(maps:values(State)),
    ok.

%%-------------------------------------------------------------------
%% Private functions
%%-------------------------------------------------------------------

is_normal(normal) -> true;
is_normal(shutdown) -> true;
is_normal({shutdown, _}) -> true;
is_normal(_) -> false.

deregister_watcher(WatcherName) ->
    case ets:lookup(?TABLE_NAME, WatcherName) of
        [] ->
            ?LOG_WARNING("Watcher ~p not found for deregistration", [WatcherName]);
        [#watcher{name = WatcherName} = Watcher] ->
            gen_event:stop(Watcher#watcher.event_manager_pid),
            ets:delete(?TABLE_NAME, WatcherName)
    end,
    ok.

maybe_cleanup_watcher([]) -> ok;
maybe_cleanup_watcher([{ConnPid, StreamRef} | Rest]) ->
    ?LOG_INFO("Cleaning up watcher for connection ~p, stream ref ~p", [ConnPid, StreamRef]),
    ok = gun:cancel(ConnPid, StreamRef),
    maybe_cleanup_watcher(Rest).

new_watcher(WatcherName, ConnPid, StreamRef, EventHandler, EventHandlerArgs, Rev) ->
    MRef = erlang:monitor(process, WatcherName),
    {ok, EventManagerPid} = gen_event:start_link(),
    case gen_event:add_handler(EventManagerPid, EventHandler, EventHandlerArgs) of
        ok ->
            {ok, #watcher{name = WatcherName,
                          conn_pid = ConnPid,
                          stream_ref = StreamRef,
                          monitor_ref = MRef,
                          event_manager_pid = EventManagerPid,
                          last_rev = Rev}};
        {'EXIT', Reason} ->
            ?LOG_ERROR("Failed to add event handler for watcher ~p", [WatcherName]),
            erlang:demonitor(MRef, [flush]),
            gen_event:stop(EventManagerPid),
            {error, {event_handler_error, Reason}};
        Other ->
            ?LOG_ERROR("Unexpected result when adding event handler for watcher ~p: ~p", [WatcherName, Other]),
            erlang:demonitor(MRef, [flush]),
            gen_event:stop(EventManagerPid),
            {error, {event_handler_error, Other}}
    end.

update_watcher(Watcher, ConnPid, StreamRef, Rev) ->
    maybe_cleanup_watcher([{Watcher#watcher.conn_pid, Watcher#watcher.stream_ref}]),
    erlang:demonitor(Watcher#watcher.monitor_ref, [flush]),
    MRef = erlang:monitor(process, Watcher#watcher.name),
    Watcher#watcher{conn_pid = ConnPid, stream_ref = StreamRef, monitor_ref = MRef, last_rev = Rev}.
