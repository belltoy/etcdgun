%% Integration tests against a cluster whose client URLs are https, see `just etcd-up <version>
%% true' and `just ct-all'. The CA of the cluster is in the directory of the environment variable
%% `ETCDGUN_CT_TLS_CERTS', the suite is skipped without it.
-module(etcdgun_tls_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).

-export([
    kv_and_members/1,
    watch_and_lease/1,
    untrusted_ca/1,
    tcp_to_a_tls_cluster/1,
    invalid_transport/1
]).

-define(CLIENT, etcdgun_tls_ct).
-define(ENDPOINTS, [{"127.0.0.1", 2379}, {"127.0.0.1", 2479}, {"127.0.0.1", 2579}]).
-define(CRED, {"root", "123456"}).

all() ->
    [kv_and_members, watch_and_lease, untrusted_ca, tcp_to_a_tls_cluster, invalid_transport].

init_per_suite(Config) ->
    case os:getenv("ETCDGUN_CT_TLS_CERTS") of
        false ->
            {skip, no_tls_cluster};
        Dir ->
            CA = filename:join(Dir, "ca.pem"),
            case filelib:is_regular(CA) of
                true ->
                    {ok, _} = application:ensure_all_started(etcdgun),
                    [{cacertfile, CA} | Config];
                false ->
                    {skip, {no_ca, CA}}
            end
    end.

end_per_suite(_Config) ->
    application:stop(etcdgun),
    ok.

end_per_testcase(_Case, _Config) ->
    _ = etcdgun:close(?CLIENT),
    ok.

%%-------------------------------------------------------------------
%% Test cases
%%-------------------------------------------------------------------

%% The endpoints are connected with TLS by the `transport' option, the members by the scheme of
%% their client URLs, which is https.
kv_and_members(Config) ->
    {ok, _} = etcdgun:open(?CLIENT, ?ENDPOINTS, opts(Config)),
    {ok, Info} = etcdgun_client:client_info(?CLIENT),
    ?assertMatch(#{actives := 3, authenticated := true}, Info),
    #{members := Members} = Info,
    [?assertMatch(<<"https://", _/binary>>, Url) || #{clientURLs := [Url | _]} <- Members],
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    Key = key(),
    {ok, _} = etcdgun_etcdserverpb_kv_client:put(Channel, #{key => Key, value => <<"tls">>}),
    {ok, #{kvs := [#{value := <<"tls">>}]}} =
        etcdgun_etcdserverpb_kv_client:range(Channel, #{key => Key}),
    {ok, #{members := Listed}} = etcdgun_etcdserverpb_cluster_client:member_list(Channel, #{}),
    ?assertEqual(3, length(Listed)),
    {ok, #{status := 'SERVING'}} = egrpc_grpc_health_v1_health_client:check(Channel, #{}).

%% The streaming calls, with the token, over TLS.
watch_and_lease(Config) ->
    {ok, _} = etcdgun:open(?CLIENT, ?ENDPOINTS, opts(Config)),
    Prefix = key(),
    Req = #{request_union => {create_request, #{
        key => Prefix,
        range_end => iolist_to_binary(etcdgun:prefix_range_end(Prefix))
    }}},
    {ok, _} = etcdgun:watch(?CLIENT, tls_watcher, etcdgun_ct_handler, self(), [Req]),
    {ok, Channel} = etcdgun_client:pick_channel(?CLIENT),
    Key = <<Prefix/binary, "/a">>,
    {ok, _} = etcdgun_etcdserverpb_kv_client:put(Channel, #{key => Key, value => <<"1">>}),
    receive
        {watch_event, {watch_events, [#{kv := #{key := Key}}]}} -> ok
    after 5000 -> ct:fail(no_watch_events)
    end,
    ok = etcdgun:cancel_watch(?CLIENT, tls_watcher),
    {ok, #{'ID' := LeaseId}} =
        etcdgun_etcdserverpb_lease_client:lease_grant(Channel, #{'TTL' => 3}),
    {ok, _} = etcdgun_lease_keepalive_sup:start_child(?CLIENT, LeaseId, true),
    timer:sleep(5000),
    {ok, #{'TTL' := TTL}} =
        etcdgun_etcdserverpb_lease_client:lease_time_to_live(Channel, #{'ID' => LeaseId}),
    ?assert(TTL > 0),
    ok = etcdgun_lease_keepalive_sup:stop_child(?CLIENT, LeaseId).

%% The certificate of the cluster is verified, a CA which is not known is an error.
untrusted_ca(_Config) ->
    Opts = #{cred => ?CRED, transport => tls, membership_check_interval => infinity},
    ?assertMatch({error, _}, etcdgun:open(?CLIENT, ?ENDPOINTS, Opts)).

%% Plain TCP to the https endpoints does not work and does not hang.
tcp_to_a_tls_cluster(_Config) ->
    Opts = #{cred => ?CRED, membership_check_interval => infinity},
    ?assertMatch({error, _}, etcdgun:open(?CLIENT, ?ENDPOINTS, Opts)).

invalid_transport(_Config) ->
    Opts = #{cred => ?CRED, transport => ssl},
    ?assertMatch({error, {invalid_transport, ssl}}, etcdgun:open(?CLIENT, ?ENDPOINTS, Opts)).

%%-------------------------------------------------------------------
%% Helpers
%%-------------------------------------------------------------------

opts(Config) ->
    #{
        cred => ?CRED,
        transport => tls,
        gun_opts => #{tls_opts => [{cacertfile, ?config(cacertfile, Config)}]},
        membership_check_interval => infinity
    }.

key() ->
    iolist_to_binary(["/etcdgun_tls_ct/", integer_to_binary(erlang:unique_integer([positive]))]).
