# Adapting Consul Proxy Metrics Tutorial for ROSA/OpenShift

## Your Environment
- **Platform:** Red Hat OpenShift on AWS (ROSA)
- **Service Mesh:** Consul Enterprise (already deployed)
- **Goal:** Add proxy metrics monitoring without recreating infrastructure

## What the Original Tutorial Creates

### ❌ Skip These (You Already Have)
1. **EKS Cluster** (`eks-cluster.tf`)
   - You have ROSA/OpenShift cluster
   
2. **Consul Installation** (`helm/consul-v*.yaml`)
   - You have Consul Enterprise deployed
   - Skip all Consul Helm chart installations

3. **VPC/Networking** (`aws-vpc.tf`)
   - ROSA handles this
   - Your cluster networking is already configured

### ✅ Keep/Adapt These

1. **Observability Stack** (`eks-observability.tf`)
   - Prometheus for metrics collection
   - Grafana for visualization
   - **Action:** Deploy to your OpenShift cluster

2. **Demo Application** (`hashicups/*.yaml`)
   - HashiCups microservices app
   - Shows proxy metrics in action
   - **Action:** Deploy to test namespace

3. **Grafana Dashboards** (`dashboards/*.json`)
   - Consul Data Plane Health
   - Consul Data Plane Performance
   - **Action:** Import into your Grafana

4. **Consul Telemetry Config** (`config/consul-telemetry-intentions.yaml`)
   - Allows Prometheus to scrape Consul metrics
   - **Action:** Apply to your Consul

## Adaptation Strategy

### Phase 1: Deploy Observability Stack (30 min)

**Create OpenShift project:**
```bash
oc new-project observability
```

**Deploy Prometheus:**
```bash
# Adapt helm/prometheus.yaml for OpenShift
# Key changes:
# - Remove securityContext (OpenShift handles this)
# - Use OpenShift Routes instead of LoadBalancer
# - Ensure proper RBAC for OpenShift

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/prometheus \
  -n observability \
  -f openshift/prometheus-values.yaml
```

**Deploy Grafana:**
```bash
# Adapt helm/grafana.yaml for OpenShift
# Key changes:
# - Use OpenShift Routes instead of LoadBalancer
# - Configure persistent storage (if needed)
# - Set up proper authentication (remove anonymous access for prod)

helm repo add grafana https://grafana.github.io/helm-charts
helm install grafana grafana/grafana \
  -n observability \
  -f openshift/grafana-values.yaml
```

### Phase 2: Configure Consul for Metrics (15 min)

**Enable Prometheus metrics in your existing Consul:**

Check your current Consul configuration:
```bash
oc get consulservers -n consul -o yaml
```

Ensure these settings are enabled:
```yaml
# In your Consul Helm values or ConsulServer CR
global:
  metrics:
    enabled: true
    enableAgentMetrics: true
    enableGatewayMetrics: true
  
connectInject:
  metrics:
    defaultEnabled: true
    defaultEnableMerging: true
```

**Apply telemetry intentions:**
```bash
# Allow Prometheus to scrape Consul metrics
oc apply -f config/consul-telemetry-intentions.yaml
```

### Phase 3: Deploy Demo App (15 min)

**Create test namespace:**
```bash
oc new-project hashicups-demo
```

**Deploy HashiCups services:**
```bash
# Adapt hashicups/*.yaml for OpenShift
# Key changes:
# - Update securityContext for OpenShift SCCs
# - Use OpenShift Routes for external access
# - Ensure Consul injection annotations are correct

oc apply -f openshift/hashicups/
```

### Phase 4: Import Dashboards (10 min)

**Access Grafana:**
```bash
# Get Grafana route
oc get route grafana -n observability

# Get admin password
oc get secret grafana -n observability -o jsonpath="{.data.admin-password}" | base64 -d
```

**Import dashboards:**
1. Login to Grafana
2. Go to Dashboards → Import
3. Upload `dashboards/consul-data-plane-health.json`
4. Upload `dashboards/consul-data-plane-performance.json`
5. Configure Prometheus data source

## Directory Structure for Adaptation

```
learn-consul-proxy-metrics/
├── openshift/                    # NEW: OpenShift-specific configs
│   ├── prometheus-values.yaml   # Adapted for OpenShift
│   ├── grafana-values.yaml      # Adapted for OpenShift
│   ├── hashicups/                # Adapted demo app
│   │   ├── frontend.yaml
│   │   ├── public-api.yaml
│   │   ├── product-api.yaml
│   │   ├── payments.yaml
│   │   └── nginx.yaml
│   └── routes/                   # OpenShift Routes
│       ├── grafana-route.yaml
│       └── prometheus-route.yaml
├── config/                       # KEEP: Consul configs
│   └── consul-telemetry-intentions.yaml
├── dashboards/                   # KEEP: Grafana dashboards
│   ├── consul-data-plane-health.json
│   └── consul-data-plane-performance.json
└── self-managed/eks/             # REFERENCE ONLY
    └── ...                       # Original EKS configs
```

## Key Differences: OpenShift vs EKS

### Security Context
**EKS:**
```yaml
securityContext:
  runAsUser: 65534
  runAsNonRoot: true
```

**OpenShift:**
```yaml
# Remove securityContext - OpenShift SCCs handle this
# Or use restricted SCC
```

### External Access
**EKS:**
```yaml
service:
  type: LoadBalancer
```

**OpenShift:**
```yaml
# Use Routes instead
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: grafana
spec:
  to:
    kind: Service
    name: grafana
  port:
    targetPort: 3000
  tls:
    termination: edge
```

### Storage
**EKS:**
```yaml
persistentVolume:
  enabled: false  # Tutorial uses ephemeral
```

**OpenShift:**
```yaml
# Consider using PVCs for production
persistence:
  enabled: true
  storageClassName: gp3-csi  # Or your storage class
  size: 10Gi
```

## Next Steps

1. **Create `openshift/` directory** with adapted configs
2. **Test Prometheus deployment** in observability namespace
3. **Test Grafana deployment** and access via Route
4. **Configure Consul metrics** (if not already enabled)
5. **Deploy HashiCups demo** to test metrics collection
6. **Import and test dashboards**
7. **Document any ROSA-specific gotchas**

## Consul Enterprise Considerations

Since you're using Consul Enterprise, you may have:
- **Admin Partitions:** Ensure metrics are collected from all partitions
- **Namespaces:** Configure Prometheus to scrape all namespaces
- **ACLs:** Ensure Prometheus has proper ACL token for scraping
- **mTLS:** Configure Prometheus to use proper certificates

## Questions to Answer

1. **What Consul version are you running?**
   - Affects available metrics and configuration

2. **How is Consul deployed?**
   - Helm chart? Operator? Manual?
   - Helps determine how to enable metrics

3. **What's your current monitoring setup?**
   - Already have Prometheus/Grafana?
   - Can we extend existing setup?

4. **Storage requirements?**
   - Ephemeral for demo?
   - Persistent for production?

5. **Access requirements?**
   - Internal only?
   - Need external access to Grafana?

## Useful Commands

```bash
# Check Consul version
oc get pods -n consul -l app=consul -o jsonpath='{.items[0].spec.containers[0].image}'

# Check if metrics are enabled
oc exec -n consul consul-server-0 -- consul operator raft list-peers

# Test Prometheus scraping
oc port-forward -n observability svc/prometheus-server 9090:80
# Visit http://localhost:9090/targets

# Test Grafana access
oc port-forward -n observability svc/grafana 3000:80
# Visit http://localhost:3000
```

## Success Criteria

✅ Prometheus successfully scraping Consul proxy metrics
✅ Grafana dashboards showing real-time data
✅ HashiCups demo app generating metrics
✅ No disruption to existing Consul Enterprise deployment
✅ Documentation for team to maintain setup

---

**Ready to start?** Let's begin with Phase 1: Deploying the observability stack!