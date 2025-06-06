-module(etcdgun_membership).

-feature(maybe_expr, enable).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/1,
    get_member_list/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    client :: atom()
}).

-define(CHECK_INTERVAL, 300_000). % 5 minutes

get_member_list(Channel) ->
    maybe
        {ok, #{members := Members0}} ?= etcdgun_etcdserverpb_cluster_service:member_list(Channel, #{}),
        Members = [M || #{} = M <- Members0,
                        (L = maps:get(isLearner, M, false)) =/= true,
                        L =/= 1],
        {ok, Members}
    end.

start_link(Client) ->
    gen_server:start_link(?MODULE, Client, []).

init(Client) ->
    process_flag(trap_exit, true),
    erlang:send_after(?CHECK_INTERVAL, self(), check_membership),
    {ok, #state{client = Client}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_membership, #state{client = Client} = State) ->
    maybe
        {ok, Channel} ?= etcdgun_client:pick_channel(Client),
        {ok, Members} ?= get_member_list(Channel),
        etcdgun_client:sync_membership(Client, Members)
    else
        {error, Reason} ->
            ?LOG_WARNING("Failed to check membership for client ~p: ~p", [Client, Reason])
    end,
    erlang:send_after(?CHECK_INTERVAL, self(), check_membership),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ?LOG_NOTICE("Terminating etcdgun_membership server, reason: ~p", [_Reason]),
    ok.
