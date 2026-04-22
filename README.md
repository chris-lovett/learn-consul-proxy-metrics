# Consul Proxy Metrics Monitoring on OpenShift

Monitor Consul service mesh health and performance using OpenShift's built-in monitoring stack.

## Overview

OpenShift ships with a comprehensive monitoring stack (Prometheus and Grafana) that you can extend to monitor your Consul service mesh. This guide shows you how to configure the built-in monitoring to collect and visualize Consul proxy metrics, giving you insights into:

- **Service Health:** Real-time health status of all services
- **Proxy Performance:** Envoy sidecar metrics including request rates, latency, and throughput
- **Network Traffic:** Upstream/downstream communication patterns
- **Error Tracking:** Error rates and failure patterns across your mesh

## Why Use Built-in Monitoring?

✅ **Already Deployed:** No need to install additional Prometheus/Grafana instances
✅ **Integrated:** Seamlessly works with OpenShift's monitoring infrastructure
✅ **Maintained:** Automatically updated with OpenShift
✅ **Secure:** Uses OpenShift's authentication and RBAC
✅ **Cost Effective:** No additional storage or compute resources needed

## Prerequisites

Before starting, ensure you have:

- ✅ **OpenShift Cluster:** ROSA or any OpenShift 4.x cluster
- ✅ **Consul Deployed:** Consul Enterprise or OSS already running
- ✅ **CLI Tools:** `oc` (OpenShift CLI)
- ✅ **Cluster Access:** Cluster-admin or monitoring-edit permissions
- ✅ **User Workload Monitoring:** Enabled (we'll verify this)

### Verify Your Environment

```bash
# Check OpenShift connection
oc whoami
oc cluster-info

# Check Consul is running
oc get pods -n consul
oc get svc -n consul

# Verify Consul version
oc get pods -n consul -l app=consul -o jsonpath='{.items[0].spec.containers[0].image}'

# Check if user workload monitoring is enabled
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml
```

## Quick Start (30 minutes)

### 1. Enable User Workload Monitoring (5 min)

OpenShift's monitoring stack has two components:
- **Platform monitoring:** Monitors OpenShift itself (already enabled)
- **User workload monitoring:** Monitors your applications (needs to be enabled)

```bash
# Check if already enabled
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep enableUserWorkload

# If not enabled, create/update the config
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

# Wait for user workload monitoring pods to start
oc get pods -n openshift-user-workload-monitoring

# Expected pods:
# - prometheus-operator
# - prometheus-user-workload (2 replicas)
# - thanos-ruler (2 replicas)
```

### 2. Configure Consul Metrics (10 min)

Ensure Consul is configured to expose metrics:

```bash
# Check current Consul configuration
helm get values consul -n consul > /tmp/current-consul-values.yaml
grep -A 5 "metrics:" /tmp/current-consul-values.yaml
```

If metrics are not enabled, update Consul:

```bash
cat > /tmp/consul-metrics-addon.yaml <<'EOF'
global:
  metrics:
    enabled: true
    enableAgentMetrics: true
    enableGatewayMetrics: true
    disableAgentHostName: true

connectInject:
  metrics:
    defaultEnabled: true
    defaultEnableMerging: true
    defaultPrometheusScrapePort: "20200"
    defaultPrometheusScrapePath: "/metrics"
EOF

# Backup current values
helm get values consul -n consul > /tmp/consul-backup-$(date +%Y%m%d-%H%M%S).yaml

# Upgrade Consul with metrics enabled
helm upgrade consul hashicorp/consul \
  -n consul \
  -f /tmp/current-consul-values.yaml \
  -f /tmp/consul-metrics-addon.yaml \
  --wait
```

Verify metrics are accessible:

```bash
# Test Consul server metrics
oc exec -n consul consul-server-0 -- curl -s http://localhost:8500/v1/agent/metrics?format=prometheus | head -20
```

### 3. Create ServiceMonitor for Consul (5 min)

ServiceMonitor is a custom resource that tells Prometheus what to scrape:

```bash
# Create ServiceMonitor for Consul servers
cat <<EOF | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: consul-server
  namespace: consul
  labels:
    app: consul
spec:
  selector:
    matchLabels:
      app: consul
      component: server
  endpoints:
  - port: http
    path: /v1/agent/metrics
    params:
      format: ['prometheus']
    interval: 30s
EOF

# Create ServiceMonitor for Consul clients (if applicable)
cat <<EOF | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: consul-client
  namespace: consul
  labels:
    app: consul
spec:
  selector:
    matchLabels:
      app: consul
      component: client
  endpoints:
  - port: http
    path: /v1/agent/metrics
    params:
      format: ['prometheus']
    interval: 30s
EOF

# Create ServiceMonitor for Envoy sidecars
cat <<EOF | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: consul-connect-injected
  namespace: consul
  labels:
    app: consul
spec:
  selector:
    matchLabels:
      consul.hashicorp.com/connect-inject-status: "injected"
  endpoints:
  - port: envoy-metrics
    path: /stats/prometheus
    interval: 30s
  namespaceSelector:
    any: true
EOF

# Verify ServiceMonitors are created
oc get servicemonitor -n consul
```

### 4. Access Grafana and Import Dashboards (10 min)

OpenShift's Grafana is accessible through the console:

```bash
# Get the Grafana route
oc get route grafana -n openshift-monitoring

# Or access via OpenShift Console:
# Navigate to: Observe → Dashboards
```

**Import Consul Dashboards:**

1. **Access Grafana:**
   - OpenShift Console → Observe → Dashboards
   - Or use the Grafana route URL

2. **Login:**
   - Use your OpenShift credentials (SSO)

3. **Import Dashboards:**
   - Click **+** → **Import**
   - Upload `dashboards/consul-data-plane-health.json`
   - Select **Prometheus** as data source
   - Click **Import**
   - Repeat for `dashboards/consul-data-plane-performance.json`

**Alternative: Import via CLI (if you have Grafana API access):**

```bash
# Get Grafana route
GRAFANA_URL=$(oc get route grafana -n openshift-monitoring -o jsonpath='{.spec.host}')

# Get auth token (requires cluster-admin)
TOKEN=$(oc sa get-token grafana -n openshift-monitoring)

# Import dashboard
curl -X POST "https://$GRAFANA_URL/api/dashboards/db" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @dashboards/consul-data-plane-health.json
```

## What Gets Configured

### ServiceMonitors
Three ServiceMonitors are created to scrape metrics:

1. **consul-server:** Scrapes Consul server metrics
   - Endpoint: `/v1/agent/metrics?format=prometheus`
   - Interval: 30 seconds

2. **consul-client:** Scrapes Consul client metrics (if using clients)
   - Endpoint: `/v1/agent/metrics?format=prometheus`
   - Interval: 30 seconds

3. **consul-connect-injected:** Scrapes Envoy sidecar metrics
   - Endpoint: `/stats/prometheus`
   - Interval: 30 seconds
   - Namespace: All namespaces with injected sidecars

### Dashboards

Two comprehensive Grafana dashboards:

1. **Consul Data Plane Health**
   - Service health status
   - Proxy health indicators
   - Connection status
   - Error rates

2. **Consul Data Plane Performance**
   - Request rates (RPS)
   - Latency percentiles (P50, P95, P99)
   - Throughput metrics
   - Resource usage

## Verification

Confirm everything is working:

```bash
# Check ServiceMonitors are created
oc get servicemonitor -n consul

# Check Prometheus is scraping Consul targets
# Access Prometheus UI: Observe → Metrics → Prometheus UI
# Or via CLI:
oc get route prometheus-k8s -n openshift-monitoring

# Query for Consul metrics
# In Prometheus UI, try queries like:
# - consul_health_service_query_count
# - envoy_cluster_upstream_rq_total
# - consul_raft_leader

# Check for any scrape errors
# In Prometheus UI: Status → Targets
# Look for consul-server, consul-client, and consul-connect-injected targets
```

## Troubleshooting

### ServiceMonitor Not Scraping

**Symptom:** No Consul metrics in Prometheus

```bash
# Check ServiceMonitor exists
oc get servicemonitor -n consul

# Check if services have correct labels
oc get svc -n consul --show-labels

# Check Prometheus logs
oc logs -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus

# Verify service endpoints
oc get endpoints -n consul
```

**Solution:** Ensure service labels match ServiceMonitor selectors. The ServiceMonitor must be in the same namespace as the services.

### Metrics Not Appearing in Grafana

**Symptom:** Dashboards show "No data"

```bash
# Test Prometheus query directly
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{job="consul-server"}'

# Check if Grafana datasource is configured
# In Grafana: Configuration → Data Sources → Prometheus
```

**Solution:** Verify Prometheus datasource in Grafana points to the user workload Prometheus instance.

### User Workload Monitoring Not Enabled

**Symptom:** No prometheus-user-workload pods

```bash
# Check cluster monitoring config
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml

# Check for errors
oc get events -n openshift-user-workload-monitoring --sort-by='.lastTimestamp'
```

**Solution:** Ensure `enableUserWorkload: true` is set in the cluster-monitoring-config ConfigMap (see step 1).

### Permission Denied

**Symptom:** Cannot create ServiceMonitors or access Grafana

```bash
# Check your permissions
oc auth can-i create servicemonitor -n consul
oc auth can-i get configmap -n openshift-monitoring
```

**Solution:** You need `monitoring-edit` role or cluster-admin. Ask your cluster administrator to grant permissions:

```bash
# Grant monitoring-edit to a user
oc adm policy add-role-to-user monitoring-edit <username> -n consul
```

## Advanced Configuration

### Adjust Scrape Interval

Edit the ServiceMonitor to change how often metrics are collected:

```bash
oc edit servicemonitor consul-server -n consul

# Change interval from 30s to 15s:
spec:
  endpoints:
  - port: http
    path: /v1/agent/metrics
    params:
      format: ['prometheus']
    interval: 15s  # Changed from 30s
```

### Add Custom Labels

Add labels to metrics for better filtering:

```bash
oc edit servicemonitor consul-server -n consul

# Add relabeling:
spec:
  endpoints:
  - port: http
    path: /v1/agent/metrics
    params:
      format: ['prometheus']
    interval: 30s
    relabelings:
    - sourceLabels: [__meta_kubernetes_pod_name]
      targetLabel: pod
    - sourceLabels: [__meta_kubernetes_namespace]
      targetLabel: namespace
```

### Configure Retention

User workload monitoring retention is configured cluster-wide:

```bash
# Edit user workload monitoring config
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    prometheus:
      retention: 15d  # Default is 24h
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 40Gi  # Default is 10Gi
EOF
```

## ServiceMonitor Configuration Files

For easier management, you can save ServiceMonitors as files:

**openshift/servicemonitor-consul-server.yaml:**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: consul-server
  namespace: consul
  labels:
    app: consul
spec:
  selector:
    matchLabels:
      app: consul
      component: server
  endpoints:
  - port: http
    path: /v1/agent/metrics
    params:
      format: ['prometheus']
    interval: 30s
```

**openshift/servicemonitor-consul-sidecars.yaml:**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: consul-connect-injected
  namespace: consul
  labels:
    app: consul
spec:
  selector:
    matchLabels:
      consul.hashicorp.com/connect-inject-status: "injected"
  endpoints:
  - port: envoy-metrics
    path: /stats/prometheus
    interval: 30s
  namespaceSelector:
    any: true
```

Apply them:
```bash
oc apply -f openshift/servicemonitor-consul-server.yaml
oc apply -f openshift/servicemonitor-consul-sidecars.yaml
```

## Useful Prometheus Queries

Access Prometheus UI via: **Observe → Metrics** in OpenShift Console

### Consul Health Queries

```promql
# Number of healthy services
count(consul_health_service_query{status="passing"})

# Services with critical health
consul_health_service_query{status="critical"}

# Consul leader status
consul_raft_leader

# Number of Consul peers
consul_raft_peers
```

### Envoy Proxy Queries

```promql
# Request rate per service
rate(envoy_cluster_upstream_rq_total[5m])

# Request latency P95
histogram_quantile(0.95, rate(envoy_cluster_upstream_rq_time_bucket[5m]))

# Error rate
rate(envoy_cluster_upstream_rq{envoy_response_code=~"5.."}[5m])

# Active connections
envoy_cluster_upstream_cx_active
```

### Service Mesh Queries

```promql
# Total requests between services
sum(rate(envoy_cluster_upstream_rq_total[5m])) by (envoy_cluster_name)

# Service-to-service latency
histogram_quantile(0.99, 
  sum(rate(envoy_cluster_upstream_rq_time_bucket[5m])) by (le, envoy_cluster_name)
)
```

## Next Steps

1. **Explore Dashboards:** Familiarize yourself with the Consul dashboards in Grafana
2. **Create Alerts:** Set up PrometheusRules for critical metrics
3. **Customize Dashboards:** Create custom views for your specific services
4. **Monitor Production:** Apply ServiceMonitors to production namespaces
5. **Set Up Notifications:** Configure AlertManager for alert notifications

## Creating Alerts

Create PrometheusRule resources for alerting:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: consul-alerts
  namespace: consul
spec:
  groups:
  - name: consul
    interval: 30s
    rules:
    - alert: ConsulServiceUnhealthy
      expr: consul_health_service_query{status="critical"} > 0
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Consul service {{ $labels.service_name }} is unhealthy"
        description: "Service {{ $labels.service_name }} has been in critical state for more than 5 minutes"
    
    - alert: ConsulHighErrorRate
      expr: rate(envoy_cluster_upstream_rq{envoy_response_code=~"5.."}[5m]) > 0.05
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "High error rate for {{ $labels.envoy_cluster_name }}"
        description: "Error rate is {{ $value }} for cluster {{ $labels.envoy_cluster_name }}"
```

Apply the alert:
```bash
oc apply -f openshift/prometheus-rule-consul.yaml
```

## Cleanup

To remove Consul monitoring (does not affect Consul itself):

```bash
# Remove ServiceMonitors
oc delete servicemonitor consul-server -n consul
oc delete servicemonitor consul-client -n consul
oc delete servicemonitor consul-connect-injected -n consul

# Remove PrometheusRules (if created)
oc delete prometheusrule consul-alerts -n consul

# Note: This does NOT disable user workload monitoring or remove dashboards
# Dashboards remain in Grafana and can be manually deleted
```

## Resources

- **OpenShift Monitoring:** https://docs.openshift.com/container-platform/latest/monitoring/
- **Consul Telemetry:** https://developer.hashicorp.com/consul/docs/agent/telemetry
- **ServiceMonitor API:** https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.ServiceMonitor
- **Prometheus Queries:** https://prometheus.io/docs/prometheus/latest/querying/basics/

## Repository Structure

```
.
├── README.md                                    # This file
├── dashboards/                                  # Grafana dashboard JSON files
│   ├── consul-data-plane-health.json
│   └── consul-data-plane-performance.json
└── openshift/                                   # OpenShift configuration files
    ├── servicemonitor-consul-server.yaml        # ServiceMonitor for Consul servers
    ├── servicemonitor-consul-sidecars.yaml      # ServiceMonitor for Envoy sidecars
    └── prometheus-rule-consul.yaml              # Example alert rules
```

---

**Ready to get started?** Follow the Quick Start guide above to enable monitoring in 30 minutes! 🚀