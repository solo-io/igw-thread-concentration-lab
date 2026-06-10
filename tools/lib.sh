#!/usr/bin/env bash
# tools/lib.sh: shared constants for run-tests.sh and the samplers.
#
# Source this from any script under the repo with:
#   source "${SCRIPT_DIR}/tools/lib.sh"       (from run-tests.sh)
#   source "$(dirname "$0")/lib.sh"           (from a sibling sampler in tools/)
#
# Why this exists: the Envoy stat prefixes for the IGW listener and the
# httpbin backend cluster were duplicated across run-tests.sh and
# tools/metric_sampler.sh. If they drift (port change, service rename,
# different Istio listener naming), the runner and the time-series
# sampler disagree silently and the dashboard / hypothesis-evaluation
# block reads different numbers. One source of truth keeps them aligned.

# IGW listener stat namespace at the HTTP layer.
# Format: `http.<listener_prefix>;.<stat>`. The trailing semicolon is part
# of Envoy's stat namespace separator; querying without the semicolon
# returns 0 silently.
# The IGW Service maps host port 80 to container port 8080, which is why
# the listener prefix uses 8080 even though the Gateway resource
# specifies port 80.
: "${LISTENER_PREFIX:=http.outbound_0.0.0.0_8080;}"

# IGW listener stat namespace at the listener (network) layer. No
# trailing semicolon: this is the root the per-worker counters hang off
# (e.g. listener.0.0.0.0_8080.worker_0.downstream_cx_total).
: "${LISTENER_RAW:=listener.0.0.0.0_8080}"

# Upstream cluster stat namespace for the httpbin backend. The pipe-
# separated form (direction|port|subset|fqdn) is Envoy's cluster name
# scheme as Istio configures it; trailing semicolon as above.
: "${CLUSTER_PREFIX:=cluster.outbound|8080||httpbin.igw-test.svc.cluster.local;}"
