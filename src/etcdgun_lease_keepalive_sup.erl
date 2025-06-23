-module(etcdgun_lease_keepalive_sup).

-behaviour(supervisor).

-export([start_link/0, init/1, start_child/2, start_child/3, stop_child/2]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_child(Client, LeaseId) ->
    start_child(Client, LeaseId, false).

start_child(Client, LeaseId, RevokeWhenShutdown) ->
    Child = #{
        id => {Client, LeaseId},
        start => {etcdgun_lease_keepalive, start_link, [Client, LeaseId, RevokeWhenShutdown]},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [etcdgun_lease_keepalive]},
    case supervisor:start_child(?SERVER, Child) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        {error, already_present} -> {error, already_present};
        {error, {already_started, _}} -> {error, already_started};
        {error, {Reason, _Spec}} -> {error, Reason};
        {error, _} = E -> E
    end.

stop_child(Client, LeaseId) ->
    case supervisor:terminate_child(?SERVER, {Client, LeaseId}) of
        ok ->
            ok = supervisor:delete_child(?SERVER, {Client, LeaseId});
        {error, not_found} = E -> E
    end.

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10},
    {ok, {SupFlags, []}}.
