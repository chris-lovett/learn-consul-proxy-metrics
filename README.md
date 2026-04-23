# Consul Proxy Metrics Monitoring on OpenShift

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


# Grafana Setup for Consul Proxy Metrics on OpenShift 

This guide covers deploying Grafana on OpenShift using the **Grafana Operator** and connecting it to the built-in Thanos Querier to visualize Consul proxy metrics.

> **Why the Grafana Operator?** The community Grafana Helm chart injects seccomp annotations that are forbidden by OpenShift's Security Context Constraints (SCCs), causing pods to fail to schedule. The Grafana Operator is OpenShift-native and handles all SCC requirements automatically.

## Prerequisites

Before starting this section, ensure you have completed:
- ✅ User workload monitoring enabled (`openshift-user-workload-monitoring` pods running)
- ✅ PodMonitor created and scraping Consul proxy metrics from your app namespace
- ✅ Metrics verified in Prometheus UI (`consul_dataplane_consul_connected = 1` for all pods)

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    observability namespace               │
│                                                          │
│  ┌─────────────────┐      ┌──────────────────────────┐  │
│  │ Grafana Operator│      │    Grafana Instance       │  │
│  │   (manages)     │─────▶│    grafana-deployment     │  │
│  └─────────────────┘      └──────────┬───────────────┘  │
│                                      │ queries           │
│                                      ▼                   │
│                         ┌────────────────────────┐       │
│                         │  Thanos Querier         │       │
│                         │  (openshift-monitoring) │       │
│                         └────────────┬───────────┘       │
│                                      │ federates         │
│                         ┌────────────▼───────────┐       │
│                         │  User Workload          │       │
│                         │  Prometheus             │       │
│                         │  (scrapes port 20200)   │       │
│                         └────────────────────────┘       │
└─────────────────────────────────────────────────────────┘
```

## Step 1 — Create the observability Namespace (if not already done)

```bash
oc new-project observability
```

## Step 2 — Install the Grafana Operator via OLM (10 min)

OpenShift uses the Operator Lifecycle Manager (OLM) to install operators. An `OperatorGroup` is required to tell OLM the target scope for the operator.

```bash
# Create the OperatorGroup
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

# Create the Subscription to install the Grafana Operator
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

Wait for the operator to install — this takes 1-2 minutes:

```bash
oc get csv -n observability --watch
```

Wait until you see `PHASE: Succeeded`:

```
NAME                       DISPLAY            VERSION   REPLACES                   PHASE
grafana-operator.v5.22.2   Grafana Operator   5.22.2    grafana-operator.v5.21.2   Succeeded
```

## Step 3 — Create a Service Account for Grafana (5 min)

Grafana needs a service account with permission to query the Thanos Querier.

```bash
# Create the service account
oc create serviceaccount grafana -n observability

# Grant permission to query cluster metrics via Thanos
oc adm policy add-cluster-role-to-user cluster-monitoring-view \
  -z grafana \
  -n observability

# Create a long-lived secret-based token (more reliable than projected tokens for Thanos auth)
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

# Wait for the token to be populated
sleep 5

# Verify the token works against Thanos
SA_TOKEN=$(oc get secret grafana-sa-token -n observability -o jsonpath='{.data.token}' | base64 -d)

curl -k -H "Authorization: Bearer $SA_TOKEN" \
  "https://thanos-querier-openshift-monitoring.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')/api/v1/query?query=up" | head -c 200
```

You should see a JSON response with `"status":"success"`. If you see `Unauthorized`, verify the service account has the `cluster-monitoring-view` role.

## Step 4 — Deploy the Grafana Instance (5 min)

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
NAME                                   READY   STATUS    RESTARTS   AGE
grafana-deployment-xxx                 1/1     Running   0          30s
```

## Step 5 — Create the Thanos Datasource (5 min)

Get your Thanos Querier URL:

```bash
oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}'
```

Create the datasource using the service account token:

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

Verify the datasource was created:

```bash
oc get grafanadatasource -n observability
```

Expected output:
```
NAME                NO MATCHING INSTANCES   LAST RESYNC   AGE
prometheus-thanos                           30s           31s
```

> **Important:** Use a secret-based token (`kubernetes.io/service-account-token`) rather than a projected token (`oc create token`). Projected tokens are not accepted by the Thanos Querier's RBAC proxy.

## Step 6 — Expose Grafana with an OpenShift Route (2 min)

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
GRAFANA_URL=$(oc get route grafana-route -n observability -o jsonpath='{.spec.host}')
echo "Grafana URL: https://$GRAFANA_URL"
```

Open the URL in your browser and log in with:
- **Username:** `admin`
- **Password:** `changeme123`

### Verify the Datasource

1. Go to **Connections → Data Sources → Prometheus**
2. Click **Save & Test**
3. You should see: `Successfully queried the Prometheus API`

## Step 7 — Load the Consul Dashboards (10 min)

The dashboard JSON files reference a hardcoded Grafana datasource UID (`PBFA97CFB590B2093`) from the original EKS tutorial environment. We need to replace this with our actual datasource UID and fix the hardcoded namespace variable before loading them.

### Get Your Datasource UID

```bash
GRAFANA_URL=$(oc get route grafana-route -n observability -o jsonpath='{.spec.host}')

DATASOURCE_UID=$(curl -sk "https://$GRAFANA_URL/api/datasources" \
  -u admin:changeme123 | python3 -m json.tool | grep '"uid"' | head -1 | tr -d ' ",' | cut -d: -f2)

echo "Datasource UID: $DATASOURCE_UID"
```

### Prepare the Dashboard JSON Files

```bash
# Copy dashboard files to a working directory
cp dashboards/consul-data-plane-health.json /tmp/health-dashboard.json
cp dashboards/consul-data-plane-performance.json /tmp/performance-dashboard.json

# Replace the hardcoded datasource UID with your actual UID
sed -i '' "s/PBFA97CFB590B2093/${DATASOURCE_UID}/g" /tmp/health-dashboard.json
sed -i '' "s/PBFA97CFB590B2093/${DATASOURCE_UID}/g" /tmp/performance-dashboard.json

# Fix the hardcoded namespace and app variables to use dynamic label_values queries
# This allows the dashboards to discover namespaces from actual metrics
python3 - <<'EOF'
import json, sys

for filepath, outpath in [
    ('/tmp/health-dashboard.json', '/tmp/health-dashboard.json'),
    ('/tmp/performance-dashboard.json', '/tmp/performance-dashboard.json')
]:
    with open(filepath, 'r') as f:
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

    with open(outpath, 'w') as f:
        json.dump(dashboard, f)

print("Done - both dashboards updated")
EOF
```

### Load Dashboards via ConfigMaps

```bash
# Create ConfigMaps from the prepared dashboard JSON files
oc create configmap consul-data-plane-health \
  -n observability \
  --from-file=consul-data-plane-health.json=/tmp/health-dashboard.json

oc create configmap consul-data-plane-performance \
  -n observability \
  --from-file=consul-data-plane-performance.json=/tmp/performance-dashboard.json

# Create GrafanaDashboard resources that reference the ConfigMaps
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

# Verify dashboards were created and synced
oc get grafanadashboard -n observability
```

Expected output:
```
NAME                            NO MATCHING INSTANCES   LAST RESYNC   AGE
consul-data-plane-health                                30s           31s
consul-data-plane-performance                           30s           31s
```

## Step 8 — Explore the Dashboards

In the Grafana UI, go to **Dashboards → Browse** and open either dashboard.

Set the filters:
- **namespace:** Select your app namespace (e.g., `demo`)
- **app:** Select `All` or a specific service

### Data Plane Health Dashboard

Shows the overall health of your service mesh:

- **Running services** — count of active Consul-connected services
- **Connections Rejected** — rejected upstream connections per service
- **Upstream Rq by Status Code** — HTTP request rates broken down by 2xx/3xx/4xx/5xx
- **Downstream Rq by Status Code** — inbound request status codes
- **HTTP Status** — overall HTTP traffic health

### Data Plane Performance Dashboard

Shows performance metrics across your mesh:

- **Dataplane Latency** — P50/P95/P99 latency across all services
- **Requests Active (Upstream)** — active upstream connections
- **Connections Rejected** — connection rejection rates
- **Latency by Throughput** — latency vs. throughput correlation
- **Mem/CPU Usage** — resource usage by pod (requires kube-state-metrics)

## Verification

Confirm everything is working end to end:

```bash
# Check all resources are running
oc get pods -n observability
oc get grafanadatasource -n observability
oc get grafanadashboard -n observability

# Confirm metrics are flowing from your app namespace
SA_TOKEN=$(oc get secret grafana-sa-token -n observability -o jsonpath='{.data.token}' | base64 -d)
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')

curl -k -H "Authorization: Bearer $SA_TOKEN" \
  "https://${THANOS_HOST}/api/v1/query?query=consul_dataplane_consul_connected" \
  | python3 -m json.tool | grep -E '"namespace"|"value"'
```

All pods in your app namespace should show `consul_dataplane_consul_connected = 1`.

## Cleanup

To remove Grafana and all related resources:

```bash
# Remove dashboards
oc delete grafanadashboard consul-data-plane-health consul-data-plane-performance -n observability

# Remove datasource
oc delete grafanadatasource prometheus-thanos -n observability

# Remove Grafana instance
oc delete grafana grafana -n observability

# Remove the operator
oc delete subscription grafana-operator -n observability
oc delete csv grafana-operator.v5.22.2 -n observability

# Remove ConfigMaps
oc delete configmap consul-data-plane-health consul-data-plane-performance -n observability

# Remove service account and token
oc delete secret grafana-sa-token -n observability
oc delete serviceaccount grafana -n observability

# Remove route
oc delete route grafana-route -n observability

# Remove OperatorGroup (only if no other operators in this namespace)
oc delete operatorgroup observability-operatorgroup -n observability
```

## Troubleshooting

### 401 Unauthorized on Datasource Test

The token type matters. Use a secret-based token, not a projected token:

```bash
# Verify your token type
oc get secret grafana-sa-token -n observability -o jsonpath='{.type}'
# Should output: kubernetes.io/service-account-token

# Test the token directly against Thanos
SA_TOKEN=$(oc get secret grafana-sa-token -n observability -o jsonpath='{.data.token}' | base64 -d)
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -k -H "Authorization: Bearer $SA_TOKEN" "https://${THANOS_HOST}/api/v1/query?query=up" | head -c 100
```

### Namespace Dropdown Only Shows `default` and `consul`

The dashboard JSON has hardcoded namespace values. Re-run the Python script from Step 7 to fix the variable queries and re-apply the ConfigMaps.

### Datasource UID Error in Dashboards

The original dashboard JSON references `PBFA97CFB590B2093` — a hardcoded UID from the EKS tutorial environment. Run the `sed` replacement from Step 7 to replace it with your actual datasource UID.

### No Data in Panels After Setting Namespace

Verify metrics exist for your namespace in Thanos:

```bash
SA_TOKEN=$(oc get secret grafana-sa-token -n observability -o jsonpath='{.data.token}' | base64 -d)
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')

curl -k -H "Authorization: Bearer $SA_TOKEN" \
  "https://${THANOS_HOST}/api/v1/query?query=envoy_cluster_upstream_rq_total{namespace=\"<your-namespace>\"}" \
  | python3 -m json.tool | head -30
```

If this returns results, data is flowing and the issue is the dashboard variable configuration. If it returns empty results, check your PodMonitor is correctly targeting the pods.

### Grafana Operator CSV Stuck in Installing

An `OperatorGroup` is required. Check:

```bash
oc get operatorgroup -n observability
```

If missing, create it (see Step 2) then delete and recreate the Subscription.

## Resources

- [Grafana Operator Documentation](https://grafana-operator.github.io/grafana-operator/)
- [OpenShift User Workload Monitoring](https://docs.openshift.com/container-platform/latest/monitoring/enabling-monitoring-for-user-defined-projects.html)
- [Thanos Querier Authentication](https://docs.openshift.com/container-platform/latest/monitoring/accessing-third-party-monitoring-uis-and-apis.html)
- [Envoy Proxy Statistics](https://www.envoyproxy.io/docs/envoy/latest/operations/stats_overview)
