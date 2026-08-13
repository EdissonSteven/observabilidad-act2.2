# otel-collector Helm chart

A minimal, hand-written chart (not the community `opentelemetry-collector`
chart) that deploys a single OTel Collector `Deployment` + `Service` +
`ConfigMap`, to demonstrate the Helm mechanics (values, templates, helpers,
NOTES) rather than depend on a pre-built chart.

It is an alternative/complement to the `kubernetes_deployment`/
`kubernetes_service` collector resources already provisioned by
`iac/terraform/gcp` — use whichever fits: apply the Terraform GKE module
end-to-end (cluster + workloads in one `apply`), or provision just the
cluster with Terraform and manage the collector's lifecycle independently
with this chart (e.g. faster iteration on collector config without touching
cluster infra state).

## Install

```bash
helm install otel-collector ./iac/helm/otel-collector \
  -n observability --create-namespace
```

## Override values

Common overrides, either via `--set` or a values file:

```bash
# Point exporters at a real Tempo/Prometheus backend instead of the placeholder
helm install otel-collector ./iac/helm/otel-collector \
  -n observability --create-namespace \
  --set-string config.exporters.otlp.endpoint=tempo.observability.svc.cluster.local:4317

# Expose OTLP outside the cluster
helm install otel-collector ./iac/helm/otel-collector \
  -n observability --create-namespace \
  --set service.type=LoadBalancer

# Or maintain a values file
helm install otel-collector ./iac/helm/otel-collector \
  -n observability --create-namespace \
  -f my-values.yaml
```

## Upgrade / uninstall

```bash
helm upgrade otel-collector ./iac/helm/otel-collector -n observability
helm uninstall otel-collector -n observability
```

## Verify

```bash
kubectl -n observability get pods,svc -l app.kubernetes.io/name=otel-collector
kubectl -n observability port-forward svc/otel-collector 13133:13133
curl localhost:13133   # health_check extension
```
