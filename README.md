# Consul Proxy Metrics Monitoring on OpenShift

Deploy Prometheus and Grafana to monitor Consul service mesh health and performance with proxy metrics on Red Hat OpenShift.

## Overview

This guide helps you set up comprehensive monitoring for your Consul service mesh using Prometheus for metrics collection and Grafana for visualization. You'll gain insights into:

- **Service Health:** Real-time health status of all services
- **Proxy Performance:** Envoy sidecar metrics including request rates, latency, and throughput
- **Network Traffic:** Upstream/downstream communication patterns
- **Error Tracking:** Error rates and failure patterns across your mesh

## Prerequisites

Before starting, ensure you have:

- ✅ **OpenShift Cluster:** ROSA or any OpenShift 4.x cluster
- ✅ **Consul Deployed:** Consul Enterprise or OSS already running
- ✅ **CLI Tools:** `oc` (OpenShift CLI) and `helm` (version 3.x)
- ✅ **Cluster Access:** Cluster-admin or appropriate RBAC permissions
- ✅ **Storage:** A storage class available (e.g., `gp3-csi` on AWS)

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

# Check available storage classes
oc get storageclass
```

## Quick Start (70 minutes)

### 1. Create Observability Namespace (2 min)

```bash
oc new-project observability
```

### 2. Add Helm Repositories (3 min)

```bash
# Add Prometheus and Grafana repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Verify repos
helm search repo prometheus-community/prometheus
helm search repo grafana/grafana
```

### 3. Deploy Prometheus (20 min)

```bash
# Deploy Prometheus with OpenShift configuration
helm install prometheus prometheus-community/prometheus \
  -n observability \
  -f openshift/prometheus-values.yaml \
  --wait

# Verify deployment
oc get pods -n observability -l app.kubernetes.io/name=prometheus
oc wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n observability --timeout=300s

# Create route for access
oc apply -f openshift/routes/prometheus-route.yaml

# Get Prometheus URL
PROM_URL=$(oc get route prometheus -n observability -o jsonpath='{.spec.host}')
echo "Prometheus: https://$PROM_URL"
```

### 4. Deploy Grafana (20 min)

```bash
# Deploy Grafana with OpenShift configuration
helm install grafana grafana/grafana \
  -n observability \
  -f openshift/grafana-values.yaml \
  --wait

# Verify deployment
oc get pods -n observability -l app.kubernetes.io/name=grafana
oc wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n observability --timeout=300s

# Create route for access
oc apply -f openshift/routes/grafana-route.yaml

# Get Grafana credentials
GRAFANA_URL=$(oc get route grafana -n observability -o jsonpath='{.spec.host}')
GRAFANA_PASS=$(oc get secret grafana -n observability -o jsonpath="{.data.admin-password}" | base64 -d)

echo "Grafana URL: https://$GRAFANA_URL"
echo "Username: admin"
echo "Password: $GRAFANA_PASS"
```

### 5. Configure Consul Metrics (15 min)

Check if metrics are already enabled in your Consul deployment:

```bash
# Get current Consul configuration
helm get values consul -n consul > /tmp/current-consul-values.yaml
grep -A 5 "metrics:" /tmp/current-consul-values.yaml
```

If metrics are not enabled, create an addon configuration:

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
# Test Consul metrics endpoint
oc exec -n consul consul-server-0 -- curl -s http://localhost:8500/v1/agent/metrics?format=prometheus | head -20

# Check Prometheus is scraping Consul
PROM_URL=$(oc get route prometheus -n observability -o jsonpath='{.spec.host}')
curl -k "https://$PROM_URL/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job | contains("consul"))'
```

### 6. Access Grafana Dashboards (10 min)

Open Grafana in your browser using the URL from step 4, then:

1. **Login** with username `admin` and the password from step 4
2. **Navigate** to Dashboards → Browse
3. **Open** the Consul folder to find two pre-loaded dashboards:
   - **Consul Data Plane Health** - Service and proxy health status
   - **Consul Data Plane Performance** - Request rates, latency, and throughput

The dashboards should immediately show metrics from your Consul deployment.

## What Gets Deployed

### Prometheus Stack
- **Prometheus Server:** Metrics collection and storage (20Gi persistent volume, 15-day retention)
- **Kube State Metrics:** Kubernetes object metrics
- **OpenShift Route:** Internal HTTPS access to Prometheus UI
- **Note:** Node Exporter is disabled by default — OpenShift's built-in monitoring stack already ships an equivalent. See `openshift/prometheus-values.yaml` for re-enable instructions.

### Grafana Stack
- **Grafana Server:** Metrics visualization (10Gi persistent volume)
- **Pre-configured Datasource:** Prometheus connection
- **Auto-loaded Dashboards:** Two Consul monitoring dashboards
- **OpenShift Route:** Internal HTTPS access to Grafana UI

### Configuration Features
- ✅ **PodSecurity Compliant:** Security contexts set on all containers (`allowPrivilegeEscalation=false`, `capabilities.drop=ALL`, `seccompProfile=RuntimeDefault`)
- ✅ **OpenShift Compatible:** Compatible with both SCCs and PodSecurity admission
- ✅ **Persistent Storage:** Data survives pod restarts
- ✅ **Internal Access:** Routes with TLS edge termination
- ✅ **Production Ready:** Authentication enabled, proper RBAC
- ✅ **Consul Discovery:** Automatic service discovery for scraping

## Dashboards

### Consul Data Plane Health

Monitor the overall health of your service mesh:

- **Service Health Status:** Up/down status for all services
- **Proxy Health:** Envoy sidecar health indicators
- **Connection Status:** Active connections and connection pools
- **Error Rates:** HTTP error rates by service and endpoint

### Consul Data Plane Performance

Track performance metrics across your mesh:

- **Request Rates:** Requests per second (RPS) by service
- **Latency Percentiles:** P50, P95, P99 response times
- **Throughput:** Bytes sent/received per service
- **Resource Usage:** CPU and memory for proxies

## Verification

Confirm everything is working:

```bash
# Check all pods are running
oc get pods -n observability

# Expected output:
# NAME                                    READY   STATUS    RESTARTS   AGE
# grafana-xxxxx                          1/1     Running   0          5m
# prometheus-kube-state-metrics-xxxxx    1/1     Running   0          10m
# prometheus-node-exporter-xxxxx         1/1     Running   0          10m
# prometheus-server-xxxxx                1/1     Running   0          10m

# Check persistent volumes are bound
oc get pvc -n observability
# Both prometheus-server and grafana should show "Bound"

# Check routes are accessible
oc get routes -n observability

# Verify Prometheus targets are healthy
PROM_URL=$(oc get route prometheus -n observability -o jsonpath='{.spec.host}')
curl -k "https://$PROM_URL/api/v1/targets" | jq '.data.activeTargets[] | select(.health != "up")'
# Should return empty (all targets healthy)
```

## Troubleshooting

### Prometheus Not Scraping Consul

**Symptom:** No Consul metrics in Prometheus

```bash
# Check Prometheus targets
PROM_URL=$(oc get route prometheus -n observability -o jsonpath='{.spec.host}')
curl -k "https://$PROM_URL/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job | contains("consul"))'

# Verify Consul metrics endpoint
oc exec -n consul consul-server-0 -- curl -s http://localhost:8500/v1/agent/metrics?format=prometheus

# Check Prometheus can reach Consul
oc exec -n observability deployment/prometheus-server -- wget -qO- http://consul-server.consul.svc.cluster.local:8500/v1/agent/metrics?format=prometheus
```

**Solution:** Ensure Consul metrics are enabled (see step 5) and Prometheus has network access to Consul services.

### Grafana Shows No Data

**Symptom:** Dashboards are empty or show "No data"

```bash
# Test Prometheus datasource from Grafana
oc exec -n observability deployment/grafana -- wget -qO- http://prometheus-server.observability.svc.cluster.local/api/v1/query?query=up

# Check Grafana logs
oc logs -n observability deployment/grafana | grep -i error
```

**Solution:** Verify the Prometheus datasource is configured correctly in Grafana (Configuration → Data Sources → Prometheus → Test).

### Pods Not Starting

**Symptom:** Pods stuck in Pending or CrashLoopBackOff

```bash
# Check pod status and events
oc get pods -n observability
oc describe pod <pod-name> -n observability

# Check for SCC issues (common in OpenShift)
oc get events -n observability --sort-by='.lastTimestamp' | grep -i "scc\|security"
```

**Solution:** The provided configurations are SCC-compatible. If issues persist, check that the `observability` namespace has proper permissions.

### Storage Issues

**Symptom:** PVCs stuck in Pending state

```bash
# Check PVC status
oc get pvc -n observability
oc describe pvc <pvc-name> -n observability

# Verify storage class exists
oc get storageclass
```

**Solution:** Update the storage class in `openshift/prometheus-values.yaml` and `openshift/grafana-values.yaml` to match an available storage class in your cluster.

## Optional: Deploy Demo Application

To generate sample metrics, deploy the HashiCups demo application:

```bash
# Create demo namespace
oc new-project hashicups-demo

# Label for Consul injection
oc label namespace hashicups-demo consul.hashicorp.com/connect-inject=enabled

# Deploy HashiCups services (adapt manifests for OpenShift if needed)
# Note: Original manifests may need SCC adjustments
oc apply -f openshift/hashicups/ -n hashicups-demo

# Wait for pods to be ready
oc wait --for=condition=ready pod --all -n hashicups-demo --timeout=300s

# Create route to access frontend
oc expose svc frontend -n hashicups-demo
oc get route frontend -n hashicups-demo
```

## Configuration Files

All configuration files are in the `openshift/` directory:

- **`prometheus-values.yaml`** - Prometheus Helm values optimized for OpenShift
- **`grafana-values.yaml`** - Grafana Helm values with pre-configured dashboards
- **`routes/prometheus-route.yaml`** - OpenShift Route for Prometheus
- **`routes/grafana-route.yaml`** - OpenShift Route for Grafana

Key configurations:

```yaml
# Prometheus: 20Gi storage, 15-day retention
server:
  persistentVolume:
    enabled: true
    storageClass: "gp3-csi"
    size: 20Gi
  retention: "15d"

# Grafana: 10Gi storage, auto-load dashboards
persistence:
  enabled: true
  storageClass: "gp3-csi"
  size: 10Gi
dashboardProviders:
  dashboardproviders.yaml:
    providers:
    - name: 'consul'
      folder: 'Consul'
```

## Customization

### Adjust Storage Size

Edit the Helm values files:

```bash
# For Prometheus
vim openshift/prometheus-values.yaml
# Change: server.persistentVolume.size

# For Grafana
vim openshift/grafana-values.yaml
# Change: persistence.size

# Upgrade deployments
helm upgrade prometheus prometheus-community/prometheus -n observability -f openshift/prometheus-values.yaml
helm upgrade grafana grafana/grafana -n observability -f openshift/grafana-values.yaml
```

### Change Retention Period

```bash
# Edit Prometheus values
vim openshift/prometheus-values.yaml
# Change: server.retention (e.g., "30d" for 30 days)

# Upgrade Prometheus
helm upgrade prometheus prometheus-community/prometheus -n observability -f openshift/prometheus-values.yaml
```

### Add Custom Dashboards

```bash
# Place dashboard JSON files in dashboards/ directory
# Update grafana-values.yaml to include them:
dashboards:
  consul:
    consul-data-plane-health:
      file: dashboards/consul-data-plane-health.json
    consul-data-plane-performance:
      file: dashboards/consul-data-plane-performance.json
    my-custom-dashboard:
      file: dashboards/my-custom-dashboard.json

# Upgrade Grafana
helm upgrade grafana grafana/grafana -n observability -f openshift/grafana-values.yaml
```

## Next Steps

1. **Explore Dashboards:** Familiarize yourself with the pre-loaded Consul dashboards
2. **Set Up Alerts:** Configure Prometheus alerts for critical metrics
3. **Customize Views:** Create custom dashboards for your specific services
4. **Configure Backup:** Set up backup for Grafana dashboards and Prometheus data
5. **Enable Authentication:** Integrate Grafana with LDAP/OAuth for team access
6. **Monitor Production:** Deploy monitoring to production namespaces

## Cleanup

To remove the monitoring stack (does not affect Consul):

```bash
# Remove Grafana
helm uninstall grafana -n observability

# Remove Prometheus
helm uninstall prometheus -n observability

# Delete routes
oc delete -f openshift/routes/

# Delete namespace (removes PVCs)
oc delete project observability

# Optional: Remove demo app
oc delete project hashicups-demo
```

## Resources

- **Consul Telemetry:** https://developer.hashicorp.com/consul/docs/agent/telemetry
- **Prometheus Documentation:** https://prometheus.io/docs/
- **Grafana Dashboards:** https://grafana.com/grafana/dashboards/
- **OpenShift Monitoring:** https://docs.openshift.com/container-platform/latest/monitoring/

## Repository Structure

```
.
├── README.md                           # This file
├── dashboards/                         # Grafana dashboard JSON files
│   ├── consul-data-plane-health.json
│   └── consul-data-plane-performance.json
└── openshift/                          # OpenShift deployment files
    ├── prometheus-values.yaml          # Prometheus Helm values
    ├── grafana-values.yaml             # Grafana Helm values
    └── routes/                         # OpenShift Routes
        ├── prometheus-route.yaml
        └── grafana-route.yaml
```

---

**Ready to get started?** Follow the Quick Start guide above to deploy monitoring in 70 minutes! 🚀