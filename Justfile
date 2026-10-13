
# List all tasks
default:
    @just --list

# Clean local development data, e.g. etcd data
clean:
    @rm -rf data/etcd-{1,2,3} data/ct

_prepare-etcd-dirs:
    @mkdir -m 700 -p data/etcd-{1,2,3}

etcd: _prepare-etcd-dirs
    @docker compose up

# Stop and remove the etcd cluster containers, the data is kept
etcd-down:
    @docker compose down
    @COMPOSE_PROJECT_NAME=etcdgun-ct docker compose down

# Start a test cluster in the background with auth (root/123456), its data is data/ct/<version>
etcd-up version="v3.5.10":
    #!/usr/bin/env bash
    set -euo pipefail
    export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-etcdgun-ct}
    export ETCD_VERSION={{version}}
    export ETCD_DATA_DIR=data/ct/$ETCD_VERSION
    mkdir -m 700 -p $ETCD_DATA_DIR/etcd-{1,2,3}
    docker compose up -d
    ctl="docker compose exec -T etcd-1 /usr/local/bin/etcdctl"
    for _ in $(seq 60); do
        $ctl endpoint health >/dev/null 2>&1 && break
        sleep 1
    done
    # With the auth already enabled the status needs the credentials, so check with them.
    if ! $ctl --user root:123456 auth status 2>/dev/null | grep -q "Authentication Status: true"; then
        $ctl user add root --new-user-password=123456 || true
        $ctl user grant-role root root || true
        $ctl auth enable
    fi
    echo "etcd $ETCD_VERSION is up, auth enabled"

# Remove the containers and the data of the clusters of `etcd-up`
etcd-ct-destroy:
    @COMPOSE_PROJECT_NAME=etcdgun-ct ETCD_DATA_DIR=data/ct docker compose down -v
    @rm -rf data/ct

# Run the CT suite on every etcd version, each from a clean cluster destroyed afterwards
ct-all:
    #!/usr/bin/env bash
    set -uo pipefail
    status=0
    trap 'just etcd-ct-destroy >/dev/null 2>&1' EXIT
    just etcd-ct-destroy >/dev/null 2>&1
    for v in v3.5.10 v3.6.5 v3.7.0; do
        echo "=== etcd $v ==="
        if just etcd-up $v; then
            mise exec -- rebar3 ct || status=1
        else
            echo "etcd $v failed to start"
            status=1
        fi
        just etcd-ct-destroy >/dev/null 2>&1
    done
    exit $status
