-module(etcdgun_client_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-export([start_child/3, stop_child/1]).

%% The options of the former versions which were replaced by `interceptors'.
-define(REMOVED_OPTS, [unary_interceptors, stream_interceptors]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_child(etcdgun:client(), [etcdgun:endpoint()], etcdgun:opts()) ->
    {ok, pid()} | {error, term()}.
start_child(Client, Endpoints, Opts) ->
    %% Silently dropping them would leave the interceptors of the former versions not working.
    case [K || K <- ?REMOVED_OPTS, is_map_key(K, Opts)] of
        [] ->
            Child = child_spec(Client, Endpoints, Opts),
            case supervisor:start_child(?MODULE, Child) of
                {ok, Pid} when is_pid(Pid) -> {ok, Pid};
                {error, Reason} -> {error, Reason}
            end;
        [Key | _] ->
            {error, {removed_option, Key}}
    end.

-spec stop_child(etcdgun:client()) -> ok | {error, not_found}.
stop_child(Client) ->
    case supervisor:terminate_child(?MODULE, Client) of
        ok -> ok = supervisor:delete_child(?MODULE, Client);
        {error, not_found} = E ->  E
    end.

init([]) ->
    %% Owned by the supervisor, so it outlives the clients. See `etcdgun_client:cached_token/1'.
    ets:new(etcdgun_client_tokens, [set, named_table, public, {read_concurrency, true}]),
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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

removed_option_test() ->
    % eqwalizer:ignore
    ?assertEqual({error, {removed_option, unary_interceptors}},
                 start_child(c, [], #{unary_interceptors => []})),
    % eqwalizer:ignore
    ?assertEqual({error, {removed_option, stream_interceptors}},
                 start_child(c, [], #{cred => {"u", "p"}, stream_interceptors => []})).
-endif.
