-module(etcdgun_client_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-export([start_child/3, stop_child/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_child(etcdgun:client(), [etcdgun:endpoint()], etcdgun:opts()) ->
    {ok, pid()} | {error, term()}.
start_child(Client, Endpoints, Opts) ->
    Child = child_spec(Client, Endpoints, Opts),
    case supervisor:start_child(?MODULE, Child) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

-spec stop_child(etcdgun:client()) -> ok | {error, not_found}.
stop_child(Client) ->
    case supervisor:terminate_child(?MODULE, Client) of
        ok -> ok = supervisor:delete_child(?MODULE, Client);
        {error, not_found} = E ->  E
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

child_spec(Client, Endpoints, Opts) ->
    #{
        id => Client,
        start => {etcdgun_client, start_link, [Client, Endpoints, Opts]},
        restart => transient,
        shutdown => infinity,
        type => worker,
        modules => [etcdgun_client]
    }.
