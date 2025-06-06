-module(etcdgun_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Clients = application:get_env(etcdgun, clients, []),
    {ok, Pid} = etcdgun_sup:start_link(),
    start_clients(Clients),
    {ok, Pid}.

stop(_State) ->
    ok.

%% internal functions
start_clients([]) ->
    ok;
start_clients([{Client, Endpoints, Opts} | Rest]) ->
    {ok, _Pid} = etcdgun_client_sup:start_child(Client, Endpoints, Opts),
    start_clients(Rest).
