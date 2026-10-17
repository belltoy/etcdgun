
# List all tasks
default:
    @just --list

# Clean local development data, e.g. etcd data
clean:
    @rm -rf data/etcd-{1,2,3} data/ct

_prepare-etcd-dirs:
    @mkdir -m 700 -p data/etcd-{1,2,3} data/certs

etcd: _prepare-etcd-dirs
    @docker compose up

# Stop and remove the etcd cluster containers, the data is kept
etcd-down:
    @docker compose down
    @COMPOSE_PROJECT_NAME=etcdgun-ct docker compose down

# Start a test cluster in the background with auth (root/123456), its data is data/ct/<version>
etcd-up version="v3.5.10" tls="false":
    #!/usr/bin/env bash
    set -euo pipefail
    export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-etcdgun-ct}
    export ETCD_VERSION={{version}}
    export ETCD_DATA_DIR=data/ct/$ETCD_VERSION
    export ETCD_CERT_DIR=data/ct/certs
    mkdir -m 700 -p $ETCD_DATA_DIR/etcd-{1,2,3} $ETCD_CERT_DIR
    ctl="docker compose exec -T etcd-1 /usr/local/bin/etcdctl"
    if [ "{{tls}}" = true ]; then
        # The client URLs are https with a certificate of a CA of the test, for 127.0.0.1.
        if [ ! -f $ETCD_CERT_DIR/server.pem ]; then
            (
                cd $ETCD_CERT_DIR
                openssl genrsa -out ca-key.pem 2048 2>/dev/null
                openssl req -x509 -new -key ca-key.pem -days 2 -subj "/CN=etcdgun-ct-ca" -out ca.pem
                openssl genrsa -out server-key.pem 2048 2>/dev/null
                openssl req -new -key server-key.pem -subj "/CN=etcdgun-ct" -out server.csr
                printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n" > ext.cnf
                openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
                    -days 2 -extfile ext.cnf -out server.pem 2>/dev/null
            )
        fi
        export ETCD_SCHEME=https ETCD_CERT_FILE=/certs/server.pem ETCD_KEY_FILE=/certs/server-key.pem
        ctl="$ctl --cacert=/certs/ca.pem --endpoints=https://127.0.0.1:2379"
    fi
    # Docker Desktop may not see a directory which was just created yet, retry.
    for i in $(seq 5); do
        docker compose up -d && break
        [ $i -lt 5 ] || exit 1
        sleep 2
    done
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
    echo "etcd $ETCD_VERSION is up, auth enabled, tls={{tls}}"

# Remove the containers and the data of the clusters of `etcd-up`
etcd-ct-destroy:
    @COMPOSE_PROJECT_NAME=etcdgun-ct ETCD_DATA_DIR=data/ct docker compose down -v
    @# On Linux the data was written by root in the containers, the same image removes it.
    @rm -rf data/ct 2>/dev/null || docker run --rm -v "$PWD/data:/data" alpine:3.22 rm -rf /data/ct

# Run the CT suites on every etcd version, each from a clean cluster destroyed afterwards
ct-all:
    #!/usr/bin/env bash
    set -uo pipefail
    status=0
    trap 'just etcd-ct-destroy >/dev/null 2>&1' EXIT
    just etcd-ct-destroy >/dev/null 2>&1
    for v in v3.5.10 v3.6.5 v3.7.0; do
        for tls in false true; do
            echo "=== etcd $v tls=$tls ==="
            if just etcd-up $v $tls; then
                if [ $tls = true ]; then
                    ETCDGUN_CT_TLS_CERTS=$PWD/data/ct/certs mise exec -- rebar3 ct --suite test/etcdgun_tls_SUITE || status=1
                else
                    mise exec -- rebar3 ct --suite test/etcdgun_SUITE || status=1
                fi
            else
                echo "etcd $v failed to start"
                status=1
            fi
            just etcd-ct-destroy >/dev/null 2>&1
        done
    done
    exit $status
