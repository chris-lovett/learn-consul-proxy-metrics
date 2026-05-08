# Grafana Operator dashboards

This directory contains Grafana Operator `GrafanaDashboard` custom resources converted from `dashboards/grafana-platform-dashboards.yaml`.

## Notes

- Namespace: `observability`
- Folder: `Platform`
- Instance selector label:

```yaml
instanceSelector:
  matchLabels:
    dashboards: grafana
```

- Source file: `dashboards/grafana-platform-dashboards.yaml`
- Conversion is in progress. Additional dashboard CRs can be added here as the full source dashboards are split out.
