%% @private
-module(etcdgun_watcher_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-export([start_child/5, stop_child/2, stop_children/1]).

start_link() ->
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
    Args = [Client, WatcherName, EventHandler, EventHandlerArgs, Request],
    Child = #{
        id => {Client, WatcherName},
        start => {etcdgun_watcher, start_link, Args},
        %% A watcher which stopped is not started again, there is no state left for it to resume
        %% from: whoever watches decides, with the reason of the exit.
        restart => temporary,
        shutdown => 1000,
        type => worker,
        modules => [etcdgun_watcher]
    },
    case supervisor:start_child(?MODULE, Child) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        %% The child spec is in the error of a failed start, with the arguments of the handler.
        {error, {Reason, Spec}} when is_tuple(Spec), element(1, Spec) =:= child ->
            {error, Reason};
        {error, Reason} -> {error, Reason}
    end.

-spec stop_child(atom(), atom()) -> ok | {error, not_found}.
stop_child(Client, WatcherName) ->
    %% The child is temporary, its spec is gone with it.
    supervisor:terminate_child(?MODULE, {Client, WatcherName}).

%% @doc Stop the watchers of a client, they have nothing to watch with when it is closed.
-spec stop_children(atom()) -> ok.
stop_children(Client) ->
    try supervisor:which_children(?MODULE) of
        Children ->
            [_ = supervisor:terminate_child(?MODULE, Id)
             || {{C, _Name} = Id, _Pid, _Type, _Modules} <- Children, C =:= Client],
            ok
    catch
        %% there is no supervisor, there is no watcher
        exit:_ -> ok
    end.
init([]) ->
    MaxRestarts = 300,
    MaxSecondsBetweenRestarts = 10,
    SupFlags = #{
        strategy => one_for_one,
        intensity => MaxRestarts,
        period => MaxSecondsBetweenRestarts
    },
    {ok, {SupFlags, []}}.
