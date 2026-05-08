# GrafanaDashboard Custom Resources

This directory contains GrafanaDashboard CRs converted from the original ConfigMaps in `grafana-platform-dashboards.yaml`.

## Overview

These Custom Resources are designed to work with the [Grafana Operator](https://github.com/grafana-operator/grafana-operator) to declaratively manage Grafana dashboards in Kubernetes.

## Files

| File | Dashboard Name | Description |
|------|---------------|-------------|
| `consul-servers.yaml` | Consul Servers | Per-datacenter Consul server health: autopilot, Raft, RPC query performance, runtime, and cluster peering |
| `hashicups-health.yaml` | HashiCups Service Health | HashiCups inter-service traffic, error rates, latency, upstream connections, and circuit breaker status |
| `envoy-app-logs.yaml` | Application & Consul Logs | HashiCups, Consul, and Envoy access logs |
| `consul-logs.yaml` | Consul Logs | Consul server logs with filtering by datacenter and log level |
| `gateway-health.yaml` | Gateway Health | API Gateway, Terminating Gateway, and Mesh Gateway health metrics |
| `pod-health.yaml` | Pod Health — Kubernetes | Per-namespace/pod CPU, memory, restart counts, readiness, and network I/O |
| `unified-logs.yaml` | Unified Logs | Single-pane log viewer for Consul servers, gateways, and applications |

## Prerequisites

1. **Grafana Operator** must be installed in your cluster:
   ```bash
   kubectl apply -f https://github.com/grafana-operator/grafana-operator/releases/latest/download/kustomize.yaml
   ```

2. **Grafana Instance** with the label `dashboards: "grafana"` must exist:
   ```yaml
   apiVersion: grafana.integreatly.org/v1beta1
   kind: Grafana
   metadata:
     name: grafana
     labels:
       dashboards: "grafana"
   ```

3. **Data Sources** configured in Grafana:
   - Prometheus with UID: `PBFA97CFB590B2093` (named "Prometheus-dc1")
   - Loki with UID: `LOKI_DC1` (named "Loki-dc1")

## Deployment

### Deploy All Dashboards

```bash
kubectl apply -f /Users/chrislovett/hashi/monitoring/learn-consul-proxy-metrics/dashboards/cr/
```

### Deploy Individual Dashboard

```bash
kubectl apply -f consul-servers.yaml
```

### Verify Deployment

```bash
# Check GrafanaDashboard resources
kubectl get grafanadashboards -n monitoring

# Check Grafana Operator logs
kubectl logs -n grafana-operator-system -l app.kubernetes.io/name=grafana-operator
```

## Structure

Each GrafanaDashboard CR follows this structure:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: <dashboard-name>
  namespace: monitoring
  labels:
    app: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  folder: Platform
  json: |
    <dashboard-json-content>
```

## Key Features

- **Declarative Management**: Dashboards are version-controlled and deployed via GitOps
- **Automatic Sync**: Grafana Operator automatically creates/updates dashboards in Grafana
- **Folder Organization**: All dashboards are organized under the "Platform" folder
- **Instance Selection**: Uses label selectors to target specific Grafana instances

## Differences from ConfigMaps

The original ConfigMaps used the Grafana sidecar pattern with the label `grafana_dashboard: "1"`. These CRs use the Grafana Operator pattern with:

- `instanceSelector` to target Grafana instances
- Direct JSON embedding in the `spec.json` field
- Explicit folder assignment via `spec.folder`

## Updating Dashboards

To update a dashboard:

1. Modify the JSON content in the CR file
2. Apply the changes:
   ```bash
   kubectl apply -f <dashboard-file>.yaml
   ```
3. The Grafana Operator will automatically sync the changes to Grafana

## Troubleshooting

### Dashboard Not Appearing

1. Check if the GrafanaDashboard resource exists:
   ```bash
   kubectl get grafanadashboard <name> -n monitoring -o yaml
   ```

2. Verify the Grafana instance has the correct label:
   ```bash
   kubectl get grafana -n monitoring -o yaml | grep -A 2 labels
   ```

3. Check Grafana Operator logs for errors:
   ```bash
   kubectl logs -n grafana-operator-system -l app.kubernetes.io/name=grafana-operator --tail=100
   ```

### Data Source Issues

If panels show "No data":

1. Verify data source UIDs match in Grafana:
   - Prometheus: `PBFA97CFB590B2093`
   - Loki: `LOKI_DC1`

2. Update the UIDs in the dashboard JSON if needed

## Migration from ConfigMaps

If you're migrating from the ConfigMap approach:

1. Deploy these CRs
2. Verify dashboards appear in Grafana
3. Delete the old ConfigMaps:
   ```bash
   kubectl delete cm grafana-dashboard-consul-servers \
                      grafana-dashboard-hashicups-health \
                      grafana-dashboard-envoy-app-logs \
                      grafana-dashboard-consul-logs \
                      grafana-dashboard-gateway-health \
                      grafana-dashboard-pod-health \
                      grafana-dashboard-unified-logs \
                      -n monitoring
   ```

## References

- [Grafana Operator Documentation](https://grafana-operator.github.io/grafana-operator/)
- [GrafanaDashboard CRD Reference](https://grafana-operator.github.io/grafana-operator/docs/dashboards/)
- [Original ConfigMaps](../grafana-platform-dashboards.yaml)