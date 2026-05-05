# Lab Design Plan

This document explains *why* the lab is shaped the way it is. The README is the practical walkthrough; this is the design rationale. If you are extending the lab, adding scenarios, or debugging an unexpected result, start here.

## What the lab is built to teach

A production failure mode that is hard to diagnose from aggregates: the Istio Ingress Gateway shows elevated tail latency under high RPS, while aggregate gateway CPU and memory remain moderate. The signature is **distributional**: a few worker threads on a few pods are pegged, while the rest sit idle.

The lab tests four hypotheses about the mechanism and four canonical tuning levers. Each scenario isolates one variable. The point is not to prove a foregone conclusion: refutations are expected and informative, and several are called out explicitly in this document so you know what they would mean if you see them.

## Reproduction environment

**Local k3d cluster.** The mechanism we are studying (HTTP/2 streams pinned to Envoy worker threads when client connection cardinality is low) is at the Envoy data-plane level. It does not depend on cloud or LB-specific infrastructure. We can drive low connection cardinality directly via the load generator's `-c` parameter, regardless of how clients arrive in production.

Per the [Envoy threading model documentation](https://blog.envoyproxy.io/envoy-threading-model-a8d44b922310), each accepted TCP connection is assigned to a single worker thread for its lifetime, regardless of how it arrived. That is the property under test.

**What this lab does NOT reproduce:** L4 load-balancer hash dynamics (e.g., AWS NLB zonal affinity collapsing client connections to one per client) or production-magnitude RPS (1M+ RPS). Those are separate axes from concentration. Reproducing the NLB-specific trigger would need an EKS cluster behind a real NLB; you would build that as a v2 of this lab if needed. The rest of the design works on a developer laptop.

## Hypotheses

Each hypothesis names a claim, a mechanism, and the metric that would confirm or refute it. They are intentionally falsifiable.

### H-A: the mechanism is real

**Claim:** With Istio's default `max_concurrent_streams: 65536` (per the [Istio Pilot environment variable reference for `PILOT_HTTP2_MAX_CONCURRENT_STREAMS`](https://istio.io/latest/docs/reference/commands/pilot-discovery/#envvars)), a small number of client TCP connections plus many concurrent HTTP/2 streams produces hot worker threads and rising tail latency, while aggregate gateway CPU stays moderate.

**Reasoning:** Per the [Envoy threading model documentation](https://blog.envoyproxy.io/envoy-threading-model-a8d44b922310), each accepted TCP connection is permanently assigned to one worker thread, and that thread handles every HTTP/2 stream multiplexed on that connection. Total stream throughput on a connection is therefore bounded by one worker thread's CPU budget, regardless of how many other workers are idle. If clients open few connections, streams pile up on a few threads and saturate them while the rest of the pod's CPU sits idle.

**Confirmation signal:** CV of `envoy_http_downstream_cx_active` across IGW pods rises by a multiple (5x or more) above the baseline. p99 listener latency rises. Aggregate `process_cpu_seconds_total` rate stays moderate.

### H-B: capping streams forces dial-out, but only on smart clients

**Claim:** Reducing `max_concurrent_streams` to ~128 forces compliant HTTP/2 clients to open more TCP connections (because new streams over the cap return `REFUSED_STREAM`), distributing streams across more worker threads. Tail latency drops at the same RPS, with no change in aggregate CPU.

**Reasoning:** The [HTTP/2 RFC 9113 section on `SETTINGS_MAX_CONCURRENT_STREAMS`](https://www.rfc-editor.org/rfc/rfc9113.html#name-defined-settings) requires clients to open a new connection for additional concurrent streams once the cap is reached. Combined with the threading model in H-A, more connections means more thread coverage. The [Envoy HTTP/2 protocol options reference for `max_concurrent_streams`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/core/v3/protocol.proto#envoy-v3-api-field-config-core-v3-http2protocoloptions-max-concurrent-streams) is the configuration surface we toggle.

**Refutation we explicitly want to surface:** the load generator does not actually open more connections. Some HTTP/2 client implementations cap their connection pool at the application layer and prefer queueing over opening new connections. `fortio` with a fixed `-c` is exactly such a client, and so is a gRPC service using a single `grpc.ClientConn` per upstream peer. **A refutation here is itself an important finding**: it tells you that `max_concurrent_streams` reduction alone will not fix anything for queueing clients. This is why the lab tests H-B twice: once with `h2dial` (smart, dials), once with `fortio` (queues).

**Confirmation signal (h2dial):** transport pool grows from ~3 to ~5+ connections after the cap is applied. CV drops.

**Confirmation signal (fortio):** the lever does NOT redistribute load. CV unchanged. (This refutes the naive form of the claim and motivates H-C.)

### H-C: counting requests forces rotation regardless of client behavior

**Claim:** `max_requests_per_connection: 10000` (at the [HTTP Connection Manager `common_http_protocol_options.max_requests_per_connection` field](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/core/v3/protocol.proto#envoy-v3-api-field-config-core-v3-httpprotocoloptions-max-requests-per-connection)) rotates connections faster than `max_connection_duration: 150s` does. The `cx_max_requests_reached` Envoy counter fires on hot connections; cold connections never hit the count limit before the time limit fires.

**Reasoning:** The two limits compose as "whichever fires first wins"; they do not stack or multiply churn. A connection at 1,000 requests per second hits the 10,000-request limit in approximately 10 seconds, while a connection at 10 requests per second hits the 150-second time limit first. This selectively rotates hot connections without disturbing low-traffic ones. The [Envoy HCM stats reference](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/stats) names both `downstream_cx_max_duration_reached` and `downstream_cx_max_requests_reached` so you can observe which limit is firing.

**Why this is the most useful lever in production:** unlike H-B, count rotation works against both queueing and dialing clients. The server issues `GOAWAY` after N requests, the client must reconnect (whether it was queueing or dialing before), and the new connection lands somewhere in the pod set via the same hashing path. With enough rotations, distribution evens out.

**Confirmation signal:** `rate(cx_max_requests_reached_total) > 0` while `cx_max_duration_reached_total` stays low. CV drops on both clients (h2dial and fortio).

### H-D: HTTP/2 flow-control window saturation under high concurrent streams

**Claim:** With Envoy's default 64 KiB stream and connection windows from the [Envoy HTTP/2 protocol options for `initial_stream_window_size` and `initial_connection_window_size`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/core/v3/protocol.proto#envoy-v3-api-field-config-core-v3-http2protocoloptions-initial-stream-window-size), high concurrent-stream load on a single connection causes `flow_control_paused_reading_total` (per the [Envoy upstream cluster stats reference](https://www.envoyproxy.io/docs/envoy/latest/configuration/upstream/cluster_manager/cluster_stats)) to rise. Raising both window sizes drives that counter down and reduces tail latency.

**Reasoning:** Per the [HTTP/2 RFC 9113 flow-control section](https://www.rfc-editor.org/rfc/rfc9113.html#name-flow-control), once a stream's window is exhausted the sender must pause until the receiver issues a `WINDOW_UPDATE`. With many streams sharing one connection, the per-connection window can fill faster than `WINDOW_UPDATE` round-trips can refill it, especially at high response size or RTT. This appears as gateway-side slowness even when CPU and memory are fine. Raising the windows widens the buffer between `WINDOW_UPDATE` round-trips.

**Refutation possibility worth calling out:** flow-control saturation does not appear at the lab's reachable scale. We see it does — at 64 KiB defaults the pause rate is significant — but raising windows to 1 MiB is only a partial mitigation (~21% drop in pause rate). For high-byte-throughput production workloads, 4 MiB or higher is more realistic. This is a refinement of the claim, not a refutation.

**Confirmation signal:** `rate(flow_control_paused_reading_total)` non-zero at default windows; drops when windows are raised. The drop scales with the window size.

### H-E2: within-pod worker balance via Envoy `connection_balance_config`

**Claim:** With `concurrency >= 2` (more than one Envoy worker thread per gateway pod), the kernel-driven `accept()` race can produce uneven distribution of new connections across workers within a single pod, even when connections are evenly distributed across pods. Setting [`connection_balance_config: { exact_balance: {} }`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/listener/v3/listener.proto#envoy-v3-api-msg-config-listener-v3-listener-connectionbalanceconfig) on the listener replaces the kernel race with an Envoy-managed counter and produces tighter per-worker distribution.

**Reasoning:** Envoy's default listener uses `SO_REUSEPORT`-style accept across worker threads, where each worker's accept loop competes for new connections. Whichever worker is least busy at accept time gets the connection; this is biased by workload type (a worker holding a hot HTTP/2 connection is less responsive on accept than an idle peer, so hot connections cluster). `ExactBalance` serializes accepts through a process-wide mutex and assigns each new connection to the worker with the fewest active connections.

**Confirmation signal:** at `concurrency >= 2`, CV across worker threads (computed from `top -H` per-thread CPU samples in `cpu_sampler.sh` output) drops measurably between control and `ExactBalance` runs, while CV across pods is unchanged.

**Refutation:** the kernel race already produces even within-pod distribution at this RPS, so `ExactBalance` adds mutex overhead without measurable benefit. This is a real production trade-off: at very high new-connection rates `ExactBalance` becomes a bottleneck. For long-lived HTTP/2 (the regime this lab studies) new connections are rare and the mutex cost is unmeasurable.

**Important:** this hypothesis is orthogonal to H-A through H-D. `connection_balance_config` does NOT redistribute connections across pods. It only affects within-pod worker assignment. If your hotspot is at the pod level (kube-proxy or LB hashing), this lever does nothing for you; you need H-B / H-C / H-D's tools.

### H-E: coefficient of variation as a hotspot leading indicator

**Claim:** A Prometheus query computing the CV of `envoy_http_downstream_cx_active` across gateway pods rises ahead of p99 listener latency. The variance metric moves first; latency follows.

**Reasoning:** Hotspotting is by definition a distribution problem. Aggregate metrics (total RPS, mean CPU) hide it. Variance does not. An uneven distribution of work across pods or threads is a precondition of saturation; saturation is a consequence. If H-E holds, the CV query is useful for alerting before tail latency rises.

**Confirmation signal:** time-series sampler captures CV every 5 seconds during scenario 2; p99 captured at the same cadence; the CV trace crosses its threshold before the p99 trace does.

## Test design

Each scenario varies one EnvoyFilter knob (or one client behavior) while pinning the rest. Cluster, IGW deployment, backend, and Prometheus stack are stable across all scenarios.

| # | Scenario | Variable | Hypothesis tested |
|---|---|---|---|
| 1 | Baseline | h2dial `-mode=distinct -c 100`, defaults | reference: high connection diversity → low CV |
| 2 | Trigger | h2dial `-mode=shared -c 500`, defaults | **H-A** mechanism |
| 3 | mcs-cap | h2dial `-mode=shared -c 500`, `max_concurrent_streams: 128` | **H-B** smart client (dial on cap) |
| 4 | mrpc | h2dial `-mode=shared -c 500`, `max_requests_per_connection: 10000` | **H-C** count rotation |
| 5 | windows | h2dial `-mode=shared`, `/bytes/16384`, windows: 1 MiB | **H-D** flow-control saturation |
| 6 | waypoint-baseline | h2dial `-mode=distinct -c 100`, with waypoint | sanity check the waypoint hop |
| 7 | waypoint-trigger | h2dial `-mode=shared -c 500`, with waypoint | mechanism transfer through L7 hop |
| 8 | buffers | h2dial `-mode=shared`, `/bytes/65536`, listener buffer 4 MiB | per-connection buffer pressure (separate axis from windows) |
| 9 | hol-blocking | h2dial 500 fast + 5 slow `/delay/2` | head-of-line blocking on slow streams |
| 10 | rotation | h2dial `-mode=shared -c 500`, `max_connection_duration: 10s` | rotation-induced spikes |
| 11 | realistic-filters | h2dial + access-log filter + JWT validation | filter-chain overhead at scale |
| 02-fortio | trigger (queueing client) | fortio `-c 2 -qps 5000`, defaults | **H-A** with queueing client |
| 03-fortio | mcs-cap (queueing client) | fortio `-c 2 -qps 5000`, cap 128 | **H-B refutation**: cap doesn't help queueing clients |
| 04-fortio | mrpc (queueing client) | fortio `-c 2 -qps 5000`, mrpc 10000 | **H-C confirmation against queueing client** |
| 05-fortio | windows (queueing client) | fortio `-c 2 -qps 5000`, windows: 1 MiB | **H-D** with queueing client |
| 12 | grpc-variant | ghz `--connections=1`, grpcbin | gRPC inherits HTTP/2 concentration |
| 13 | conn-balance | h2dial `-mode=shared`, listener `connection_balance_config: exact_balance` | **H-E2** within-pod worker balance (skipped at concurrency=1; requires IGW_CPU>=2 in config.env + redeploy) |

A transversal check, run during the ramp of scenario 2: confirm the CV-of-`downstream_cx_active` query rises before p99 listener latency does. This validates **H-E**.

### Design choices and why

- **One variable at a time.** Each fix scenario isolates one knob. Knobs are not stacked. If we stacked them, a positive result could not be attributed to a specific knob and a refutation of any one hypothesis would be ambiguous. In production you would stack them; here we are characterizing each.
- **2 connections at 5,000 RPS is deliberately extreme.** The concentration ratio (~2,500 streams per connection) is what makes the mechanism observable at local scale. Production scale is millions of RPS spread across many client pods; we do not need to match magnitude, only the per-connection saturation regime.
- **`max_connection_duration` is not a separate fix scenario.** Test 4 already isolates `max_requests_per_connection`. The composition behavior of the two limits (whichever fires first wins) is documented and does not need a separate test. Adding one would consume time without adding signal. Scenario 10 exercises `max_connection_duration` for a different purpose (rotation-induced spikes).
- **Waypoint scenarios are a subset, not a full mirror.** Scenarios 6 and 7 test the mechanism only at the waypoint hop. We do not run the full fix matrix at the waypoint because the mechanism transfer is the load-bearing claim and one scenario each (sanity + trigger) is enough to confirm or refute it. Tuning specifically at the waypoint hop is a v2 extension if needed.
- **Plaintext (HTTP) on the downstream IGW listener.** TLS handshake cost adds variance unrelated to the HTTP/2 thread mechanism under test. Scenario 10 demonstrates the rotation pattern in plaintext; real mTLS adds handshake CPU on top.
- **Backend returns a fixed-shape response.** Removes backend variance from the p99 signal, so any p99 movement attributes to gateway-side concentration.

## Tooling

- **Cluster:** k3d 5.x. Cluster name `igw-tc-lab`. Context `k3d-igw-tc-lab`. Traefik disabled at cluster creation.
- **Istio:** 1.27.8. Self-contained `istioctl` download (in `.gitignore`).
- **Load generators:**
  - `fortio` running as an in-cluster Deployment, invoked via `kubectl exec` per scenario. HTTP/2 supported; `-c` controls connections, `-qps` controls RPS.
  - `h2dial` running as an in-cluster Deployment, custom Go client (`h2dial/main.go`). `-mode=shared` shares one transport across all goroutines (smart client); `-mode=distinct` gives each worker its own transport.
  - `ghz` for the gRPC scenario, running against `grpcbin`.
- **Backend:** `mccutchen/go-httpbin`, in-cluster, ambient.
- **Metrics:** kube-prometheus-stack via Helm (Prometheus + Grafana + PodMonitors). Scraped from `istio-proxy` port 15090 on the IGW and waypoint pods, and from the ztunnel daemonset.
- **EnvoyFilters:** one manifest per scenario in `manifests/envoyfilters/`, applied between scenarios.
- **Per-thread CPU snapshots:** `top -H -b -n 1 -p $(pgrep envoy)` captured inside the gateway pod at the peak of each scenario; written to `results/<ts>/<scenario>/`.
- **Time-series sampler:** every 5 seconds during a scenario, dumps the gauge values for `cx_active`, `rq_active`, and the histogram p99 to a CSV for offline plotting.

## Why baseline CV is not zero (theoretical floor)

Scenario 1 with `h2dial -mode=distinct -c 100` opens 100 separate TCP connections (one per worker, each with its own `http2.Transport`). They are then hashed across IGW pods by kube-proxy's iptables-mode random selection.

Theoretical CV for N connections randomly distributed across P pods, assuming uniform random hashing:

- Each pod's count follows binomial(N, 1/P)
- Mean per pod: N/P
- Variance per pod: N · (1/P) · (1 − 1/P)
- Stddev: sqrt(N · (1/P) · (1 − 1/P))
- CV: stddev / mean

For 6 IGW pods with N=100 connections:

- Mean: 16.67
- Variance: 100 · (1/6) · (5/6) ≈ 13.89
- Stddev: ≈ 3.73
- **Expected CV: ≈ 0.22**

For 3 IGW pods with N=100 connections:

- Mean: 33.33
- Variance: 22.22
- Stddev: 4.71
- **Expected CV: ≈ 0.14**

Measured baseline CV (typically 0.14 to 0.30) sits within one standard deviation of the theoretical value, consistent with random hashing. The "noise floor" of the baseline is not zero; it is the fractional standard deviation of binomial(N, 1/P), and it grows as you add pods (more pods → each gets fewer connections → fractional stddev is larger relative to mean).

This is the floor against which the trigger-scenario CV (1.0+) is compared. The 4-7x jump from baseline to trigger is the relevant signal regardless of replica count.

## Refutation possibilities to keep in mind

These are not failure modes of the lab; they are findings worth knowing if you see them:

- **H-B refutation (load gen queues, doesn't dial).** The fortio variants are designed to surface this. If h2dial also fails to dial, suspect the shared-transport setup in `h2dial/main.go`.
- **H-C refutation (count limit never fires).** If `cx_max_requests_reached_total` stays at zero, your scenario is too short or your value is too high relative to per-connection RPS. Drop the value or extend the runtime.
- **H-D refutation (windows already big enough).** Possible at low byte-throughput. Switch the load gen to `/bytes/65536` to push more bytes per response. If `flow_control_paused_reading_total` is still zero, the scenario does not exercise this hypothesis at the lab's RTT.
- **H-E refutation (variance does NOT lead latency).** Has not happened in any run we have done; would suggest the metric pipeline is sampling too slowly or the scenario ramp is too fast. Slow the ramp; sample faster.

## Out of scope

- Production-magnitude RPS (1M+ RPS).
- AWS NLB / EKS reproduction.
- Multicluster topologies.
- Real mTLS handshake measurement.
- Full waypoint tuning matrix (scenarios 6 and 7 confirm mechanism transfer; per-knob tuning at the waypoint is a v2).

## References

### Upstream documentation

- [Envoy threading model](https://blog.envoyproxy.io/envoy-threading-model-a8d44b922310)
- [Envoy HTTP Connection Manager protocol options (`max_requests_per_connection`)](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/core/v3/protocol.proto#envoy-v3-api-field-config-core-v3-httpprotocoloptions-max-requests-per-connection)
- [Envoy HTTP/2 protocol options (`max_concurrent_streams`, `initial_stream_window_size`, `initial_connection_window_size`)](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/core/v3/protocol.proto#config-core-v3-http2protocoloptions)
- [Envoy HCM stats reference](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/stats)
- [Envoy upstream cluster stats reference](https://www.envoyproxy.io/docs/envoy/latest/configuration/upstream/cluster_manager/cluster_stats)
- [Istio Pilot environment variables (`PILOT_HTTP2_MAX_CONCURRENT_STREAMS`)](https://istio.io/latest/docs/reference/commands/pilot-discovery/#envvars)
- [Istio ambient mode architecture](https://istio.io/latest/docs/ambient/architecture/)
- [Istio HBONE protocol overview](https://istio.io/latest/docs/ambient/architecture/hbone/)
- [Istio waypoint usage guide](https://istio.io/latest/docs/ambient/usage/waypoint/)
- [Istio Gateway installation guide](https://istio.io/latest/docs/setup/additional-setup/gateway/)
- [HTTP/2 RFC 9113 — `SETTINGS_MAX_CONCURRENT_STREAMS`](https://www.rfc-editor.org/rfc/rfc9113.html#name-defined-settings)
- [HTTP/2 RFC 9113 — flow control](https://www.rfc-editor.org/rfc/rfc9113.html#name-flow-control)
- [fortio load generator](https://github.com/fortio/fortio)
- [ghz gRPC load tester](https://github.com/bojand/ghz)

### Solo product documentation

- [Solo Enterprise for Istio: ambient mode overview](https://docs.solo.io/gloo-mesh/latest/ambient/)
- [Solo Enterprise for Istio: ambient architecture (ztunnel and waypoint components)](https://docs.solo.io/gloo-mesh/latest/ambient/about/architecture/)

### Related public GitHub issues

- [istio/istio#49892 — High response times on ingress gateways](https://github.com/istio/istio/issues/49892)
- [istio/istio#58114 — HTTP/2 single-connection throughput limitation](https://github.com/istio/istio/issues/58114)
