-module(etcdgun).

-export([
    clients/0,
    open/2,
    open/3,
    close/1
]).

-export_type([
    client/0
]).

-type client() :: atom().

clients() ->
    Clients = [
        etcdgun_client:client_info(Pid)
     || {_, Pid, _, _} <- supervisor:which_children(etcdgun_client_sup)
    ],
    [Info || {ok, Info} <- Clients].

open(Client, Endpoints) ->
    open(Client, Endpoints, #{}).

open(Client, Endpoints, Opts) ->
    etcdgun_client_sup:start_child(Client, Endpoints, Opts).

close(Client) ->
    etcdgun_client:stop(Client).
