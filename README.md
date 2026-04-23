# Consul Proxy Metrics on OpenShift (ROSA)

Monitor Consul service mesh health and performance using OpenShift's built-in monitoring stack — no extra Helm charts required.

## Overview

This guide walks you through configuring OpenShift's built-in Prometheus to scrape Consul Envoy sidecar metrics and visualizing them in Grafana. It is written specifically for ROSA (Red Hat OpenShift Service on AWS) and accounts for OpenShift's security requirements, which differ significantly from vanilla Kubernetes.

**What you'll gain visibility into:**
- Proxy health and connection status per service
- Upstream/downstream request rates and error codes
- Latency percentiles (P50, P95, P99) across your mesh
- Consul dataplane connection status and server discovery events

## Why Not Just Use the Community Helm Charts?

The community `prometheus` and `grafana` Helm charts work well on vanilla Kubernetes but fail on OpenShift due to Security Context Constraint (SCC) conflicts:

- The Grafana chart injects seccomp annotations that OpenShift forbids
- node-exporter requires `hostNetwork`, `hostPID`, and `hostPath` volumes that are blocked by default
- Hardcoded UIDs (`472`, `65534`) fall outside the namespace UID range OpenShift assigns

**The solution:** Use what ROSA already provides:
- **OpenShift user workload monitoring** (built-in Prometheus) for scraping
- **Grafana Operator** (from OperatorHub) for visualization — it handles SCCs natively

## Prerequisites

- ROSA or OpenShift 4.11+ cluster
- Consul Enterprise or OSS deployed via Helm in the `consul` namespace
- At least one application namespace with Consul sidecar injection enabled
- CLI tools: `oc`, `helm >= 3.x`, `python3`
- Cluster-admin access

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        OpenShift Cluster                      │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │            openshift-user-workload-monitoring         │    │
│  │   prometheus-user-workload (x2)   thanos-ruler (x2)  │    │
│  └──────────────────────┬───────────────────────────────┘    │
│                         │ scrapes :20200/metrics              │
│                         ▼                                     │
│  ┌──────────────────────────────────────────────────────┐    │
│  │                  app namespace (e.g. demo)            │    │
│  │   ┌────────────────────────────────────────────┐     │    │
│  │   │  pod: app container + consul-dataplane      │     │    │
│  │   │                        :20200/metrics       │     │    │
│  │   └────────────────────────────────────────────┘     │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │                observability namespace                │    │
│  │   Grafana Operator ──▶ Grafana ──▶ Thanos Querier    │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

---

## Part 1 — Configure Prometheus Scraping

### Step 1 — Verify Your Environment

```bash
# Confirm cluster-admin access
oc whoami

# Confirm Consul is running
oc get pods -n consul

# Confirm your app namespace has sidecar injection enabled
oc get namespaces -l consul.hashicorp.com/connect-inject=true

# Confirm app pods have sidecars — look for 2/2 in the READY column
oc get pods -n <your-app-namespace>
```

`2/2 Running` confirms the `consul-dataplane` sidecar is injected alongside your app container.

### Step 2 — Enable User Workload Monitoring

ROSA ships with user workload monitoring disabled by default. Check if it's already on:

```bash
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

Wait for the monitoring stack to come up:

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

### Step 3 — Enable Consul Proxy Metrics

Check your current Consul Helm values:

```bash
helm get values consul -n consul
```

Look for `connectInject.metrics.defaultEnabled: true`. If it's missing or false, enable it:

```bash
helm upgrade consul hashicorp/consul \
  -n consul \
  --reuse-values \
  --set connectInject.metrics.defaultEnabled=true \
  --set connectInject.metrics.defaultEnableMerging=false \
  --wait
```

> **Note:** Existing pods must be restarted to pick up the new proxy configuration:
> ```bash
> oc rollout restart deployment -n <your-app-namespace>
> ```

**Verify the Consul server metrics endpoint** (Consul Enterprise uses TLS and ACLs):

```bash
# Get the bootstrap ACL token
oc get secret consul-bootstrap-acl-token -n consul -o jsonpath='{.data.token}' | base64 -d

# Test the metrics endpoint using HTTPS port 8501 (not HTTP 8500)
oc exec -n consul consul-server-0 -- curl -sk \
  https://localhost:8501/v1/agent/metrics?format=prometheus \
  -H "X-Consul-Token: <token>" | head -20
```

**Verify the Envoy proxy metrics endpoint** on port `20200`:

> **Note:** Most app containers and the `consul-dataplane` sidecar do not include `curl`. Use port-forwarding from your local machine instead.

```bash
# Port-forward to the sidecar metrics port
oc port-forward -n <your-app-namespace> <pod-name> 20200:20200
```

In a separate terminal:

```bash
curl -s http://localhost:20200/metrics | head -20
```

You should see output like:
```
# HELP consul_dataplane_consul_connected ...
# TYPE consul_dataplane_consul_connected gauge
consul_dataplane_consul_connected 1
```

Kill the port-forward with `Ctrl+C` once confirmed.

### Step 4 — Create a PodMonitor

A `PodMonitor` tells the built-in Prometheus to scrape port `20200` on all Consul-injected pods.

> **Why PodMonitor instead of ServiceMonitor?** Port `20200` is a sidecar port — it's not exposed by the Kubernetes Service, which only exposes the app port. `PodMonitor` scrapes pods directly and doesn't require a Service port definition.

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

### Step 5 — Verify Prometheus is Scraping

Port-forward to the user workload Prometheus UI:

```bash
oc port-forward -n openshift-user-workload-monitoring prometheus-user-workload-0 9090:9090
```

Open **http://localhost:9090/targets** in your browser. You should see one target per app pod in `UP` state listed under `<namespace>/consul-proxy-metrics`.

Then go to **http://localhost:9090/graph** and run:

```promql
consul_dataplane_consul_connected
```

You should see a value of `1` for each pod. Kill the port-forward with `Ctrl+C`.

---

## Part 2 — Deploy Grafana

> **Why the Grafana Operator?** The community Grafana Helm chart injects seccomp annotations that are forbidden by OpenShift's SCCs, preventing pods from scheduling. The Grafana Operator from OperatorHub is OpenShift-native and handles all security requirements automatically.

### Step 6 — Create the observability Namespace

```bash
oc new-project observability
```

### Step 7 — Install the Grafana Operator

OpenShift uses OLM (Operator Lifecycle Manager) to install operators. An `OperatorGroup` is required before a `Subscription` will work — without it, OLM won't create an InstallPlan.

```bash
# Create the OperatorGroup first
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: observability-operatorgroup
  namespace: observability
spec:
  targetNamespaces:
    - observability
EOF

# Create the Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: observability
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF
```

Wait for the operator to reach `Succeeded` — this takes 1-2 minutes:

```bash
oc get csv -n observability --watch
```

Expected output:
```
NAME                       DISPLAY            VERSION   PHASE
grafana-operator.v5.22.2   Grafana Operator   5.22.2    Succeeded
```

### Step 8 — Create a Service Account for Grafana

Grafana needs a service account with permission to query the Thanos Querier.

> **Important:** Use a `kubernetes.io/service-account-token` secret — not `oc create token`. Projected tokens created with `oc create token` are rejected by the Thanos Querier's RBAC proxy.

```bash
# Create the service account
oc create serviceaccount grafana -n observability

# Grant permission to query cluster metrics
oc adm policy add-cluster-role-to-user cluster-monitoring-view \
  -z grafana \
  -n observability

# Create a long-lived secret-based token
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: grafana-sa-token
  namespace: observability
  annotations:
    kubernetes.io/service-account.name: grafana
type: kubernetes.io/service-account-token
EOF

# Wait for the token to be populated, then verify it against Thanos
sleep 5
SA_TOKEN=$(oc get secret grafana-sa-token -n observability -o jsonpath='{.data.token}' | base64 -d)
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')

curl -k -H "Authorization: Bearer $SA_TOKEN" \
  "https://${THANOS_HOST}/api/v1/query?query=up" | head -c 100
```

You should see `{"status":"success",...}`. If you see `Unauthorized`, verify the `cluster-monitoring-view` role was granted.

### Step 9 — Deploy Grafana

```bash
cat <<EOF | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: observability
  labels:
    dashboards: grafana
spec:
  config:
    auth:
      disable_login_form: "false"
    security:
      admin_user: admin
      admin_password: changeme123
  deployment:
    spec:
      template:
        spec:
          containers:
            - name: grafana
              env:
                - name: THANOS_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: grafana-sa-token
                      key: token
EOF
```

Wait for the pod to start:

```bash
oc get pods -n observability --watch
```

Expected output:
```
NAME                         READY   STATUS    RESTARTS   AGE
grafana-deployment-xxx       1/1     Running   0          30s
```

### Step 10 — Create the Prometheus Datasource

```bash
SA_TOKEN=$(oc get secret grafana-sa-token -n observability -o jsonpath='{.data.token}' | base64 -d)
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')

cat <<EOF | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus-thanos
  namespace: observability
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: https://${THANOS_HOST}
    isDefault: true
    jsonData:
      httpHeaderName1: "Authorization"
      tlsSkipVerify: true
      timeInterval: "5s"
    secureJsonData:
      httpHeaderValue1: "Bearer ${SA_TOKEN}"
EOF
```

### Step 11 — Expose Grafana with a Route

```bash
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: grafana-route
  namespace: observability
spec:
  to:
    kind: Service
    name: grafana-service
  port:
    targetPort: grafana
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

# Get the Grafana URL
echo "https://$(oc get route grafana-route -n observability -o jsonpath='{.spec.host}')"
```

Open the URL and log in with `admin` / `changeme123`.

Go to **Connections → Data Sources → Prometheus → Save & Test**. You should see:
```
Successfully queried the Prometheus API.
```

---

## Part 3 — Load the Consul Dashboards

The dashboard JSON files in `dashboards/` contain two hardcoded values from the original EKS tutorial environment that must be fixed before loading:

1. A hardcoded datasource UID (`PBFA97CFB590B2093`)
2. Hardcoded namespace dropdown values (`default, consul`) as a static custom variable

The script below fixes both issues automatically.

### Step 12 — Prepare and Load the Dashboards

```bash
# Get your Grafana URL and datasource UID
GRAFANA_URL=$(oc get route grafana-route -n observability -o jsonpath='{.spec.host}')

DATASOURCE_UID=$(curl -sk "https://$GRAFANA_URL/api/datasources" \
  -u admin:changeme123 | python3 -m json.tool | grep '"uid"' | head -1 \
  | tr -d ' ",' | cut -d: -f2)

echo "Datasource UID: $DATASOURCE_UID"

# Copy dashboards to a working directory
cp dashboards/consul-data-plane-health.json /tmp/health-dashboard.json
cp dashboards/consul-data-plane-performance.json /tmp/performance-dashboard.json

# Replace the hardcoded datasource UID
sed -i '' "s/PBFA97CFB590B2093/${DATASOURCE_UID}/g" /tmp/health-dashboard.json
sed -i '' "s/PBFA97CFB590B2093/${DATASOURCE_UID}/g" /tmp/performance-dashboard.json

# Fix hardcoded namespace/app variables to be dynamic
python3 - <<'EOF'
import json

for path in ['/tmp/health-dashboard.json', '/tmp/performance-dashboard.json']:
    with open(path, 'r') as f:
        dashboard = json.load(f)

    for template in dashboard.get('templating', {}).get('list', []):
        if template.get('name') == 'namespace':
            template['type'] = 'query'
            template['query'] = 'label_values(envoy_cluster_upstream_rq_total, namespace)'
            template['queryValue'] = ''
            template['options'] = []
            template['current'] = {}
        if template.get('name') == 'app':
            template['type'] = 'query'
            template['query'] = 'label_values(envoy_cluster_upstream_rq_total{namespace="$namespace"}, local_cluster)'
            template['queryValue'] = ''
            template['options'] = []
            template['current'] = {}

    with open(path, 'w') as f:
        json.dump(dashboard, f)

print("Done")
EOF

# Load dashboards as ConfigMaps
oc create configmap consul-data-plane-health \
  -n observability \
  --from-file=consul-data-plane-health.json=/tmp/health-dashboard.json

oc create configmap consul-data-plane-performance \
  -n observability \
  --from-file=consul-data-plane-performance.json=/tmp/performance-dashboard.json

# Create GrafanaDashboard resources pointing at the ConfigMaps
cat <<EOF | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: consul-data-plane-health
  namespace: observability
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  configMapRef:
    name: consul-data-plane-health
    key: consul-data-plane-health.json
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: consul-data-plane-performance
  namespace: observability
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  configMapRef:
    name: consul-data-plane-performance
    key: consul-data-plane-performance.json
EOF
```

Wait ~30 seconds, then hard-refresh your browser (`Cmd+Shift+R`) and go to **Dashboards → Browse**.

### Step 13 — Explore the Dashboards

Set the **namespace** dropdown to your app namespace (e.g., `demo`). The **app** dropdown will populate automatically based on services in that namespace.

**Data Plane Health** shows mesh-wide health:
- Running service count
- Connections rejected per service
- Upstream/downstream request rates by HTTP status code

**Data Plane Performance** shows performance metrics:
- Dataplane latency (live graph)
- Requests active (upstream)
- Connections rejected over time
- Latency by throughput

---

## Useful Prometheus Queries

Access the Prometheus UI at any time:

```bash
oc port-forward -n openshift-user-workload-monitoring prometheus-user-workload-0 9090:9090
```

Then open **http://localhost:9090/graph** and try:

```promql
# Are all sidecars connected to Consul?
consul_dataplane_consul_connected

# Upstream request rate per service
rate(envoy_cluster_upstream_rq_total[5m])

# Request errors (5xx) per service
rate(envoy_cluster_upstream_rq_total{envoy_response_code=~"5.."}[5m])

# P99 latency per service
histogram_quantile(0.99,
  rate(envoy_cluster_upstream_rq_time_bucket[5m])
)

# Active upstream connections
envoy_cluster_upstream_cx_active
```

---

## Cleanup

Remove all monitoring resources without affecting Consul or your apps:

```bash
# Part 1 — PodMonitor
oc delete podmonitor consul-proxy-metrics -n <your-app-namespace>

# Part 2 — Grafana
oc delete grafanadashboard consul-data-plane-health consul-data-plane-performance -n observability
oc delete grafanadatasource prometheus-thanos -n observability
oc delete grafana grafana -n observability
oc delete subscription grafana-operator -n observability
oc delete csv grafana-operator.v5.22.2 -n observability
oc delete configmap consul-data-plane-health consul-data-plane-performance -n observability
oc delete secret grafana-sa-token -n observability
oc delete serviceaccount grafana -n observability
oc delete route grafana-route -n observability
oc delete operatorgroup observability-operatorgroup -n observability

# Optionally delete the namespace entirely
oc delete project observability
```

---

## Troubleshooting

### "Permission denied: anonymous token lacks permission 'agent:read'"

Consul ACLs are enabled. Use HTTPS port `8501` and pass a token:

```bash
oc get secret consul-bootstrap-acl-token -n consul -o jsonpath='{.data.token}' | base64 -d
```

Then pass `-H "X-Consul-Token: <token>"` in your curl request.

### curl not found in pod containers

Neither `consul-dataplane` nor most app containers include `curl`. Use port-forwarding instead:

```bash
oc port-forward -n <namespace> <pod-name> 20200:20200
curl -s http://localhost:20200/metrics | head -20
```

### PodMonitor targets not appearing in Prometheus

1. Confirm pods have the expected label:
   ```bash
   oc get pods -n <your-app-namespace> --show-labels | grep "connect-inject-status=injected"
   ```
2. Confirm user workload monitoring is running:
   ```bash
   oc get pods -n openshift-user-workload-monitoring
   ```
3. Check Prometheus operator logs:
   ```bash
   oc logs -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus-operator
   ```

### Grafana Operator CSV stuck in Installing

The `OperatorGroup` is missing. Create it first, then delete and recreate the Subscription:

```bash
oc get operatorgroup -n observability
```

See Step 7 for the OperatorGroup manifest.

### 401 Unauthorized on Grafana datasource test

Verify you are using a secret-based token, not a projected token:

```bash
oc get secret grafana-sa-token -n observability -o jsonpath='{.type}'
# Must be: kubernetes.io/service-account-token
```

Test the token directly:

```bash
SA_TOKEN=$(oc get secret grafana-sa-token -n observability -o jsonpath='{.data.token}' | base64 -d)
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -k -H "Authorization: Bearer $SA_TOKEN" "https://${THANOS_HOST}/api/v1/query?query=up" | head -c 100
```

### Namespace dropdown only shows `default` and `consul`

The dashboard JSON has hardcoded namespace values. Re-run the Python script from Step 12 and reapply the ConfigMaps.

### "Datasource PBFA97CFB590B2093 was not found"

The dashboard JSON has a hardcoded datasource UID from the original EKS tutorial. Re-run the `sed` replacement from Step 12.

### No metrics after Consul Helm upgrade

Restart your app pods to pick up the updated proxy configuration:

```bash
oc rollout restart deployment -n <your-app-namespace>
```

---

## Repository Structure

```
.
├── README.md                               # This file
├── dashboards/
│   ├── consul-data-plane-health.json       # Grafana health dashboard
│   └── consul-data-plane-performance.json  # Grafana performance dashboard
└── openshift/
    ├── servicemonitor-consul-server.yaml   # ServiceMonitor for Consul servers
    ├── servicemonitor-consul-sidecars.yaml # ServiceMonitor for Envoy sidecars
    └── prometheus-rule-consul.yaml         # Example alerting rules
```

## Resources

- [OpenShift User Workload Monitoring](https://docs.openshift.com/container-platform/latest/monitoring/enabling-monitoring-for-user-defined-projects.html)
- [Grafana Operator Documentation](https://grafana-operator.github.io/grafana-operator/)
- [Consul Telemetry Docs](https://developer.hashicorp.com/consul/docs/agent/telemetry)
- [Consul on Kubernetes Metrics](https://developer.hashicorp.com/consul/docs/observe/telemetry/k8s)
- [PodMonitor API Reference](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PodMonitor)
- [Envoy Proxy Statistics](https://www.envoyproxy.io/docs/envoy/latest/operations/stats_overview)
- [Thanos Querier Authentication](https://docs.openshift.com/container-platform/latest/monitoring/accessing-third-party-monitoring-uis-and-apis.html)
