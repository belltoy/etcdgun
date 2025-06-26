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
- [x] unary and streaming [interceptors](src/interceptors/) for more flexible needs.
- [x] etcd authentication and auto-token-refreshing.
- [x] lease keep alive [`etcdgun_lease_keepalive`](src/etcdgun_lease_keepalive.erl).
- [x] watcher with auto-reconnect [`etcdgun_watcher`](src/etcdgun_watcher.erl).
- [x] auth-check etcd member list [`etcdgun_membership`](src/etcdgun_membership.erl).
- [x] etcd endpoints health check when dial.
- [ ] health check for active channels in interval.
- [ ] idle connection keep alive?

Generating etcd v3 API codes via the proto files in etcd v3.5.10, without changing their packets.

Extract `ResponseHeader` from `rpc.proto` into `response_header.proto` to avoid [gpb](https://hex.pm/packages/gpb) to generate the
same structure in multiple output pb modules.

## Client APIs

### Starting Client

```erlang
Client = foo,
Opts = #{},
{ok, _Pid} = etcdgun:open(my_client, [{"127.0.0.1", 2379}], Opts),

% Now you can use `my_client` to pick channels and call the etcd gRPC APIs.
{ok, Channel} = etcdgun_client:pick_channel(my_client).
{ok, #{header := _, members := Members}} = etcdgun_etcdserverpb_cluster_client:member_list(Channel, #{}).

{ok,#{status => 'SERVING'}} = egrpc_grpc_health_v1_health_client:check(Channel, #{}).
```

### Client Options

See `etcdgun:opts()` for the available options.

Support unary interceptors and streaming interceptors.

### API Call


## Development

```bash
# Generate pb modules
rebar3 protobuf compile

# Generate the etcd gRPC client code
rebar3 egrpc gen
```
