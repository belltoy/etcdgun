%% @doc The retry policy of etcdgun for the unary calls, which egrpc carries out (every attempt
%% picks a subchannel again and the deadline of the call is shared).
%%
%% The protos of etcd do not say which methods are safe to repeat (`idempotency_level'), so egrpc
%% only repeats a request which was not sent. The read-only methods of etcd are repeated when the
%% server is unavailable or the connection fails, with `opts/2' in the options of the call, as
%% the official clients do. The others (`Put', `DeleteRange', `Txn', `LeaseGrant', ...) are not,
%% the result of one which failed after it was sent is not known.
-module(etcdgun_retry).

-export([policy/0, opts/2, opts/3]).

%% The policy of the channel, see `m:egrpc_retry'. The window of a leader election is a matter
%% of seconds, the waits add up to about 2.5 seconds on average.
-spec policy() -> map().
policy() ->
    #{max_attempts => 6, initial_backoff => 200, max_backoff => 2000}.

%% @doc The options for a call of the function `Function' of the stub `Module'.
-spec opts(module(), atom()) -> egrpc_client:opts().
opts(Module, Function) ->
    opts(Module, Function, #{}).

%% @doc `Opts' with the retry of the method, a `retry' in `Opts' is kept.
-spec opts(module(), atom(), egrpc_client:opts()) -> egrpc_client:opts().
opts(Module, Function, Opts) ->
    case is_read(Module, Function) of
        true -> maps:merge(#{retry => #{retry_non_idempotent => true}}, Opts);
        false -> Opts
    end.

%% The read-only methods of the table of the official client (`LeaseGrant', `LeaseRevoke' and
%% `MoveLeader' are in it, but not here: a repeated one can leave a lease or report an error for
%% what worked).
is_read(etcdgun_etcdserverpb_kv_stub, range) -> true;
is_read(etcdgun_etcdserverpb_lease_stub, F) -> lists:member(F, [lease_time_to_live, lease_leases]);
is_read(etcdgun_etcdserverpb_cluster_stub, member_list) -> true;
is_read(etcdgun_etcdserverpb_maintenance_stub, F) -> lists:member(F, [alarm, status, hash, hash_kv]);
is_read(etcdgun_etcdserverpb_auth_stub, F) -> lists:member(F, [user_list, user_get, role_get, role_list]);
is_read(_, _) -> false.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

opts_test() ->
    ?assertEqual(#{retry => #{retry_non_idempotent => true}},
                 opts(etcdgun_etcdserverpb_kv_stub, range)),
    ?assertEqual(#{}, opts(etcdgun_etcdserverpb_kv_stub, put)),
    ?assertEqual(#{}, opts(etcdgun_etcdserverpb_lease_stub, lease_grant)),
    ?assertEqual(#{deadline => 1000, retry => false},
                 opts(etcdgun_etcdserverpb_kv_stub, range, #{deadline => 1000, retry => false})).
-endif.
