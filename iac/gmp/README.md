# Google Managed Prometheus -- scrape config (Módulo A/B)

Hallazgo real de este laboratorio (2026-08-30): Google Managed Prometheus
(managed collection) viene HABILITADO POR DEFECTO en el clúster GKE de
este proyecto (confirmado con `kubectl get crd | grep
monitoring.googleapis.com` -- los CRDs `podmonitorings.monitoring.
googleapis.com`, `clusterpodmonitorings...`, etc. ya existen sin que este
repo tuviera que activar nada en `google_container_cluster`), pero sin un
recurso `PodMonitoring` que le diga explícitamente QUÉ pod y puerto
scrapear, no colecta nada -- confirmado en la consola real de Cloud
Monitoring: con tráfico real ya generado (1286 requests, 0 errores), la
query MQL `fetch prometheus_target | metric
'prometheus.googleapis.com/http_requests_total/counter'` devolvía
`Could not find a metric named ...` y "No hay datos disponibles".

Esto bloqueaba por completo el Paso 1 del Módulo B
(`docs/runbooks/02-modulo-b-aiops.md`): sin este scrape, las 3 alert
policies gateadas de `iac/terraform/gcp/monitoring_aiops.tf`
(`correlated_degradation`, `correlated_degradation_data_service`,
`naive_static_threshold`) nunca iban a encontrar la métrica sin importar
cuánto tráfico se generara.

## Por qué es YAML aparte y no un recurso de Terraform

Mismo patrón y misma razón que `iac/istio/` (ver su README): el recurso
`kubernetes_manifest` del provider `hashicorp/kubernetes` sí existe y sí
soporta CRDs arbitrarios, pero sigue siendo beta y es conocido en la
comunidad por ser frágil con el schema de recursos -- justo el tipo de
sorpresa que ya tuvimos en este mismo laboratorio con el bug real
"Unexpected Identity Change" de `kubernetes_deployment` tras un
`terraform init -upgrade`. Para un CRD que además ya viene preinstalado
por GKE (no lo crea este repo), `kubectl apply` de un YAML plano es más
simple, más predecible, y es el método que la propia documentación de
Google Managed Prometheus usa en sus ejemplos.

## Requisito real verificado

`PodMonitoring.spec.endpoints[].port` debe ser un **puerto de contenedor
con nombre**, no un número (confirmado contra la documentación oficial de
GKE/Managed Prometheus) -- por eso `iac/terraform/gcp/main.tf` nombra el
puerto 8889 del otel-collector como `prom-metrics` (el puerto que expone
el exporter `prometheus` de `otel-collector/collector-config.gcp.yaml`).

## Aplicar

```bash
kubectl apply -f iac/gmp/podmonitoring-otel-collector.yaml
```

## Verificar

```bash
# El propio operador de Managed Prometheus expone su estado de scrape:
kubectl get podmonitoring -n observability-lab otel-collector -o yaml

# En Cloud Monitoring -> Metrics Explorer (PromQL o MQL), unos ~2-3 min
# después de aplicar (más rápido que el delay de métricas basadas en
# logs, porque esto es scraping directo, no un log-based metric):
#   rate(http_requests_total[1m])
```

## Nota (limpieza opcional, no bloqueante)

Con este fix, el otel-collector ya no usa el exporter `googlecloud` para
métricas (ver el comentario en `collector-config.gcp.yaml`), por lo que
el rol `roles/monitoring.metricWriter` que le dimos vía
`google_project_iam_member.otel_collector_monitoring` (`main.tf`) queda
sin uso real -- el scraping de Managed Prometheus lo hace el propio
componente gestionado de Google, con sus propias credenciales, no con la
Service Account del otel-collector. No se retiró ese permiso en este fix
para no mezclar dos cambios distintos en el mismo `apply`; queda anotado
como limpieza de "least privilege" para una pasada posterior.
