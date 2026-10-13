%% @private
-module(etcdgun_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    %% The subtrees are independent: a restart of one is not a reason to drop the connections,
    %% the watches and the lease keepalives of the others, which are not started again by a
    %% supervisor which is restarted (they are dynamic children), the lease keepalives are
    %% not restarted at all. The clients and the watchers notice that a connection is gone.
    SupFlags = #{
        strategy => one_for_one,
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
    {ok, {SupFlags, [ClientSup, EventManagerSup, LeaseKeepaliveSup, WatcherSup]}}.
