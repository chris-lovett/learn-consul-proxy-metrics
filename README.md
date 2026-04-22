# Consul Proxy Metrics Monitoring on OpenShift (ROSA)

Monitor Consul service mesh health and performance using OpenShift's built-in monitoring stack on ROSA (Red Hat OpenShift Service on AWS).

## Overview

Rather than deploying a separate Prometheus and Grafana stack, this guide uses OpenShift's **built-in user workload monitoring** — which ships with ROSA and is already production-ready. This avoids the SCC (Security Context Constraint) conflicts that occur when deploying community Helm charts on OpenShift.

You will configure Prometheus to scrape Consul proxy (Envoy) metrics from your service mesh sidecars on port `20200`, and verify data is flowing before moving on to Grafana dashboards.

**What you'll gain visibility into:**
- **Proxy Health:** Envoy sidecar connection status and error rates
- **Request Rates:** Upstream/downstream traffic per service
- **Latency Percentiles:** P50, P95, P99 response times across your mesh
- **Network Traffic:** Bytes sent/received per service
- **Consul Dataplane:** Connection status, server discovery, and reconnection events

## Why Use the Built-in Monitoring Stack?

✅ **Already deployed on ROSA** — no additional Helm charts needed  
✅ **No SCC conflicts** — fully compatible with OpenShift security policies  
✅ **Production-grade** — HA Prometheus with two replicas and Thanos  
✅ **Integrated auth** — uses OpenShift RBAC and SSO  
✅ **Zero extra cost** — no additional storage or compute required  

## Prerequisites

- ROSA or OpenShift 4.x cluster
- Consul Enterprise or OSS deployed via Helm in the `consul` namespace
- At least one application namespace with Consul sidecar injection enabled (`consul.hashicorp.com/connect-inject=true`)
- CLI tools: `oc`, `helm >= 3.x`
- Cluster-admin access

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  OpenShift Cluster                   │
│                                                      │
│  ┌─────────────────────────────────────────────┐    │
│  │     openshift-user-workload-monitoring       │    │
│  │  ┌──────────────────┐  ┌─────────────────┐  │    │
│  │  │ prometheus-user- │  │  thanos-ruler   │  │    │
│  │  │   workload (x2)  │  │     (x2)        │  │    │
│  │  └────────┬─────────┘  └─────────────────┘  │    │
│  └───────────┼─────────────────────────────────┘    │
│              │ scrapes port 20200                    │
│              ▼                                       │
│  ┌───────────────────────────────────────────┐      │
│  │              demo namespace               │      │
│  │  ┌──────────────────────────────────────┐ │      │
│  │  │  app pod                             │ │      │
│  │  │  ┌────────────┐  ┌────────────────┐  │ │      │
│  │  │  │  app       │  │ consul-        │  │ │      │
│  │  │  │  container │  │ dataplane      │  │ │      │
│  │  │  │            │  │ :20200/metrics │  │ │      │
│  │  │  └────────────┘  └────────────────┘  │ │      │
│  │  └──────────────────────────────────────┘ │      │
│  └───────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────┘
```

## Step 1 — Verify Your Environment (5 min)

```bash
# Confirm you're connected and have cluster-admin
oc whoami

# Confirm Consul is running
oc get pods -n consul

# Confirm your app namespace has sidecar injection enabled
oc get namespaces -l consul.hashicorp.com/connect-inject=true

# Confirm app pods have sidecars (look for 2/2 READY)
oc get pods -n <your-app-namespace>
```

Pods showing `2/2` in the READY column confirms the `consul-dataplane` sidecar is injected and running alongside your application container.

## Step 2 — Enable User Workload Monitoring (5 min)

ROSA's user workload monitoring must be enabled before you can scrape app metrics.

```bash
# Check if already enabled
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep enableUserWorkload
```

If `enableUserWorkload: true` is not present, enable it:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
```

Wait for the pods to come up:

```bash
oc get pods -n openshift-user-workload-monitoring
```

Expected output:
```
NAME                                   READY   STATUS    RESTARTS   AGE
prometheus-operator-xxx                3/3     Running   0          ...
prometheus-user-workload-0             6/6     Running   0          ...
prometheus-user-workload-1             6/6     Running   0          ...
thanos-ruler-user-workload-0           4/4     Running   0          ...
thanos-ruler-user-workload-1           4/4     Running   0          ...
```

## Step 3 — Verify Consul Metrics Are Enabled (5 min)

Check your current Consul Helm values:

```bash
helm get values consul -n consul
```

Look for this block under `global`:

```yaml
global:
  metrics:
    enabled: true
    enableAgentMetrics: true
```

And this under `connectInject`:

```yaml
connectInject:
  metrics:
    defaultEnabled: true
```

If `connectInject.metrics.defaultEnabled` is missing or false, enable it:

```bash
helm upgrade consul hashicorp/consul \
  -n consul \
  --reuse-values \
  --set connectInject.metrics.defaultEnabled=true \
  --set connectInject.metrics.defaultEnableMerging=false \
  --wait
```

> **Note:** After upgrading, existing pods need to be restarted to pick up the new proxy configuration:
> ```bash
> kubectl rollout restart deployment -n <your-app-namespace>
> ```

### Verify the Consul Server Metrics Endpoint

Consul uses TLS and ACLs, so you need a token and the HTTPS port:

```bash
# Get the bootstrap ACL token
oc get secret consul-bootstrap-acl-token -n consul -o jsonpath='{.data.token}' | base64 -d

# Test the metrics endpoint (replace <token> with the value above)
oc exec -n consul consul-server-0 -- curl -sk \
  https://localhost:8501/v1/agent/metrics?format=prometheus \
  -H "X-Consul-Token: <token>" | head -20
```

You should see Prometheus-formatted metrics output.

### Verify the Proxy Metrics Endpoint

The Envoy sidecar exposes metrics on port `20200`. Verify it's configured:

```bash
# Port-forward the Envoy admin interface from one of your app pods
oc port-forward -n <your-app-namespace> <pod-name> 19000:19000
```

In a separate terminal:

```bash
# Confirm port 20200 is present in the Envoy config
curl -s http://localhost:19000/config_dump | grep -A 5 "20200"
```

Then verify metrics are actually flowing:

```bash
# Port-forward the metrics port directly
oc port-forward -n <your-app-namespace> <pod-name> 20200:20200
```

In a separate terminal:

```bash
curl -s http://localhost:20200/metrics | head -20
```

You should see output like:

```
# HELP consul_dataplane_consul_connected This will either be 0 or 1 depending on whether the dataplane is currently connected to a Consul server.
# TYPE consul_dataplane_consul_connected gauge
consul_dataplane_consul_connected 1
```

Kill both port-forwards with `Ctrl+C` once confirmed.

## Step 4 — Create a PodMonitor (5 min)

A `PodMonitor` tells the built-in Prometheus to scrape port `20200` on all pods with Consul sidecars in your app namespace. We use `PodMonitor` (rather than `ServiceMonitor`) because port 20200 is a sidecar port not exposed by the Kubernetes Service.

```bash
cat <<EOF | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: consul-proxy-metrics
  namespace: <your-app-namespace>
  labels:
    release: prometheus
spec:
  namespaceSelector:
    matchNames:
      - <your-app-namespace>
  selector:
    matchLabels:
      consul.hashicorp.com/connect-inject-status: injected
  podMetricsEndpoints:
    - path: /metrics
      targetPort: 20200
EOF
```

Verify it was created:

```bash
oc get podmonitor -n <your-app-namespace>
```

## Step 5 — Verify Prometheus is Scraping (5 min)

Port-forward to the user workload Prometheus:

```bash
oc port-forward -n openshift-user-workload-monitoring prometheus-user-workload-0 9090:9090
```

Open **http://localhost:9090/targets** in your browser. You should see one target per app pod (e.g., 3 targets for a 3-service app), all in `UP` state under `demo/consul-proxy-metrics`.

Then go to **http://localhost:9090/graph** and run a test query:

```
consul_dataplane_consul_connected
```

You should see a value of `1` for each pod, confirming all sidecars are connected to Consul.

Other useful queries to try:

```promql
# Dataplane connect duration
consul_dataplane_connect_duration_sum

# Connection errors
consul_dataplane_connection_errors

# Envoy upstream requests (if L7 traffic is flowing)
envoy_cluster_upstream_rq_total
```

## Cleanup

To remove only the monitoring configuration (does not affect Consul or your apps):

```bash
# Remove the PodMonitor
oc delete podmonitor consul-proxy-metrics -n <your-app-namespace>
```

To disable user workload monitoring (only if you enabled it in this guide and don't need it):

```bash
oc edit configmap cluster-monitoring-config -n openshift-monitoring
# Remove or set: enableUserWorkload: false
```

## Troubleshooting

### Consul metrics endpoint returns "Permission denied"

Consul ACLs are enabled. You must pass a valid token:

```bash
oc get secret consul-bootstrap-acl-token -n consul -o jsonpath='{.data.token}' | base64 -d
```

Use the token in your curl request with `-H "X-Consul-Token: <token>"`.

### curl not found in pod containers

The `consul-dataplane` sidecar and many app containers don't include curl. Use port-forwarding from your local machine instead:

```bash
oc port-forward -n <namespace> <pod-name> 20200:20200
curl -s http://localhost:20200/metrics | head -20
```

### Targets not appearing in Prometheus

1. Confirm the PodMonitor selector matches your pod labels:
   ```bash
   oc get pods -n <your-app-namespace> --show-labels | grep "connect-inject-status=injected"
   ```

2. Confirm user workload monitoring is enabled and pods are running:
   ```bash
   oc get pods -n openshift-user-workload-monitoring
   ```

3. Check Prometheus operator logs for errors:
   ```bash
   oc logs -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus-operator
   ```

### No metrics after Consul Helm upgrade

After enabling `connectInject.metrics.defaultEnabled=true`, existing pods must be restarted to receive the updated proxy configuration:

```bash
oc rollout restart deployment -n <your-app-namespace>
```

## Repository Structure

```
.
├── README.md                    # This file
├── dashboards/                  # Grafana dashboard JSON files
│   ├── consul-data-plane-health.json
│   └── consul-data-plane-performance.json
└── openshift/                   # OpenShift configuration files
    └── podmonitor-consul-proxy.yaml  # PodMonitor for Envoy sidecar metrics
```

## Resources

- [OpenShift User Workload Monitoring](https://docs.openshift.com/container-platform/latest/monitoring/enabling-monitoring-for-user-defined-projects.html)
- [Consul Telemetry Docs](https://developer.hashicorp.com/consul/docs/agent/telemetry)
- [Consul on Kubernetes Metrics](https://developer.hashicorp.com/consul/docs/observe/telemetry/k8s)
- [PodMonitor API Reference](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PodMonitor)
- [Envoy Proxy Statistics](https://www.envoyproxy.io/docs/envoy/latest/operations/stats_overview)
