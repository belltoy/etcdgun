-module(etcdgun_client_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-export([start_child/3]).

-define(SERVER, ?MODULE).
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_child(Client, Endpoints, Opts) ->
    supervisor:start_child(?SERVER, [Client, Endpoints, Opts]).

init([]) ->
    MaxRestarts = 300,
    MaxSecondsBetweenRestarts = 10,
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => MaxRestarts,
        period => MaxSecondsBetweenRestarts
    },
    Worker = etcdgun_client,
    Child = #{
        id => Worker,
        start => {Worker, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [Worker]
    },
    {ok, {SupFlags, [Child]}}.
