# Service mesh básico sobre GKE (Módulo A)

Cloud Service Mesh gestionado (Anthos) tiene cargos de fleet management que
no se justifican para este laboratorio. Se usa en su lugar **Istio open
source** sobre el mismo clúster GKE que ya provisiona
`iac/terraform/gcp/main.tf` -- funcionalmente equivalente para lo que pide
el Módulo A (observabilidad de red L7: mTLS automático entre pods, métricas
por request de Envoy, trazas de proxy) sin costo de control plane adicional
sobre el clúster ya presupuestado.

Se instala con `istioctl` (el método soportado por el propio proyecto
Istio), NO como recursos de Terraform: los Helm charts oficiales de Istio
(`base`, `istiod`, `gateway`) cambian de esquema entre versiones con más
frecuencia de lo que vale la pena perseguir con el proveedor `helm` de
Terraform para un laboratorio -- `istioctl install` es el camino oficial,
más simple, y el que la propia documentación de Istio recomienda validar
primero con `istioctl analyze` antes de aplicar.

## Prerequisitos

```bash
gcloud container clusters get-credentials <cluster_name> --region <region> --project <project_id>
# (el comando exacto sale de: terraform output get_credentials_command)

curl -L https://istio.io/downloadIstio | sh -
export PATH="$PWD/istio-<version>/bin:$PATH"
```

## Instalación (perfil `demo`: incluye ingress/egress gateway, apto para ver
## todo el mesh funcionando; para producción usar el perfil `default`)

```bash
istioctl x precheck                 # valida ANTES de instalar -- responde
                                     # directamente al pedido de "no correr
                                     # y que no funcione" del runbook general
istioctl install --set profile=demo -y
```

El label `istio-injection=enabled` del namespace ya lo declara
`kubernetes_namespace.app` en `iac/terraform/gcp/main.tf` -- no hace falta
ponerlo a mano con `kubectl label`. Hallazgo real (2026-08-30): un
`kubectl label ... --overwrite` manual SÍ funciona al momento, pero el
provider `hashicorp/kubernetes` trata `metadata.labels` como el mapa
completo y autoritativo -- el siguiente `terraform apply` (aunque sea por
un cambio sin relación con Istio) se lo come sin avisar. Por eso quedó
declarado en el propio `.tf`: sobrevive a cualquier `apply` futuro.

```bash
# Reinicia los Deployments para que el sidecar de Envoy se inyecte
# (la inyección automática solo aplica a pods NUEVOS después del label):
kubectl rollout restart deployment -n observability-lab service-a service-b data-service otel-collector postgres
```

## mTLS estricto entre los 3 microservicios

```bash
kubectl apply -f iac/istio/peer-authentication-strict-mtls.yaml
kubectl apply -f iac/istio/destination-rules.yaml
```

## Verificación

```bash
istioctl proxy-status                        # todos los pods deben verse SYNCED
kubectl exec deploy/service-a -n observability-lab -c istio-proxy -- \
  pilot-agent request GET stats/prometheus | grep istio_requests_total

# Kiali (opcional, visualización del mesh):
istioctl dashboard kiali
```

## Desinstalación (parte del runbook de cierre de ventana de despliegue)

```bash
istioctl uninstall --purge -y
kubectl delete namespace istio-system
```
