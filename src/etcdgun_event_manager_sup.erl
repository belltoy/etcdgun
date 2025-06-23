-module(etcdgun_event_manager_sup).

-behaviour(supervisor).

-export([start_link/0, start_event_manager/0, stop_event_manager/1]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_event_manager() ->
    supervisor:start_child(?MODULE, []).

stop_event_manager(EventManagerPid) ->
    gen_event:stop(EventManagerPid).

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 1,
        period => 5
    },
    EventManager = #{
        id => etcdgun_event_manager,
        start => {gen_event, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [gen_event]
    },
    {ok, {SupFlags, [EventManager]}}.
