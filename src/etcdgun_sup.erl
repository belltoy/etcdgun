-module(etcdgun_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 1,
        period => 5
    },
    ClientSup = #{
        id => etcdgun_client_sup,
        start => {etcdgun_client_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [etcdgun_client_sup]
    },
    LeaseKeepaliveSup = #{
        id => etcdgun_lease_keepalive_sup,
        start => {etcdgun_lease_keepalive_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [etcdgun_lease_keepalive_sup]
    },
    WatcherSup = #{
        id => etcdgun_watcher_sup,
        start => {etcdgun_watcher_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [etcdgun_watcher_sup]
    },
    EventManagerSup = #{
        id => etcdgun_event_manager_sup,
        start => {etcdgun_event_manager_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [etcdgun_event_manager_sup]
    },
    {ok, {SupFlags, [ClientSup, LeaseKeepaliveSup, EventManagerSup, WatcherSup]}}.
