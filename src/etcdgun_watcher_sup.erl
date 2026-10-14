%% @private
-module(etcdgun_watcher_sup).

-feature(maybe_expr, enable).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-export([start_child/5, stop_child/2, stop_children/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_child(Client, WatcherName, EventHandler, EventHandlerArgs, Request) ->
    maybe
        ok ?= validate_handler(EventHandler),
        ok ?= validate_request(Request),
        do_start_child(Client, WatcherName, EventHandler, EventHandlerArgs, Request)
    end.

%% A watch without a handler has nobody to give the events to: the handler is a module (or
%% `{Module, Id}', as for `gen_event') which has the callbacks which are called.
validate_handler({Module, _Id}) when is_atom(Module) ->
    validate_handler(Module, {Module, _Id});
validate_handler(Module) ->
    validate_handler(Module, Module).

validate_handler(Module, Handler) when is_atom(Module), Module =/= undefined ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, init, 1)
                andalso erlang:function_exported(Module, handle_event, 2) of
                true -> ok;
                false -> {error, {invalid_handler, Handler}}
            end;
        _ ->
            {error, {invalid_handler, Handler}}
    end;
validate_handler(_Module, Handler) ->
    {error, {invalid_handler, Handler}}.

%% A watcher has one watch, `Request' is the create request of it.
validate_request(#{key := Key} = Request) when is_binary(Key), Key =/= <<>> ->
    case maps:get(fragment, Request, false) of
        false -> ok;
        %% The events of a revision may be split over the fragments, the revision to resume from
        %% would not be right between them.
        _ -> {error, {unsupported_option, fragment}}
    end;
validate_request(#{}) ->
    {error, {invalid_request, key}};
validate_request(_) ->
    {error, {invalid_request, not_a_map}}.

do_start_child(Client, WatcherName, EventHandler, EventHandlerArgs, Request) ->
    Args = [Client, WatcherName, EventHandler, EventHandlerArgs, Request],
    Child = #{
        id => {Client, WatcherName},
        start => {etcdgun_watcher, start_link, Args},
        %% A watcher which stopped is not started again, there is no state left for it to resume
        %% from: whoever watches decides, with the reason of the exit.
        restart => temporary,
        shutdown => 1000,
        type => worker,
        modules => [etcdgun_watcher]
    },
    case supervisor:start_child(?MODULE, Child) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        %% The child spec is in the error of a failed start, with the arguments of the handler.
        {error, {Reason, Spec}} when is_tuple(Spec), element(1, Spec) =:= child ->
            {error, Reason};
        {error, Reason} -> {error, Reason}
    end.

-spec stop_child(atom(), atom()) -> ok | {error, not_found}.
stop_child(Client, WatcherName) ->
    %% The supervisor waits for the watcher to end, which waits for it when it is the handler who
    %% asks: it is killed after its shutdown time. A handler asks with its return.
    whereis(WatcherName) =:= self() andalso error(called_from_the_handler),
    %% The child is temporary, its spec is gone with it.
    supervisor:terminate_child(?MODULE, {Client, WatcherName}).

%% @doc Stop the watchers of a client, they have nothing to watch with when it is closed.
-spec stop_children(atom()) -> ok.
stop_children(Client) ->
    try supervisor:which_children(?MODULE) of
        Children ->
            [begin
                 Pid =:= self() andalso error(called_from_the_handler),
                 supervisor:terminate_child(?MODULE, Id)
             end || {{C, _Name} = Id, Pid, _Type, _Modules} <- Children, C =:= Client],
            ok
    catch
        %% there is no supervisor, there is no watcher
        exit:_ -> ok
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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

validate_handler_test() ->
    %% there has to be a handler, a module which has the callbacks
    ?assertEqual({error, {invalid_handler, undefined}}, validate_handler(undefined)),
    ?assertEqual({error, {invalid_handler, no_such_handler_module_xyz}},
                 validate_handler(no_such_handler_module_xyz)),
    ?assertEqual({error, {invalid_handler, lists}}, validate_handler(lists)),
    ?assertEqual({error, {invalid_handler, {lists, id}}}, validate_handler({lists, id})),
    ?assertEqual({error, {invalid_handler, 1}}, validate_handler(1)),
    ?assertEqual({error, {invalid_handler, "handler"}}, validate_handler("handler")).
-endif.
