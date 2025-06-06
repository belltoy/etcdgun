An OTP application

## Client APIs

### Starting Client

```erlang
Client = foo,
{ok, _Pid} = etcdgun:open(my_client, [{"127.0.0.1", 2379}]),

% Now you can use `my_client` to pick channels and call the etcd gRPC APIs.
{ok, Channel} = etcdgun_client:pick_channel(my_client).
{ok, #{header := _, members := Members}} = etcdgun_etcdserverpb_cluster_service:member_list(Channel, #{}).
```

### API Call


## Development

```bash
# Generate pb modules
rebar3 protobuf compile

# Generate the etcd gRPC client code
rebar3 etcdgun gen
```
