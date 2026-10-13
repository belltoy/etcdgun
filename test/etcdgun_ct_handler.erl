%% A gen_event handler for the watcher tests, sends every event to the pid it was added with.
-module(etcdgun_ct_handler).

-behaviour(gen_event).

-export([init/1, handle_event/2, handle_call/2]).

init(Pid) -> {ok, Pid}.

handle_event(Event, Pid) ->
    Pid ! {watch_event, Event},
    {ok, Pid}.

handle_call(_Request, Pid) -> {ok, ok, Pid}.
