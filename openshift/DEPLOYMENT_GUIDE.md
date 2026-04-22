# OpenShift Deployment Guide - Consul Proxy Metrics

## Environment
- **Platform:** ROSA (Red Hat OpenShift on AWS)
- **Consul:** Enterprise 1.22.6+ent (deployed via Helm)
- **Access:** Internal only
- **Storage:** Persistent (gp3-csi)

## Prerequisites

✅ OpenShift CLI (`oc`) installed and configured
✅ Helm 3.x installed
✅ Access to ROSA cluster with cluster-admin or appropriate permissions
✅ Consul Enterprise 1.22.6+ent already deployed
✅ kubectl context set to your ROSA cluster

## Verify Prerequisites

```bash
# Check OpenShift connection
oc whoami
oc cluster-info

# Check Consul deployment
oc get pods -n consul
oc get consulservers -n consul

# Check Consul version
oc get pods -n consul -l app=consul -o jsonpath='{.items[0].spec.containers[0].image}'
# Should show: hashicorp/consul-enterprise:1.22.6-ent

# Verify Helm
helm version
```

## Phase 1: Deploy Observability Stack (30 minutes)

### Step 1: Create Observability Namespace

```bash
# Create namespace
oc new-project observability

# Verify
oc project observability
```

### Step 2: Add Helm Repositories

```bash
# Add Prometheus repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

# Add Grafana repo
helm repo add grafana https://grafana.github.io/helm-charts

# Update repos
helm repo update

# Verify
helm search repo prometheus-community/prometheus
helm search repo grafana/grafana
```

### Step 3: Deploy Prometheus

```bash
# Deploy Prometheus with OpenShift-adapted values
helm install prometheus prometheus-community/prometheus \
  -n observability \
  -f openshift/prometheus-values.yaml \
  --wait

# Verify deployment
oc get pods -n observability -l app.kubernetes.io/name=prometheus
oc get pvc -n observability

# Check Prometheus is running
oc wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n observability --timeout=300s
```

### Step 4: Create Prometheus Route

```bash
# Apply route for internal access
oc apply -f openshift/routes/prometheus-route.yaml

# Get Prometheus URL
oc get route prometheus -n observability -o jsonpath='{.spec.host}'
# Save this URL - you'll need it

# Test access (from within cluster or VPN)
PROM_URL=$(oc get route prometheus -n observability -o jsonpath='{.spec.host}')
curl -k https://$PROM_URL/-/healthy
# Should return: Prometheus is Healthy.
```

### Step 5: Deploy Grafana

```bash
# Deploy Grafana with OpenShift-adapted values
helm install grafana grafana/grafana \
  -n observability \
  -f openshift/grafana-values.yaml \
  --wait

# Verify deployment
oc get pods -n observability -l app.kubernetes.io/name=grafana
oc get pvc -n observability

# Check Grafana is running
oc wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n observability --timeout=300s
```

### Step 6: Create Grafana Route and Get Credentials

```bash
# Apply route for internal access
oc apply -f openshift/routes/grafana-route.yaml

# Get Grafana URL
oc get route grafana -n observability -o jsonpath='{.spec.host}'
# Save this URL

# Get admin password
oc get secret grafana -n observability -o jsonpath="{.data.admin-password}" | base64 -d
echo  # Add newline
# Save this password

# Test access
GRAFANA_URL=$(oc get route grafana -n observability -o jsonpath='{.spec.host}')
echo "Grafana URL: https://$GRAFANA_URL"
echo "Username: admin"
echo "Password: (from command above)"
```

### Step 7: Verify Observability Stack

```bash
# Check all pods are running
oc get pods -n observability

# Expected output:
# NAME                                    READY   STATUS    RESTARTS   AGE
# grafana-xxxxx                          1/1     Running   0          5m
# prometheus-kube-state-metrics-xxxxx    1/1     Running   0          10m
# prometheus-node-exporter-xxxxx         1/1     Running   0          10m
# prometheus-server-xxxxx                1/1     Running   0          10m

# Check PVCs are bound
oc get pvc -n observability
# Both prometheus-server and grafana should show "Bound"

# Check routes
oc get routes -n observability
```

## Phase 2: Configure Consul for Metrics (15 minutes)

### Step 1: Check Current Consul Configuration

```bash
# Get current Consul Helm values
helm get values consul -n consul > /tmp/current-consul-values.yaml

# Check if metrics are already enabled
grep -A 5 "metrics:" /tmp/current-consul-values.yaml
```

### Step 2: Enable Consul Metrics (if not already enabled)

Create a values file for metrics:

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
```

Update Consul (if needed):

```bash
# Backup current values
helm get values consul -n consul > /tmp/consul-backup-$(date +%Y%m%d-%H%M%S).yaml

# Upgrade Consul with metrics enabled
helm upgrade consul hashicorp/consul \
  -n consul \
  -f /tmp/current-consul-values.yaml \
  -f /tmp/consul-metrics-addon.yaml \
  --wait

# Verify upgrade
oc get pods -n consul
oc wait --for=condition=ready pod -l app=consul -n consul --timeout=300s
```

### Step 3: Apply Telemetry Intentions

```bash
# Apply intentions to allow Prometheus to scrape Consul
oc apply -f self-managed/eks/config/consul-telemetry-intentions.yaml

# Verify intentions
oc get serviceintentions -n consul
```

### Step 4: Verify Metrics Endpoint

```bash
# Test Consul server metrics
oc exec -n consul consul-server-0 -- curl -s http://localhost:8500/v1/agent/metrics?format=prometheus | head -20

# Should see Prometheus-format metrics

# Test from Prometheus
PROM_URL=$(oc get route prometheus -n observability -o jsonpath='{.spec.host}')
curl -k "https://$PROM_URL/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job | contains("consul"))'
```

## Phase 3: Deploy Demo Application (15 minutes)

### Step 1: Create Demo Namespace

```bash
# Create namespace for HashiCups demo
oc new-project hashicups-demo

# Label for Consul injection
oc label namespace hashicups-demo consul.hashicorp.com/connect-inject=enabled
```

### Step 2: Deploy HashiCups Services

```bash
# Deploy all HashiCups services
# Note: We'll adapt these for OpenShift in the next step

# For now, deploy the original manifests
oc apply -f self-managed/eks/hashicups/ -n hashicups-demo

# Verify deployments
oc get pods -n hashicups-demo
oc get svc -n hashicups-demo

# Wait for all pods to be ready
oc wait --for=condition=ready pod --all -n hashicups-demo --timeout=300s
```

### Step 3: Create Route for Frontend (Optional)

```bash
# Create route to access HashiCups frontend
oc expose svc frontend -n hashicups-demo

# Get frontend URL
oc get route frontend -n hashicups-demo -o jsonpath='{.spec.host}'
```

### Step 4: Generate Traffic

```bash
# Deploy traffic generator
oc apply -f self-managed/eks/hashicups/traffic-generator.yaml -n hashicups-demo

# Verify traffic is being generated
oc logs -f -n hashicups-demo -l app=traffic-generator
```

## Phase 4: Import Dashboards (10 minutes)

### Step 1: Access Grafana

```bash
# Get Grafana URL and credentials
GRAFANA_URL=$(oc get route grafana -n observability -o jsonpath='{.spec.host}')
GRAFANA_PASS=$(oc get secret grafana -n observability -o jsonpath="{.data.admin-password}" | base64 -d)

echo "Grafana URL: https://$GRAFANA_URL"
echo "Username: admin"
echo "Password: $GRAFANA_PASS"

# Open in browser (if you have access)
open "https://$GRAFANA_URL"
```

### Step 2: Verify Prometheus Data Source

1. Login to Grafana
2. Go to **Configuration** → **Data Sources**
3. Click on **Prometheus**
4. Click **Test** button
5. Should see "Data source is working"

### Step 3: Import Consul Dashboards

The dashboards should be automatically loaded via the Helm values. Verify:

1. Go to **Dashboards** → **Browse**
2. Look for **Consul** folder
3. Should see:
   - Consul Data Plane Health
   - Consul Data Plane Performance

If not automatically loaded, import manually:

1. Go to **Dashboards** → **Import**
2. Upload `dashboards/consul-data-plane-health.json`
3. Select **Prometheus** as data source
4. Click **Import**
5. Repeat for `dashboards/consul-data-plane-performance.json`

### Step 4: Verify Metrics

1. Open **Consul Data Plane Health** dashboard
2. Should see metrics for:
   - Service health status
   - Proxy health
   - Connection status
   - Error rates

3. Open **Consul Data Plane Performance** dashboard
4. Should see metrics for:
   - Request rates
   - Latency percentiles
   - Throughput
   - Resource usage

## Verification Checklist

✅ Prometheus is running and accessible
✅ Grafana is running and accessible
✅ Prometheus is scraping Consul metrics
✅ Prometheus is scraping Envoy proxy metrics
✅ HashiCups demo app is deployed
✅ Traffic generator is running
✅ Grafana dashboards show live data
✅ No errors in Prometheus targets
✅ All pods are in Running state

## Troubleshooting

### Prometheus Not Scraping Consul

```bash
# Check Prometheus targets
PROM_URL=$(oc get route prometheus -n observability -o jsonpath='{.spec.host}')
curl -k "https://$PROM_URL/api/v1/targets" | jq '.data.activeTargets[] | select(.health != "up")'

# Check Consul metrics endpoint
oc exec -n consul consul-server-0 -- curl -s http://localhost:8500/v1/agent/metrics?format=prometheus

# Check service discovery
oc exec -n observability deployment/prometheus-server -- wget -qO- http://consul-server.consul.svc.cluster.local:8500/v1/catalog/services
```

### Grafana Can't Connect to Prometheus

```bash
# Check Prometheus service
oc get svc prometheus-server -n observability

# Test from Grafana pod
oc exec -n observability deployment/grafana -- wget -qO- http://prometheus-server.observability.svc.cluster.local

# Check Grafana logs
oc logs -n observability deployment/grafana
```

### Pods Not Starting

```bash
# Check pod status
oc get pods -n observability
oc describe pod <pod-name> -n observability

# Check events
oc get events -n observability --sort-by='.lastTimestamp'

# Check SCC issues (common in OpenShift)
oc get pod <pod-name> -n observability -o yaml | grep -A 5 "securityContext"
```

### Storage Issues

```bash
# Check PVCs
oc get pvc -n observability

# Check storage class
oc get storageclass gp3-csi

# Describe PVC for issues
oc describe pvc <pvc-name> -n observability
```

## Cleanup (if needed)

```bash
# Remove demo app
oc delete project hashicups-demo

# Remove observability stack
helm uninstall grafana -n observability
helm uninstall prometheus -n observability
oc delete project observability

# Note: This does NOT remove Consul - your existing deployment is untouched
```

## Next Steps

1. **Customize dashboards** for your specific services
2. **Set up alerts** in Prometheus for critical metrics
3. **Configure retention** policies based on your needs
4. **Add authentication** to Grafana (LDAP/OAuth)
5. **Deploy to production** namespaces
6. **Document** your specific service metrics

## Support

- Consul Metrics: https://developer.hashicorp.com/consul/docs/agent/telemetry
- Prometheus on OpenShift: https://docs.openshift.com/container-platform/latest/monitoring/
- Grafana Dashboards: https://grafana.com/grafana/dashboards/

---

**Deployment complete!** 🎉 You now have Consul proxy metrics monitoring on your ROSA cluster.