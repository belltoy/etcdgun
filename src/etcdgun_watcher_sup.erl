-module(etcdgun_watcher_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-export([start_child/5, stop_child/2]).

-define(WATCHER_EVENT_MANAGER, etcdgun_event_manager_table).
-record(watcher_event_manager, {id , event_manager_pid}).

start_link() ->
    etcdgun_watcher:create_watch_cache_table(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_child(Client, WatcherName, EventHandler, EventHandlerArgs, Requests) ->

    {ok, EventMgr} = etcdgun_event_manager_sup:start_event_manager(),
    try
        case gen_event:add_handler(EventMgr, EventHandler, EventHandlerArgs) of
            ok ->
                Args = [Client, WatcherName, EventMgr, Requests],
                Child = #{
                    id => {Client, WatcherName},
                    start => {etcdgun_watcher, start_link, Args},
                    restart => transient,
                    shutdown => 1000,
                    type => worker,
                    modules => [etcdgun_watcher]
                },
                case supervisor:start_child(?MODULE, Child) of
                    {ok, Pid} when is_pid(Pid) ->
                        Record = #watcher_event_manager{
                            id = {Client, WatcherName},
                            event_manager_pid = EventMgr
                        },
                        ets:insert(?WATCHER_EVENT_MANAGER, Record),
                        {ok, Pid};
                    {error, Reason} -> error(Reason)
                end;
            {'EXIT', Reason} ->
                error(Reason);
            Other ->
                error(Other)
        end
    catch
        error:Reason1 ->
            gen_event:stop(EventMgr),
            {error, Reason1}
    end.

-spec stop_child(atom(), atom()) -> ok | {error, not_found}.
stop_child(Client, WatcherName) ->
    case supervisor:terminate_child(?MODULE, {Client, WatcherName}) of
        ok ->
            ok = supervisor:delete_child(?MODULE, {Client, WatcherName}),
            case ets:lookup(?WATCHER_EVENT_MANAGER, {Client, WatcherName}) of
                [#watcher_event_manager{event_manager_pid = EventMgr} = Record] ->
                    ets:delete_object(?WATCHER_EVENT_MANAGER, Record),
                    ok = etcdgun_event_manager_sup:stop_event_manager(EventMgr),
                    ok;
                [] -> ok
            end,
            ok;
        {error, not_found} = E -> E
    end.

init([]) ->
    case ets:info(?WATCHER_EVENT_MANAGER) of
        undefined ->
            ets:new(?WATCHER_EVENT_MANAGER,
                    [named_table, public, set, {keypos, #watcher_event_manager.id}]);
        _ -> ok
    end,
    MaxRestarts = 300,
    MaxSecondsBetweenRestarts = 10,
    SupFlags = #{
        strategy => one_for_one,
        intensity => MaxRestarts,
        period => MaxSecondsBetweenRestarts
    },
    {ok, {SupFlags, []}}.
