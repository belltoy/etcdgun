-module(etcdgun_lease_keepalive_sup).

-behaviour(supervisor).

-export([start_link/0, init/1, start_child/2, start_child/3, stop_child/2]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Equivalent to `start_child(Client, LeaseId, false)'.
start_child(Client, LeaseId) ->
    start_child(Client, LeaseId, false).

%% @doc Start a process which keeps the lease alive.
%%
%% It returns when the keepalive stream is established and the first response was received.
%% Otherwise `{error, Reason}' is returned, for example `lease_expired' when the lease does not
%% exist or has no time to live, `client_not_running' or the error of the connection or of the
%% server. The process which failed to start exits with `Reason', which is not `normal', so the
%% failure of the start is also in the logs as a crash report of the process.
%%
%% A started process is not restarted. It stops with the reason `{shutdown, lease_expired}' when
%% the lease is gone (revoked by someone else or expired), and the pid is to be monitored to know.
%% `RevokeWhenShutdown' revokes the lease when the process is stopped normally, by `stop_child/2'
%% or at the shutdown of the application.
-spec start_child(etcdgun:client(), integer(), boolean()) ->
    {ok, pid()} | {error, term()}.
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
    %% The child is `temporary', its spec is gone once it is terminated.
    supervisor:terminate_child(?SERVER, {Client, LeaseId}).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10},
    {ok, {SupFlags, []}}.
