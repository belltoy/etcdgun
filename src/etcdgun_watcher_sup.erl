-module(etcdgun_watcher_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-export([start_child/5]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_child(Client, WatcherName, EventHandler, EventHandlerArgs, Request) ->
    supervisor:start_child(?MODULE, [Client, WatcherName, EventHandler, EventHandlerArgs, Request]).

init([]) ->
    MaxRestarts = 300,
    MaxSecondsBetweenRestarts = 10,
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => MaxRestarts,
        period => MaxSecondsBetweenRestarts
    },
    Worker = etcdgun_watcher,
    Child = #{
        id => Worker,
        start => {Worker, start_link, []},
        restart => transient,
        shutdown => 1000,
        type => worker,
        modules => [Worker]
    },
    {ok, {SupFlags, [Child]}}.
