%% Integration tests against an etcd cluster of the docker-compose, 3.5, 3.6 or 3.7, which has
%% authentication enabled with the user `root' and the password `123456', see `just etcd-up' and
%% `just ct-all'. The suite is skipped when the cluster is not reachable.
-module(etcdgun_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).

-export([
    no_credentials/1,
    wrong_password/1,
    kv_and_cluster/1,
    update_and_unset_cred/1,
    token_refresh/1,
    watch_events/1,
    watch_reconnect/1,
    lease_keepalive/1,
    membership_sync/1,
    member_down/1,
    member_add_remove/1
]).

-define(CLIENT, etcdgun_ct).
-define(ENDPOINTS, [{"127.0.0.1", 2379}, {"127.0.0.1", 2479}, {"127.0.0.1", 2579}]).
-define(CRED, {"root", "123456"}).
-define(TOKEN_TABLE, etcdgun_client_tokens).

all() ->
    [
        no_credentials,
        wrong_password,
        kv_and_cluster,
        update_and_unset_cred,
        token_refresh,
        watch_events,
        watch_reconnect,
        lease_keepalive,
        membership_sync,
        member_down,
        member_add_remove
    ].

init_per_suite(Config) ->
    case gen_tcp:connect("127.0.0.1", 2379, [], 1000) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            {ok, _} = application:ensure_all_started(etcdgun),
            Config;
        {error, _} ->
            {skip, no_etcd}
    end.

end_per_suite(_Config) ->
    application:stop(etcdgun),
    ok.

init_per_testcase(Case, Config) when Case =:= no_credentials; Case =:= wrong_password ->
    Config;
init_per_testcase(Case, Config) when Case =:= member_down; Case =:= member_add_remove ->
    case docker_member(2379) of
        {ok, _} -> open_client(1000, Config);
        {error, Reason} -> {skip, {no_docker, Reason}}
    end;
init_per_testcase(_Case, Config) ->
    open_client(infinity, Config).

open_client(Interval, Config) ->
    Opts = #{
        cred => ?CRED,
        membership_check_interval => Interval,
        interceptors => [fun etcdgun_interceptor_auth:refresh_token/4]
    },
    {ok, _} = etcdgun:open(?CLIENT, ?ENDPOINTS, Opts),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = etcdgun:close(?CLIENT),
    ok.

%%-------------------------------------------------------------------
%% Test cases
%%-------------------------------------------------------------------

%% The members and the status are what the client needs to open. Which of the RPCs require the
%% token depends on the version, see `etcdgun_interceptor_auth': etcd 3.5 does not require it for
%% any of them, so the client opens and only the KV requests are rejected. Newer versions refuse
%% to open without the credentials.
no_credentials(_Config) ->
    Opts = #{membership_check_interval => infinity},
    case etcd_version() of
        {3, 5} ->
            {ok, _} = etcdgun:open(?CLIENT, ?ENDPOINTS, Opts),
            {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
            ?assertMatch({error, _},
                         etcdgun_etcdserverpb_kv_client:range(Channel, #{key => key()})),
            ok = etcdgun:close(?CLIENT);
        _ ->
            ?assertMatch({error, _}, open_without_cred(Opts))
    end.

wrong_password(_Config) ->
    Res = open_without_cred(#{cred => {"root", "wrong-password"}}),
    ?assertMatch({error, _}, Res).

kv_and_cluster(_Config) ->
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    Key = key(),
    {ok, _} = etcdgun_etcdserverpb_kv_client:put(Channel, #{key => Key, value => <<"v1">>}),
    {ok, #{kvs := [#{value := <<"v1">>}]}} =
        etcdgun_etcdserverpb_kv_client:range(Channel, #{key => Key}),
    {ok, #{members := Members}} = etcdgun_etcdserverpb_cluster_client:member_list(Channel, #{}),
    ?assertEqual(3, length(Members)),
    {ok, #{status := 'SERVING'}} = egrpc_grpc_health_v1_health_client:check(Channel, #{}),
    {ok, Info} = etcdgun_client:client_info(?CLIENT),
    ?assertMatch(#{actives := 3, token := <<_/binary>>}, Info).

%% The token of a wrong password is not taken, the old one is kept.
update_and_unset_cred(_Config) ->
    {ok, #{token := Token0}} = etcdgun_client:client_info(?CLIENT),
    ?assertMatch({error, _}, etcdgun_client:update_cred(?CLIENT, <<"root">>, <<"nope">>)),
    {ok, #{token := Token0}} = etcdgun_client:client_info(?CLIENT),
    ok = etcdgun_client:update_cred(?CLIENT, <<"root">>, <<"123456">>),
    {ok, #{token := Token1}} = etcdgun_client:client_info(?CLIENT),
    ?assert(is_binary(Token1)),
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, _} = etcdgun_etcdserverpb_kv_client:range(Channel, #{key => key()}),
    %% Without the credentials the token is dropped, so the server rejects the request.
    ok = etcdgun_client:unset_cred(?CLIENT),
    {ok, #{token := undefined}} = etcdgun_client:client_info(?CLIENT),
    ?assertEqual(undefined, etcdgun_client:cached_token(?CLIENT)),
    {ok, Channel1} = etcdgun_client:pick_channel(?CLIENT),
    ?assertMatch({error, _}, etcdgun_etcdserverpb_kv_client:range(Channel1, #{key => key()})).

%% An invalid token is refreshed by the interceptor and the request is retried. A channel which
%% was picked before the refresh sends the new token afterwards.
token_refresh(_Config) ->
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, Token0} = etcdgun_client:cached_token(?CLIENT),
    ets:insert(?TOKEN_TABLE, {?CLIENT, <<"invalid.token">>}),
    {ok, _} = etcdgun_etcdserverpb_kv_client:range(Channel, #{key => key()}),
    {ok, Token1} = etcdgun_client:cached_token(?CLIENT),
    ?assertNotEqual(<<"invalid.token">>, Token1),
    ?assertNotEqual(Token0, Token1),
    %% The same channel keeps working with the new token.
    {ok, _} = etcdgun_etcdserverpb_kv_client:range(Channel, #{key => key()}).

watch_events(_Config) ->
    Prefix = key(),
    {ok, _} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), [watch_req(Prefix)]),
    Key = <<Prefix/binary, "/a">>,
    put_retry(Key, <<"1">>),
    ?assertMatch([#{kv := #{key := Key, value := <<"1">>}}], recv_events()),
    put_retry(Key, <<"2">>),
    ?assertMatch([#{kv := #{key := Key, value := <<"2">>}}], recv_events()),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% The watcher is restarted when its connection is down, and resumes from the last revision, so
%% the event which happened while it was down is not lost.
watch_reconnect(_Config) ->
    Prefix = key(),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), [watch_req(Prefix)]),
    A = <<Prefix/binary, "/a">>,
    B = <<Prefix/binary, "/b">>,
    put_retry(A, <<"1">>),
    ?assertMatch([#{kv := #{key := A}}], recv_events()),
    {monitors, [{process, ConnPid}]} = process_info(Pid, monitors),
    exit(ConnPid, kill),
    put_retry(B, <<"2">>),
    ?assertMatch([#{kv := #{key := B}}], recv_events(15000)),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

lease_keepalive(_Config) ->
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, #{'ID' := LeaseId}} =
        etcdgun_etcdserverpb_lease_client:lease_grant(Channel, #{'TTL' => 3}),
    {ok, _} = etcdgun_lease_keepalive_sup:start_child(?CLIENT, LeaseId, true),
    %% Longer than the TTL, the lease is alive only because of the keepalive.
    timer:sleep(6000),
    {ok, #{'TTL' := TTL}} =
        etcdgun_etcdserverpb_lease_client:lease_time_to_live(Channel, #{'ID' => LeaseId}),
    ?assert(TTL > 0),
    %% Revoked when the keepalive is stopped, `-1' is a lease which does not exist.
    ok = etcdgun_lease_keepalive_sup:stop_child(?CLIENT, LeaseId),
    {ok, #{'TTL' := -1}} =
        etcdgun_etcdserverpb_lease_client:lease_time_to_live(Channel, #{'ID' => LeaseId}).

%% Members which are not in the membership anymore are dropped, and come back when they are
%% added again.
membership_sync(_Config) ->
    {ok, #{members := Members, actives := 3}} = etcdgun_client:client_info(?CLIENT),
    ?assertEqual(3, length(Members)),
    [_ | Rest] = Members,
    ok = etcdgun_client:sync_membership(?CLIENT, Rest),
    ok = wait_until(fun() ->
        {ok, #{actives := N, members := Ms}} = etcdgun_client:client_info(?CLIENT),
        N =:= 2 andalso length(Ms) =:= 2
    end),
    ok = etcdgun_client:sync_membership(?CLIENT, Members),
    ok = wait_until(fun() ->
        {ok, #{actives := N, members := Ms}} = etcdgun_client:client_info(?CLIENT),
        N =:= 3 andalso length(Ms) =:= 3
    end),
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, _} = etcdgun_etcdserverpb_kv_client:range(Channel, #{key => key()}).

%% A member goes down and comes back, the client drops its channel and connects again.
member_down(_Config) ->
    {ok, Container} = docker_member(2579),
    {0, _} = sh(["docker stop -t 1 ", Container]),
    try
        ok = wait_until(fun() -> actives() =:= 2 end),
        %% The requests are served by the other members.
        {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
        {ok, _} = etcdgun_etcdserverpb_kv_client:range(Channel, #{key => key()})
    after
        {0, _} = sh(["docker start ", Container])
    end,
    ok = wait_until(fun() -> actives() =:= 3 end, 60).

%% A new member is added to the cluster and removed again. The membership is found by the periodic
%% check, `sync_membership/2' is not called. The new member is a container which joins the network
%% of the cluster, the members of the cluster are not changed.
member_add_remove(_Config) ->
    {ok, Etcd1} = docker_member(2379),
    {0, Network} = sh(["docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}",
                       "{{end}}' ", Etcd1]),
    {0, Image} = sh(["docker inspect -f '{{.Config.Image}}' ", Etcd1]),
    Ctl = ["docker exec ", Etcd1, " /usr/local/bin/etcdctl --user root:123456 "],
    New = "etcdgun_ct_etcd4",
    _ = sh(["docker rm -f ", New]),
    try
        %% Refused while a member is not in sync yet, e.g. right after one was restarted.
        ok = wait_until(fun() ->
            {Code, _} = sh([Ctl, "member add etcd-4 --peer-urls=http://etcd-4:2380"]),
            Code =:= 0
        end, 60),
        {0, _} = sh(["docker run -d --name ", New, " --network ", Network,
                     " --network-alias etcd-4 -p 2679:2379 --entrypoint /usr/local/bin/etcd ",
                     Image, " --name=etcd-4 --data-dir=/etcd_data",
                     " --listen-peer-urls=http://0.0.0.0:2380",
                     " --listen-client-urls=http://0.0.0.0:2379",
                     " --initial-advertise-peer-urls=http://etcd-4:2380",
                     " --advertise-client-urls=http://127.0.0.1:2679",
                     " --initial-cluster-token=etcd-cluster",
                     " --initial-cluster=etcd-1=http://etcd-1:2380,etcd-2=http://etcd-2:2380,",
                     "etcd-3=http://etcd-3:2380,etcd-4=http://etcd-4:2380",
                     " --initial-cluster-state=existing"]),
        ok = wait_until(fun() -> members() =:= 4 andalso actives() =:= 4 end, 90),
        {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
        {ok, _} = etcdgun_etcdserverpb_kv_client:range(Channel, #{key => key()}),
        remove_member(Ctl, "etcd-4"),
        ok = wait_until(fun() -> members() =:= 3 andalso actives() =:= 3 end, 90)
    after
        %% Leave the cluster as it was, also when the test failed.
        remove_member(Ctl, "etcd-4"),
        _ = sh(["docker rm -f ", New])
    end.

%%-------------------------------------------------------------------
%% Helpers
%%-------------------------------------------------------------------

members() ->
    {ok, #{members := Members}} = etcdgun_client:client_info(?CLIENT),
    length(Members).

actives() ->
    {ok, #{actives := Actives}} = etcdgun_client:client_info(?CLIENT),
    Actives.

%% Run a shell command, return its exit code and the output without the trailing newline.
sh(Cmd) ->
    Out = os:cmd(lists:flatten(Cmd) ++ " 2>&1; echo \"\n$?\""),
    Lines = string:split(string:trim(Out), "\n", all),
    Code = list_to_integer(string:trim(lists:last(Lines))),
    {Code, string:trim(lists:join("\n", lists:droplast(Lines)))}.

%% The container of the compose cluster which publishes the port, the members are told apart by it.
docker_member(Port) ->
    case sh(["docker ps --filter publish=", integer_to_list(Port), " --format '{{.Names}}'"]) of
        {0, [_ | _] = Name} -> {ok, hd(string:split(Name, "\n"))};
        {0, _} -> {error, no_container};
        {_, Output} -> {error, Output}
    end.

%% Remove the member by name, nothing happens if there is no one.
remove_member(Ctl, Name) ->
    {_, Out} = sh([Ctl, "member list"]),
    case [L || L <- string:split(Out, "\n", all), string:find(L, Name) =/= nomatch] of
        [Line | _] ->
            [Id | _] = string:split(Line, ","),
            sh([Ctl, "member remove ", string:trim(Id)]);
        [] ->
            ok
    end.

%% The {Major, Minor} of the server, asked through a client with the credentials.
etcd_version() ->
    {ok, _} = etcdgun:open(?CLIENT, ?ENDPOINTS, #{cred => ?CRED, membership_check_interval => infinity}),
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, #{version := Version}} = etcdgun_etcdserverpb_maintenance_client:status(Channel, #{}),
    ok = etcdgun:close(?CLIENT),
    [Major, Minor | _] = string:split(binary_to_list(Version), ".", all),
    {list_to_integer(Major), list_to_integer(Minor)}.

open_without_cred(Opts) ->
    Res = etcdgun:open(?CLIENT, ?ENDPOINTS, Opts#{membership_check_interval => infinity}),
    _ = etcdgun:close(?CLIENT),
    Res.

key() ->
    iolist_to_binary(["/etcdgun_ct/", integer_to_binary(erlang:unique_integer([positive]))]).

watch_req(Prefix) ->
    #{request_union => {create_request, #{
        key => Prefix,
        range_end => iolist_to_binary(etcdgun:prefix_range_end(Prefix))
    }}}.

%% The watch events of one `watch_events' message.
recv_events() -> recv_events(5000).

recv_events(Timeout) ->
    receive
        {watch_event, {watch_events, Events}} -> Events;
        {watch_event, _Other} -> recv_events(Timeout)
    after Timeout ->
        ct:fail(no_watch_events)
    end.

%% A put through a channel which may be being replaced, e.g. right after a connection was killed.
put_retry(Key, Value) ->
    put_retry(Key, Value, 20).

put_retry(_Key, _Value, 0) ->
    ct:fail(put_failed);
put_retry(Key, Value, N) ->
    Res =
        case etcdgun_client:pick_channel(?CLIENT) of
            {ok, Channel} ->
                etcdgun_etcdserverpb_kv_client:put(Channel, #{key => Key, value => Value});
            {error, _} = Error ->
                Error
        end,
    case Res of
        {ok, _} -> ok;
        {error, _} -> timer:sleep(500), put_retry(Key, Value, N - 1)
    end.

wait_until(Fun) -> wait_until(Fun, 40).

wait_until(_Fun, 0) -> ct:fail(timeout);
wait_until(Fun, N) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(500), wait_until(Fun, N - 1)
    end.
