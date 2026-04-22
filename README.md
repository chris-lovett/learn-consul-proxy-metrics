# Consul Proxy Metrics on OpenShift

Monitor Consul service mesh health and performance with proxy metrics on ROSA (Red Hat OpenShift on AWS).

## Overview

This repository provides OpenShift-adapted configurations for deploying Consul proxy metrics monitoring with Prometheus and Grafana. It's designed for environments with existing Consul Enterprise deployments on ROSA.

Consul proxy metrics provide detailed health and performance information for your service mesh applications, including:
- Upstream/downstream network traffic metrics
- Ingress/egress request details
- Error rates and latency percentiles
- Resource utilization

## Quick Start

```bash
# Navigate to OpenShift deployment files
cd openshift/

# Follow the deployment guide
cat DEPLOYMENT_GUIDE.md
```

## Repository Structure

```
.
├── README.md                    # This file
├── ROSA_ADAPTATION.md          # Architecture and adaptation strategy
├── dashboards/                 # Grafana dashboards (JSON)
│   ├── consul-data-plane-health.json
│   └── consul-data-plane-performance.json
└── openshift/                  # OpenShift deployment files
    ├── README.md               # Quick reference
    ├── DEPLOYMENT_GUIDE.md     # Step-by-step instructions
    ├── prometheus-values.yaml  # Prometheus Helm values
    ├── grafana-values.yaml     # Grafana Helm values
    └── routes/                 # OpenShift Routes
        ├── prometheus-route.yaml
        └── grafana-route.yaml
```

## Prerequisites

- **Platform:** ROSA (Red Hat OpenShift on AWS)
- **Consul:** Enterprise 1.22.6+ent (Helm deployed)
- **Tools:** OpenShift CLI (`oc`), Helm 3.x
- **Access:** Cluster-admin or appropriate RBAC permissions
- **Storage:** Storage class `gp3-csi` available

## Features

### OpenShift Optimized
- ✅ Security Context Constraints (SCC) compatible
- ✅ OpenShift Routes for internal access
- ✅ Persistent storage with AWS EBS gp3
- ✅ TLS edge termination
- ✅ Production-ready authentication

### Monitoring Stack
- **Prometheus:** Metrics collection and storage
  - Consul service discovery
  - Envoy proxy scraping
  - 20Gi persistent storage
  - 15-day retention

- **Grafana:** Metrics visualization
  - Pre-configured Prometheus datasource
  - Auto-loaded Consul dashboards
  - 10Gi persistent storage
  - Admin authentication enabled

### Dashboards

Two comprehensive dashboards included:

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

## Deployment

### 1. Review Documentation

Start with the adaptation strategy:
```bash
cat ROSA_ADAPTATION.md
```

### 2. Deploy Monitoring Stack

Follow the comprehensive deployment guide:
```bash
cd openshift/
cat DEPLOYMENT_GUIDE.md
```

### 3. Quick Deploy (70 minutes)

```bash
# Phase 1: Setup (10 min)
oc new-project observability
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Phase 2: Deploy Prometheus (20 min)
helm install prometheus prometheus-community/prometheus \
  -n observability \
  -f openshift/prometheus-values.yaml

# Phase 3: Deploy Grafana (20 min)
helm install grafana grafana/grafana \
  -n observability \
  -f openshift/grafana-values.yaml

# Phase 4: Configure Access (20 min)
oc apply -f openshift/routes/
```

### 4. Access Monitoring

```bash
# Get Grafana credentials
GRAFANA_URL=$(oc get route grafana -n observability -o jsonpath='{.spec.host}')
GRAFANA_PASS=$(oc get secret grafana -n observability -o jsonpath="{.data.admin-password}" | base64 -d)

echo "Grafana: https://$GRAFANA_URL"
echo "Username: admin"
echo "Password: $GRAFANA_PASS"

# Get Prometheus URL
PROM_URL=$(oc get route prometheus -n observability -o jsonpath='{.spec.host}')
echo "Prometheus: https://$PROM_URL"
```

## Key Differences from EKS

This repository has been adapted from the original HashiCorp tutorial for OpenShift:

| Feature | EKS (Original) | OpenShift (This Repo) |
|---------|----------------|------------------------|
| Infrastructure | Creates EKS cluster | Uses existing ROSA |
| Consul | Deploys Consul | Uses existing Consul Enterprise |
| Security Context | Explicit `runAsUser` | SCC-managed |
| External Access | LoadBalancer | Routes (internal) |
| Storage | Ephemeral | Persistent (gp3-csi) |
| Authentication | Anonymous | Enabled |
| TLS | Optional | Edge termination |

## Troubleshooting

### Check Prometheus Targets

```bash
PROM_URL=$(oc get route prometheus -n observability -o jsonpath='{.spec.host}')
curl -k "https://$PROM_URL/api/v1/targets" | jq '.data.activeTargets[] | select(.health != "up")'
```

### Verify Consul Metrics

```bash
# Check if Consul is exposing metrics
oc exec -n consul consul-server-0 -- curl -s http://localhost:8500/v1/agent/metrics?format=prometheus | head -20
```

### View Logs

```bash
# Prometheus logs
oc logs -n observability deployment/prometheus-server -f

# Grafana logs
oc logs -n observability deployment/grafana -f
```

### Common Issues

1. **No metrics in Grafana**
   - Verify Prometheus targets are healthy
   - Check Consul telemetry configuration
   - Ensure service discovery is working

2. **Storage issues**
   - Verify `gp3-csi` storage class exists
   - Check PVC status: `oc get pvc -n observability`

3. **Route access issues**
   - Verify routes are created: `oc get routes -n observability`
   - Check TLS certificates

See [DEPLOYMENT_GUIDE.md](openshift/DEPLOYMENT_GUIDE.md) for detailed troubleshooting.

## Next Steps

1. ✅ Deploy monitoring stack (Prometheus + Grafana)
2. 📊 Explore pre-loaded dashboards
3. 🚀 Deploy demo app (HashiCups) to generate metrics
4. 🎨 Customize dashboards for your services
5. 🔔 Set up alerts in Prometheus
6. 💾 Configure backup/retention policies

## Documentation

- **[openshift/README.md](openshift/README.md)** - Quick reference guide
- **[openshift/DEPLOYMENT_GUIDE.md](openshift/DEPLOYMENT_GUIDE.md)** - Complete deployment instructions
- **[ROSA_ADAPTATION.md](ROSA_ADAPTATION.md)** - Architecture and adaptation strategy

## External Resources

- [Original Tutorial](https://developer.hashicorp.com/consul/tutorials/service-mesh-observability/consul-proxy-metrics) - HashiCorp Learn
- [Consul Telemetry](https://developer.hashicorp.com/consul/docs/agent/telemetry) - Official documentation
- [OpenShift Monitoring](https://docs.openshift.com/container-platform/latest/monitoring/) - Red Hat documentation
- [Prometheus Operator](https://prometheus-operator.dev/) - Prometheus on Kubernetes

## License

This repository is based on HashiCorp's learn-consul-proxy-metrics tutorial and adapted for OpenShift environments.

---

**Ready to get started?** Head to [openshift/DEPLOYMENT_GUIDE.md](openshift/DEPLOYMENT_GUIDE.md)! 🚀