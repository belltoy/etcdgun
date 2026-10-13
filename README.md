[![Hex Version](https://img.shields.io/hexpm/v/etcdgun.svg)](https://hex.pm/packages/etcdgun) [![Hex Docs](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/etcdgun/)

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
- [x] watcher with auto-reconnect [`etcdgun_watcher`](src/etcdgun_watcher.erl).
- [x] check the member list of the cluster periodically, and sync the connections with it
  ([`etcdgun_client`](src/etcdgun_client.erl), the `membership_check_interval` option).
- [x] etcd endpoints health check when dial.
- [ ] health check for active channels in interval.
- [ ] idle connection keep alive?

Generating etcd v3 API codes via the proto files in etcd v3.5.10, without changing their packets.

Extract `ResponseHeader` from `rpc.proto` into `response_header.proto` to avoid
[gpb](https://hex.pm/packages/gpb) to generate the same structure in multiple output pb modules.

## Client APIs

### Starting Client

```erlang
Client = my_client,
Opts = #{},
{ok, _Pid} = etcdgun:open(Client, [{"127.0.0.1", 2379}], Opts),

%% Now you can use `Client' to pick channels and call the etcd gRPC APIs.
{ok, Channel} = etcdgun_client:pick_channel(Client).

%% Get etcd member list via v3 API
{ok, #{header := _, members := Members}} =
    etcdgun_etcdserverpb_cluster_client:member_list(Channel, #{}).

%% Check heath via egrpc provided standard health check API
{ok, #{status := 'SERVING'}} = egrpc_grpc_health_v1_health_client:check(Channel, #{}).
```

### Client Options

See [`etcdgun:opts()`](https://hexdocs.pm/etcdgun/etcdgun.html#t:opts/0) for the available options.

Support egrpc interceptors, set with the `interceptors` option, e.g. the request logging
`fun etcdgun_interceptor_log:log/4` and the token refreshing
`fun etcdgun_interceptor_auth:refresh_token/4`.

The authentication token is not an interceptor: etcdgun sets egrpc `call_credentials` on every
channel it opens, which adds the current token of the client to each call, streaming calls
included. When the token is refreshed, the channels already picked use the new one too.

### Lease Keepalive

`etcdgun_lease_keepalive_sup:start_child(Client, LeaseId, RevokeWhenShutdown)` starts a process
which keeps the lease alive, on its own connection to the cluster and reconnecting when it is
lost. `RevokeWhenShutdown` revokes the lease when the process is stopped normally.

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

### TLS

The members of the cluster are connected with the scheme of their client URLs, `https://` is TLS.
The `Endpoints` given to `etcdgun:open/3` have no scheme, so `transport => tls` tells that they
are TLS, and `gun_opts` are the options of [gun](https://hex.pm/packages/gun) of every
connection, e.g. the CA of the cluster:

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

### API Call

The channel from `etcdgun_client:pick_channel/1` is used with the generated clients, e.g.
`etcdgun_etcdserverpb_kv_client`. The token is added to every call for you.

#### Known issue: `MemberPromote` with authentication on etcd 3.5 and 3.6

When the authentication is enabled, etcd 3.5 and 3.6 reject
`etcdgun_etcdserverpb_cluster_client:member_promote/2` if the channel is connected to a
follower: the follower forwards the request to the leader with an internal request which has no
token, the leader logs `failed to promote a member ... auth: user name is empty` and the caller
only gets `{error, ...}` of `request timed out`. It is not a problem of the token of etcdgun,
and the request works when it reaches the leader. etcd 3.7 does not have it. Send the
`member_promote` through the channel of the leader, e.g. the member whose id is the `leader`
of `etcdgun_etcdserverpb_maintenance_client:status/2`. The other member requests (`member_add`,
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
