# Enabling Consul UI Topology Metrics and Grafana Deep Links on OpenShift

This guide walks through enabling the Consul UI topology metrics view and per-service Grafana dashboard deep links for a Consul deployment on OpenShift. It incorporates lessons learned from a real deployment, including common pitfalls and their fixes.

## Overview

The Consul UI topology view can display live Envoy proxy metrics (request rate, error rate, latency) directly on the service graph, and provide an "Open Dashboard" button that deep-links to a per-service Grafana dashboard. Enabling both features requires correctly wiring together three components:

- **Consul Helm values** — `ui.metrics` and `ui.dashboardURLTemplates`
- **Prometheus** — must be reachable by the Consul agent at its internal cluster DNS name
- **Grafana** — dashboards must be imported and externally reachable via an OpenShift Route

## Prerequisites

Before starting, confirm the following are already deployed and running:

```bash
# Consul
kubectl get pods -n consul | grep server

# Prometheus and Grafana
kubectl get svc -n observability

# Confirm Prometheus service name and port
kubectl get svc prometheus-server -n observability
```

The expected Prometheus service is `prometheus-server` in the `observability` namespace on port 80 (HTTP internally).

## Step 1: Acquire Dashboard JSON and Understand Reconciliation

There are two distinct flows in this environment:

1. **Upstream dashboard acquisition** (download dashboard JSON from `hashicorp/consul` into this repo)
2. **Local cluster reconciliation** (Grafana Operator continuously applies dashboards from Kubernetes resources in `observability`)

### 1A) Download upstream dashboards (for Consul UI deep-link use cases)

The official Consul Grafana dashboards live in the main `hashicorp/consul` GitHub repository under the `grafana/` directory. The filenames use no hyphens or separators.

```bash
mkdir -p dashboards

curl -L -o dashboards/consul-dataplane.json \
  https://raw.githubusercontent.com/hashicorp/consul/main/grafana/consuldataplanedashboard.json

curl -L -o dashboards/consul-service.json \
  https://raw.githubusercontent.com/hashicorp/consul/main/grafana/consulservicedashboard.json

curl -L -o dashboards/consul-service-to-service.json \
  https://raw.githubusercontent.com/hashicorp/consul/main/grafana/consulservicetoservicedashboard.json
```

> **Common mistake:** Earlier versions of HashiCorp tutorial repos used different filenames like `consul-data-plane-health.json`. These no longer exist at those upstream paths. The current canonical upstream filenames are shown above. If `curl` returns a 14-byte file, the path is wrong — check the file size with `ls -lh dashboards/`.

Verify the downloads succeeded:

```bash
ls -lh dashboards/
# Each file should be tens of KB, not 14 bytes

grep '"uid"' dashboards/consul-service.json
grep '"uid"' dashboards/consul-dataplane.json
```

Note the `uid` values — you will need the `consul-service` UID for the Helm values in the next step.

### Optional manual Grafana UI import

Open your Grafana Route URL in a browser. On OpenShift, expose Grafana if no route exists yet:

```bash
# Check for an existing route
oc get route -n observability

# If none exists, create one
oc expose svc grafana-service -n observability --port=3000
oc get route grafana-service -n observability
```

> **Note:** The Grafana service may be named `grafana-service` rather than `grafana` depending on your installation. Always check with `kubectl get svc -n observability` before assuming service names.

In the Grafana UI:
1. Go to **Dashboards → Import**
2. Upload `dashboards/consul-service.json` — note the UID shown during import
3. Upload `dashboards/consul-dataplane.json`
4. Upload `dashboards/consul-service-to-service.json`

### 1B) Reconcile the local Consul data-plane dashboards in this cluster (source-of-truth path)

For this repository's live OpenShift environment, dashboard persistence is managed by the Grafana Operator with this control loop:

`dashboards/*.json` → `ConfigMap` → `GrafanaDashboard` → Grafana Operator → Grafana UI

The live resources are in namespace `observability`:

- `ConfigMap/consul-data-plane-health` (key: `consul-data-plane-health.json`)
- `ConfigMap/consul-data-plane-performance` (key: `consul-data-plane-performance.json`)
- `GrafanaDashboard/consul-data-plane-health`
- `GrafanaDashboard/consul-data-plane-performance`

`ConfigMap` and `GrafanaDashboard` are both required conceptually:

- The ConfigMaps hold the dashboard JSON payload consumed by the operator.
- The GrafanaDashboard CRs tell the operator which ConfigMap and key to reconcile.

The authoritative files for this model are:

- `dashboards/consul-data-plane-health.json`
- `dashboards/consul-data-plane-performance.json`
- `openshift/grafana-dashboards/kustomization.yaml`
- `grafanadashboard-consul-data-plane-health.yaml`
- `grafanadashboard-consul-data-plane-performance.yaml`

`kustomization.yaml` generates stable-name ConfigMaps directly from `dashboards/*.json` (no checked-in rendered ConfigMap YAML files), then applies both GrafanaDashboard CRs.

Apply them to reproduce the setup from source control:

```bash
oc apply -k openshift/grafana-dashboards
```

> **Important:** UI-only edits do not persist. The operator reconciles from ConfigMap content and overwrites drift in Grafana on resync.

Use the sync helper to push local JSON into the live ConfigMaps and request a reconcile:

```bash
./scripts/sync-grafana-dashboards.sh
```

Override defaults when needed:

```bash
NAMESPACE=observability DASHBOARD_DIR=./dashboards ./scripts/sync-grafana-dashboards.sh
```

### Recommended workflow for dashboard or panel updates

1. Edit the target dashboard in Grafana UI (or edit JSON directly).
2. Export the full updated dashboard JSON from Grafana.
3. Save it to the matching source-controlled file:
   - `dashboards/consul-data-plane-health.json` or
   - `dashboards/consul-data-plane-performance.json`
4. Apply the operator manifests (Kustomize regenerates both ConfigMaps from JSON automatically):

```bash
oc apply -k openshift/grafana-dashboards
```

5. Sync to the live cluster when you want to update existing ConfigMaps in-place and request reconcile:

```bash
./scripts/sync-grafana-dashboards.sh
```

6. Commit JSON changes (and any intentional changes to the GrafanaDashboard CRs or kustomization).

If you skip steps 3-6, the next operator reconcile can overwrite your UI-only changes.

### Verify live reconciliation state

Check which JSON is currently stored in the live ConfigMaps:

```bash
oc get configmap consul-data-plane-health -n observability -o yaml
oc get configmap consul-data-plane-performance -n observability -o yaml
```

Check GrafanaDashboard reconcile status:

```bash
oc get grafanadashboard -n observability
oc get grafanadashboard consul-data-plane-health -n observability -o yaml
oc get grafanadashboard consul-data-plane-performance -n observability -o yaml
```

## Step 2: Update Consul Helm Values

Get your current values before editing:

```bash
helm get values consul -n consul -o yaml > values-current.yaml
cp values-current.yaml values.yaml
```

### What to configure

The `ui` section needs two things:

1. `metrics` — points the Consul agent's metrics proxy at your Prometheus instance
2. `dashboardURLTemplates.service` — a URL template for per-service Grafana deep links

### Common mistakes to avoid

**Do not use `ui.server.extraConfig`** — this key does not exist in the Consul Helm schema and silently does nothing. Any `ui_config` JSON placed there is dead configuration. The correct Helm keys are `ui.metrics` and `ui.dashboardURLTemplates`.

**Do not use Go template syntax** (`{{.Service}}`, `{{.Namespace}}`) in the URL template — the correct Consul placeholder syntax uses dot-notation without the leading dot: `{{Service.Name}}`, `{{Service.Namespace}}`, `{{Datacenter}}`.

**The metrics `baseURL` uses `http://`** not `https://`, even if your Consul server uses TLS. The `baseURL` is the Consul agent → Prometheus connection (internal cluster traffic), which is plain HTTP. The Consul server's TLS settings apply to a different set of connections.

### Correct `ui` configuration

Replace your `ui:` block in `values.yaml` with the following, substituting your actual Grafana route hostname and the `consul-service` dashboard UID:

```yaml
ui:
  enabled: true
  metrics:
    enabled: true
    provider: prometheus
    baseURL: http://prometheus-server.observability.svc.cluster.local
  dashboardURLTemplates:
    service: "https://<GRAFANA_ROUTE_HOSTNAME>/d/<CONSUL_SERVICE_UID>/consul-service?orgId=1&var-service={{Service.Name}}&var-namespace={{Service.Namespace}}&var-dc={{Datacenter}}"
```

For example, if your Grafana route is `grafana-observability.apps.rosa.cluster1.example.openshiftapps.com` and the consul-service UID is `hashicupsnm`:

```yaml
  dashboardURLTemplates:
    service: "https://grafana-observability.apps.rosa.cluster1.example.openshiftapps.com/d/hashicupsnm/consul-service?orgId=1&var-service={{Service.Name}}&var-namespace={{Service.Namespace}}&var-dc={{Datacenter}}"
```

### Remove deprecated TLS settings

If your `server.extraConfig` contains the older `verify_incoming`, `verify_outgoing`, and `verify_server_hostname` fields, replace them with the current non-deprecated equivalents. Also, if `verify_incoming: true` is set globally, the Consul UI will be inaccessible from a browser because it requires a client certificate. Use `verify_incoming_rpc` instead to scope mTLS enforcement to agent communication only:

```yaml
server:
  extraConfig: |
    {
      "verify_incoming_rpc": true,
      "verify_incoming_https": false,
      "verify_outgoing": true,
      "verify_server_hostname": true
    }
```

> **Note:** As of Consul 1.22, these fields are deprecated in favor of `tls.internal_rpc.verify_incoming`, `tls.https.verify_incoming`, etc. The deprecated fields still work but produce warnings in the logs. Migrating to the new `tls` block format is recommended for future upgrades.

## Step 3: Apply the Helm Upgrade

```bash
helm upgrade --values values.yaml consul hashicorp/consul --namespace consul
```

### Troubleshooting: `consul-gateway-resources` job conflict

If the upgrade fails with:

```
Error: UPGRADE FAILED: post-upgrade hooks failed: jobs.batch "consul-gateway-resources" already exists
```

Delete the stuck job and re-run:

```bash
kubectl delete job consul-gateway-resources -n consul
helm upgrade --values values.yaml consul hashicorp/consul --namespace consul
```

This happens when a previous upgrade left behind a hook job that wasn't cleaned up. It is safe to delete.

### Watch the rollout

```bash
kubectl get pods -n consul -w
```

Wait for `consul-server-0` to show `1/1 Running` and any `acl-init` jobs to complete before testing.

## Step 4: Restart Sidecar Proxies

The sidecar proxies in your application namespaces need to be restarted to pick up the updated metrics configuration:

```bash
# Replace with your application namespace(s)
kubectl rollout restart deployment --namespace <your-app-namespace>
```

Prometheus will then begin scraping the `/metrics` endpoint on port `20200` for all proxy sidecars. Confirm the scrape annotations are present on your app pods:

```bash
kubectl get pods -n <your-app-namespace> -o yaml | grep prometheus
```

You should see annotations like:

```yaml
prometheus.io/scrape: "true"
prometheus.io/path: /metrics
prometheus.io/port: "20200"
```

## Step 5: Access the Consul UI

The Consul UI is exposed via an OpenShift Route with TLS passthrough:

```bash
oc get route -n consul
```

Open the `consul-ui` route hostname in your browser (HTTPS). You will be prompted to log in with an ACL token. Retrieve the bootstrap token:

```bash
kubectl get secret consul-bootstrap-acl-token -n consul \
  -o jsonpath='{.data.token}' | base64 -d && echo
```

### Verifying the UI is reachable

Before opening in a browser, confirm the TLS handshake succeeds:

```bash
curl -k -s -o /dev/null -w "%{http_code}" \
  https://<consul-ui-route-hostname>
```

A `200` response confirms the UI is up. If you get `SSL_ERROR_SYSCALL` or a connection reset, `verify_incoming_https` is likely still set to `true` — re-check your `server.extraConfig` and re-apply.

## Step 6: Verify Metrics and Deep Links in the Topology View

1. In the Consul UI, navigate to **Services** and select a service that has a sidecar proxy
2. Click the **Topology** tab
3. You should see metrics (request rate, error rate, latency) displayed on the service nodes
4. You should see an **"Open Dashboard"** button that opens the Grafana `consul-service` dashboard pre-filtered to that service

> **Note:** Metrics take a few minutes to populate after enabling. Generate some traffic to your services if the graphs appear empty.

If metrics are not appearing:

```bash
# Check Prometheus is scraping your services
kubectl port-forward svc/prometheus-server -n observability 9090:80
# Then open http://localhost:9090/targets and look for your service pods
```

If the "Open Dashboard" button is missing, the `dashboardURLTemplates` was not applied correctly. Verify with:

```bash
kubectl exec consul-server-0 -n consul -- \
  consul config read -kind proxy-defaults -name global 2>/dev/null || \
  kubectl exec consul-server-0 -n consul -- \
  curl -sk https://localhost:8501/v1/agent/self \
  -H "X-Consul-Token: $(kubectl get secret consul-bootstrap-acl-token -n consul -o jsonpath='{.data.token}' | base64 -d)" \
  | python3 -m json.tool | grep -A5 "dashboard_url"
```

## Fixing the `prometheus-operator` ACL Errors

After completing the above, you may see repeated errors in the Consul server logs like:

```
Permission denied: token with AccessorID '...' lacks permission 'service:write' on "prometheus-operator"
```

This happens because the `prometheus-operator` pod was injected into the Consul service mesh without a proper ACL token. Since it does not need to be part of the mesh, exclude it from injection:

```bash
kubectl annotate deployment prometheus-operator \
  -n observability \
  "consul.hashicorp.com/connect-inject=false" \
  --overwrite

kubectl rollout restart deployment prometheus-operator -n observability
```

This stops the sidecar from being injected into the prometheus-operator pod, which eliminates the ACL errors and removes an unnecessary mesh participant.

## Summary of Key Configuration

The complete set of changes to `values.yaml` relative to a base install:

```yaml
global:
  metrics:
    enabled: true
    enableAgentMetrics: true
    enableGatewayMetrics: true
    agentMetricsRetentionTime: 60s

connectInject:
  metrics:
    defaultEnabled: true

ui:
  enabled: true
  metrics:
    enabled: true
    provider: prometheus
    baseURL: http://prometheus-server.observability.svc.cluster.local
  dashboardURLTemplates:
    service: "https://<GRAFANA_ROUTE>/d/<CONSUL_SERVICE_DASHBOARD_UID>/consul-service?orgId=1&var-service={{Service.Name}}&var-namespace={{Service.Namespace}}&var-dc={{Datacenter}}"

server:
  extraConfig: |
    {
      "verify_incoming_rpc": true,
      "verify_incoming_https": false,
      "verify_outgoing": true,
      "verify_server_hostname": true
    }
```
