-module(etcdgun_watch_event_handler).

-behaviour(gen_event).

-include_lib("kernel/include/logger.hrl").

-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2]).

init(Opts) ->
    ?LOG_INFO("Watch event handler initialized: ~p", [Opts]),
    {ok, Opts}.

handle_event(Event, State) ->
    ?LOG_INFO("Watch event handler received event: ~p", [Event]),
    {ok, State}.

handle_call(_Request, State) ->
    {reply, ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
