#!/usr/bin/env bash
# ============================================================================
# cleanup.sh: tear down the lab cluster.
#
# Idempotent: safe to run when the cluster already does not exist.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config.env if present so we tear down whatever cluster name
# deploy.sh actually used. Defaults match deploy.sh.
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/config.env"
fi
: "${CLUSTER_NAME:=igw-tc-lab}"

# Stop the Grafana port-forward background process if present.
PORTFORWARD_PIDFILE="${SCRIPT_DIR}/.grafana-portforward.pid"
if [[ -f "${PORTFORWARD_PIDFILE}" ]]; then
    pid="$(cat "${PORTFORWARD_PIDFILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
        echo "Stopping Grafana port-forward (pid ${pid})..."
        # Kill the wrapper loop and any child kubectl process.
        pkill -P "${pid}" 2>/dev/null || true
        kill "${pid}" 2>/dev/null || true
    fi
    rm -f "${PORTFORWARD_PIDFILE}"
fi

if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}[[:space:]]"; then
    echo "Deleting k3d cluster '${CLUSTER_NAME}'..."
    k3d cluster delete "${CLUSTER_NAME}"
    echo "Done."
else
    echo "Cluster '${CLUSTER_NAME}' does not exist; nothing to clean up."
fi

# Note: the locally-built `h2dial:local` and `ghz:local` Docker images
# are intentionally left behind. They speed up the next ./deploy.sh
# (deploy.sh checks `docker image inspect <tag>` and skips the build on
# a hit). To force a rebuild after editing h2dial/main.go or
# ghz-image/Dockerfile, `docker rmi h2dial:local` (or `ghz:local`)
# before re-running deploy.sh.
