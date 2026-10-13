# etcdgun Agent Instructions

## Overview
Erlang gRPC client for etcd v3 (229 source files). Auto-generates gRPC service stubs and protobuf message decoders from etcd v3.5.10 proto files. Includes auth interceptors, watchers, lease keep-alive, and cluster membership tracking.

## Key Constraints

**Generated code is read-only**: `src/clients/*.erl`, `src/protos/*.erl`, `include/*.hrl`
- Named with prefixes: `etcdgun_*_pb.erl` (protobuf), `etcdgun_*_client.erl` (gRPC)
- Regenerated from `priv/protos/*.proto` via `rebar3 protobuf compile` then `rebar3 egrpc gen`
- Code generation runs automatically during `rebar3 compile` (pre-compile hooks in dev profile)
- Never edit generated code; changes will be overwritten on next generation

## Build & Verify Commands

| Command | Purpose |
|---------|---------|
| `rebar3 compile` | Build with code generation (proto → egrpc → compile) |
| `rebar3 eunit` | Run embedded tests (in src/etcdgun.erl and src/etcdgun_client.erl) |
| `rebar3 ct` | Integration tests in `test/etcdgun_SUITE.erl`, need a running etcd cluster with auth (`just etcd-up [version]`); skipped if it is not reachable |
| `just ct-all` | Run the CT suite on etcd v3.5.10, v3.6.5 and v3.7.0, each from a clean cluster (data in `data/ct/`) which is destroyed afterwards; the images must be pulled |
| `rebar3 fmt -w` | Format code with erlfmt |
| `rebar3 dialyzer` | Static type analysis (Erlang 26.2 compatible) |
| `rebar3 ex_doc` | Generate hexdocs documentation |

Run in sequence for full verification. The CT suite assumes the cluster has authentication enabled with `root`/`123456`, which `just etcd-up` sets up.

## Dev Environment

**Start etcd cluster:**
```bash
just etcd          # Starts 3-node cluster via docker-compose (v3.5.10)
just clean         # Cleans persistent data (data/etcd-{1,2,3})
```

**Dev shell configuration** (`config/sys.dev.config`):
- Auto-loads etcdgun app with dev client config
- Auth: username=`"root"`, password=`"123456"` (hardcoded for dev testing)
- Interceptors loaded: stream auth, unary auth token refresh, request logging
- Logger set to debug level with colorful formatting

## Architecture

**Hand-written modules** (src/):
- `etcdgun.erl` - Public API (open, close, watch, prefix_range_end)
- `etcdgun_client.erl` - Connection pool & channel selection (gen_server)
- `etcdgun_*_sup.erl` - Supervisor tree (client, watcher, lease keep-alive)
- `etcdgun_interceptor_*.erl` - Auth & logging interceptors
- `etcdgun_watcher.erl` - Watch stream with auto-reconnect
- `etcdgun_lease_keepalive.erl` - Lease TTL refresh with periodic pings

**Auto-generated modules** (src/clients/ & src/protos/, read-only):
- `etcdgun_*_client.erl` - gRPC service stubs (Auth, KV, Watch, Lease, Cluster, Maintenance, Election, Lock)
- `etcdgun_*_pb.erl` - Protobuf message encoders/decoders
- Header files in include/ - Type specs for proto messages

**Source protos** (priv/protos/):
- etcd v3 APIs: rpc.proto, v3election.proto, v3lock.proto
- Dependencies: google/api, gogoproto, mvccpb, authpb, etc.

## Important Gotchas

**Linting & Type Checking:**
- W0038 warnings (old edoc syntax) intentionally disabled in `.elp_lint.toml` — don't "fix" these
- xref configured to ignore `etcdgun_rpc_pb`, `etcdgun_v3election_pb`, `etcdgun_v3lock_pb` (all generated)

**Proto Generation:**
- Proto files in `priv/protos/` are from etcd v3.5.10 (not modified)
- Generated code uses module prefixes configured in rebar.config:34-37
- Manual code gen: `rebar3 protobuf compile && rebar3 egrpc gen` (rarely needed; auto-runs)

**Dev & Testing:**
- Integration tests require running etcd cluster (`just etcd`)
- Dev config hardcodes auth for testing; change via `etcdgun_client:update_cred/3` at runtime
- A few inline eunit tests and one CT suite (`rebar3 ct`); no CI workflows
- `just etcd-down` removes the cluster containers, the data in `data/` is kept
- The test clusters (`etcd-up`, `ct-all`) are a separate compose project with their own data in `data/ct/`, never `data/etcd-*` of `just etcd`; destroy them with `just etcd-ct-destroy`
- The suite must pass on etcd 3.5, 3.6 and 3.7, always from a clean cluster as the regression

**Tool Versions** (from .mise.toml):
- Erlang 26.2, Rebar 3.24.0, ELP otp-26
