[![Hex Version](https://img.shields.io/hexpm/v/etcdgun.svg)](https://hex.pm/packages/etcdgun)
[![Hex Docs](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/etcdgun/)
[![CI](https://github.com/belltoy/etcdgun/actions/workflows/ci.yml/badge.svg?branch=redesign)](https://github.com/belltoy/etcdgun/actions/workflows/ci.yml)

An etcd client built on top of [gun](https://github.com/ninenines/gun) and [egrpc](https://github.com/belltoy/egrpc).

## Features

- [x] etcd v3 gRPC APIs.
    - `etcdserverpb.KV`
    - `etcdserverpb.Watch`
    - `etcdserverpb.Lease`
    - `etcdserverpb.Auth`
    - `etcdserverpb.Cluster`
    - `etcdserverpb.Maintenance`
- [x] etcd v3 concurrency gRPC APIs.
    - `v3electionpb.Election`
    - `v3lockpb.Lock`
- [x] gRPC health v1 API (via [`egrpc`](https://github.com/belltoy/grpc))
- [x] [interceptors](src/interceptors/) for more flexible needs, the token is sent by egrpc `call_credentials`.
- [x] etcd authentication and auto-token-refreshing.
- [x] lease keep alive [`etcdgun_lease_keepalive`](src/etcdgun_lease_keepalive.erl).
- [x] watcher with auto-reconnect and resuming from the last revision, see [Watch](#watch)
  ([`etcdgun_watcher`](src/etcdgun_watcher.erl)).
- [x] check the member list of the cluster periodically, and sync the connections with it
  ([`etcdgun_client`](src/etcdgun_client.erl), the `membership_check_interval` option).
- [x] one logical [`egrpc`](https://github.com/belltoy/egrpc) channel for the cluster: its endpoints
  are the members, the connections, the reconnects and the choice of the endpoint for each call
  (round robin) are those of egrpc.
- [x] the read-only requests are repeated on another endpoint when the server is unavailable or
  the connection fails, see [Retry](#retry).
- [x] an endpoint is checked (health service, and the member knows a leader) when it connects and is
  not used until it passes, then again every 10 seconds (every second while it does not pass);
  the requests carry `hasleader`, so a member without a leader refuses them at once.
- [ ] leader aware calls.
- [ ] temporary penalty of endpoints which fail often.
- [x] idle connection keep alive: the HTTP/2 `PING` of gun, off by default, see
  [Connection keepalive](#connection-keepalive).

Generating etcd v3 API codes via the proto files in etcd v3.5.10, without changing their packets.

Extract `ResponseHeader` from `rpc.proto` into `response_header.proto` to avoid
[gpb](https://hex.pm/packages/gpb) to generate the same structure in multiple output pb modules.

## Client APIs

### Starting Client

```erlang
Client = my_client,
Opts = #{},
{ok, _Pid} = etcdgun:open(Client, [{"127.0.0.1", 2379}], Opts),

%% The name of the client is the name of its egrpc channel, call the etcd gRPC APIs with it.
%% Get etcd member list via v3 API
{ok, #{header := _, members := Members}} =
    etcdgun_etcdserverpb_cluster_stub:member_list(Client, #{}).

%% Check heath via egrpc provided standard health check API
{ok, #{status := 'SERVING'}} = egrpc_grpc_health_v1_health_stub:check(Client, #{}).
```

### Client Options

See [`etcdgun:opts()`](https://hexdocs.pm/etcdgun/etcdgun.html#t:opts/0) for the available options.

Support egrpc interceptors, set with the `interceptors` option, e.g. the request logging
`etcdgun_interceptor_log` (a module with `unary/3`, see `m:egrpc_interceptor`).

The authentication is set by etcdgun on every client: egrpc `call_credentials` add the current
token to each attempt of a call, streaming calls included, and the first interceptor refreshes
the token when it is refused (once for the requests which are refused at the same time) and maps
the errors of the server to `{etcd_error, Reason}`.

### Retry

The calls are made by egrpc, in your process. Every attempt of a call picks an endpoint again, and
the `deadline` of the call (milliseconds, in the options of the call) is shared by the attempts.
Without anything else only a request which was not sent (`GOAWAY`, a refused stream) is made
again. The protos of etcd do not mark the read-only methods, so they are repeated (when the
server is `unavailable` or the connection fails, up to 6 attempts, about 2.5 seconds of waiting on
average) with the options of `etcdgun_retry:opts/2,3`:

```erlang
Opts = etcdgun_retry:opts(etcdgun_etcdserverpb_kv_stub, range, #{deadline => 10000}),
{ok, _} = etcdgun_etcdserverpb_kv_stub:range(my_client, #{key => <<"foo">>}, Opts).
```

`Range`, `LeaseTimeToLive`, `LeaseLeases`, `MemberList`, `Alarm`, `Status`, `Hash`, `HashKV` and
the read-only requests of `Auth` are in the table. The writes (`Put`, `DeleteRange`, `Txn`, ...),
`LeaseGrant` and `LeaseRevoke` are not: the result of one which failed after it was sent is not
known, the caller decides. The streams (watch, lease keepalive) are not repeated by egrpc, see
[Watch](#watch) and [Lease Keepalive](#lease-keepalive).

### Lease Keepalive

`etcdgun_lease_keepalive_sup:start_child(Client, LeaseId, RevokeWhenShutdown)` starts a process
which keeps the lease alive. The leases of a client share one `LeaseKeepAlive` stream, which is
opened again (on another endpoint) when it is lost, and a keepalive is sent for every lease at once.
`RevokeWhenShutdown` revokes the lease when the process is stopped normally.

`start_child/3` returns `{error, Reason}` when the process can not start, e.g. `lease_expired`
for a lease which does not exist. The process which failed exits with `Reason` (not `normal`),
so the failure of a start is also in the logs as a crash report.

The process is not restarted when the lease is gone (revoked by someone else or expired): it
stops with the reason `{shutdown, lease_expired}`. `start_child/3` returns its pid, monitor it
to know:

```erlang
{ok, Pid} = etcdgun_lease_keepalive_sup:start_child(my_client, LeaseId, true),
MRef = erlang:monitor(process, Pid),
receive
    {'DOWN', MRef, process, Pid, {shutdown, lease_expired}} -> lease_is_gone
end.
```

### Watch

`etcdgun:watch(Client, WatcherName, Handler, HandlerArgs, Request)` starts a watcher, which is one
watch: `Request` is a `WatchCreateRequest` of etcd, e.g. `#{key => Key, range_end => RangeEnd,
start_revision => Revision}`. The events are given to `Handler`, a module with the callbacks of a
`gen_event` handler (`init/1`, `handle_event/2` and `terminate/2`), which is called by the watcher
itself, in its process.

```erlang
-module(my_watch_handler).
-export([init/1, handle_event/2, terminate/2]).

init(Owner) -> {ok, Owner}.

handle_event({watch_events, Events}, Owner) ->
    [Owner ! {changed, Key, Value} || #{kv := #{key := Key, value := Value}} <- Events],
    {ok, Owner};
handle_event({watch_stopped, Reason, LastRevision}, Owner) ->
    Owner ! {stopped, Reason, LastRevision},
    {ok, Owner};
%% The events which are not of interest, e.g. `watch_paused' and `watch_resumed'.
handle_event(_Event, Owner) ->
    {ok, Owner}.

terminate(_Reason, _Owner) -> ok.
```

```erlang
Prefix = <<"/app/config/">>,
Request = #{key => Prefix, range_end => etcdgun:prefix_range_end(Prefix)},
{ok, Watcher} = etcdgun:watch(my_client, my_watcher, my_watch_handler, self(), Request),
%% The watcher is the lifecycle of the watch: the reason of its exit is how it ended.
MRef = erlang:monitor(process, Watcher),

receive
    {changed, Key, Value} -> {Key, Value};
    {'DOWN', MRef, process, Watcher, Reason} -> {watch_ended, Reason}
end.
```

The events of the handler are:

| Event | When |
|---|---|
| `{watch_events, Events}` | the events of the watch |
| `{watch_paused, Reason, LastRevision}` | the connection is lost (or could not be made at the start); the watcher stays and connects again, no event is lost |
| `{watch_resumed, LastRevision}` | the watch is created again, after a pause |
| `{watch_stopped, Reason, LastRevision}` | the watcher stops, when it is able to (it is not when it is killed) |

`LastRevision` is the revision of the last event which was given to the handler, `undefined` when
the watch was not created yet. To watch again without a gap or a repeat, start from the one after
it: `Request#{start_revision => LastRevision + 1}`.

A handler must have a clause for the events which are not of interest. It returns `{ok, State}`,
or `{cancel_watch, State}` to cancel the watch (it is the way to do it from the handler, calling
`etcdgun:cancel_watch/2` or `etcdgun:close/1` there raises `called_from_the_handler`). Any other
return, or an exception, is a crash of the handler: its `terminate({error, Reason}, State)` is
called and the watcher stops with `{handler_failed, Reason, LastRevision}`. It is not restarted,
and `LastRevision` does not count the events which the handler crashed at, so that watching again
from `LastRevision + 1` gives them again.

The events are given **at least once**. When a handler crashed after it did a part of the events
they are given again from the start of what the server sent at once (a response, which is up to
a thousand revisions when it catches up), so a handler has to be idempotent, or tell what it did
already by the revision of the events (`mod_revision` of the key value). The one who watches
watches again, with a backoff of its own, and decides what to do with events which a handler
always crashes at, or the watch would end and start again for ever. The state of a handler is
gone with the watcher: keep what it needs, or read it from etcd again before watching.

The watcher does not give up when the network or the cluster is not available, it tries again
every second. It stops, and is not restarted, when it is not going to change by trying again.
Monitor the pid to know, the reason of the exit is:

| Reason | |
|---|---|
| `shutdown` | `etcdgun:cancel_watch/2`, `etcdgun:close/1` of the client, the application is stopped, or the handler returned `{cancel_watch, State}` |
| `{shutdown, {canceled, {compacted, Revision}}}` | the revision to start from is compacted, `Revision` is the one the store was compacted to |
| `{shutdown, {canceled, Reason}}` | the server cancelled the watch, e.g. it is not allowed |
| `{grpc_error, Status}` | the call was refused, not for the network or the availability of the server |
| `{auth_failed, Reason}` | the token was refused again after it was refreshed, e.g. the credentials were changed or removed |
| `{handler_failed, Reason, LastRevision}` | the handler crashed; `LastRevision` is of the last events it handled, to watch again from after it |

Things to know:

- The handler runs in the process of the watcher: a slow handler holds the watch back, and one
  which does not return holds it for good.
- A watcher which was killed is not able to tell the handler, and the `'DOWN'` has the reason
  `killed`; keep the last revision in the state of the handler if it has to be known.
- `fragment` is not supported (`{error, {unsupported_option, fragment}}`), and the `watch_id`
  of the request is ignored.
- The name `WatcherName` is registered locally, so it is one per node, whatever the client is.
- A watch of a key which is changed rarely: see `progress_notify` in the documentation of
  [`etcdgun:watch/5`](https://hexdocs.pm/etcdgun/etcdgun.html#watch/5).

### TLS

The transport is a setting of the whole channel, not of an endpoint (a limit of egrpc): the client
URLs of the members found by the member list are used only if their scheme is the one of
`transport` (`http://` is `tcp`, `https://` is `tls`). A member of the other scheme is ignored, so a
cluster which mixes both is not supported. The `Endpoints` given to `etcdgun:open/3` have no
scheme, so `transport => tls` tells that they are TLS, and `gun_opts` are the options of
[gun](https://hex.pm/packages/gun) of every connection, e.g. the CA of the cluster:

```erlang
{ok, _} = etcdgun:open(my_client, [{"etcd.example.com", 2379}], #{
    cred => {"root", "123456"},
    transport => tls,
    gun_opts => #{tls_opts => [{cacertfile, "/etc/etcd/ca.pem"}]}
}).
```

The certificate of the server is verified by the TLS options of gun and OTP. Pass the options of
`ssl` in `tls_opts`, e.g. `{cacerts, ...}` or the client certificate with `{certfile, _}` and
`{keyfile, _}` for a cluster which has `--client-cert-auth`.

### Connection keepalive

etcdgun does not ping the connections itself. [gun](https://hex.pm/packages/gun) sends HTTP/2
`PING` frames when `keepalive` is set in its `http2_opts`, which are passed in `gun_opts` (off by
default, `infinity`):

```erlang
{ok, _} = etcdgun:open(my_client, [{"etcd.example.com", 2379}], #{
    gun_opts => #{http2_opts => #{keepalive => 30_000, keepalive_tolerance => 2}}
}).
```

A connection is closed (and opened again by egrpc) when `keepalive_tolerance` pings in a row got
no answer.

The etcd server limits the pings of the clients (`--grpc-keepalive-min-time`, 5 seconds by
default, and the server is built with `PermitWithoutStream: false`, in etcd 3.5, 3.6 and 3.7):

- Do not set `keepalive` below the `--grpc-keepalive-min-time` of the cluster, 5 seconds by
  default; the server counts the pings which come sooner as abuse and closes the connection
  (`GOAWAY`, `too_many_pings`).
- Because of `PermitWithoutStream: false`, a connection which has no open stream (no watch, no
  lease keepalive, no call going on) is not allowed to be pinged by default: by the rules of
  grpc-go such a ping counts as abuse unless it comes 2 hours after the last one. So `keepalive`
  helps the connections which have a watch or the lease keepalive stream open; it is not a way to
  keep a fully idle connection open on a default etcd (there is no flag of etcd for it).
- The server pings the clients too (`--grpc-keepalive-interval`, 2 hours, and
  `--grpc-keepalive-timeout`, 20 seconds), and gun answers them.

### API Call

The name of the client is used with the generated stubs, e.g. `etcdgun_etcdserverpb_kv_stub`.
The token is added to every call for you.

#### Known issue: `MemberPromote` with authentication on etcd 3.5 and 3.6

When the authentication is enabled, etcd 3.5 and 3.6 reject
`etcdgun_etcdserverpb_cluster_stub:member_promote/2` if the channel is connected to a
follower: the follower forwards the request to the leader with an internal request which has no
token, the leader logs `failed to promote a member ... auth: user name is empty` and the caller
only gets `{error, ...}` of `request timed out`. It is not a problem of the token of etcdgun,
and the request works when it reaches the leader. etcd 3.7 does not have it. A client has one channel
for the cluster and a call can not choose the member, so open a client with the endpoint of the
leader only (the `leader` of `etcdgun_etcdserverpb_maintenance_stub:status/2`) for it. The other member requests (`member_add`,
`member_remove`, `member_list`) are not affected.


## Development

### To Generate Protobuf Modules

```bash
rebar3 protobuf compile
```

### To Generate the etcd gRPC Client Codes

```bash
rebar3 egrpc gen
```

### To Run the Tests

The unit tests are inline eunit tests and need nothing else:

```bash
rebar3 eunit
```

The integration tests are a Common Test suite, [`test/etcdgun_SUITE.erl`](test/etcdgun_SUITE.erl),
which runs against a real etcd cluster. It needs [just](https://github.com/casey/just) and
docker, and the etcd images `quay.io/coreos/etcd:v3.5.10`, `v3.6.5` and `v3.7.0` (`docker pull`
them first).

Run the suites on every supported etcd version. Each version starts from a clean 3-node cluster
with authentication enabled (`root` / `123456`), first with `http` client URLs for
`etcdgun_SUITE`, then with `https` for `etcdgun_tls_SUITE` (a CA and a server certificate are
generated by `openssl` into `data/ct/certs`), and the cluster and its data are destroyed
afterwards, so every run is a regression from scratch:

```bash
just ct-all
```

Run the suite on one version by yourself:

```bash
just etcd-up v3.6.5     # start the cluster in the background, auth enabled
rebar3 ct --suite test/etcdgun_SUITE   # skipped if no cluster is reachable
just etcd-ct-destroy    # remove the containers and the data

# the same with https client URLs
just etcd-up v3.6.5 true
ETCDGUN_CT_TLS_CERTS=$PWD/data/ct/certs rebar3 ct --suite test/etcdgun_tls_SUITE
just etcd-ct-destroy
```

The test clusters publish the client ports 2379, 2479 and 2579 and keep their data in
`data/ct/`, they do not touch the data of the development cluster started by `just etcd`. Stop
that one first, as the ports are the same.

Two cases (`member_down` and `member_add_remove`) stop and add etcd members through docker, and
are skipped if docker is not available.

If you want to run the `rebar shell` (without TLS), copy the `sys.example.config` to
`sys.dev.config` and run: `rebar3 shell`, you can then call the etcd APIs with `foo` (the name of
the client in the config) and see the logs of the client printed in the shell. The `sys.dev.config`
is not committed, so you can change it for your needs, e.g. the endpoints, the credentials, the TLS
options, the interceptors, etc.
