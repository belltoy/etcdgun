%% Integration tests against an etcd cluster of the docker-compose, 3.5, 3.6 or 3.7, which has
%% authentication enabled with the user `root' and the password `123456', see `just etcd-up' and
%% `just ct-all'. The suite is skipped when the cluster is not reachable.
-module(etcdgun_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).

-export([
    no_credentials/1,
    wrong_password/1,
    invalid_cred/1,
    secrets_not_exposed/1,
    binary_cred/1,
    kv_and_cluster/1,
    update_and_unset_cred/1,
    token_refresh/1,
    watch_events/1,
    watch_reconnect/1,
    watch_reconnect_before_event/1,
    watch_handler_crash/1,
    watch_handler_remove/1,
    watch_handler_init_failed/1,
    watch_handler_crash_loop/1,
    watch_paused_resumed/1,
    watch_stopped_revision/1,
    watch_compacted/1,
    watch_auth_failed/1,
    lease_keepalive/1,
    membership_sync/1,
    member_down/1,
    member_add_remove/1,
    learner_member/1,
    leader_change/1,
    watch_many_watchers/1,
    watch_invalid_request/1,
    watch_recreate_same_name/1,
    watch_replay_from_start/1,
    watch_without_connection/1,
    keepalive_unknown_lease/1,
    keepalive_lease_gone/1,
    one_subtree_crash/1
]).



-define(CLIENT, etcdgun_ct).
-define(ENDPOINTS, [{"127.0.0.1", 2379}, {"127.0.0.1", 2479}, {"127.0.0.1", 2579}]).
-define(CRED, {"root", "123456"}).
-define(TOKEN_TABLE, etcdgun_client_tokens).

all() ->
    [
        no_credentials,
        wrong_password,
        invalid_cred,
        secrets_not_exposed,
        binary_cred,
        kv_and_cluster,
        update_and_unset_cred,
        token_refresh,
        watch_events,
        watch_reconnect,
        watch_reconnect_before_event,
        watch_handler_crash,
        watch_handler_remove,
        watch_handler_init_failed,
        watch_handler_crash_loop,
        watch_paused_resumed,
        watch_stopped_revision,
        watch_compacted,
        watch_auth_failed,
        lease_keepalive,
        membership_sync,
        member_down,
        member_add_remove,
        learner_member,
        leader_change,
        watch_many_watchers,
        watch_invalid_request,
        watch_recreate_same_name,
        watch_replay_from_start,
        watch_without_connection,
        keepalive_unknown_lease,
        keepalive_lease_gone,
        one_subtree_crash
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

init_per_testcase(Case, Config)
  when Case =:= no_credentials; Case =:= wrong_password; Case =:= invalid_cred;
       Case =:= binary_cred; Case =:= secrets_not_exposed ->
    Config;
init_per_testcase(Case, Config)
  when Case =:= member_down; Case =:= member_add_remove; Case =:= learner_member ->
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
    %% A watcher which is left by a failed case has the same name in the next one.
    [_ = etcdgun:cancel_watch(?CLIENT, Name) || Name <- [ct_watcher, ct_watcher2]],
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

%% A credential which is not a username and a password, both not empty, is an error, not a client
%% which silently has no authentication.
invalid_cred(_Config) ->
    Opts = #{membership_check_interval => infinity},
    [?assertEqual({error, invalid_cred}, etcdgun:open(?CLIENT, ?ENDPOINTS, Opts#{cred => Cred}))
     || Cred <- [{"", "123456"}, {"root", ""}, {root, "123456"}, "root"]],
    %% the same through the update of a client, which is kept as it was
    {ok, _} = etcdgun:open(?CLIENT, ?ENDPOINTS, Opts#{cred => ?CRED}),
    try
        {ok, Token} = etcdgun_client:cached_token(?CLIENT),
        ?assertEqual({error, invalid_cred}, etcdgun_client:update_cred(?CLIENT, "", "x")),
        ?assertEqual({ok, Token}, etcdgun_client:cached_token(?CLIENT))
    after
        ok = etcdgun:close(?CLIENT)
    end.

%% The password and the token are not in what a client shows: `client_info/1', the child spec of
%% the supervisor, `sys:get_status/1', and the error of a failed open.
secrets_not_exposed(_Config) ->
    Password = "s3cr3t-pa55",
    Secrets = [Password, "wrong-pa55"],
    Shown = fun(Term) -> lists:flatten(io_lib:format("~0p", [Term])) end,
    %% a wrong password is an error, which does not have it in it
    Res = etcdgun:open(?CLIENT, ?ENDPOINTS, #{cred => {"root", "wrong-pa55"},
                                            membership_check_interval => infinity}),
    ?assertMatch({error, _}, Res),
    [?assertEqual(nomatch, string:find(Shown(Res), S)) || S <- Secrets],
    %% a client which is running, with the password of the cluster
    {ok, _} = etcdgun:open(?CLIENT, ?ENDPOINTS, #{cred => ?CRED,
                                                membership_check_interval => infinity}),
    try
        {ok, Token} = etcdgun_client:cached_token(?CLIENT),
        {ok, Info} = etcdgun_client:client_info(?CLIENT),
        Views = [
            Info,
            etcdgun:clients(),
            supervisor:get_childspec(etcdgun_client_sup, ?CLIENT),
            sys:get_status(?CLIENT)
        ],
        [begin
             ?assertEqual(nomatch, string:find(Shown(View), "123456")),
             ?assertEqual(nomatch, string:find(Shown(View), binary_to_list(Token)))
         end || View <- Views],
        ?assertMatch(#{username := <<"root">>, authenticated := true}, Info),
        ?assertNot(maps:is_key(cred, Info)),
        ?assertNot(maps:is_key(token, Info))
    after
        ok = etcdgun:close(?CLIENT)
    end.

%% The username and the password may be binaries, for the options and `update_cred/3'.
binary_cred(_Config) ->
    Opts = #{membership_check_interval => infinity, cred => {<<"root">>, <<"123456">>}},
    {ok, _} = etcdgun:open(?CLIENT, ?ENDPOINTS, Opts),
    try
        {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
        {ok, _} = etcdgun_etcdserverpb_kv_client:range(Channel, #{key => key()}),
        ok = etcdgun_client:update_cred(?CLIENT, "root", <<"123456">>),
        {ok, Channel1} = etcdgun_client:pick_channel(?CLIENT),
        {ok, _} = etcdgun_etcdserverpb_kv_client:range(Channel1, #{key => key()})
    after
        ok = etcdgun:close(?CLIENT)
    end.

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
    ?assertMatch(#{actives := 3, authenticated := true, username := <<"root">>}, Info),
    ?assertMatch({ok, <<_/binary>>}, etcdgun_client:cached_token(?CLIENT)).

%% The token of a wrong password is not taken, the old one is kept.
update_and_unset_cred(_Config) ->
    {ok, Token0} = etcdgun_client:cached_token(?CLIENT),
    ?assertMatch({error, _}, etcdgun_client:update_cred(?CLIENT, <<"root">>, <<"nope">>)),
    ?assertEqual({ok, Token0}, etcdgun_client:cached_token(?CLIENT)),
    ok = etcdgun_client:update_cred(?CLIENT, <<"root">>, <<"123456">>),
    {ok, Token1} = etcdgun_client:cached_token(?CLIENT),
    ?assert(is_binary(Token1)),
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, _} = etcdgun_etcdserverpb_kv_client:range(Channel, #{key => key()}),
    %% Without the credentials the token is dropped, so the server rejects the request.
    ok = etcdgun_client:unset_cred(?CLIENT),
    ?assertMatch({ok, #{authenticated := false, username := undefined}},
                 etcdgun_client:client_info(?CLIENT)),
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
    {ok, _} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    Key = <<Prefix/binary, "/a">>,
    put_retry(Key, <<"1">>),
    ?assertMatch([#{kv := #{key := Key, value := <<"1">>}}], recv_events()),
    put_retry(Key, <<"2">>),
    ?assertMatch([#{kv := #{key := Key, value := <<"2">>}}], recv_events()),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% The watcher stays when its connection is down (it is the same process), and resumes from the
%% last revision, so the event which happened while it was down is not lost.
watch_reconnect(_Config) ->
    Prefix = key(),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    A = <<Prefix/binary, "/a">>,
    B = <<Prefix/binary, "/b">>,
    put_retry(A, <<"1">>),
    ?assertMatch([#{kv := #{key := A}}], recv_events()),
    {monitors, [{process, ConnPid}]} = process_info(Pid, monitors),
    exit(ConnPid, kill),
    put_retry(B, <<"2">>),
    ?assertMatch([#{kv := #{key := B}}], recv_events(15000)),
    ?assertEqual(Pid, whereis(ct_watcher)),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% No event was received before the connection is lost: the watch is resumed from where it was
%% created, not from the time of the new connection, or the event of the meantime would be lost.
watch_reconnect_before_event(_Config) ->
    Prefix = key(),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    A = <<Prefix/binary, "/a">>,
    {monitors, [{process, ConnPid}]} = process_info(Pid, monitors),
    exit(ConnPid, kill),
    put_retry(A, <<"1">>),
    ?assertMatch([#{kv := #{key := A}}], recv_events(15000)),
    ?assertEqual(Pid, whereis(ct_watcher)),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% A handler which crashes is initialised again, the watcher stays (it is not an event manager
%% which drops the handler silently), and the events after it are given.
watch_handler_crash(_Config) ->
    Prefix = key(),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    wait_handler_init(),
    A = <<Prefix/binary, "/a">>,
    B = <<Prefix/binary, "/b">>,
    put_retry(A, <<"crash">>),
    wait_handler_init(),
    ?assertEqual(Pid, whereis(ct_watcher)),
    put_retry(B, <<"1">>),
    ?assertEqual([B], recv_keys(1, 5000)),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% `remove_handler' says the handler does not want events: the watcher stops with `normal', and the
%% handler is terminated.
watch_handler_remove(_Config) ->
    Prefix = key(),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    wait_handler_init(),
    MRef = erlang:monitor(process, Pid),
    put_retry(<<Prefix/binary, "/a">>, <<"remove">>),
    receive
        {'DOWN', MRef, process, Pid, Reason} -> ?assertEqual(normal, Reason)
    after 5000 ->
        ct:fail(watcher_not_stopped)
    end,
    receive {handler_terminate, remove_handler} -> ok after 1000 -> ct:fail(no_terminate) end,
    _ = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% The handler can not be initialised: `watch/5' returns the reason and leaves nothing.
watch_handler_init_failed(_Config) ->
    ?assertEqual({error, {handler_init, init_failed}},
                 etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, fail, watch_req(key()))),
    ?assertEqual(undefined, whereis(ct_watcher)),
    ?assertEqual({error, not_found}, etcdgun:cancel_watch(?CLIENT, ct_watcher)).

%% A handler which crashes at every event is given up, not initialised forever.
watch_handler_crash_loop(_Config) ->
    Prefix = key(),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    wait_handler_init(),
    MRef = erlang:monitor(process, Pid),
    [put_retry(<<Prefix/binary, "/", (integer_to_binary(I))/binary>>, <<"crash">>)
     || I <- lists:seq(1, 8)],
    receive
        {'DOWN', MRef, process, Pid, Reason} ->
            ?assertMatch({handler_failed, {error, crash_by_request, _}}, Reason)
    after 10000 ->
        ct:fail(watcher_not_stopped)
    end,
    _ = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% The handler is told once that the watch is paused, and when it is resumed, both with the
%% revision of the last event.
watch_paused_resumed(_Config) ->
    Prefix = key(),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    A = <<Prefix/binary, "/a">>,
    B = <<Prefix/binary, "/b">>,
    RevA = put_retry(A, <<"1">>),
    ?assertMatch([#{kv := #{key := A}}], recv_events()),
    {monitors, [{process, ConnPid}]} = process_info(Pid, monitors),
    exit(ConnPid, kill),
    receive
        {watch_event, {watch_paused, _Reason, PausedRev}} -> ?assertEqual(RevA, PausedRev)
    after 5000 ->
        ct:fail(no_watch_paused)
    end,
    put_retry(B, <<"2">>),
    receive
        {watch_event, {watch_resumed, ResumedRev}} -> ?assertEqual(RevA, ResumedRev)
    after 15000 ->
        ct:fail(no_watch_resumed)
    end,
    ?assertMatch([#{kv := #{key := B}}], recv_events()),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% The handler is told that the watcher stops, with the reason and the revision of the last event,
%% to start from after it.
watch_stopped_revision(_Config) ->
    Prefix = key(),
    {ok, _} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    A = <<Prefix/binary, "/a">>,
    RevA = put_retry(A, <<"1">>),
    ?assertMatch([#{kv := #{key := A}}], recv_events()),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher),
    receive
        {watch_event, {watch_stopped, Reason, Rev}} ->
            ?assertEqual(shutdown, Reason),
            ?assertEqual(RevA, Rev)
    after 5000 ->
        ct:fail(no_watch_stopped)
    end,
    receive {handler_terminate, shutdown} -> ok after 1000 -> ct:fail(no_terminate) end.

%% A watch which starts at a revision which was compacted is refused by the server, there is
%% nothing to wait for: the watcher stops with the revision of the compaction.
watch_compacted(_Config) ->
    Prefix = key(),
    Key = <<Prefix/binary, "/a">>,
    Rev1 = put_retry(Key, <<"1">>),
    Rev2 = put_retry(Key, <<"2">>),
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, _} = etcdgun_etcdserverpb_kv_client:compact(Channel, #{revision => Rev2}),
    Req = (watch_req(Prefix))#{start_revision => Rev1},
    {ok, _} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), Req),
    receive
        {watch_event, {watch_stopped, Reason, _}} ->
            ?assertEqual({shutdown, {canceled, {compacted, Rev2}}}, Reason)
    after 10000 ->
        ct:fail(no_watch_stopped)
    end,
    _ = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% The credentials are removed, the token is refused when the watch is created again, and the
%% refresh fails: the watcher gives up and says why.
watch_auth_failed(_Config) ->
    Prefix = key(),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    ok = etcdgun_client:unset_cred(?CLIENT),
    {monitors, [{process, ConnPid}]} = process_info(Pid, monitors),
    exit(ConnPid, kill),
    receive
        {watch_event, {watch_stopped, Reason, _}} -> ?assertMatch({auth_failed, _}, Reason)
    after 20000 ->
        ct:fail(no_watch_stopped)
    end,
    _ = etcdgun:cancel_watch(?CLIENT, ct_watcher).

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
    with_new_member(false, fun(Ctl) ->
        ok = wait_until(fun() -> members() =:= 4 andalso actives() =:= 4 end, 90),
        {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
        {ok, _} = etcdgun_etcdserverpb_kv_client:range(Channel, #{key => key()}),
        remove_member(Ctl, "etcd-4"),
        ok = wait_until(fun() -> members() =:= 3 andalso actives() =:= 3 end, 90)
    end).

%% A learner does not serve the requests, the client does not connect to it until it is promoted.
learner_member(_Config) ->
    with_new_member(true, fun(Ctl) ->
        %% Long enough for several periodic checks, the learner is not a member to connect to.
        timer:sleep(4000),
        ?assertEqual({3, 3}, {members(), actives()}),
        %% With the authentication, etcd 3.5 and 3.6 fail a promote which a follower forwards to
        %% the leader: the internal peer request has no token, the leader logs `failed to promote
        %% a member ... auth: user name is empty' and the caller sees `request timed out'. 3.7
        %% does not, a follower works there. So it is sent to the leader.
        ok = wait_until({promote, Ctl}, fun() ->
            {Code, Out} = sh([leader_ctl(), "member promote ", member_id(Ctl, "etcd-4")]),
            put(last_output, Out),
            Code =:= 0
        end, 60),
        ok = wait_until({four, Ctl}, fun() -> members() =:= 4 andalso actives() =:= 4 end, 90),
        remove_member(Ctl, "etcd-4"),
        ok = wait_until({three, Ctl}, fun() -> members() =:= 3 andalso actives() =:= 3 end, 90)
    end).

%% Many watchers at once, each one has its own watch and gets only its events.
watch_many_watchers(_Config) ->
    Prefix = key(),
    %% The trailing slash: `/1' would also be the prefix of `/10' and `/100'.
    Prefixes = [<<Prefix/binary, "/", (integer_to_binary(I))/binary, "/">> || I <- lists:seq(1, 30)],
    Names = [list_to_atom("ct_watcher_" ++ integer_to_list(I)) || I <- lists:seq(1, 30)],
    try
        Pids = [begin
                    {ok, Pid} = etcdgun:watch(?CLIENT, N, etcdgun_ct_handler, self(), watch_req(P)),
                    Pid
                end || {N, P} <- lists:zip(Names, Prefixes)],
        ?assertEqual(30, length(lists:usort(Pids))),
        [put_retry(<<P/binary, "k">>, <<"v">>) || P <- Prefixes],
        Keys = lists:sort([<<P/binary, "k">> || P <- Prefixes]),
        ?assertEqual(Keys, lists:sort(recv_keys(length(Keys), 10000)))
    after
        [_ = etcdgun:cancel_watch(?CLIENT, N) || N <- Names]
    end.

%% The request is checked before anything is started.
watch_invalid_request(_Config) ->
    Valid = watch_req(key()),
    H = etcdgun_ct_handler,
    Watch = fun(Req) -> etcdgun:watch(?CLIENT, ct_watcher, H, self(), Req) end,
    ?assertEqual({error, {invalid_request, key}}, Watch(maps:remove(key, Valid))),
    ?assertEqual({error, {invalid_request, key}}, Watch(Valid#{key := <<>>})),
    ?assertEqual({error, {invalid_request, not_a_map}}, Watch([Valid])),
    ?assertEqual({error, {unsupported_option, fragment}}, Watch(Valid#{fragment => true})),
    ?assertEqual(undefined, whereis(ct_watcher)),
    %% `fragment => false' is what the server does by default
    {ok, _} = Watch(Valid#{fragment => false}),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% The watcher of a name which was cancelled starts from what the request says, not from the last
%% revision of the former one.
watch_recreate_same_name(_Config) ->
    Prefix = key(),
    A = <<Prefix/binary, "/a">>,
    B = <<Prefix/binary, "/b">>,
    C = <<Prefix/binary, "/c">>,
    {ok, _} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    Rev = put_retry(A, <<"1">>),
    put_retry(B, <<"2">>),
    ?assertEqual([A, B], recv_keys(2, 5000)),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher),
    put_retry(C, <<"3">>),
    %% All the events since the first put are expected again.
    Req = #{
        key => Prefix,
        range_end => iolist_to_binary(etcdgun:prefix_range_end(Prefix)),
        start_revision => Rev
    },
    {ok, _} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), Req),
    ?assertEqual([A, B, C], recv_keys(3, 5000)),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% A watch which starts at an old revision gets the events of the history in several responses
%% (etcd sends at most 1000 revisions at a time), and a reconnection in the middle resumes without
%% a gap or a duplicate: from the revision of the last event, not from the header of the response,
%% which is the current revision of the store.
watch_replay_from_start(_Config) ->
    Prefix = key(),
    Keys = [<<Prefix/binary, "/", (integer_to_binary(I))/binary>> || I <- lists:seq(1000, 3499)],
    [Rev | _] = [put_retry(K, <<"v">>) || K <- Keys],
    Req = #{
        key => Prefix,
        range_end => iolist_to_binary(etcdgun:prefix_range_end(Prefix)),
        start_revision => Rev
    },
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), Req),
    First = recv_keys(1, 10000),
    ?assert(length(First) < length(Keys)),
    %% The connection is lost while the history is being sent.
    {monitors, [{process, ConnPid}]} = process_info(Pid, monitors),
    exit(ConnPid, kill),
    Rest = recv_keys(length(Keys) - length(First), 30000),
    ?assertEqual(Keys, First ++ Rest),
    ?assertEqual(Pid, whereis(ct_watcher)),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% A lease which does not exist: the start is refused with the reason, not with a
%% `bad_return_value' of the init function.
keepalive_unknown_lease(_Config) ->
    ?assertEqual({error, lease_expired},
                 etcdgun_lease_keepalive_sup:start_child(?CLIENT, 4242424242, false)).

%% The keepalive process stops with `{shutdown, lease_expired}' when its lease is gone (revoked
%% by someone else, or expired), so a process which has to know monitors it.
keepalive_lease_gone(_Config) ->
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, #{'ID' := LeaseId}} =
        etcdgun_etcdserverpb_lease_client:lease_grant(Channel, #{'TTL' => 2}),
    {ok, Pid} = etcdgun_lease_keepalive_sup:start_child(?CLIENT, LeaseId, false),
    MRef = erlang:monitor(process, Pid),
    {ok, _} = etcdgun_etcdserverpb_lease_client:lease_revoke(Channel, #{'ID' => LeaseId}),
    receive
        {'DOWN', MRef, process, Pid, Reason} ->
            ?assertEqual({shutdown, lease_expired}, Reason)
    after 15000 ->
        ct:fail(keepalive_still_running)
    end.

%% A crash of a subtree of the application does not take the others with it: the clients keep
%% their connections and the lease keepalives keep running (they are not restarted, so they would
%% be gone for good).
one_subtree_crash(_Config) ->
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, #{'ID' := LeaseId}} =
        etcdgun_etcdserverpb_lease_client:lease_grant(Channel, #{'TTL' => 30}),
    {ok, Lease} = etcdgun_lease_keepalive_sup:start_child(?CLIENT, LeaseId, true),
    {ok, #{pid := Client}} = etcdgun_client:client_info(?CLIENT),
    Sup = whereis(etcdgun_watcher_sup),
    true = is_pid(Sup),
    exit(Sup, kill),
    ok = wait_until(fun() ->
        case whereis(etcdgun_watcher_sup) of
            Pid when is_pid(Pid), Pid =/= Sup -> true;
            _ -> false
        end
    end, 20),
    ?assert(is_process_alive(Client)),
    ?assert(is_process_alive(Lease)),
    ?assertMatch({ok, #{pid := Client}}, etcdgun_client:client_info(?CLIENT)),
    ok = etcdgun_lease_keepalive_sup:stop_child(?CLIENT, LeaseId).

%% No member is available when the watch is created: it does not block, and the watch is
%% established when the members are back, also when the token of the members was lost by their
%% restart.
watch_without_connection(_Config) ->
    Containers = [C || P <- [2379, 2479, 2579], {ok, C} <- [docker_member(P)]],
    ?assertEqual(3, length(Containers)),
    Prefix = key(),
    [{0, _} = sh(["docker stop -t 1 ", C]) || C <- Containers],
    try
        ok = wait_until(fun() -> actives() =:= 0 end, 60),
        {Time, Res} = timer:tc(fun() ->
            etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix))
        end),
        ?assertMatch({ok, _}, Res),
        %% The supervisor is not blocked by a watcher which can not connect.
        ?assert(Time < 500000)
    after
        [{0, _} = sh(["docker start ", C]) || C <- Containers]
    end,
    ok = wait_until(fun() -> actives() =:= 3 end, 120),
    %% The events of before the watch exists are not seen, so write until one is seen.
    ok = wait_until(fun() ->
        put_retry(<<Prefix/binary, "/x">>, <<"v">>),
        receive
            {watch_event, {watch_events, [_ | _]}} -> true
        after 1000 -> false
        end
    end, 60),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% The leader moves to another member, the watcher and the lease keepalive keep working.
leader_change(_Config) ->
    Prefix = key(),
    {ok, _} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, #{'ID' := LeaseId}} =
        etcdgun_etcdserverpb_lease_client:lease_grant(Channel, #{'TTL' => 3}),
    {ok, _} = etcdgun_lease_keepalive_sup:start_child(?CLIENT, LeaseId, false),
    try
        A = <<Prefix/binary, "/a">>,
        put_retry(A, <<"1">>),
        ?assertMatch([#{kv := #{key := A}}], recv_events()),
        Leader0 = move_leader(),
        ok = wait_until(fun() -> leader() =/= Leader0 end, 30),
        B = <<Prefix/binary, "/b">>,
        put_retry(B, <<"2">>),
        ?assertMatch([#{kv := #{key := B}}], recv_events(15000)),
        %% Longer than the TTL, the keepalive is working on the new leader.
        timer:sleep(5000),
        {ok, Ch} = etcdgun_client:pick_channel(?CLIENT),
        {ok, #{'TTL' := TTL}} =
            etcdgun_etcdserverpb_lease_client:lease_time_to_live(Ch, #{'ID' => LeaseId}),
        ?assert(TTL > 0)
    after
        _ = etcdgun_lease_keepalive_sup:stop_child(?CLIENT, LeaseId),
        _ = etcdgun:cancel_watch(?CLIENT, ct_watcher)
    end.

%%-------------------------------------------------------------------
%% Helpers
%%-------------------------------------------------------------------

%% Add a fourth member, a container which joins the cluster, call the function, and leave the
%% cluster as it was, also when the function fails.
with_new_member(Learner, Fun) ->
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
            {Code, _} = sh([Ctl, "member add etcd-4 --peer-urls=http://etcd-4:2380",
                            [" --learner" || Learner]]),
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
        Fun(Ctl)
    after
        remove_member(Ctl, "etcd-4"),
        _ = sh(["docker rm -f ", New])
    end.

member_id(Ctl, Name) ->
    {_, Out} = sh([Ctl, "member list"]),
    [Line | _] = [L || L <- string:split(Out, "\n", all), string:find(L, Name) =/= nomatch],
    [Id | _] = string:split(Line, ","),
    string:trim(Id).

%% `etcdctl' in the container of the leader, the client URL of the member is published on the host,
%% so the container is the one which publishes the port.
leader_ctl() ->
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, #{members := Members}} = etcdgun_etcdserverpb_cluster_client:member_list(Channel, #{}),
    LeaderId = leader(),
    [#{clientURLs := [Url | _]}] = [M || #{'ID' := Id} = M <- Members, Id =:= LeaderId],
    #{port := Port} = uri_string:parse(Url),
    {ok, Container} = docker_member(Port),
    ["docker exec ", Container, " /usr/local/bin/etcdctl --user root:123456 "].

%% The member id of the leader, by the status of any member.
leader() ->
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, #{leader := Leader}} = etcdgun_etcdserverpb_maintenance_client:status(Channel, #{}),
    Leader.

%% Ask the leader to move the leadership to another member, return the old leader. The request is
%% only accepted by the leader, so the channels are picked until one of them is its.
move_leader() ->
    Leader = leader(),
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    {ok, #{members := Members}} = etcdgun_etcdserverpb_cluster_client:member_list(Channel, #{}),
    [Target | _] = [Id || #{'ID' := Id} <- Members, Id =/= Leader],
    ok = move_leader(Leader, Target, 20),
    Leader.

move_leader(_Leader, _Target, 0) ->
    ct:fail(move_leader_failed);
move_leader(Leader, Target, N) ->
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    case etcdgun_etcdserverpb_maintenance_client:move_leader(Channel, #{targetID => Target}) of
        {ok, _} -> ok;
        {error, _} -> move_leader(Leader, Target, N - 1)
    end.

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
    #{
        key => Prefix,
        range_end => iolist_to_binary(etcdgun:prefix_range_end(Prefix))
    }.

wait_handler_init() ->
    receive handler_init -> ok after 5000 -> ct:fail(no_handler_init) end.

%% The watch events of one `watch_events' message.
recv_events() -> recv_events(5000).

recv_events(Timeout) ->
    receive
        {watch_event, {watch_events, Events}} -> Events;
        {watch_event, _Other} -> recv_events(Timeout)
    after Timeout ->
        ct:fail(no_watch_events)
    end.

%% The keys of the next `N' events, in order.
recv_keys(N, _Timeout) when N =< 0 ->
    [];
recv_keys(N, Timeout) ->
    Events = recv_events(Timeout),
    Keys = [K || #{kv := #{key := K}} <- Events],
    Keys ++ recv_keys(N - length(Keys), Timeout).

%% A put through a channel which may be being replaced, e.g. right after a connection was killed.
%% Returns the revision of the put.
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
        {ok, #{header := #{revision := Revision}}} -> Revision;
        {error, _} -> timer:sleep(500), put_retry(Key, Value, N - 1)
    end.

wait_until(Fun) -> wait_until(Fun, 40).

wait_until(Fun, N) -> wait_until(undefined, Fun, N).

%% `Label' tells which wait timed out, with the state of the client and of the cluster.
wait_until(Label, _Fun, 0) ->
    {ok, Info} = etcdgun_client:client_info(?CLIENT),
    Cluster = case Label of
        {_, Ctl} ->
            #{members => sh([Ctl, "member list"]),
              learner_log => sh(["docker logs --tail 15 etcdgun_ct_etcd4"])};
        _ ->
            undefined
    end,
    ct:pal("timeout ~p~nclient: ~p~ncluster: ~p~nlast output: ~p",
           [label_name(Label), maps:remove(token, Info), Cluster, get(last_output)]),
    ct:fail({timeout, label_name(Label)});
wait_until(Label, Fun, N) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(500), wait_until(Label, Fun, N - 1)
    end.

label_name(Label) when is_tuple(Label) -> element(1, Label);
label_name(Label) -> Label.
