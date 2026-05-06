#!/usr/bin/env bash
# ============================================================================
# run-tests.sh -- Execute the scenario suite. See PLAN.md for the
# hypothesis design and per-scenario rationale.
#
# Each scenario:
#   1. Apply the scenario's EnvoyFilter (or remove for no-overrides scenarios).
#   2. Wait for Envoy hot-reload.
#   3. Reset Envoy stats so we measure only this scenario's window.
#   4. Start a background CPU sampler (per-pod top + per-thread top -H,
#      every 5s during the measure window).
#   5. Run the load gen twice (warmup + measure; per learning L003).
#   6. Stop the CPU sampler.
#   7. Capture the 9 core metrics + concentration ratio per pod.
#   8. Capture per-thread CPU snapshots from each IGW pod.
#   9. Render the Grafana dashboard for this measure window via the
#      render API and save the PNG (handled in the second pass once the
#      dashboard is provisioned).
#
# Primary load gen: h2dial (custom Go HTTP/2 client, shared http2.Transport
# in scenarios 2-12; distinct-Transport-per-worker in scenarios 1 and 6
# for the low-CV reference baseline).
#
# Comparison load gen: fortio (used only in scenarios 02-fortio and
# 03-fortio for the explicit queue-on-cap demonstration of H-B).
# ============================================================================

set -euo pipefail

# --- Cleanup on exit --------------------------------------------------------
# Background samplers (cpu_sampler, metric_sampler) loop on a sentinel
# file. The normal stop_*_sampler helpers `rm` the sentinel; this trap is
# the safety net for Ctrl-C, set -e exits, or anything else that bypasses
# the helpers. Also kills any of our backgrounded shell jobs so they don't
# survive the script.
cleanup_on_exit() {
    if [[ -n "${RESULTS_DIR:-}" && -d "${RESULTS_DIR}" ]]; then
        find "${RESULTS_DIR}" -name '.cpu_sampler.running' -delete 2>/dev/null || true
        find "${RESULTS_DIR}" -name '.metric_sampler.running' -delete 2>/dev/null || true
    fi
    local pids
    pids="$(jobs -pr 2>/dev/null || true)"
    [[ -n "${pids}" ]] && kill ${pids} 2>/dev/null || true
}
trap cleanup_on_exit EXIT INT TERM

# --- Argument parsing -------------------------------------------------------
ONLY=""
SKIP_EVAL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY="$2"; shift 2 ;;
        --only=*) ONLY="${1#*=}"; shift ;;
        --skip-eval) SKIP_EVAL=1; shift ;;
        -h|--help)
            cat <<USAGE
Usage: run-tests.sh [options]
  --only <list>     Run only the named scenarios (comma-separated, e.g. 02-trigger,03-mcs-cap).
                    Names match the scenario directory under results/<ts>/.
  --skip-eval       Skip the hypothesis-evaluation block at the end (only useful with --only).
  -h | --help       This message.

Without --only, the lab's default (IGW_CPU=1) runs 16 of the 17
defined scenarios in sequence (~25-30 min); scenario 13 (within-pod
connection balance) auto-skips because it requires concurrency >= 2.
Set IGW_CPU=2+ in config.env and redeploy to exercise scenario 13.
USAGE
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

should_run() {
    [[ -z "${ONLY}" ]] && return 0
    [[ ",${ONLY}," == *",$1,"* ]] && return 0
    return 1
}

# --- Configuration ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional config.env (gitignored). See config.env.example for the keys.
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/config.env"
fi
: "${CLUSTER_NAME:=igw-tc-lab}"
CONTEXT="k3d-${CLUSTER_NAME}"

MANIFESTS="${SCRIPT_DIR}/manifests"
ENVOYFILTERS="${MANIFESTS}/envoyfilters"
TOOLS="${SCRIPT_DIR}/tools"
RESULTS_DIR="${SCRIPT_DIR}/results/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${RESULTS_DIR}"

NAMESPACE_APP="igw-test"
NAMESPACE_LOAD="loadgen"
NAMESPACE_ISTIO="istio-system"
# (No NAMESPACE_MONITORING here: run-tests.sh doesn't talk to the
# Prometheus stack directly; it only exec's into IGW/waypoint/ztunnel
# pods. The Grafana URL is hard-coded to localhost:3000 since the
# port-forward is set up by deploy.sh.)

IGW_URL="http://istio-ingressgateway.${NAMESPACE_ISTIO}:80"

# Per-scenario warmup and measure durations (Go-style duration strings).
# Override via config.env if you want longer measure runs for steadier
# numbers, or shorter ones for fast iteration on a single scenario.
: "${SCENARIO_WARMUP_DURATION:=15s}"
: "${SCENARIO_MEASURE_DURATION:=60s}"

# Stat name prefixes used everywhere.
LISTENER_PREFIX='http.outbound_0.0.0.0_8080;'
LISTENER_RAW='listener.0.0.0.0_8080'
CLUSTER_PREFIX='cluster.outbound|8080||httpbin.igw-test.svc.cluster.local;'

# --- Helpers ----------------------------------------------------------------
kctl()     { kubectl --context "${CONTEXT}" "$@"; }
fortio()   { kctl exec -n "${NAMESPACE_LOAD}" deploy/fortio -- fortio load "$@"; }
h2dial()   { kctl exec -n "${NAMESPACE_LOAD}" deploy/h2dial -- /h2dial "$@"; }
admin()    { kctl exec -n "${NAMESPACE_ISTIO}" "$1" -- pilot-agent request GET "$2"; }

all_igw_pods() {
    kctl get pod -n "${NAMESPACE_ISTIO}" -l app=istio-ingressgateway -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

# Waypoint pods (3 replicas, scaled up after deploy). Same exec mechanism as IGW pods.
all_waypoint_pods() {
    kctl get pod -n "${NAMESPACE_APP}" -l gateway.istio.io/managed=istio.io-mesh-controller -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

# CV across waypoint pods on a stat. Uses the inbound listener prefix
# the waypoint is configured with (HBONE on port 15008 wrapping HTTP/2).
cv_across_waypoints() {
    local stat="$1"
    local lines=""
    for pod in $(all_waypoint_pods); do
        local val
        val="$(kctl exec -n "${NAMESPACE_APP}" "${pod}" -- pilot-agent request GET stats 2>/dev/null | awk -v s="${stat}: " 'index($0, s) == 1 {print $NF; exit}')"
        lines="${lines}${pod} ${val:-0}"$'\n'
    done
    printf '%b' "${lines}" | awk '
    { n++; sum += $2; sumsq += $2 * $2 }
    END {
        if (n == 0 || sum == 0) { print "0"; exit }
        mean = sum / n
        var = (sumsq / n) - (mean * mean)
        if (var < 0) var = 0
        printf "%.3f\n", sqrt(var) / mean
    }'
}

reset_stats() {
    for pod in $(all_igw_pods); do
        kctl exec -n "${NAMESPACE_ISTIO}" "${pod}" -- pilot-agent request POST reset_counters "" >/dev/null 2>&1 || true
    done
}

apply_scenario() {
    local file="$1"
    kctl apply -f "${file}" >/dev/null
    sleep 5
}

# stat_per_pod: write "<pod> <value>" lines for each IGW pod, exact-match
# on stat name.
stat_per_pod() {
    local stat="$1"
    for pod in $(all_igw_pods); do
        local val
        val="$(admin "${pod}" stats 2>/dev/null | awk -v s="${stat}: " 'index($0, s) == 1 {print $NF; exit}')"
        echo "${pod} ${val:-0}"
    done
}

# Coefficient of variation across pods on a stat (stddev / mean).
cv_across_pods() {
    local stat="$1"
    stat_per_pod "${stat}" | awk '
    {
        n++; sum += $2; sumsq += $2 * $2
    }
    END {
        if (n == 0 || sum == 0) { print "0"; exit }
        mean = sum / n
        var = (sumsq / n) - (mean * mean)
        if (var < 0) var = 0
        printf "%.3f\n", sqrt(var) / mean
    }'
}

# Capture the 9 core metrics + concentration ratio + listener latency
# histogram. Output in <out>/<metric>_per_pod.txt.
capture_metrics() {
    local out="$1"
    # 1. Active connections per pod (gauge, valid only mid-run, but we
    # snapshot post-run for completeness; for analytics we use the _total
    # counter below)
    stat_per_pod "${LISTENER_PREFIX}.downstream_cx_active" \
        > "${out}/cx_active_per_pod.txt" 2>/dev/null || true
    # HTTP/2 connections opened total (counter, primary distribution metric)
    stat_per_pod "${LISTENER_PREFIX}.downstream_cx_http2_total" \
        > "${out}/cx_http2_total_per_pod.txt" 2>/dev/null || true
    # 2. Active requests per pod (for concentration ratio with cx_active)
    stat_per_pod "${LISTENER_PREFIX}.downstream_rq_active" \
        > "${out}/rq_active_per_pod.txt" 2>/dev/null || true
    # 3. GOAWAY counters (max_duration / max_requests_reached)
    stat_per_pod "${LISTENER_PREFIX}.downstream_cx_max_duration_reached" \
        > "${out}/cx_max_duration_reached.txt" 2>/dev/null || true
    stat_per_pod "${LISTENER_PREFIX}.downstream_cx_max_requests_reached" \
        > "${out}/cx_max_requests_reached.txt" 2>/dev/null || true
    # 4. Upstream pending requests (saturation upstream)
    stat_per_pod "${CLUSTER_PREFIX}.upstream_rq_pending_active" \
        > "${out}/upstream_rq_pending_active.txt" 2>/dev/null || true
    stat_per_pod "${CLUSTER_PREFIX}.upstream_rq_pending_overflow" \
        > "${out}/upstream_rq_pending_overflow.txt" 2>/dev/null || true
    # 5. Upstream connection pool overflow
    stat_per_pod "${CLUSTER_PREFIX}.upstream_cx_overflow" \
        > "${out}/upstream_cx_overflow.txt" 2>/dev/null || true
    # 6. Stream / connection idle timeouts
    stat_per_pod "${LISTENER_PREFIX}.downstream_rq_idle_timeout" \
        > "${out}/downstream_rq_idle_timeout.txt" 2>/dev/null || true
    stat_per_pod "${LISTENER_PREFIX}.downstream_cx_idle_timeout" \
        > "${out}/downstream_cx_idle_timeout.txt" 2>/dev/null || true
    # 7. Listener-level tail latency histogram (P0..P100). Written as a
    # multiline blob since values are histograms not scalars.
    for pod in $(all_igw_pods); do
        local hist
        hist="$(admin "${pod}" stats 2>/dev/null | awk -v s="${LISTENER_RAW}.downstream_cx_length_ms: " 'index($0, s) == 1 {print; exit}')"
        echo "${pod} ${hist}"
    done > "${out}/cx_length_ms_per_pod.txt" 2>/dev/null || true
    # 8. Flow-control pause counters
    stat_per_pod "${CLUSTER_PREFIX}.upstream_flow_control_paused_reading_total" \
        > "${out}/flow_control_paused.txt" 2>/dev/null || true
    # 9. Bytes buffered (RX/TX) on the upstream cluster
    stat_per_pod "${CLUSTER_PREFIX}.upstream_cx_rx_bytes_buffered" \
        > "${out}/upstream_cx_rx_bytes_buffered.txt" 2>/dev/null || true
    stat_per_pod "${CLUSTER_PREFIX}.upstream_cx_tx_bytes_buffered" \
        > "${out}/upstream_cx_tx_bytes_buffered.txt" 2>/dev/null || true
    # SSL handshakes (for mTLS rotation scenario; harmless on plaintext)
    stat_per_pod "${LISTENER_RAW}.ssl.handshake" \
        > "${out}/ssl_handshake.txt" 2>/dev/null || true

    # Waypoint capture: if the httpbin Service is currently labeled with
    # use-waypoint, also dump waypoint-pod stats for the same time window.
    # The waypoint Envoy stat prefix differs from the IGW; we capture the
    # full stat set so post-run analysis can pick the right metric.
    if kctl get svc httpbin -n "${NAMESPACE_APP}" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}' 2>/dev/null | grep -q .; then
        mkdir -p "${out}/waypoint_stats"
        local wp_total=0 wp_count=0 wp_var=0 wp_mean=0
        for wp in $(all_waypoint_pods); do
            kctl exec -n "${NAMESPACE_APP}" "${wp}" -- pilot-agent request GET stats \
                > "${out}/waypoint_stats/${wp}.txt" 2>/dev/null || true
            local v
            v="$(awk -F': ' '/downstream_cx_http2_total: /{s+=$2} END{print s+0}' "${out}/waypoint_stats/${wp}.txt" 2>/dev/null)"
            wp_count=$((wp_count + 1))
            wp_total=$((wp_total + ${v:-0}))
        done
        if [[ ${wp_count} -gt 0 && ${wp_total} -gt 0 ]]; then
            wp_mean=$(awk -v t=${wp_total} -v n=${wp_count} 'BEGIN{printf "%.3f", t/n}')
            wp_var=$(for wp in $(all_waypoint_pods); do
                v="$(awk -F': ' '/downstream_cx_http2_total: /{s+=$2} END{print s+0}' "${out}/waypoint_stats/${wp}.txt" 2>/dev/null)"
                awk -v val=${v:-0} -v m=${wp_mean} 'BEGIN{print (val-m)*(val-m)}'
            done | awk -v n=${wp_count} '{s+=$1} END{printf "%.6f", sqrt(s/n)/'"${wp_mean}"'}')
            echo "WAYPOINT_CV: ${wp_var}" > "${out}/waypoint_cv.txt"
            echo "WAYPOINT_TOTAL_CONNS: ${wp_total}" >> "${out}/waypoint_cv.txt"
            echo "WAYPOINT_PODS: ${wp_count}" >> "${out}/waypoint_cv.txt"
        fi
    fi

    # CV across pods on the primary distribution metric (cumulative counter)
    local cv
    cv="$(cv_across_pods "${LISTENER_PREFIX}.downstream_cx_http2_total")"
    echo "  CV(downstream_cx_http2_total across pods) = ${cv}" | tee "${out}/cv.txt"

    # Also capture CV(downstream_cx_active) gauge: this is the leading-
    # indicator query the Grafana dashboard uses live. The gauge is
    # sampled post-run so it may be near-zero if connections closed
    # cleanly; for the live-trend version see the Grafana dashboard's
    # CV panel which queries cx_active over a moving window.
    local cv_active
    cv_active="$(cv_across_pods "${LISTENER_PREFIX}.downstream_cx_active")"
    echo "  CV(downstream_cx_active across pods, post-run gauge) = ${cv_active}" | tee -a "${out}/cv.txt"

    # Per-worker CV within each pod. This is the within-pod balance
    # metric that scenario 13 (connection_balance_config) operates on.
    # At concurrency=1 every pod has one worker; CV is undefined and we
    # write 0. At concurrency >= 2 we compute CV across worker_N values
    # of downstream_cx_total per pod, then surface the worst-case (max)
    # across pods so a single hot pod can't hide behind even peers.
    : > "${out}/worker_cv_per_pod.txt"
    for pod in $(all_igw_pods); do
        local pod_worker_cv
        pod_worker_cv="$(admin "${pod}" stats 2>/dev/null \
            | awk '/^listener\.0\.0\.0\.0_8080\.worker_[0-9]+\.downstream_cx_total: /{print $NF}' \
            | awk '
                { n++; sum += $1; sumsq += $1 * $1 }
                END {
                    if (n < 2 || sum == 0) { print "0"; exit }
                    mean = sum / n
                    var = (sumsq / n) - (mean * mean)
                    if (var < 0) var = 0
                    printf "%.3f\n", sqrt(var) / mean
                }')"
        echo "${pod} ${pod_worker_cv}" >> "${out}/worker_cv_per_pod.txt"
    done
    # Surface both mean and max per-pod worker CV. The mean is the
    # discriminating metric for H-E (connection_balance_config produces
    # a tighter mean distribution); the max is informative but the
    # kernel's accept race is good enough often enough that exact_balance
    # doesn't always eliminate the single worst pod's imbalance.
    local worker_cv_mean worker_cv_max
    read worker_cv_mean worker_cv_max < <(awk '
        { n++; sum += $2; if ($2 > max) max = $2 }
        END {
            if (n == 0) { print "0 0"; exit }
            printf "%.3f %.3f\n", sum / n, max
        }' "${out}/worker_cv_per_pod.txt")
    echo "  CV(worker_N.downstream_cx_total within a pod, mean across pods) = ${worker_cv_mean:-0}" \
        | tee -a "${out}/cv.txt"
    echo "  CV(worker_N.downstream_cx_total within a pod, max across pods)  = ${worker_cv_max:-0}" \
        | tee -a "${out}/cv.txt"
}

# Per-thread CPU snapshot dropped: cpu_sampler.sh runs throughout the
# measure window with the same per-thread top -H output (sample-NNN-*.txt),
# so a separate post-run snapshot is redundant. The sampler captures with
# real load on the threads; the post-run snapshot caught threads idle.

# Start CPU sampler in background; returns sentinel path used to stop it.
start_cpu_sampler() {
    local out="$1"
    local sentinel="${out}/.cpu_sampler.running"
    touch "${sentinel}"
    "${TOOLS}/cpu_sampler.sh" "${CONTEXT}" "${NAMESPACE_ISTIO}" "${out}/cpu_samples" "${sentinel}" 5 \
        > "${out}/cpu_samples.log" 2>&1 &
    echo "${sentinel}"
}

stop_cpu_sampler() {
    local sentinel="$1"
    rm -f "${sentinel}"
    sleep 1  # give the loop one tick to exit
}

# Start metric time-series sampler for the CV-as-leading-indicator measurement principle.
# Used only on scenario 02-trigger.
start_metric_sampler() {
    local out="$1"
    local sentinel="${out}/.metric_sampler.running"
    touch "${sentinel}"
    "${TOOLS}/metric_sampler.sh" "${CONTEXT}" "${NAMESPACE_ISTIO}" "${out}/timeseries.csv" "${sentinel}" 5 \
        > "${out}/metric_sampler.log" 2>&1 &
    echo "${sentinel}"
}

stop_metric_sampler() {
    local sentinel="$1"
    rm -f "${sentinel}"
    sleep 1
}

# Extract p99 from h2dial or fortio output.
extract_p99() {
    local file="$1"
    grep -E '^# target 99% ' "${file}" 2>/dev/null | awk '{print $4}' | head -1 || echo "n/a"
}

# capture_grafana_screenshot: render the lab dashboard for the time
# window of this scenario's measure run via Grafana's image-renderer
# plugin. Saved to <out>/grafana.png. Failure is non-fatal; the live
# dashboard remains available at http://localhost:3000 for manual
# screenshots if the renderer is unavailable.
GRAFANA_URL="http://localhost:3000"
GRAFANA_AUTH="admin:admin"
GRAFANA_DASHBOARD_UID="igw-thread-concentration"

capture_grafana_screenshot() {
    local out="$1"
    local from_ms="$2"
    # Sleep briefly to let Prometheus complete a scrape including the very
    # end of the measure window (default scrape interval is 15s).
    sleep 16
    local final_to_ms
    final_to_ms="$(($(date +%s) * 1000))"
    local png="${out}/grafana.png"
    # Try the render API in case image-renderer IS available (linux-amd64).
    local url="${GRAFANA_URL}/render/d/${GRAFANA_DASHBOARD_UID}?orgId=1&from=${from_ms}&to=${final_to_ms}&width=1600&height=2400&theme=light&kiosk=tv"
    if curl -fsS --max-time 60 -u "${GRAFANA_AUTH}" "${url}" -o "${png}" 2>"${out}/grafana-render.log"; then
        local size
        size="$(stat -f%z "${png}" 2>/dev/null || stat -c%s "${png}" 2>/dev/null)"
        if [[ "${size:-0}" -gt 5000 ]]; then
            echo "  Grafana screenshot saved (${size} bytes): ${png}"
            return
        fi
    fi
    # Fallback: print the URL with from/to params so the user can paste
    # into a browser and screenshot manually.
    rm -f "${png}" 2>/dev/null
    local manual_url="${GRAFANA_URL}/d/${GRAFANA_DASHBOARD_UID}?from=${from_ms}&to=${final_to_ms}&kiosk=tv"
    echo "  Grafana renderer unavailable. Manual screenshot URL:"
    echo "    ${manual_url}"
    # Save the URL to a file so the README export step can include it.
    echo "${manual_url}" > "${out}/grafana-url.txt"
}

# --- h2dial scenario runner -------------------------------------------------
# Args: name filter url [c=200] [mode=shared]
run_h2dial_scenario() {
    local name="$1"; shift
    local filter="$1"; shift
    local url="$1"; shift
    local concurrent="${1:-200}"; [[ $# -gt 0 ]] && shift
    local mode="${1:-shared}"; [[ $# -gt 0 ]] && shift
    if ! should_run "${name}"; then echo "  (skipping ${name}, not in --only list)"; return 0; fi
    local out="${RESULTS_DIR}/${name}"
    mkdir -p "${out}"

    echo ""
    echo "================================================================"
    echo "  Scenario: ${name} (h2dial mode=${mode}, c=${concurrent})"
    echo "================================================================"
    echo "  EnvoyFilter: $(basename "${filter}")"

    apply_scenario "${filter}"

    local measure_from_ms=0
    for run in warmup measure; do
        echo "  Run: ${run}"
        reset_stats
        local dur="${SCENARIO_WARMUP_DURATION}"
        [[ "${run}" == "measure" ]] && dur="${SCENARIO_MEASURE_DURATION}"

        local cpu_sentinel=""
        local metric_sentinel=""
        if [[ "${run}" == "measure" ]]; then
            measure_from_ms=$(($(date +%s) * 1000))
            cpu_sentinel="$(start_cpu_sampler "${out}")"
            # Time-series metric sampler for the CV-as-leading-indicator
            # measurement principle. Only enable on the
            # trigger scenario (02-trigger) where we expect to see CV
            # rise before p99 jumps.
            if [[ "${name}" == "02-trigger" ]]; then
                metric_sentinel="$(start_metric_sampler "${out}")"
            fi
        fi

        h2dial "-mode=${mode}" "-url=${url}" "-d=${dur}" "-c=${concurrent}" \
            >"${out}/h2dial-${run}.txt" 2>&1 || true

        if [[ "${run}" == "measure" ]]; then
            stop_cpu_sampler "${cpu_sentinel}"
            [[ -n "${metric_sentinel}" ]] && stop_metric_sampler "${metric_sentinel}"
        fi
    done

    echo "  Capturing metrics..."
    capture_metrics "${out}"
    capture_grafana_screenshot "${out}" "${measure_from_ms}" 0

    local p99
    p99="$(extract_p99 "${out}/h2dial-measure.txt")"
    echo "  p99 latency = ${p99}s" | tee -a "${out}/cv.txt"
}

# --- fortio comparison runner (only for scenarios 02-fortio, 03-fortio) ----
# Args: name filter [fortio-args...]
run_fortio_scenario() {
    local name="$1"; shift
    local filter="$1"; shift
    if ! should_run "${name}"; then echo "  (skipping ${name}, not in --only list)"; return 0; fi
    local out="${RESULTS_DIR}/${name}"
    mkdir -p "${out}"

    echo ""
    echo "================================================================"
    echo "  Scenario: ${name} (fortio fixed-pool client)"
    echo "================================================================"
    echo "  EnvoyFilter: $(basename "${filter}")"

    apply_scenario "${filter}"

    local measure_from_ms=0
    for run in warmup measure; do
        echo "  Run: ${run}"
        reset_stats
        local dur="${SCENARIO_WARMUP_DURATION}"
        [[ "${run}" == "measure" ]] && dur="${SCENARIO_MEASURE_DURATION}"

        local sentinel=""
        if [[ "${run}" == "measure" ]]; then
            measure_from_ms=$(($(date +%s) * 1000))
            sentinel="$(start_cpu_sampler "${out}")"
        fi

        local args=("$@")
        local url="${args[${#args[@]}-1]}"
        unset 'args[${#args[@]}-1]'
        fortio -t "${dur}" "${args[@]}" "${url}" \
            >"${out}/fortio-${run}.txt" 2>&1 || true

        if [[ "${run}" == "measure" ]]; then
            stop_cpu_sampler "${sentinel}"
        fi
    done

    echo "  Capturing metrics..."
    capture_metrics "${out}"
    capture_grafana_screenshot "${out}" "${measure_from_ms}" 0

    local p99
    p99="$(extract_p99 "${out}/fortio-measure.txt")"
    echo "  p99 latency = ${p99}s" | tee -a "${out}/cv.txt"
}

# --- Scenarios --------------------------------------------------------------

# Scenario 1: low-CV reference baseline.
# h2dial -mode=distinct gives one TCP connection per worker = 100 connections
# distributed evenly across 3 IGW pods = low CV.
run_h2dial_scenario "01-baseline" \
    "${ENVOYFILTERS}/scenario1-baseline.yaml" \
    "${IGW_URL}/get" 100 distinct

# Scenarios 2-5: H-A mechanism + tuning levers, h2dial shared transport.
# 500 in-flight workers on a shared http2.Transport => stream multiplexing
# happens; the cap can be exercised.
run_h2dial_scenario "02-trigger" \
    "${ENVOYFILTERS}/scenario2-trigger.yaml" \
    "${IGW_URL}/bytes/16384" 500 shared

run_h2dial_scenario "03-mcs-cap" \
    "${ENVOYFILTERS}/scenario3-mcs-cap.yaml" \
    "${IGW_URL}/bytes/16384" 500 shared

run_h2dial_scenario "04-mrpc" \
    "${ENVOYFILTERS}/scenario4-mrpc.yaml" \
    "${IGW_URL}/bytes/16384" 500 shared

run_h2dial_scenario "05-windows" \
    "${ENVOYFILTERS}/scenario5-windows.yaml" \
    "${IGW_URL}/bytes/16384" 500 shared

# Scenarios 02-fortio through 05-fortio: explicit queue-on-cap demonstration
# with fortio's fixed-pool semantics. Same EnvoyFilter as the h2dial-driven
# scenario; only the load gen differs. All four together let us show that
# server-side levers behave very differently with queueing vs dialing
# clients.
run_fortio_scenario "02-fortio" \
    "${ENVOYFILTERS}/scenario2-trigger.yaml" \
    -h2 -c 2 -qps 5000 "${IGW_URL}/bytes/16384"

run_fortio_scenario "03-fortio" \
    "${ENVOYFILTERS}/scenario3-mcs-cap.yaml" \
    -h2 -c 2 -qps 5000 "${IGW_URL}/bytes/16384"

run_fortio_scenario "04-fortio" \
    "${ENVOYFILTERS}/scenario4-mrpc.yaml" \
    -h2 -c 2 -qps 5000 "${IGW_URL}/bytes/16384"

run_fortio_scenario "05-fortio" \
    "${ENVOYFILTERS}/scenario5-windows.yaml" \
    -h2 -c 2 -qps 5000 "${IGW_URL}/bytes/16384"

# Waypoint scenarios: enable waypoint label on httpbin Service, run.
echo ""
echo "================================================================"
echo "  Enabling waypoint for httpbin (scenarios 6 and 7)"
echo "================================================================"
kctl label svc httpbin -n "${NAMESPACE_APP}" istio.io/use-waypoint=igw-test-waypoint --overwrite >/dev/null
sleep 5

run_h2dial_scenario "06-waypoint-baseline" \
    "${ENVOYFILTERS}/scenario1-baseline.yaml" \
    "${IGW_URL}/get" 100 distinct

run_h2dial_scenario "07-waypoint-trigger" \
    "${ENVOYFILTERS}/scenario2-trigger.yaml" \
    "${IGW_URL}/bytes/16384" 500 shared

echo ""
echo "  Removing waypoint label"
kctl label svc httpbin -n "${NAMESPACE_APP}" istio.io/use-waypoint- >/dev/null 2>&1 || true

# Scenarios 8, 9, 10, 11, 12 are guarded on the presence of their
# respective EnvoyFilter manifests so the suite degrades gracefully if
# you drop a scenario file. See PLAN.md for the hypothesis each one
# tests.

if [[ -f "${ENVOYFILTERS}/scenario8-buffers.yaml" ]]; then
    run_h2dial_scenario "08-buffers" \
        "${ENVOYFILTERS}/scenario8-buffers.yaml" \
        "${IGW_URL}/bytes/65536" 500 shared
fi

if [[ -f "${ENVOYFILTERS}/scenario9-hol-blocking.yaml" ]] && should_run "09-hol-blocking"; then
    # HOL: 5 slow workers fire /delay/2 alongside 500 primary workers on
    # /bytes/16384. All on the same http.Client. Latency stats track
    # primary URL only.
    out_dir="${RESULTS_DIR}/09-hol-blocking"
    mkdir -p "${out_dir}"
    echo ""
    echo "================================================================"
    echo "  Scenario: 09-hol-blocking (h2dial with slow streams)"
    echo "================================================================"
    apply_scenario "${ENVOYFILTERS}/scenario9-hol-blocking.yaml"
    measure_from_ms_hol=0
    for run in warmup measure; do
        echo "  Run: ${run}"
        reset_stats
        dur="${SCENARIO_WARMUP_DURATION}"
        [[ "${run}" == "measure" ]] && dur="${SCENARIO_MEASURE_DURATION}"
        sentinel=""
        if [[ "${run}" == "measure" ]]; then
            measure_from_ms_hol=$(($(date +%s) * 1000))
            sentinel="$(start_cpu_sampler "${out_dir}")"
        fi
        h2dial "-mode=shared" \
            "-url=${IGW_URL}/bytes/16384" \
            "-slow-url=${IGW_URL}/delay/2" \
            "-slow-workers=5" \
            "-d=${dur}" "-c=500" \
            >"${out_dir}/h2dial-${run}.txt" 2>&1 || true
        if [[ "${run}" == "measure" ]]; then
            stop_cpu_sampler "${sentinel}"
        fi
    done
    capture_metrics "${out_dir}"
    capture_grafana_screenshot "${out_dir}" "${measure_from_ms_hol}" 0
    p99_hol="$(extract_p99 "${out_dir}/h2dial-measure.txt")"
    echo "  p99 latency (fast stream) = ${p99_hol}s" | tee -a "${out_dir}/cv.txt"
fi

if [[ -f "${ENVOYFILTERS}/scenario10-rotation.yaml" ]]; then
    # Connection rotation pattern (proxy for mTLS handshake cost).
    # Same load as scenario 2; only difference is max_connection_duration=10s.
    run_h2dial_scenario "10-rotation" \
        "${ENVOYFILTERS}/scenario10-rotation.yaml" \
        "${IGW_URL}/bytes/16384" 500 shared
fi

if [[ -f "${ENVOYFILTERS}/scenario11-realistic-filters.yaml" ]] && should_run "11-realistic-filters"; then
    # Enable JWT validation on the IGW listener for this scenario.
    # h2dial sends the Istio demo JWT (publicly published, stable token).
    # Validation runs in PERMISSIVE mode (no AuthorizationPolicy paired),
    # AuthorizationPolicy enforces it), so the filter runs and incurs
    # cost but does not reject requests.
    echo ""
    echo "  Applying RequestAuthentication for JWT validation..."
    kctl apply -f "${MANIFESTS}/11-jwt-auth.yaml" >/dev/null
    sleep 5
    DEMO_JWT="$(curl -fsSL https://raw.githubusercontent.com/istio/istio/release-1.27/security/tools/jwt/samples/demo.jwt 2>/dev/null | tr -d '\n')"
    if [[ -z "${DEMO_JWT}" ]]; then
        echo "  WARNING: could not fetch Istio demo JWT; scenario 11 will run without Authorization header."
    fi

    out_dir="${RESULTS_DIR}/11-realistic-filters"
    mkdir -p "${out_dir}"
    echo ""
    echo "================================================================"
    echo "  Scenario: 11-realistic-filters (h2dial + JWT validation + access log)"
    echo "================================================================"
    apply_scenario "${ENVOYFILTERS}/scenario11-realistic-filters.yaml"
    measure_from_ms_11=0
    for run in warmup measure; do
        echo "  Run: ${run}"
        reset_stats
        dur="${SCENARIO_WARMUP_DURATION}"
        [[ "${run}" == "measure" ]] && dur="${SCENARIO_MEASURE_DURATION}"
        sentinel=""
        if [[ "${run}" == "measure" ]]; then
            measure_from_ms_11=$(($(date +%s) * 1000))
            sentinel="$(start_cpu_sampler "${out_dir}")"
        fi
        if [[ -n "${DEMO_JWT}" ]]; then
            h2dial "-mode=shared" \
                "-url=${IGW_URL}/bytes/16384" \
                "-d=${dur}" "-c=500" \
                "-header=Authorization: Bearer ${DEMO_JWT}" \
                >"${out_dir}/h2dial-${run}.txt" 2>&1 || true
        else
            h2dial "-mode=shared" "-url=${IGW_URL}/bytes/16384" "-d=${dur}" "-c=500" \
                >"${out_dir}/h2dial-${run}.txt" 2>&1 || true
        fi
        if [[ "${run}" == "measure" ]]; then
            stop_cpu_sampler "${sentinel}"
        fi
    done
    capture_metrics "${out_dir}"
    capture_grafana_screenshot "${out_dir}" "${measure_from_ms_11}"
    p99_11="$(extract_p99 "${out_dir}/h2dial-measure.txt")"
    echo "  p99 latency = ${p99_11}s" | tee -a "${out_dir}/cv.txt"

    echo "  Removing RequestAuthentication..."
    kctl delete -f "${MANIFESTS}/11-jwt-auth.yaml" --ignore-not-found >/dev/null 2>&1 || true
fi

# gRPC variant via ghz + grpcbin. Single grpc.ClientConn (--connections 1)
# models real-world grpc-go single-ClientConn behavior: streams queue at the
# server stream cap rather than driving the transport to dial. Compare to
# scenario 02-trigger (h2dial-shared) and 02-fortio (fortio-fixed-pool).
if should_run "12-grpc-variant" && kctl get deploy grpcbin -n "${NAMESPACE_APP}" &>/dev/null \
   && kctl get deploy ghz -n "${NAMESPACE_LOAD}" &>/dev/null; then
    out_dir="${RESULTS_DIR}/12-grpc-variant"
    mkdir -p "${out_dir}"
    echo ""
    echo "================================================================"
    echo "  Scenario: 12-grpc-variant (ghz against grpcbin via IGW, single ClientConn)"
    echo "================================================================"
    apply_scenario "${ENVOYFILTERS}/scenario2-trigger.yaml"
    measure_from_ms_12=0
    for run in warmup measure; do
        echo "  Run: ${run}"
        reset_stats
        dur="${SCENARIO_WARMUP_DURATION}"
        [[ "${run}" == "measure" ]] && dur="${SCENARIO_MEASURE_DURATION}"
        sentinel=""
        if [[ "${run}" == "measure" ]]; then
            measure_from_ms_12=$(($(date +%s) * 1000))
            sentinel="$(start_cpu_sampler "${out_dir}")"
        fi
        # ghz: --insecure (h2c through Envoy listener), --proto via reflection,
        # --concurrency 500 workers, --connections 1 (single ClientConn),
        # --duration matches the run window, --skipTLS, target the IGW
        # service with --authority so the VirtualService routes to grpcbin.
        kctl exec -n "${NAMESPACE_LOAD}" deploy/ghz -- ghz \
            --insecure \
            --concurrency=500 \
            --connections=1 \
            --authority=grpcbin.igw-test \
            --duration="${dur}" \
            --call=grpc.gateway.testing.GRPCBin/DummyUnary \
            --data='{}' \
            "istio-ingressgateway.${NAMESPACE_ISTIO}:80" \
            >"${out_dir}/ghz-${run}.txt" 2>&1 || true
        if [[ "${run}" == "measure" ]]; then
            stop_cpu_sampler "${sentinel}"
        fi
    done
    capture_metrics "${out_dir}"
    capture_grafana_screenshot "${out_dir}" "${measure_from_ms_12}"
    # ghz output format differs from fortio/h2dial; just save the summary.
    grep -E '^(Average|Slowest|Fastest|Requests/sec|Total|Latency distribution|99 %)' \
        "${out_dir}/ghz-measure.txt" 2>/dev/null > "${out_dir}/ghz-summary.txt" || true
fi

# Scenario 13: connection_balance_config (within-pod worker balance).
# Skips automatically when concurrency=1 (the lab's default), since there
# is nothing to balance within a single-thread pod. To exercise: set
# IGW_CPU=2+ in config.env, redeploy, then re-run.
if [[ -f "${ENVOYFILTERS}/scenario13-conn-balance.yaml" ]] && should_run "13-conn-balance"; then
    igw_pod_for_check="$(all_igw_pods | head -1)"
    concurrency_check="$(kctl exec -n "${NAMESPACE_ISTIO}" "${igw_pod_for_check}" \
        -- pilot-agent request GET server_info 2>/dev/null \
        | grep -oE '"concurrency": *[0-9]+' | head -1 | grep -oE '[0-9]+')"
    if [[ -z "${concurrency_check}" || "${concurrency_check}" -lt 2 ]]; then
        echo ""
        echo "================================================================"
        echo "  Scenario: 13-conn-balance (SKIPPED)"
        echo "================================================================"
        echo "  Envoy concurrency on the IGW is ${concurrency_check:-unknown}."
        echo "  Within-pod worker balance only matters at concurrency >= 2."
        echo "  To run this scenario:"
        echo "    1) set IGW_CPU=2 (or higher) in config.env"
        echo "    2) ./cleanup.sh && ./deploy.sh"
        echo "    3) ./run-tests.sh --only 13-conn-balance"
    else
        # Load profile is intentionally different from the trigger scenarios:
        # distinct mode with c=300 gives ~50 connections per pod, so each
        # pod's workers actually have multiple connections to balance. With
        # shared mode (c=500 across the lab's 3-5 transport-pool conns),
        # most pods get 0 or 1 connection and there's nothing to balance.
        run_h2dial_scenario "13-conn-balance" \
            "${ENVOYFILTERS}/scenario13-conn-balance.yaml" \
            "${IGW_URL}/bytes/16384" 300 distinct
    fi
fi

# --- Hypothesis evaluation -------------------------------------------------
if [[ "${SKIP_EVAL}" -eq 1 || -n "${ONLY}" ]]; then
    echo ""
    echo "Skipping hypothesis evaluation (incomplete run; use full ./run-tests.sh for it)."
    echo "Results directory: ${RESULTS_DIR}"
    exit 0
fi

echo ""
echo "================================================================"
echo "  Hypothesis evaluation"
echo "================================================================"

read_cv() {
    awk -F'= *' '/^  CV/{print $2; exit}' "$1" 2>/dev/null | head -1
}
sum_metric() {
    awk '{s+=$2} END{print s+0}' "$1" 2>/dev/null
}

S1_CV="$(read_cv "${RESULTS_DIR}/01-baseline/cv.txt")"
S2_CV="$(read_cv "${RESULTS_DIR}/02-trigger/cv.txt")"
S3_CV="$(read_cv "${RESULTS_DIR}/03-mcs-cap/cv.txt")"

echo ""
echo "  H-A (mechanism, h2dial shared transport):"
echo "     CV scenario 1 (baseline, distinct conns) = ${S1_CV}"
echo "     CV scenario 2 (trigger, shared transport, cap=65536) = ${S2_CV}"
if awk -v s1="${S1_CV}" -v s2="${S2_CV}" 'BEGIN{exit !(s2 > s1 * 2)}'; then
    echo "     PASS: CV jumped (>=2x) baseline -> trigger"
else
    echo "     INVESTIGATE: CV did not jump as expected"
fi

S2F_CV="$(read_cv "${RESULTS_DIR}/02-fortio/cv.txt")"
S3F_CV="$(read_cv "${RESULTS_DIR}/03-fortio/cv.txt")"
echo ""
echo "  H-B with fortio (fixed-pool client, expected: NO redistribution):"
echo "     CV scenario 02-fortio = ${S2F_CV}, CV scenario 03-fortio = ${S3F_CV}"
if awk -v s2="${S2F_CV}" -v s3="${S3F_CV}" 'BEGIN{exit !(s3 < s2 * 0.5)}'; then
    echo "     UNEXPECTED PASS: queueing client showed redistribution. Investigate."
else
    echo "     EXPECTED: CV stable. Queueing client cannot use the cap to redistribute."
fi

echo ""
echo "  H-B with h2dial (smart client, expected: CV drops + more conns):"
S2_TOTAL="$(sum_metric "${RESULTS_DIR}/02-trigger/cx_http2_total_per_pod.txt")"
S3_TOTAL="$(sum_metric "${RESULTS_DIR}/03-mcs-cap/cx_http2_total_per_pod.txt")"
echo "     scenario 2: CV = ${S2_CV}, total connections = ${S2_TOTAL}"
echo "     scenario 3: CV = ${S3_CV}, total connections = ${S3_TOTAL}"
if awk -v s2="${S2_CV}" -v s3="${S3_CV}" 'BEGIN{exit !(s3 < s2 * 0.7)}'; then
    echo "     PASS: CV dropped when cap applied; smart client redistributes via dial-on-cap"
elif [[ "${S3_TOTAL}" -gt "${S2_TOTAL}" ]]; then
    echo "     PARTIAL: smart client opened more connections under cap, but CV did not drop proportionally"
else
    echo "     INVESTIGATE: smart client did not open more connections"
fi

S4_MRC="$(sum_metric "${RESULTS_DIR}/04-mrpc/cx_max_requests_reached.txt")"
echo ""
echo "  H-C (max_requests_per_connection rotation):"
echo "     cx_max_requests_reached (sum across pods, scenario 4) = ${S4_MRC}"
if [[ "${S4_MRC}" -gt 0 ]]; then
    echo "     PASS: count-based GOAWAY fired"
else
    echo "     INVESTIGATE: count-based GOAWAY did not fire"
fi

S2_FCP="$(sum_metric "${RESULTS_DIR}/02-trigger/flow_control_paused.txt")"
S5_FCP="$(sum_metric "${RESULTS_DIR}/05-windows/flow_control_paused.txt" 2>/dev/null || echo 0)"
echo ""
echo "  H-D (HTTP/2 flow-control window, expected: refute at local scale):"
echo "     flow_control_paused scenario 2 = ${S2_FCP}, scenario 5 = ${S5_FCP}"
if [[ "${S2_FCP}" -gt 0 ]] && awk -v a="${S2_FCP}" -v b="${S5_FCP}" 'BEGIN{exit !(b < a * 0.2)}'; then
    echo "     PASS: window saturation observed in scenario 2 and resolved in scenario 5"
elif [[ "${S2_FCP}" -eq 0 ]]; then
    echo "     REFUTE (expected): no flow-control pause at local scale; would need WAN RTT"
else
    echo "     INVESTIGATE: window change did not clear the pauses"
fi

S6_CV="$(read_cv "${RESULTS_DIR}/06-waypoint-baseline/cv.txt" 2>/dev/null || echo 0)"
S7_CV="$(read_cv "${RESULTS_DIR}/07-waypoint-trigger/cv.txt" 2>/dev/null || echo 0)"
echo ""
echo "  Waypoint mechanism transfer:"
echo "     CV at IGW pods, baseline = ${S6_CV}, trigger = ${S7_CV}"
# Waypoint-side CV: the waypoint listener stat prefix is discovered at
# the same time as the IGW prefix during the build phase; here we read
# the latest captured value if the runner saved it.
if [[ -f "${RESULTS_DIR}/07-waypoint-trigger/waypoint_cv.txt" ]]; then
    S7_WP_CV="$(awk '/^WAYPOINT_CV:/{print $2}' "${RESULTS_DIR}/07-waypoint-trigger/waypoint_cv.txt")"
    echo "     CV at waypoint pods, trigger = ${S7_WP_CV}"
fi

echo ""
echo "Generating comparison plots..."
if command -v python3 >/dev/null 2>&1 && python3 -c "import matplotlib" 2>/dev/null; then
    python3 "${TOOLS}/plot_results.py" "${RESULTS_DIR}" 2>&1 | sed 's/^/  /'
else
    echo "  matplotlib not available; skipping plots. Install with: pip3 install --user matplotlib"
fi

echo ""
echo "Results directory: ${RESULTS_DIR}"
echo "Plots:             ${RESULTS_DIR}/plots/"
echo "Live dashboard:    ${GRAFANA_URL}/d/${GRAFANA_DASHBOARD_UID}"
echo "Done."
