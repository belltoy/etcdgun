%% @private
-module(etcdgun_watcher_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-export([start_child/5, stop_child/2]).

-define(WATCHER_EVENT_MANAGER, etcdgun_event_manager_table).
-record(watcher_event_manager, {id , event_manager_pid}).

start_link() ->
    etcdgun_watcher:create_watch_cache_table(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_child(Client, WatcherName, EventHandler, EventHandlerArgs, Request) ->
    case validate_request(Request) of
        ok -> do_start_child(Client, WatcherName, EventHandler, EventHandlerArgs, Request);
        {error, _} = Error -> Error
    end.

%% A watcher has one watch, `Request' is the create request of it.
validate_request(#{key := Key} = Request) when is_binary(Key), Key =/= <<>> ->
    case maps:get(fragment, Request, false) of
        false -> ok;
        %% The events of a revision may be split over the fragments, the revision to resume from
        %% would not be right between them.
        _ -> {error, {unsupported_option, fragment}}
    end;
validate_request(#{}) ->
    {error, {invalid_request, key}};
validate_request(_) ->
    {error, {invalid_request, not_a_map}}.

do_start_child(Client, WatcherName, EventHandler, EventHandlerArgs, Request) ->
    {ok, EventMgr} = etcdgun_event_manager_sup:start_event_manager(),
    try
        case gen_event:add_handler(EventMgr, EventHandler, EventHandlerArgs) of
            ok ->
                Args = [Client, WatcherName, EventMgr, Request],
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
            %% The revisions of a watcher which was cancelled are not for a new one of the name,
            %% which would start from them instead of from what its requests say.
            etcdgun_watcher:delete_last_revisions(WatcherName),
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
