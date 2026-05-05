#!/usr/bin/env bash
# metric_sampler.sh -- background metric time-series sampler for the
# CV-as-leading-indicator measurement principle.
#
# Every INTERVAL seconds during the measure window, captures:
#   - timestamp
#   - CV(downstream_cx_http2_total) across IGW pods
#   - sum of downstream_cx_http2_total
#   - sum of downstream_rq_total
#   - upstream cluster histogram p50/p95/p99 (from upstream_rq_time)
#
# Writes CSV: timestamp,cv,sum_cx,sum_rq,upstream_p50,upstream_p95,upstream_p99
#
# Args mirror cpu_sampler.sh:
#   $1 CONTEXT, $2 NAMESPACE_ISTIO, $3 OUT_FILE, $4 SENTINEL_PATH, $5 INTERVAL

set -uo pipefail

CONTEXT="$1"
NAMESPACE_ISTIO="$2"
OUT_FILE="$3"
SENTINEL="$4"
INTERVAL="${5:-5}"

LISTENER_PREFIX='http.outbound_0.0.0.0_8080;'
CLUSTER_PREFIX='cluster.outbound|8080||httpbin.igw-test.svc.cluster.local;'

mkdir -p "$(dirname "${OUT_FILE}")"
echo "timestamp,cv,sum_cx,sum_rq,upstream_p50,upstream_p95,upstream_p99" > "${OUT_FILE}"

cv_calc() {
    awk '{ n++; sum += $2; sumsq += $2*$2 }
        END {
            if (n == 0 || sum == 0) { print "0"; exit }
            mean = sum / n
            var = (sumsq / n) - (mean * mean)
            if (var < 0) var = 0
            printf "%.3f\n", sqrt(var) / mean
        }'
}

while [[ -f "${SENTINEL}" ]]; do
    ts="$(date -u +%s)"
    cx_lines=""
    rq_lines=""
    upstream_hist=""
    for pod in $(kubectl --context "${CONTEXT}" get pod -n "${NAMESPACE_ISTIO}" -l app=istio-ingressgateway -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
        all_stats="$(kubectl --context "${CONTEXT}" exec -n "${NAMESPACE_ISTIO}" "${pod}" -- pilot-agent request GET stats 2>/dev/null || true)"
        cx_val="$(echo "${all_stats}" | awk -v s="${LISTENER_PREFIX}.downstream_cx_http2_total: " 'index($0, s) == 1 {print $NF; exit}')"
        rq_val="$(echo "${all_stats}" | awk -v s="${LISTENER_PREFIX}.downstream_rq_total: " 'index($0, s) == 1 {print $NF; exit}')"
        cx_lines="${cx_lines}${pod} ${cx_val:-0}\n"
        rq_lines="${rq_lines}${pod} ${rq_val:-0}\n"
        # Capture upstream cluster histogram once (first pod with data)
        if [[ -z "${upstream_hist}" ]]; then
            upstream_hist="$(echo "${all_stats}" | awk -v s="${CLUSTER_PREFIX}.upstream_rq_time: " 'index($0, s) == 1 {print; exit}')"
        fi
    done

    cv="$(printf '%b' "${cx_lines}" | cv_calc)"
    sum_cx="$(printf '%b' "${cx_lines}" | awk '{s+=$2} END {print s+0}')"
    sum_rq="$(printf '%b' "${rq_lines}" | awk '{s+=$2} END {print s+0}')"

    # Parse Envoy histogram format: "...P50(interval,cumulative) P95(...) P99(...)..."
    # Use cumulative values (second number). Returns 0 if missing or "nan".
    parse_pct() {
        local pct="$1"
        local val
        val="$(printf '%s' "${upstream_hist}" | sed -nE "s/.*P${pct}\([^,]+,([^)]+)\).*/\1/p")"
        if [[ -z "${val}" || "${val}" == "nan" ]]; then echo 0; else echo "${val}"; fi
    }
    p50="$(parse_pct 50)"
    p95="$(parse_pct 95)"
    p99="$(parse_pct 99)"

    echo "${ts},${cv},${sum_cx:-0},${sum_rq:-0},${p50:-0},${p95:-0},${p99:-0}" >> "${OUT_FILE}"
    sleep "${INTERVAL}"
done
