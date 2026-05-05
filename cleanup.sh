#!/usr/bin/env bash
# ============================================================================
# cleanup.sh -- Tear down the lab cluster.
#
# Idempotent: safe to run when the cluster already does not exist.
# ============================================================================

set -euo pipefail

CLUSTER_NAME="igw-tc-lab"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}\s"; then
    echo "Deleting k3d cluster '${CLUSTER_NAME}'..."
    k3d cluster delete "${CLUSTER_NAME}"
    echo "Done."
else
    echo "Cluster '${CLUSTER_NAME}' does not exist; nothing to clean up."
fi
