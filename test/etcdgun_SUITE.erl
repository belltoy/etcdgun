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
    token_refresh_single_flight/1,
    token_refresh_stale/1,
    token_refresh_failed/1,
    watch_events/1,
    watch_reconnect/1,
    watch_reconnect_before_event/1,
    watch_handler_crash/1,
    watch_handler_cancel/1,
    watch_handler_remove_handler/1,
    watch_cancel_in_handler/1,
    watch_handler_init_failed/1,
    watch_paused_resumed/1,
    watch_stopped_revision/1,
    watch_compacted/1,
    watch_auth_failed/1,
    watcher_exit_reasons/1,
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
        token_refresh_single_flight,
        token_refresh_stale,
        token_refresh_failed,
        watch_events,
        watch_reconnect,
        watch_reconnect_before_event,
        watch_handler_crash,
        watch_handler_cancel,
        watch_handler_remove_handler,
        watch_cancel_in_handler,
        watch_handler_init_failed,
        watch_paused_resumed,
        watch_stopped_revision,
        watch_compacted,
        watch_auth_failed,
        watcher_exit_reasons,
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
        interceptors => []
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
            Channel = ?CLIENT,
            ?assertMatch({error, _},
                         etcdgun_etcdserverpb_kv_stub:range(Channel, #{key => key()})),
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
        Channel = ?CLIENT,
        {ok, _} = etcdgun_etcdserverpb_kv_stub:range(Channel, #{key => key()}),
        ok = etcdgun_client:update_cred(?CLIENT, "root", <<"123456">>),
        Channel1 = ?CLIENT,
        {ok, _} = etcdgun_etcdserverpb_kv_stub:range(Channel1, #{key => key()})
    after
        ok = etcdgun:close(?CLIENT)
    end.

kv_and_cluster(_Config) ->
    Channel = ?CLIENT,
    Key = key(),
    {ok, _} = etcdgun_etcdserverpb_kv_stub:put(Channel, #{key => Key, value => <<"v1">>}),
    {ok, #{kvs := [#{value := <<"v1">>}]}} =
        etcdgun_etcdserverpb_kv_stub:range(Channel, #{key => Key}),
    {ok, #{members := Members}} = etcdgun_etcdserverpb_cluster_stub:member_list(Channel, #{}),
    ?assertEqual(3, length(Members)),
    {ok, #{status := 'SERVING'}} = egrpc_grpc_health_v1_health_stub:check(Channel, #{}),
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
    Channel = ?CLIENT,
    {ok, _} = etcdgun_etcdserverpb_kv_stub:range(Channel, #{key => key()}),
    %% Without the credentials the token is dropped, so the server rejects the request.
    ok = etcdgun_client:unset_cred(?CLIENT),
    ?assertMatch({ok, #{authenticated := false, username := undefined}},
                 etcdgun_client:client_info(?CLIENT)),
    ?assertEqual(undefined, etcdgun_client:cached_token(?CLIENT)),
    Channel1 = ?CLIENT,
    ?assertMatch({error, _}, etcdgun_etcdserverpb_kv_stub:range(Channel1, #{key => key()})).

%% An invalid token is refreshed by the interceptor and the request is retried. A channel which
%% was picked before the refresh sends the new token afterwards.
token_refresh(_Config) ->
    Channel = ?CLIENT,
    {ok, Token0} = etcdgun_client:cached_token(?CLIENT),
    invalidate_token(Token0),
    {ok, _} = etcdgun_etcdserverpb_kv_stub:range(Channel, #{key => key()}),
    {ok, Token1} = etcdgun_client:cached_token(?CLIENT),
    ?assertNotEqual(<<"invalid.token">>, Token1),
    ?assertNotEqual(Token0, Token1),
    %% The same channel keeps working with the new token.
    {ok, _} = etcdgun_etcdserverpb_kv_stub:range(Channel, #{key => key()}).

%% Many requests which are refused at once authenticate once, the others wait for the result of
%% the refresh. Counted by tracing the calls of `Authenticate'.
token_refresh_single_flight(_Config) ->
    {ok, Token0} = etcdgun_client:cached_token(?CLIENT),
    invalidate_token(Token0),
    Self = self(),
    Count = count_authenticates(fun() ->
        Pids = [spawn_link(fun() ->
                    Channel = ?CLIENT,
                    Self ! {self(), etcdgun_etcdserverpb_kv_stub:range(Channel, #{key => key()})}
                end) || _ <- lists:seq(1, 50)],
        [?assertMatch({ok, _}, receive {Pid, R} -> R after 30000 -> timeout end) || Pid <- Pids]
    end),
    ?assertEqual(1, Count),
    {ok, Token1} = etcdgun_client:cached_token(?CLIENT),
    ?assertNotEqual(Token0, Token1).

%% A caller which was refused with a token which is not the current one does not authenticate.
token_refresh_stale(_Config) ->
    {ok, Token} = etcdgun_client:cached_token(?CLIENT),
    Count = count_authenticates(fun() ->
        ?assertEqual({ok, Token}, etcdgun_client:refresh_token(?CLIENT, <<"old.token">>))
    end),
    ?assertEqual(0, Count),
    %% The current token, or none, is refreshed.
    ?assertEqual(1, count_authenticates(fun() ->
        {ok, _} = etcdgun_client:refresh_token(?CLIENT, Token)
    end)),
    ?assertEqual(1, count_authenticates(fun() ->
        {ok, _} = etcdgun_client:refresh_token(?CLIENT)
    end)).

%% The refresh which failed is the answer of the next second, then etcd is asked again.
token_refresh_failed(_Config) ->
    %% The password of the client is not the one of etcd anymore (the state is replaced, the
    %% client keeps it as it was given).
    sys:replace_state(whereis(?CLIENT), fun(State) ->
        list_to_tuple([case E of {<<"root">>, _} -> {<<"root">>, <<"nope">>}; _ -> E end
                       || E <- tuple_to_list(State)])
    end),
    Count = count_authenticates(fun() ->
        {error, Error} = etcdgun_client:refresh_token(?CLIENT),
        ?assertEqual({error, Error}, etcdgun_client:refresh_token(?CLIENT)),
        %% Refused with a token which is not the current one: nothing to refresh
        ?assertMatch({ok, _}, etcdgun_client:refresh_token(?CLIENT, <<"x">>))
    end),
    ?assertEqual(1, Count),
    timer:sleep(1100),
    ?assertEqual(1, count_authenticates(fun() ->
        ?assertMatch({error, _}, etcdgun_client:refresh_token(?CLIENT))
    end)).

watch_events(_Config) ->
    Prefix = key(),
    {ok, _} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    Key = <<Prefix/binary, "/a">>,
    put_retry(Key, <<"1">>),
    ?assertMatch([#{kv := #{key := Key, value := <<"1">>}}], recv_events()),
    put_retry(Key, <<"2">>),
    ?assertMatch([#{kv := #{key := Key, value := <<"2">>}}], recv_events()),
    %% The handler is told about a pause and a resume only when the watch was interrupted, not
    %% for the creation of it.
    receive
        {watch_event, {watch_paused, _, _}} -> ct:fail(watch_paused);
        {watch_event, {watch_resumed, _}} -> ct:fail(watch_resumed)
    after 0 -> ok
    end,
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

%% A handler which crashes stops the watcher with the revision of what it handled before: the
%% events are not lost, watching again from after it gives them again (and again, as long as the
%% handler crashes at them, which is for the one who watches to decide).
watch_handler_crash(_Config) ->
    Prefix = key(),
    Req = watch_req(Prefix),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), Req),
    wait_handler_init(),
    MRef = erlang:monitor(process, Pid),
    A = <<Prefix/binary, "/a">>,
    B = <<Prefix/binary, "/b">>,
    C = <<Prefix/binary, "/c">>,
    RevA = put_retry(A, <<"1">>),
    ?assertMatch([#{kv := #{key := A}}], recv_events()),
    RevB = put_retry(B, <<"crash">>),
    receive
        {'DOWN', MRef, process, Pid, Reason} ->
            ?assertMatch({handler_failed, {error, crash_by_request, _}, RevA}, Reason)
    after 5000 ->
        ct:fail(watcher_not_stopped)
    end,
    receive {handler_terminate, {error, _}} -> ok after 1000 -> ct:fail(no_terminate) end,
    %% not restarted, and the name is free
    ?assertEqual(undefined, whereis(ct_watcher)),
    %% from after the last revision which was handled: the events are given again
    {ok, Pid2} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(),
                               Req#{start_revision => RevA + 1}),
    wait_handler_init(),
    MRef2 = erlang:monitor(process, Pid2),
    receive
        {'DOWN', MRef2, process, Pid2, Reason2} ->
            ?assertMatch({handler_failed, {error, crash_by_request, _}, RevA}, Reason2)
    after 5000 ->
        ct:fail(watcher_not_stopped)
    end,
    %% from after them, to go on
    put_retry(C, <<"3">>),
    {ok, _} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(),
                            Req#{start_revision => RevB + 1}),
    ?assertEqual([C], recv_keys(1, 5000)),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% The handler returns `{cancel_watch, State}': the watch is cancelled as by `cancel_watch/2', the
%% watcher stops with `shutdown', and the handler is told as it is then, with the revision of the
%% events which it returned it for (they were given to it).
watch_handler_cancel(_Config) ->
    Prefix = key(),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    wait_handler_init(),
    MRef = erlang:monitor(process, Pid),
    Rev = put_retry(<<Prefix/binary, "/a">>, <<"remove">>),
    receive
        {'DOWN', MRef, process, Pid, Reason} -> ?assertEqual(shutdown, Reason)
    after 5000 ->
        ct:fail(watcher_not_stopped)
    end,
    receive
        {watch_event, {watch_stopped, shutdown, Rev1}} -> ?assertEqual(Rev, Rev1)
    after 1000 ->
        ct:fail(no_watch_stopped)
    end,
    receive {handler_terminate, shutdown} -> ok after 1000 -> ct:fail(no_terminate) end,
    %% the name is free
    ?assertEqual({error, not_found}, etcdgun:cancel_watch(?CLIENT, ct_watcher)).

%% `remove_handler' of the `gen_event' handlers is not a return of the handler anymore: it is not
%% understood, as any other, it is a crash of the handler.
watch_handler_remove_handler(_Config) ->
    Prefix = key(),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    wait_handler_init(),
    MRef = erlang:monitor(process, Pid),
    put_retry(<<Prefix/binary, "/a">>, <<"legacy">>),
    receive
        {'DOWN', MRef, process, Pid, Reason} ->
            ?assertMatch({handler_failed, {bad_return_value, remove_handler}, _}, Reason)
    after 5000 ->
        ct:fail(watcher_not_stopped)
    end.

%% The handler can not ask the supervisor to stop the watcher which is waiting for it: it fails at
%% once, the watcher is not held for its shutdown time and killed.
watch_cancel_in_handler(_Config) ->
    Prefix = key(),
    {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, self(), watch_req(Prefix)),
    wait_handler_init(),
    {Time, ok} = timer:tc(fun() ->
        put_retry(<<Prefix/binary, "/a">>, <<"direct">>),
        receive
            {cancel_in_handler, {error, called_from_the_handler}} -> ok
        after 5000 ->
            ct:fail(no_cancel_in_handler)
        end
    end),
    ?assert(Time < 900000),
    ?assertEqual(Pid, whereis(ct_watcher)),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher).

%% The handler can not be initialised: `watch/5' returns the reason and leaves nothing.
watch_handler_init_failed(_Config) ->
    ?assertEqual({error, {handler_init, init_failed}},
                 etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, fail, watch_req(key()))),
    ?assertEqual(undefined, whereis(ct_watcher)),
    ?assertEqual({error, not_found}, etcdgun:cancel_watch(?CLIENT, ct_watcher)).

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
    Channel = ?CLIENT,
    {ok, _} = etcdgun_etcdserverpb_kv_stub:compact(Channel, #{revision => Rev2}),
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

%% How a watcher ends, what the handler is told, and what the one who watches sees (`DOWN'). The
%% handler is told by `terminate/2' of the watcher, which is not called when it is killed.
watcher_exit_reasons(_Config) ->
    Start = fun(Args) ->
        {ok, Pid} = etcdgun:watch(?CLIENT, ct_watcher, etcdgun_ct_handler, Args, watch_req(key())),
        wait_handler_init(),
        {Pid, erlang:monitor(process, Pid)}
    end,
    Down = fun(Pid, MRef) ->
        receive
            {'DOWN', MRef, process, Pid, Reason} -> Reason
        after 10000 ->
            ct:fail(no_down)
        end
    end,
    Told = fun(Reason) ->
        receive {watch_event, {watch_stopped, Reason, _}} -> ok after 1000 -> ct:fail(no_watch_stopped) end,
        receive {handler_terminate, Reason} -> ok after 1000 -> ct:fail(no_terminate) end
    end,
    NotTold = fun() ->
        receive
            {watch_event, {watch_stopped, _, _}} -> ct:fail(watch_stopped);
            {handler_terminate, _} -> ct:fail(terminate)
        after 500 -> ok
        end
    end,
    %% the handler was told, and its `terminate' did not end in time
    NotTerminated = fun(Reason) ->
        receive {watch_event, {watch_stopped, Reason, _}} -> ok after 1000 -> ct:fail(no_watch_stopped) end,
        receive {handler_terminate, _} -> ct:fail(terminate) after 500 -> ok end
    end,
    %% cancelled
    {P1, M1} = Start(self()),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher),
    ?assertEqual(shutdown, Down(P1, M1)),
    Told(shutdown),
    %% another process ends it: the handler is told with the reason
    {P2, M2} = Start(self()),
    exit(P2, some_reason),
    ?assertEqual(some_reason, Down(P2, M2)),
    Told(some_reason),
    %% a normal exit of a process which is linked is not the end of the watch
    {P3, M3} = Start(self()),
    exit(P3, normal),
    timer:sleep(300),
    ?assert(is_process_alive(P3)),
    erlang:demonitor(M3, [flush]),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher),
    Told(shutdown),
    %% killed: nothing is called, but the name is free for a new watcher (it is not restarted)
    {P4, M4} = Start(self()),
    exit(P4, kill),
    ?assertEqual(killed, Down(P4, M4)),
    NotTold(),
    ?assertEqual(undefined, whereis(ct_watcher)),
    {P5, M5} = Start(self()),
    ok = etcdgun:cancel_watch(?CLIENT, ct_watcher),
    ?assertEqual(shutdown, Down(P5, M5)),
    Told(shutdown),
    %% a `terminate' of the handler which does not end in time: the watcher is killed
    {P6, M6} = Start({slow_terminate, self()}),
    {Time, ok} = timer:tc(fun() -> etcdgun:cancel_watch(?CLIENT, ct_watcher) end),
    ?assertEqual(killed, Down(P6, M6)),
    ?assert(Time >= 1000000),
    NotTerminated(shutdown),
    %% the supervisor of the watchers is shut down, as when the application stops
    {P7, M7} = Start(self()),
    ok = supervisor:terminate_child(etcdgun_sup, etcdgun_watcher_sup),
    ?assertEqual(shutdown, Down(P7, M7)),
    Told(shutdown),
    {ok, _} = supervisor:restart_child(etcdgun_sup, etcdgun_watcher_sup),
    %% the supervisor of the watchers is killed
    {P8, M8} = Start(self()),
    Sup = whereis(etcdgun_watcher_sup),
    exit(Sup, kill),
    ?assertEqual(killed, Down(P8, M8)),
    Told(killed),
    ok = wait_until(fun() ->
        case whereis(etcdgun_watcher_sup) of
            Pid when is_pid(Pid), Pid =/= Sup -> true;
            _ -> false
        end
    end, 20),
    %% the client is closed
    {P9, M9} = Start(self()),
    ok = etcdgun:close(?CLIENT),
    ?assertEqual(shutdown, Down(P9, M9)),
    Told(shutdown).

lease_keepalive(_Config) ->
    Channel = ?CLIENT,
    {ok, #{'ID' := LeaseId}} =
        etcdgun_etcdserverpb_lease_stub:lease_grant(Channel, #{'TTL' => 3}),
    {ok, _} = etcdgun_lease_keepalive_sup:start_child(?CLIENT, LeaseId, true),
    %% Longer than the TTL, the lease is alive only because of the keepalive.
    timer:sleep(6000),
    {ok, #{'TTL' := TTL}} =
        etcdgun_etcdserverpb_lease_stub:lease_time_to_live(Channel, #{'ID' => LeaseId}),
    ?assert(TTL > 0),
    %% Revoked when the keepalive is stopped, `-1' is a lease which does not exist.
    ok = etcdgun_lease_keepalive_sup:stop_child(?CLIENT, LeaseId),
    {ok, #{'TTL' := -1}} =
        etcdgun_etcdserverpb_lease_stub:lease_time_to_live(Channel, #{'ID' => LeaseId}).

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
    Channel = ?CLIENT,
    {ok, _} = etcdgun_etcdserverpb_kv_stub:range(Channel, #{key => key()}).

%% A member goes down and comes back, the client drops its channel and connects again.
member_down(_Config) ->
    {ok, Container} = docker_member(2579),
    {0, _} = sh(["docker stop -t 1 ", Container]),
    try
        ok = wait_until(fun() -> actives() =:= 2 end),
        %% The requests are served by the other members, when the member which was stopped was the
        %% leader the first ones may be refused while another one is elected.
        ok = wait_until(fun() ->
            Channel = ?CLIENT,
            case etcdgun_etcdserverpb_kv_stub:range(Channel, #{key => key()}) of
                {ok, _} -> true;
                {error, _} -> false
            end
        end, 20)
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
        Channel = ?CLIENT,
        {ok, _} = etcdgun_etcdserverpb_kv_stub:range(Channel, #{key => key()}),
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
    %% there is no watcher without a handler
    ?assertEqual({error, {invalid_handler, undefined}},
                 etcdgun:watch(?CLIENT, ct_watcher, undefined, self(), Valid)),
    ?assertEqual({error, {invalid_handler, no_such_handler_module}},
                 etcdgun:watch(?CLIENT, ct_watcher, no_such_handler_module, self(), Valid)),
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
    Channel = ?CLIENT,
    {ok, #{'ID' := LeaseId}} =
        etcdgun_etcdserverpb_lease_stub:lease_grant(Channel, #{'TTL' => 2}),
    {ok, Pid} = etcdgun_lease_keepalive_sup:start_child(?CLIENT, LeaseId, false),
    MRef = erlang:monitor(process, Pid),
    {ok, _} = etcdgun_etcdserverpb_lease_stub:lease_revoke(Channel, #{'ID' => LeaseId}),
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
    Channel = ?CLIENT,
    {ok, #{'ID' := LeaseId}} =
        etcdgun_etcdserverpb_lease_stub:lease_grant(Channel, #{'TTL' => 30}),
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
    Channel = ?CLIENT,
    {ok, #{'ID' := LeaseId}} =
        etcdgun_etcdserverpb_lease_stub:lease_grant(Channel, #{'TTL' => 3}),
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
        Ch = ?CLIENT,
        {ok, #{'TTL' := TTL}} =
            etcdgun_etcdserverpb_lease_stub:lease_time_to_live(Ch, #{'ID' => LeaseId}),
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
    Channel = ?CLIENT,
    {ok, #{members := Members}} = etcdgun_etcdserverpb_cluster_stub:member_list(Channel, #{}),
    LeaderId = leader(),
    [#{clientURLs := [Url | _]}] = [M || #{'ID' := Id} = M <- Members, Id =:= LeaderId],
    #{port := Port} = uri_string:parse(Url),
    {ok, Container} = docker_member(Port),
    ["docker exec ", Container, " /usr/local/bin/etcdctl --user root:123456 "].

%% The member id of the leader, by the status of any member.
leader() ->
    Channel = ?CLIENT,
    {ok, #{leader := Leader}} = etcdgun_etcdserverpb_maintenance_stub:status(Channel, #{}),
    Leader.

%% Ask the leader to move the leadership to another member, return the old leader. The request is
%% only accepted by the leader, so the channels are picked until one of them is its.
move_leader() ->
    Leader = leader(),
    Channel = ?CLIENT,
    {ok, #{members := Members}} = etcdgun_etcdserverpb_cluster_stub:member_list(Channel, #{}),
    [Target | _] = [Id || #{'ID' := Id} <- Members, Id =/= Leader],
    ok = move_leader(Leader, Target, 20),
    Leader.

move_leader(_Leader, _Target, 0) ->
    ct:fail(move_leader_failed);
move_leader(Leader, Target, N) ->
    Channel = ?CLIENT,
    case etcdgun_etcdserverpb_maintenance_stub:move_leader(Channel, #{targetID => Target}) of
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
    Channel = ?CLIENT,
    {ok, #{version := Version}} = etcdgun_etcdserverpb_maintenance_stub:status(Channel, #{}),
    ok = etcdgun:close(?CLIENT),
    [Major, Minor | _] = string:split(binary_to_list(Version), ".", all),
    {list_to_integer(Major), list_to_integer(Minor)}.

open_without_cred(Opts) ->
    Res = etcdgun:open(?CLIENT, ?ENDPOINTS, Opts#{membership_check_interval => infinity}),
    _ = etcdgun:close(?CLIENT),
    Res.

%% The token is not valid anymore, as it is not after a restart of the cluster: the client and
%% what the callers read have it.
invalidate_token(Token) ->
    sys:replace_state(whereis(?CLIENT), fun(State) ->
        list_to_tuple([case E of Token -> <<"invalid.token">>; _ -> E end
                       || E <- tuple_to_list(State)])
    end),
    ets:insert(?TOKEN_TABLE, {?CLIENT, <<"invalid.token">>}).

%% How many times `Authenticate' was called while Fun ran.
count_authenticates(Fun) ->
    Self = self(),
    Tracer = spawn_link(fun() -> count_loop(0) end),
    MFA = {etcdgun_etcdserverpb_auth_stub, authenticate, 2},
    _ = erlang:trace_pattern(MFA, true, [global]),
    _ = erlang:trace(all, true, [call, {tracer, Tracer}]),
    try Fun() after
        _ = erlang:trace(all, false, [call]),
        _ = erlang:trace_pattern(MFA, false, [global])
    end,
    Tracer ! {done, Self},
    receive {count, N} -> N after 5000 -> error(no_count) end.

count_loop(N) ->
    receive
        {trace, _, call, _} -> count_loop(N + 1);
        {done, To} -> To ! {count, N}
    end.

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

%% A put right after a connection was killed or a member stopped, it is not repeated by etcdgun.
%% Returns the revision of the put.
put_retry(Key, Value) ->
    put_retry(Key, Value, 20).

put_retry(_Key, _Value, 0) ->
    ct:fail(put_failed);
put_retry(Key, Value, N) ->
    case etcdgun_etcdserverpb_kv_stub:put(?CLIENT, #{key => Key, value => Value}) of
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
