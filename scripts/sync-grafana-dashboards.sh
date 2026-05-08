#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-observability}"
DASHBOARD_DIR="${DASHBOARD_DIR:-./dashboards}"

sync_dashboard() {
  local cm_name="$1"
  local key_name="$2"
  local file_path="$3"
  local gd_name="$4"

  if [[ ! -f "$file_path" ]]; then
    echo "ERROR: dashboard JSON file not found: $file_path" >&2
    exit 1
  fi

  echo "Updating ConfigMap/${cm_name} from ${file_path}..."
  oc create configmap "$cm_name" \
    -n "$NAMESPACE" \
    --from-file="${key_name}=${file_path}" \
    --dry-run=client -o yaml | oc apply -f -

  local epoch="$(date +%s)"

  echo "Requesting resync for GrafanaDashboard/${gd_name}..."
  oc annotate grafanadashboard "$gd_name" \
    -n "$NAMESPACE" \
    resync-requested="$epoch" \
    --overwrite >/dev/null

  echo "Done: ConfigMap/${cm_name} and GrafanaDashboard/${gd_name}"
  echo
}

sync_dashboard \
  "consul-data-plane-health" \
  "consul-data-plane-health.json" \
  "${DASHBOARD_DIR}/consul-data-plane-health.json" \
  "consul-data-plane-health"

sync_dashboard \
  "consul-data-plane-performance" \
  "consul-data-plane-performance.json" \
  "${DASHBOARD_DIR}/consul-data-plane-performance.json" \
  "consul-data-plane-performance"

echo "All dashboard ConfigMaps updated and reconciliation requested."
echo "Verify with: oc get grafanadashboard -n ${NAMESPACE}"
