
# List all tasks
default:
    @just --list

# Clean local development data, e.g. etcd data
clean:
    @rm -rf data/etcd-{1,2,3}

_prepare-etcd-dirs:
    @mkdir -m 700 -p data/etcd-{1,2,3}

etcd: _prepare-etcd-dirs
    @docker compose up

# Stop and remove the etcd cluster containers, the data is kept
etcd-down:
    @docker compose down
