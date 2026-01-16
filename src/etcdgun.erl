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
      cred => {Username :: string(), Password :: string()},
      transport => tcp | tls,
      stream_interceptors => [egrpc_stub:stream_interceptor()],
      unary_interceptors => [egrpc_stub:unary_interceptor()]
}.

clients() ->
    Clients = [
        etcdgun_client:client_info(Pid)
     || {_, Pid, _, _} <- supervisor:which_children(etcdgun_client_sup)
    ],
    [Info || {ok, Info} <- Clients].

-spec open(client(), [endpoint()]) -> {ok, pid()} | {error, Reason :: term()}.
open(Client, Endpoints) ->
    open(Client, Endpoints, #{}).

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

-spec prefix_range_end(Key :: binary() | string()) -> string().
prefix_range_end(Key) when is_binary(Key) ->
    prefix_range_end(binary_to_list(Key));

prefix_range_end(Key) when is_list(Key) ->
    RangeEndRev = lists:reverse(Key),
    lists:reverse(find_prefix_rev(RangeEndRev)).

find_prefix_rev([]) -> ?UNBOUND_RANGE_END;
find_prefix_rev([H | T]) when H < 255 -> [H + 1 | T];
find_prefix_rev([_ | T]) -> find_prefix_rev(T).

-ifdef(TEST).
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
