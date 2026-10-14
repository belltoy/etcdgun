%% A gen_event handler for the watcher tests, sends every event to the pid it was added with.
%%
%% The value of a key says what the handler does with the events of it: `crash' makes it raise,
%% `remove' returns `remove_handler'. The arg `fail' makes the initialisation fail.
-module(etcdgun_ct_handler).

-behaviour(gen_event).

-export([init/1, handle_event/2, handle_call/2, terminate/2]).

init(fail) ->
    {error, init_failed};
init({slow_terminate, Pid}) ->
    put(slow_terminate, true),
    init(Pid);
init(Pid) ->
    Pid ! handler_init,
    {ok, Pid}.

handle_event({watch_events, Events}, Pid) ->
    Values = [V || #{kv := #{value := V}} <- Events],
    case lists:member(<<"crash">>, Values) of
        true -> error(crash_by_request);
        false ->
            case lists:member(<<"remove">>, Values) of
                true -> remove_handler;
                false -> send({watch_events, Events}, Pid)
            end
    end;
handle_event(Event, Pid) ->
    send(Event, Pid).

send(Event, Pid) ->
    Pid ! {watch_event, Event},
    {ok, Pid}.

handle_call(_Request, Pid) -> {ok, ok, Pid}.

terminate(Reason, Pid) ->
    get(slow_terminate) =:= true andalso timer:sleep(5000),
    Pid ! {handler_terminate, Reason},
    ok.
