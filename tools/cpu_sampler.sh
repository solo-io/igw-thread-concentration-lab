#!/usr/bin/env bash
# cpu_sampler.sh -- background CPU sampler invoked from run-tests.sh.
#
# Samples per-pod CPU (kubectl top) and per-thread CPU (top -H inside the
# Envoy process) for each IGW pod every INTERVAL seconds, until the file
# at SENTINEL_PATH is removed. Output goes to OUT_DIR/<sample-N>.txt.
#
# This addresses the customer's data ask (per-pod CPU spread + per-thread
# CPU view during peak load) which a post-run snapshot misses.
#
# Args:
#   $1: CONTEXT (k3d cluster context)
#   $2: NAMESPACE_ISTIO (where IGW pods live)
#   $3: OUT_DIR (where samples are written)
#   $4: SENTINEL_PATH (delete this file to stop the sampler)
#   $5: INTERVAL (seconds between samples; default 5)

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
            echo "--- top -H @ ${pod} ---"
            kubectl --context "${CONTEXT}" exec -n "${NAMESPACE_ISTIO}" "${pod}" -- sh -c 'top -H -b -n 1 -p $(pgrep envoy) 2>/dev/null | head -20' 2>/dev/null
            echo
        done
    } > "${sample}" 2>&1
    sleep "${INTERVAL}"
done
