%% @doc The balancer of etcdgun channels: round robin among the ready endpoints which passed the
%% check of etcdgun (`healthy => true' in the attributes of the endpoint, which an endpoint
%% without the attribute has).
%%
%% An endpoint which is connected but not healthy yet (just found, or its member has no leader)
%% takes no calls, as the connections which did not pass the check were not used before egrpc.
%% It is not a transport state, the connection is kept. When no ready endpoint is healthy, the
%% ready ones take the calls: a cluster which has no leader does not serve any, but the calls are
%% retried and the first member to be back is used.
%%
%% A call with `attributes => #{etcdgun_target => EndpointId}' goes to that endpoint, healthy or
%% not, this is how the check is made. It fails when the endpoint is not ready.
-module(etcdgun_balancer).

-behaviour(egrpc_balancer).
-behaviour(egrpc_picker).

-include_lib("egrpc/include/egrpc.hrl").

-export([init/1, update_endpoints/2, subchannel_state_changed/3, picker/1]).
-export([pick/2]).

-record(state, {
    endpoints = [] :: [#egrpc_endpoint{}],
    states = #{} :: #{term() => egrpc_balancer:conn_state()},
    counter :: atomics:atomics_ref()
}).

init(_Config) ->
    {ok, #state{counter = atomics:new(1, [])}}.

%% Same ids and addresses: only the attributes changed, the subchannels are kept.
update_endpoints(New, #state{endpoints = Old, states = States0} = State) ->
    {Removed, Added} = egrpc_balancer:diff(Old, New),
    States1 = maps:without(Removed, States0),
    States = maps:merge(States1, #{Id => idle || #egrpc_endpoint{id = Id} <- Added}),
    Actions =
        [{remove_subchannel, Id} || Id <- Removed] ++
        lists:append([[{create_subchannel, E}, {connect, Id}] || #egrpc_endpoint{id = Id} = E <- Added]),
    {ok, Actions, State#state{endpoints = New, states = States}}.

subchannel_state_changed(Id, ConnState, #state{states = States} = State) ->
    case maps:is_key(Id, States) of
        true -> {ok, [], State#state{states = States#{Id := ConnState}}};
        false -> {ok, [], State}
    end.

picker(#state{endpoints = Endpoints, states = States, counter = Counter}) ->
    Ready = [E || #egrpc_endpoint{id = Id} = E <- Endpoints, maps:get(Id, States, idle) =:= ready],
    case Ready of
        [] ->
            egrpc_picker:failing(no_ready_subchannel);
        _ ->
            Healthy = [Id || #egrpc_endpoint{id = Id, attributes = #{healthy := true}} <- Ready]
                ++ [Id || #egrpc_endpoint{id = Id, attributes = A} <- Ready, not is_map_key(healthy, A)],
            Ids = [Id || #egrpc_endpoint{id = Id} <- Ready],
            egrpc_picker:new(?MODULE, {list_to_tuple(Ids), list_to_tuple(candidates(Healthy, Ids)), Counter})
    end.

candidates([], Ready) -> Ready;
candidates(Healthy, _Ready) -> Healthy.

%% @private
pick({Ready, _Candidates, _Counter}, #egrpc_pick_info{call_attributes = #{etcdgun_target := Id}}) ->
    case lists:member(Id, tuple_to_list(Ready)) of
        true -> {ok, result(Id)};
        false -> {error, target_not_ready}
    end;
pick({_Ready, Candidates, Counter}, #egrpc_pick_info{previous_subchannels = Previous}) ->
    N = tuple_size(Candidates),
    Start = atomics:add_get(Counter, 1, 1) - 1,
    Order = [element((Start + I) rem N + 1, Candidates) || I <- lists:seq(0, N - 1)],
    Id = case [I || I <- Order, not lists:member(I, Previous)] of
        [First | _] -> First;
        [] -> hd(Order)
    end,
    {ok, result(Id)}.

result(Id) ->
    #egrpc_pick_result{subchannel = Id, done = egrpc_picker:default_done()}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

ep(Id, Healthy) ->
    #egrpc_endpoint{id = Id, addresses = [#egrpc_address{host = "h", port = 1}],
                    attributes = #{healthy => Healthy}}.

pick_id(Picker, Info) ->
    {ok, #egrpc_pick_result{subchannel = Id}} = egrpc_picker:pick(Picker, Info),
    Id.

ready_all(Ids, S) ->
    lists:foldl(fun(Id, S0) -> {ok, [], S1} = subchannel_state_changed(Id, ready, S0), S1 end, S, Ids).

unhealthy_endpoints_take_no_calls_test() ->
    {ok, S0} = init(#{}),
    {ok, _, S1} = update_endpoints([ep(a, true), ep(b, false), ep(c, true)], S0),
    ?assertEqual({error, no_ready_subchannel}, egrpc_picker:pick(picker(S1), #egrpc_pick_info{})),
    P = picker(ready_all([a, b, c], S1)),
    ?assertEqual([a, c, a, c], [pick_id(P, #egrpc_pick_info{}) || _ <- lists:seq(1, 4)]),
    %% an endpoint which is not ready is not picked
    {ok, [], S2} = subchannel_state_changed(a, transient_failure, ready_all([a, b, c], S1)),
    ?assertEqual([c, c], [pick_id(picker(S2), #egrpc_pick_info{}) || _ <- [1, 2]]).

all_unhealthy_ready_ones_are_used_test() ->
    {ok, S0} = init(#{}),
    {ok, _, S1} = update_endpoints([ep(a, false), ep(b, false)], S0),
    P = picker(ready_all([a, b], S1)),
    ?assertEqual([a, b], lists:sort([pick_id(P, #egrpc_pick_info{}) || _ <- [1, 2]])).

no_attribute_is_healthy_test() ->
    {ok, S0} = init(#{}),
    E = #egrpc_endpoint{id = a, addresses = [#egrpc_address{host = "h", port = 1}]},
    {ok, _, S1} = update_endpoints([E, ep(b, false)], S0),
    P = picker(ready_all([a, b], S1)),
    ?assertEqual([a, a], [pick_id(P, #egrpc_pick_info{}) || _ <- [1, 2]]).

target_test() ->
    {ok, S0} = init(#{}),
    {ok, _, S1} = update_endpoints([ep(a, true), ep(b, false), ep(c, true)], S0),
    {ok, [], S2} = subchannel_state_changed(a, ready, S1),
    {ok, [], S3} = subchannel_state_changed(b, ready, S2),
    P = picker(S3),
    Target = fun(Id) -> #egrpc_pick_info{call_attributes = #{etcdgun_target => Id}} end,
    ?assertEqual([b, b, a], [pick_id(P, Target(Id)) || Id <- [b, b, a]]),
    ?assertEqual({error, target_not_ready}, egrpc_picker:pick(P, Target(c))).

previous_is_avoided_test() ->
    {ok, S0} = init(#{}),
    {ok, _, S1} = update_endpoints([ep(a, true), ep(b, true)], S0),
    P = picker(ready_all([a, b], S1)),
    ?assertEqual([b, b], [pick_id(P, #egrpc_pick_info{previous_subchannels = [a]}) || _ <- [1, 2]]),
    ?assertEqual(a, pick_id(picker(ready_all([a], S1#state{endpoints = [ep(a, true)]})),
                            #egrpc_pick_info{previous_subchannels = [a]})).

attributes_change_keeps_subchannels_test() ->
    {ok, S0} = init(#{}),
    {ok, _, S1} = update_endpoints([ep(a, false)], S0),
    ?assertMatch({ok, [], _}, update_endpoints([ep(a, true)], S1)).
-endif.
