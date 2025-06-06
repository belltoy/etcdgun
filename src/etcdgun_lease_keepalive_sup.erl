-module(etcdgun_lease_keepalive_sup).

-behaviour(supervisor).

-export([start_link/0, init/1, start_child/2]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_child(Client, LeaseId) ->
    supervisor:start_child(?SERVER, [Client, LeaseId]).

init([]) ->
    MaxRestarts = 300,
    MaxSecondsBetweenRestarts = 10,
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => MaxRestarts,
        period => MaxSecondsBetweenRestarts},
    Worker = etcdgun_lease_keepalive,
    Child = #{
        id => Worker,
        start => {Worker, start_link, []},
        restart => transient,
        shutdown => 1000,
        type => worker,
        modules => [Worker]},
    {ok, {SupFlags, [Child]}}.
