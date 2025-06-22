-module(etcdgun).

-export([
    clients/0,
    open/2,
    open/3,
    close/1
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
    etcdgun_client:stop(Client).
