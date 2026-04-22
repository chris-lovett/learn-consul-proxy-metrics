# OpenShift Deployment Files

Adapted configurations for deploying Consul proxy metrics monitoring on ROSA (Red Hat OpenShift on AWS) with existing Consul Enterprise 1.22.6+ent.

## Quick Start

```bash
# 1. Create observability namespace
oc new-project observability

# 2. Deploy Prometheus
helm install prometheus prometheus-community/prometheus \
  -n observability \
  -f prometheus-values.yaml

# 3. Deploy Grafana
helm install grafana grafana/grafana \
  -n observability \
  -f grafana-values.yaml

# 4. Create routes
oc apply -f routes/

# 5. Get access URLs
oc get routes -n observability
```

## Files

### Helm Values
- **`prometheus-values.yaml`** - Prometheus configuration for OpenShift
  - Persistent storage (gp3-csi, 20Gi)
  - Consul service discovery
  - Envoy proxy scraping
  - OpenShift SCC compatible

- **`grafana-values.yaml`** - Grafana configuration for OpenShift
  - Persistent storage (gp3-csi, 10Gi)
  - Pre-configured Prometheus datasource
  - Auto-loaded Consul dashboards
  - Authentication enabled
  - OpenShift SCC compatible

### Routes
- **`routes/prometheus-route.yaml`** - Internal HTTPS route for Prometheus
- **`routes/grafana-route.yaml`** - Internal HTTPS route for Grafana

### Documentation
- **`DEPLOYMENT_GUIDE.md`** - Complete step-by-step deployment guide
  - Prerequisites verification
  - Phase-by-phase deployment (70 min total)
  - Troubleshooting section
  - Verification checklist

## Key Differences from EKS

| Feature | EKS (Original) | OpenShift (Adapted) |
|---------|----------------|---------------------|
| Security Context | Explicit `runAsUser` | Removed (SCC handles) |
| External Access | LoadBalancer | Routes (internal) |
| Storage | Ephemeral | Persistent (gp3-csi) |
| Authentication | Anonymous | Enabled (admin/password) |
| TLS | Optional | Edge termination |

## Environment Details

- **Platform:** ROSA (Red Hat OpenShift on AWS)
- **Consul:** Enterprise 1.22.6+ent (Helm deployed)
- **Access:** Internal only (via Routes)
- **Storage:** Persistent (AWS EBS gp3)
- **Namespace:** `observability`

## Prerequisites

✅ OpenShift CLI (`oc`) configured
✅ Helm 3.x installed
✅ Consul Enterprise 1.22.6+ent deployed
✅ Cluster-admin or appropriate RBAC permissions
✅ Storage class `gp3-csi` available

## Access

After deployment:

```bash
# Get Grafana URL and credentials
GRAFANA_URL=$(oc get route grafana -n observability -o jsonpath='{.spec.host}')
GRAFANA_PASS=$(oc get secret grafana -n observability -o jsonpath="{.data.admin-password}" | base64 -d)

echo "Grafana: https://$GRAFANA_URL"
echo "Username: admin"
echo "Password: $GRAFANA_PASS"

# Get Prometheus URL
PROM_URL=$(oc get route prometheus -n observability -o jsonpath='{.spec.host}')
echo "Prometheus: https://$PROM_URL"
```

## Dashboards

Two Consul dashboards are automatically imported:

1. **Consul Data Plane Health**
   - Service health status
   - Proxy health
   - Connection status
   - Error rates

2. **Consul Data Plane Performance**
   - Request rates
   - Latency percentiles (P50, P95, P99)
   - Throughput
   - Resource usage

## Troubleshooting

### Check Prometheus Targets

```bash
PROM_URL=$(oc get route prometheus -n observability -o jsonpath='{.spec.host}')
curl -k "https://$PROM_URL/api/v1/targets" | jq '.data.activeTargets[] | select(.health != "up")'
```

### Check Consul Metrics

```bash
oc exec -n consul consul-server-0 -- curl -s http://localhost:8500/v1/agent/metrics?format=prometheus | head -20
```

### View Logs

```bash
# Prometheus logs
oc logs -n observability deployment/prometheus-server

# Grafana logs
oc logs -n observability deployment/grafana
```

## Next Steps

1. Review **DEPLOYMENT_GUIDE.md** for detailed instructions
2. Deploy demo app (HashiCups) to generate metrics
3. Customize dashboards for your services
4. Set up alerts in Prometheus
5. Configure backup/retention policies

## Support

- [Deployment Guide](DEPLOYMENT_GUIDE.md) - Complete setup instructions
- [Adaptation Plan](../ROSA_ADAPTATION.md) - Architecture and strategy
- [Consul Telemetry Docs](https://developer.hashicorp.com/consul/docs/agent/telemetry)
- [OpenShift Monitoring](https://docs.openshift.com/container-platform/latest/monitoring/)

---

**Ready to deploy?** Start with the [Deployment Guide](DEPLOYMENT_GUIDE.md)! 🚀