An etcd client built on top of [gun](https://github.com/ninenines/gun) and [egrpc](https://github.com/belltoy/egrpc).

## Features

- [x] etcd v3 gRPC APIs.
- [x] unary and streaming interceptors for more flexible needs.
- [x] etcd authentication and auto-token-refreshing.
- [x] lease keep alive.
- [x] watch with auto-reconnect.
- [x] etcd member list
- [ ] etcd endpoints health check.

## Client APIs

### Starting Client

```erlang
Client = foo,
Opts = #{},
{ok, _Pid} = etcdgun:open(my_client, [{"127.0.0.1", 2379}], Opts),

% Now you can use `my_client` to pick channels and call the etcd gRPC APIs.
{ok, Channel} = etcdgun_client:pick_channel(my_client).
{ok, #{header := _, members := Members}} = etcdgun_etcdserverpb_cluster_service:member_list(Channel, #{}).
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
rebar3 etcdgun gen
```
