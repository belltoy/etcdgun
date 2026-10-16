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
            case hide_cred(Opts) of
                {ok, Opts1} -> do_start_child(Client, Endpoints, Opts1);
                {error, _} = Error -> Error
            end;
        [Key | _] ->
            {error, {removed_option, Key}}
    end.

do_start_child(Client, Endpoints, Opts) ->
    Child = child_spec(Client, Endpoints, Opts),
    case supervisor:start_child(?MODULE, Child) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        %% The child spec is in the error of a failed start.
        {error, {Reason, Spec}} when is_tuple(Spec), element(1, Spec) =:= child ->
            {error, Reason};
        {error, Reason} -> {error, Reason}
    end.

%% The child spec is printed by the supervisor, in the reports and in `which_children'-like calls
%% (`supervisor:get_childspec/2'), and the credentials must not be in it. A fun is printed as a
%% reference to the module, not with what it captured.
hide_cred(#{cred := Cred} = Opts) when Cred =/= undefined ->
    case etcdgun_client:normalize_cred(Cred) of
        {ok, Normalized} -> {ok, Opts#{cred := fun() -> Normalized end}};
        {error, _} = Error -> Error
    end;
hide_cred(Opts) ->
    {ok, Opts}.

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

hide_cred_test() ->
    {ok, #{cred := Fun} = Opts} = hide_cred(#{cred => {"root", "secret"}, other => 1}),
    ?assertEqual({<<"root">>, <<"secret">>}, Fun()),
    ?assertEqual(1, maps:get(other, Opts)),
    %% nothing of the secret is in what is printed
    ?assertEqual(nomatch, string:find(lists:flatten(io_lib:format("~0p", [Opts])), "secret")),
    ?assertEqual({ok, #{}}, hide_cred(#{})),
    ?assertEqual({ok, #{cred => undefined}}, hide_cred(#{cred => undefined})),
    ?assertEqual({error, invalid_cred}, hide_cred(#{cred => {"root", ""}})).

removed_option_test() ->
    ?assertEqual({error, {removed_option, unary_interceptors}},
                % eqwalizer:ignore
                 start_child(c, [], #{unary_interceptors => []})),
    ?assertEqual({error, {removed_option, stream_interceptors}},
                % eqwalizer:ignore
                 start_child(c, [], #{cred => {"u", "p"}, stream_interceptors => []})).
-endif.
