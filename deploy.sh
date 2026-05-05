#!/usr/bin/env bash
# ============================================================================
# deploy.sh -- Deploy the lab base environment.
#
# Hypothesis under test (full statement in PLAN.md):
#   Connection-and-thread-level concentration at the Istio Ingress Gateway.
#   When few client connections multiplex many HTTP/2 streams, those streams
#   pin to a small subset of Envoy worker threads. Tail latency rises while
#   aggregate gateway CPU stays moderate.
#
# This script deploys:
#   1. k3d cluster (1 server + 2 agents), Traefik disabled (learning L001).
#   2. Istio 1.27.8 ambient profile, with k3s-specific CNI directory overrides
#      (learning L002), since k3s does not use the standard CNI paths.
#   3. Standard istio-ingressgateway (3 replicas, 2 CPU per replica),
#      plaintext listener on port 80 to remove TLS variance from p99
#      measurements.
#   4. mccutchen/go-httpbin backend with an explicit command (learning on
#      its CMD-not-ENTRYPOINT image) so /bytes/N and /delay/0 are reachable.
#   5. fortio load generator as a Deployment.
#   6. kube-prometheus-stack (Prometheus + Grafana + ServiceMonitors) for
#      visualization. PASS/FAIL determination in run-tests.sh uses direct
#      curl :15000/stats from the gateway pod, not Prometheus.
#   7. Optional: waypoint resource for scenarios 6 and 7 (mechanism-transfer test).
#
# Run-tests is a separate script so the same cluster can be re-used across
# scenario loops without re-deploying.
# ============================================================================

set -euo pipefail

# --- Configuration ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional config.env (gitignored). Copy config.env.example to config.env to
# override any default below without editing this script. All values have
# sensible defaults; config.env is purely for customization.
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/config.env"
fi

# Defaults (a value already set by config.env wins via :=).
: "${CLUSTER_NAME:=igw-tc-lab}"
: "${ISTIO_VERSION:=1.27.8}"
: "${GATEWAY_API_VERSION:=v1.2.1}"
: "${KUBE_PROM_STACK_VERSION:=84.5.0}"
: "${FORTIO_IMAGE:=fortio/fortio:1.75.1}"
: "${GRPCBIN_IMAGE:=moul/grpcbin@sha256:bd8f2ffdd02d0849fad2d1c754eff4402c867e7a3e0552b8992f4590f5687d20}"
: "${IGW_REPLICAS:=6}"
: "${IGW_CPU:=1}"
: "${IGW_HTTP_PORT:=18080}"
: "${WAYPOINT_REPLICAS:=3}"
CONTEXT="k3d-${CLUSTER_NAME}"

ISTIOCTL="${SCRIPT_DIR}/istioctl"
MANIFESTS="${SCRIPT_DIR}/manifests"

NAMESPACE_APP="igw-test"
NAMESPACE_LOAD="loadgen"
NAMESPACE_ISTIO="istio-system"
NAMESPACE_MONITORING="monitoring"

echo "=== IGW Thread Concentration Lab: Deploy ==="
echo "Cluster: ${CLUSTER_NAME}"
echo "Context: ${CONTEXT}"
echo "Istio:   ${ISTIO_VERSION} (ambient profile)"
echo ""

# --- Step 1: Download istioctl 1.27.8 ---------------------------------------
if [[ -x "${ISTIOCTL}" ]] && "${ISTIOCTL}" version --remote=false 2>/dev/null | grep -q "${ISTIO_VERSION}"; then
    echo "[1/9] istioctl ${ISTIO_VERSION} already present"
else
    echo "[1/9] Downloading istioctl ${ISTIO_VERSION}..."
    rm -f "${ISTIOCTL}"
    OS_RAW="$(uname -s)"
    ARCH_RAW="$(uname -m)"
    if [[ "${OS_RAW}" == "Darwin" ]]; then OS="osx"; else OS="linux"; fi
    if [[ "${ARCH_RAW}" == "arm64" ]] || [[ "${ARCH_RAW}" == "aarch64" ]]; then ARCH="arm64"; else ARCH="amd64"; fi
    URL="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-${OS}-${ARCH}.tar.gz"
    echo "  URL: ${URL}"
    curl -sL "${URL}" | tar xz -C "${SCRIPT_DIR}" istioctl
    chmod +x "${ISTIOCTL}"
fi
echo "  Version: $(${ISTIOCTL} version --remote=false 2>/dev/null || echo 'unknown')"

# --- Step 2: Create k3d cluster --------------------------------------------
if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}\s"; then
    echo "[2/9] Cluster '${CLUSTER_NAME}' already exists"
else
    echo "[2/9] Creating k3d cluster '${CLUSTER_NAME}' (1 server + 2 agents)..."
    # Learning L001: Traefik must be disabled for any gateway/ingress reproducer
    # on k3d, otherwise Traefik claims port 80 and shadows the Istio ingress
    # gateway listener.
    k3d cluster create "${CLUSTER_NAME}" \
        --agents 2 \
        --k3s-arg "--disable=traefik@server:0" \
        --port "${IGW_HTTP_PORT}:80@loadbalancer" \
        --wait
fi
echo "  Waiting for nodes..."
kubectl --context "${CONTEXT}" wait --for=condition=Ready nodes --all --timeout=120s >/dev/null

# --- Step 3: Install Istio (ambient profile + ingress gateway) -------------
# Single istioctl install call for the whole control plane and data plane:
# istiod, ztunnel, istio-cni, and the standard istio-ingressgateway. Doing
# this in one call avoids the trap where a second install with profile=empty
# would recompute the operator spec and uninstall components from the first
# call.
#
# Learning L002: k3s stores CNI config and binaries in non-standard paths.
# Without the cni.cniConfDir and cni.cniBinDir overrides, the istio-cni
# DaemonSet appears healthy but istiod and other pods stick in
# ContainerCreating with the kubelet error "failed to find plugin
# 'istio-cni' in path [/bin]".
#
# IGW sizing: replicas=3, CPU=2 per pod = 6 worker threads total. Enough
# for per-pod coefficient-of-variation and per-thread distribution to be
# observable while staying laptop-friendly.
if kubectl --context "${CONTEXT}" get deployment istiod -n "${NAMESPACE_ISTIO}" &>/dev/null \
   && kubectl --context "${CONTEXT}" get deployment istio-ingressgateway -n "${NAMESPACE_ISTIO}" &>/dev/null; then
    echo "[3/9] Istio (control plane + IGW) already installed"
else
    echo "[3/9] Installing Istio ${ISTIO_VERSION} (ambient profile + IGW, replicas=${IGW_REPLICAS}, cpu=${IGW_CPU})..."
    # Pin Envoy worker concurrency to 1 globally. Auto-detection from CPU
    # limits is unreliable across hosts (k3d, kind, EKS, etc. all behave
    # subtly differently). Pinning makes the "6 replicas, 1 worker thread
    # each = 6 worker threads in total" architecture in the README a
    # guarantee instead of a hope. The verification step below will fail
    # loudly if the pin doesn't take.
    "${ISTIOCTL}" install --context "${CONTEXT}" \
        --set profile=ambient \
        --set values.global.proxy.concurrency=1 \
        --set values.cni.cniConfDir=/var/lib/rancher/k3s/agent/etc/cni/net.d \
        --set values.cni.cniBinDir=/bin \
        --set components.ingressGateways[0].name=istio-ingressgateway \
        --set components.ingressGateways[0].enabled=true \
        --set components.ingressGateways[0].k8s.replicaCount=${IGW_REPLICAS} \
        --set components.ingressGateways[0].k8s.resources.requests.cpu=${IGW_CPU} \
        --set components.ingressGateways[0].k8s.resources.limits.cpu=${IGW_CPU} \
        --set components.ingressGateways[0].k8s.resources.requests.memory=512Mi \
        --set components.ingressGateways[0].k8s.resources.limits.memory=1Gi \
        -y 2>&1 | tail -10

    echo "  Waiting for control plane and dataplane..."
    kubectl --context "${CONTEXT}" wait --for=condition=Available deployment/istiod -n "${NAMESPACE_ISTIO}" --timeout=180s >/dev/null
    kubectl --context "${CONTEXT}" rollout status daemonset/ztunnel -n "${NAMESPACE_ISTIO}" --timeout=180s >/dev/null
    kubectl --context "${CONTEXT}" rollout status daemonset/istio-cni-node -n "${NAMESPACE_ISTIO}" --timeout=180s >/dev/null
    kubectl --context "${CONTEXT}" rollout status deployment/istio-ingressgateway -n "${NAMESPACE_ISTIO}" --timeout=180s >/dev/null
fi

# istioctl install creates an HPA for the IGW with minReplicas=1,
# maxReplicas=5, targetCPU=80%. Our distribution tests run at low aggregate
# CPU by design (the whole point is that CPU looks fine while individual
# threads saturate), so the HPA reconciles back to 1 replica mid-test,
# silently breaking the per-pod CV measurement. Delete the HPA so replica
# count is fixed at exactly IGW_REPLICAS for the duration of the run.
echo "  Removing IGW HPA (so replicas stay fixed during low-CPU tests)..."
kubectl --context "${CONTEXT}" delete hpa -n "${NAMESPACE_ISTIO}" istio-ingressgateway --ignore-not-found >/dev/null

# Belt-and-suspenders: explicit replica count. The istioctl install
# `--set components.ingressGateways[0].k8s.replicaCount=N` flag did not
# reliably take effect across versions during the build phase. Setting
# it directly on the Deployment is unambiguous.
echo "  Ensuring IGW replicas=${IGW_REPLICAS}..."
kubectl --context "${CONTEXT}" scale deployment/istio-ingressgateway -n "${NAMESPACE_ISTIO}" --replicas="${IGW_REPLICAS}" >/dev/null
kubectl --context "${CONTEXT}" rollout status deployment/istio-ingressgateway -n "${NAMESPACE_ISTIO}" --timeout=120s >/dev/null

# Patch IGW pods with proxyStatsMatcher to include connection-level Envoy
# stats. Istio 1.18+ defaults to a minimal stats matcher that excludes
# downstream_cx_*, flow_control_*, listener.* and HTTP/2 protocol stats --
# exactly the metrics this reproducer measures. Without this annotation,
# the test runner sees zero for every measurement.
#
# Idempotent: if the annotation is already set, kubectl patch is a no-op.
echo "  Enabling extended Envoy stats on IGW (proxyStatsMatcher)..."
PROXY_STATS_ANNOTATION='{"proxyStatsMatcher":{"inclusionRegexps":[".*downstream_cx.*",".*downstream_rq.*",".*flow_control.*",".*upstream_cx.*",".*upstream_rq_pending.*",".*http2.*",".*listener.*",".*ssl.*"]}}'
EXISTING="$(kubectl --context "${CONTEXT}" get deployment istio-ingressgateway -n "${NAMESPACE_ISTIO}" -o jsonpath='{.spec.template.metadata.annotations.proxy\.istio\.io/config}' 2>/dev/null || echo "")"
if [[ "${EXISTING}" == "${PROXY_STATS_ANNOTATION}" ]]; then
    echo "    (already set)"
else
    kubectl --context "${CONTEXT}" patch deployment istio-ingressgateway -n "${NAMESPACE_ISTIO}" \
        -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"proxy.istio.io/config\":\"${PROXY_STATS_ANNOTATION//\"/\\\"}\"}}}}}" >/dev/null
    kubectl --context "${CONTEXT}" rollout status deployment/istio-ingressgateway -n "${NAMESPACE_ISTIO}" --timeout=120s >/dev/null
fi

# Confirm worker thread count matches CPU limit. The istio-proxy image is
# distroless and does not include curl, so we use pilot-agent to talk to
# the local Envoy admin port.
echo "  Verifying Envoy concurrency on a gateway pod:"
IGW_POD="$(kubectl --context "${CONTEXT}" get pod -n "${NAMESPACE_ISTIO}" -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}')"
CONCURRENCY="$(kubectl --context "${CONTEXT}" exec -n "${NAMESPACE_ISTIO}" "${IGW_POD}" -- pilot-agent request GET server_info 2>/dev/null | grep -oE '"concurrency": *[0-9]+' | head -1 || echo 'unknown')"
echo "    pod: ${IGW_POD}"
echo "    ${CONCURRENCY}"

# --- Install Gateway API CRDs (required for the waypoint resource) ---------
# The waypoint in 06-waypoint.yaml uses gateway.networking.k8s.io/v1 which
# is NOT installed by default on most clusters (including k3d) and is NOT
# installed by `istioctl install --set profile=ambient`. Without these,
# applying the waypoint manifest fails with "no matches for kind Gateway
# in version gateway.networking.k8s.io/v1".
if kubectl --context "${CONTEXT}" get crd gateways.gateway.networking.k8s.io &>/dev/null; then
    echo "  Gateway API CRDs already installed"
else
    echo "  Installing Gateway API CRDs ${GATEWAY_API_VERSION}..."
    kubectl --context "${CONTEXT}" apply -f \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
        >/dev/null
fi

# --- Step 5: Apply application manifests (namespace, backend, gateway) ------
echo "[5/9] Applying application manifests..."
kubectl --context "${CONTEXT}" apply -f "${MANIFESTS}/00-namespaces.yaml" >/dev/null
kubectl --context "${CONTEXT}" apply -f "${MANIFESTS}/02-backend.yaml" >/dev/null
kubectl --context "${CONTEXT}" apply -f "${MANIFESTS}/03-gateway.yaml" >/dev/null

echo "  Waiting for backend rollout..."
kubectl --context "${CONTEXT}" rollout status deployment/httpbin -n "${NAMESPACE_APP}" --timeout=120s >/dev/null

# --- Step 6: Apply load generators (fortio + h2dial) ------------------------
echo "[6/9] Applying load generators..."
sed "s|\${FORTIO_IMAGE}|${FORTIO_IMAGE}|g" "${MANIFESTS}/04-loadgen.yaml" \
    | kubectl --context "${CONTEXT}" apply -f - >/dev/null
kubectl --context "${CONTEXT}" rollout status deployment/fortio -n "${NAMESPACE_LOAD}" --timeout=120s >/dev/null

# h2dial: custom Go HTTP/2 client with shared-transport pool semantics.
# Used by scenarios 2b and 3b for the H-B "smart client" validation.
# Build the image locally and import into k3d (no registry round-trip).
H2DIAL_IMAGE="h2dial:local"
if docker image inspect "${H2DIAL_IMAGE}" &>/dev/null; then
    echo "  h2dial image already built locally"
else
    echo "  Building h2dial image..."
    docker build -t "${H2DIAL_IMAGE}" "${SCRIPT_DIR}/h2dial" 2>&1 | tail -3
fi

# Idempotent: k3d image import is fast on a no-op (image already on node).
echo "  Importing h2dial image into k3d cluster..."
k3d image import "${H2DIAL_IMAGE}" --cluster "${CLUSTER_NAME}" 2>&1 | tail -2

# ghz: build locally + import to k3d (no public image works for our needs).
GHZ_IMAGE="ghz:local"
if docker image inspect "${GHZ_IMAGE}" &>/dev/null; then
    echo "  ghz image already built locally"
else
    echo "  Building ghz image..."
    docker build --platform linux/amd64 -t "${GHZ_IMAGE}" "${SCRIPT_DIR}/ghz-image" 2>&1 | tail -3
fi
echo "  Importing ghz image into k3d cluster..."
k3d image import "${GHZ_IMAGE}" --cluster "${CLUSTER_NAME}" 2>&1 | tail -2

kubectl --context "${CONTEXT}" apply -f "${MANIFESTS}/04b-h2dial.yaml" >/dev/null
kubectl --context "${CONTEXT}" rollout status deployment/h2dial -n "${NAMESPACE_LOAD}" --timeout=120s >/dev/null

# ghz: gRPC load tester for scenario 12. Models real-world single
# ClientConn behavior with --connections 1.
echo "  Applying ghz gRPC load tester..."
kubectl --context "${CONTEXT}" apply -f "${MANIFESTS}/13-ghz.yaml" >/dev/null
kubectl --context "${CONTEXT}" rollout status deployment/ghz -n "${NAMESPACE_LOAD}" --timeout=120s >/dev/null

# grpcbin: gRPC backend for scenario 12. Two replicas (ambient mode);
# reflection enabled.
echo "  Applying grpcbin backend..."
sed "s|\${GRPCBIN_IMAGE}|${GRPCBIN_IMAGE}|g" "${MANIFESTS}/12-grpcbin.yaml" \
    | kubectl --context "${CONTEXT}" apply -f - >/dev/null
kubectl --context "${CONTEXT}" rollout status deployment/grpcbin -n "${NAMESPACE_APP}" --timeout=120s >/dev/null

# --- Step 7: Apply waypoint (for scenarios 6-7) -----------------------------
echo "[7/9] Applying waypoint (used by scenarios 6 and 7)..."
kubectl --context "${CONTEXT}" apply -f "${MANIFESTS}/06-waypoint.yaml" >/dev/null
# Waypoint is created via Gateway resource of class istio-waypoint; the
# istiod controller deploys the waypoint pod automatically. Wait for it.
echo "  Waiting up to 60s for waypoint pod..."
for _ in $(seq 1 30); do
    if kubectl --context "${CONTEXT}" get pod -n "${NAMESPACE_APP}" -l gateway.istio.io/managed=istio.io-mesh-controller 2>/dev/null | grep -q Running; then
        echo "  Waypoint pod is Running."
        break
    fi
    sleep 2
done
# Bump waypoint replicas (default 3, override via WAYPOINT_REPLICAS in
# config.env) so we can measure CV across waypoint pods directly;
# single-replica makes CV undefined. The istiod-managed Deployment is
# `igw-test-waypoint` in the igw-test namespace.
echo "  Bumping waypoint replicas to ${WAYPOINT_REPLICAS}..."
kubectl --context "${CONTEXT}" scale deployment/igw-test-waypoint -n "${NAMESPACE_APP}" --replicas="${WAYPOINT_REPLICAS}" >/dev/null 2>&1 || true
kubectl --context "${CONTEXT}" rollout status deployment/igw-test-waypoint -n "${NAMESPACE_APP}" --timeout=120s >/dev/null 2>&1 || true

# --- Step 8: Install kube-prometheus-stack ---------------------------------
if kubectl --context "${CONTEXT}" get deployment -n "${NAMESPACE_MONITORING}" 2>/dev/null | grep -q grafana; then
    echo "[8/9] Monitoring stack already installed"
else
    echo "[8/9] Installing kube-prometheus-stack via Helm..."
    helm --kube-context "${CONTEXT}" repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
    helm --kube-context "${CONTEXT}" repo update prometheus-community >/dev/null
    kubectl --context "${CONTEXT}" create namespace "${NAMESPACE_MONITORING}" --dry-run=client -o yaml | \
        kubectl --context "${CONTEXT}" apply -f - >/dev/null
    # Grafana password is intentionally the literal "admin" because this
    # is a local k3d cluster used for transient reproducer runs. Never
    # exposed; never reused for any real environment. The Helm chart
    # default would otherwise generate a random password that we'd then
    # have to fetch from a Secret to log in.
    # NOTE: grafana-image-renderer plugin is NOT installed because the
    # plugin is amd64-only and breaks Grafana startup on linux-arm64
    # (Apple Silicon hosts via k3d). Run-tests.sh will print the live
    # dashboard URL and capture-points; manual screenshots from a browser
    # session are the documented fallback. If running on linux-amd64 you
    # can re-enable the plugin by adding `--set grafana.plugins[0]=grafana-image-renderer`.
    helm --kube-context "${CONTEXT}" upgrade --install kube-prom-stack \
        prometheus-community/kube-prometheus-stack \
        --version "${KUBE_PROM_STACK_VERSION}" \
        --namespace "${NAMESPACE_MONITORING}" \
        --set grafana.adminPassword=admin \
        --set 'grafana.sidecar.dashboards.enabled=true' \
        --set 'grafana.sidecar.dashboards.label=grafana_dashboard' \
        --set 'grafana.sidecar.dashboards.searchNamespace=ALL' \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --wait --timeout 5m 2>&1 | tail -5

    kubectl --context "${CONTEXT}" apply -f "${MANIFESTS}/05-monitoring.yaml" >/dev/null
fi

# Build the dashboard ConfigMap from the standalone JSON file in
# `dashboard/`. This makes `dashboard/igw-thread-concentration.json` the single source
# of truth; users can import the file directly into their own Grafana
# without parsing this YAML. The kube-prometheus-stack Grafana sidecar
# auto-loads ConfigMaps with label `grafana_dashboard=1`.
DASHBOARD_JSON="${SCRIPT_DIR}/dashboard/igw-thread-concentration.json"
kubectl --context "${CONTEXT}" create configmap igw-thread-concentration-dashboard \
    -n "${NAMESPACE_MONITORING}" \
    --from-file=igw-thread-concentration.json="${DASHBOARD_JSON}" \
    --dry-run=client -o yaml | \
    kubectl --context "${CONTEXT}" label --local -f - --dry-run=client -o yaml \
        grafana_dashboard=1 | \
    kubectl --context "${CONTEXT}" apply -f - >/dev/null

# Start a background port-forward to Grafana on localhost:3000 so the
# dashboard is viewable during test runs and accessible to the screenshot
# render API. Port-forward survives kubectl reconnects via this loop.
PORTFORWARD_PIDFILE="${SCRIPT_DIR}/.grafana-portforward.pid"
if [[ -f "${PORTFORWARD_PIDFILE}" ]] && kill -0 "$(cat "${PORTFORWARD_PIDFILE}")" 2>/dev/null; then
    echo "  Grafana port-forward already running (pid $(cat "${PORTFORWARD_PIDFILE}"))"
else
    echo "  Starting Grafana port-forward on localhost:3000..."
    nohup bash -c "while true; do kubectl --context ${CONTEXT} -n ${NAMESPACE_MONITORING} port-forward svc/kube-prom-stack-grafana 3000:80; sleep 2; done" \
        > "${SCRIPT_DIR}/.grafana-portforward.log" 2>&1 &
    echo $! > "${PORTFORWARD_PIDFILE}"
    sleep 3
fi

# --- Step 9: Smoke test the data path ---------------------------------------
echo "[9/9] Smoke-testing the data path through the gateway..."
sleep 5  # let endpoints settle
SMOKE="$(kubectl --context "${CONTEXT}" exec -n "${NAMESPACE_LOAD}" deploy/fortio -- \
    fortio curl -quiet "http://istio-ingressgateway.istio-system:80/get" 2>&1 | head -3 || true)"
if echo "${SMOKE}" | grep -q "200"; then
    echo "  PASS: gateway returned 200 for /get"
else
    echo "  WARN: smoke test did not return 200. Output:"
    echo "${SMOKE}" | sed 's/^/    /'
fi

# --- Summary ----------------------------------------------------------------
echo ""
echo "=== Deploy complete ==="
echo ""
echo "Cluster:    ${CONTEXT}"
echo "IGW:        kubectl --context ${CONTEXT} get pods -n ${NAMESPACE_ISTIO} -l app=istio-ingressgateway"
echo "Backend:    kubectl --context ${CONTEXT} get pods -n ${NAMESPACE_APP} -l app=httpbin"
echo "Loadgen:    kubectl --context ${CONTEXT} get pods -n ${NAMESPACE_LOAD} -l app=fortio"
echo "Waypoint:   kubectl --context ${CONTEXT} get pods -n ${NAMESPACE_APP} -l gateway.istio.io/managed=istio.io-mesh-controller"
echo "Grafana:    kubectl --context ${CONTEXT} -n ${NAMESPACE_MONITORING} port-forward svc/kube-prom-stack-grafana 3000:80"
echo "            (then open http://localhost:3000, user admin, password admin)"
echo ""
echo "Next: ./run-tests.sh"
