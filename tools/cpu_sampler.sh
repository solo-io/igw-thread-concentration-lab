#!/usr/bin/env bash
# cpu_sampler.sh: background sampler invoked from run-tests.sh.
#
# Samples two things every INTERVAL seconds, until the file at
# SENTINEL_PATH is removed:
#
#   1. Per-pod CPU/memory via `kubectl top pod`: the proxy-side view.
#   2. Per-worker connection counts via Envoy admin
#      (`listener.0.0.0.0_8080.worker_N.downstream_cx_*`): the within-pod
#      thread-balance view.
#
# Why this isn't `top -H` inside the pod: the istio-proxy container
# ships without `sh`, `top`, and `pgrep`, so the obvious approach
# silently produces empty samples. Envoy's own admin exposes per-worker
# accept counts directly, which is what `connection_balance_config:
# exact_balance` operates on, so it's actually a more direct measurement
# than CPU.
#
# Output: OUT_DIR/sample-NNN-<ts>.txt
#
# Args:
#   $1: CONTEXT (k3d cluster context)
#   $2: NAMESPACE_ISTIO (where IGW pods live)
#   $3: OUT_DIR (where samples are written)
#   $4: SENTINEL_PATH (delete this file to stop the sampler)
#   $5: INTERVAL (seconds between samples; default 5)

# Deliberately omit `-e`: a transient kubectl error on one sample
# (network blip, pod transition) should NOT terminate the sampler. The
# main loop will retry on the next tick. The parent run-tests.sh removes
# the sentinel file when it wants this loop to exit cleanly.
set -uo pipefail

CONTEXT="$1"
NAMESPACE_ISTIO="$2"
OUT_DIR="$3"
SENTINEL="$4"
INTERVAL="${5:-5}"

mkdir -p "${OUT_DIR}"

i=0
while [[ -f "${SENTINEL}" ]]; do
    i=$((i + 1))
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    sample="${OUT_DIR}/sample-$(printf '%03d' $i)-${ts}.txt"
    {
        echo "=== sample $i @ ${ts} ==="
        echo "--- kubectl top pod (per-pod CPU/memory) ---"
        kubectl --context "${CONTEXT}" top pod -n "${NAMESPACE_ISTIO}" -l app=istio-ingressgateway --no-headers 2>/dev/null
        echo
        for pod in $(kubectl --context "${CONTEXT}" get pod -n "${NAMESPACE_ISTIO}" -l app=istio-ingressgateway -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
            echo "--- per-worker stats @ ${pod} ---"
            kubectl --context "${CONTEXT}" exec -n "${NAMESPACE_ISTIO}" "${pod}" \
                -- pilot-agent request GET stats 2>/dev/null \
                | grep -E '^listener\.0\.0\.0\.0_8080\.worker_[0-9]+\.downstream_(cx_total|cx_active|rq_total): ' \
                | sort
            echo
        done
    } > "${sample}" 2>&1
    sleep "${INTERVAL}"
done
