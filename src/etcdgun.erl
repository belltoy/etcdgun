-module(etcdgun).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    clients/0,
    open/2,
    open/3,
    close/1,
    watch/5,
    cancel_watch/2,
    prefix_range_end/1
]).

-export_type([
    client/0,
    endpoint/0,
    opts/0
]).

-type client() :: atom().
-type endpoint() :: {Host :: string(), Port :: inet:port_number()}.
-type opts() :: #{
      %% A binary or a string, neither is empty, otherwise `{error, invalid_cred}'.
      cred => {Username :: binary() | string(), Password :: binary() | string()},
      %% The transport of the `Endpoints' to connect to, `tcp' by default. The transport of the
      %% members of the cluster is the scheme of their client URLs, `http' or `https'.
      transport => tcp | tls,
      %% The options of gun for every connection, e.g. `#{tls_opts => [{cacertfile, "ca.pem"}]}'
      %% for `https'. The `transport' is set by etcdgun.
      gun_opts => gun:opts(),
      %% How often to check the members of the cluster, in milliseconds, 5 minutes by default.
      %% `0' and `infinity' disable the check.
      membership_check_interval => non_neg_integer() | infinity,
      %% The egrpc interceptors of every channel, the authentication is not one of them.
      interceptors => [egrpc_interceptor:spec()]
}.

%% @doc The information of the clients which are running.
clients() ->
    Children = supervisor:which_children(etcdgun_client_sup),
    Clients = [client_info(Pid) || Pid <- client_pids(Children)],
    [Info || {ok, Info} <- Clients].

%% A child which is being restarted has no pid (`restarting'), nor one which is not started.
client_pids(Children) ->
    [Pid || {_Id, Pid, _Type, _Modules} <- Children, is_pid(Pid)].

%% The client may be gone since the list was taken.
client_info(Pid) ->
    try
        etcdgun_client:client_info(Pid)
    catch
        exit:_ -> {error, not_running}
    end.

%% @doc Equivalent to `open(Client, Endpoints, #{})', see `open/3'.
-spec open(client(), [endpoint()]) -> {ok, pid()} | {error, Reason :: term()}.
open(Client, Endpoints) ->
    open(Client, Endpoints, #{}).

%% @doc Open a client and connect to the members of the etcd cluster.
%%
%% Returns `{error, no_credentials}' if the etcd server requires authentication but no `cred' is
%% given.
%%
%% The options `unary_interceptors' and `stream_interceptors' of the former versions are replaced
%% by `interceptors', they return `{error, {removed_option, Key}}'. The authentication is not an
%% interceptor to be configured anymore.
-spec open(client(), [endpoint()], opts()) -> {ok, pid()} | {error, Reason :: term()}.
open(Client, Endpoints, Opts) ->
    etcdgun_client_sup:start_child(Client, Endpoints, Opts).

close(Client) ->
    etcdgun_client_sup:stop_child(Client).

watch(Client, WatcherName, EventHandler, EventHandlerArgs, Requests) ->
    etcdgun_watcher_sup:start_child(Client, WatcherName, EventHandler, EventHandlerArgs, Requests).

cancel_watch(Client, WatcherName) ->
    etcdgun_watcher_sup:stop_child(Client, WatcherName).

-define(UNBOUND_RANGE_END, "\0").

%% @doc Given a etcd key, return the end key for a prefix range.
%%
%% The result has the type of the key: a binary for a binary and a string for a string.
-spec prefix_range_end(Key :: binary()) -> binary();
                      (Key :: string()) -> string().
prefix_range_end(Key) when is_binary(Key) ->
    list_to_binary(prefix_range_end(binary_to_list(Key)));

prefix_range_end(Key) when is_list(Key) ->
    RangeEndRev = lists:reverse(Key),
    lists:reverse(find_prefix_rev(RangeEndRev)).

find_prefix_rev([]) -> ?UNBOUND_RANGE_END;
find_prefix_rev([H | T]) when H < 255 -> [H + 1 | T];
find_prefix_rev([_ | T]) -> find_prefix_rev(T).

-ifdef(TEST).
client_pids_test() ->
    Pid = self(),
    Children = [{a, Pid, worker, [m]}, {b, restarting, worker, [m]}, {c, undefined, worker, [m]}],
    ?assertEqual([Pid], client_pids(Children)),
    ?assertEqual([], client_pids([])).

prefix_range_end_binary_test() ->
    ?assertEqual(<<"b">>, prefix_range_end(<<"a">>)),
    ?assertEqual(<<"ab">>, prefix_range_end(<<"aa">>)),
    ?assertEqual(<<"a\x02">>, prefix_range_end(<<"a\x01">>)),
    ?assertEqual(<<"b">>, prefix_range_end(<<"a\xff">>)),
    ?assertEqual(<<0>>, prefix_range_end(<<>>)),
    ?assertEqual(<<0>>, prefix_range_end(<<255, 255>>)),
    ?assert(is_binary(prefix_range_end(<<"/etcdgun_ct/1/">>))).

get_prefix_range_end_test() ->
    ?assertEqual(?UNBOUND_RANGE_END, prefix_range_end([])),
    ?assertEqual("b", prefix_range_end("a")),
    ?assertEqual("a\x01", prefix_range_end("a\x00")),
    ?assertEqual("a\x02", prefix_range_end("a\x01")),
    ?assertEqual("b", prefix_range_end("a\xff")),
    ?assertEqual("c", prefix_range_end("b")),
    ?assertEqual("ab", prefix_range_end("aa")),
    ok.
-endif.
