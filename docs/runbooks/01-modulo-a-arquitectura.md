# Runbook 1 -- Módulo A: desplegar la arquitectura completa

Requiere haber pasado el Runbook 0 (`plan` limpio en GCP). **Alcance de
esta entrega: solo GCP** -- la sección "AWS" de abajo NO se ejecuta, se
deja como referencia del diseño equivalente ya escrito y validado
sintácticamente (ver decisión de alcance en `docs/reporte-ejecutivo-final.md`).

## AWS -- NO EJECUTAR (diseño de referencia, no desplegado en esta entrega)

```bash
cd iac/terraform/aws

# 1. Primero SIN RDS ni App Mesh -- confirma que el resto del stack (igual
#    a la Actividad 2.2 + data-service en Fargate) funciona con el LabRole.
terraform apply -var deploy_rds=false -var enable_app_mesh=false

# 2. Construir y subir las 3 imágenes (incluye data-service, nuevo)
ACCOUNT_ID=$(terraform output -raw account_id)
REGION=us-east-1
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
for svc in service-a service-b data-service; do
  docker build -t $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/observability-lab/$svc:latest ../../../services/$svc
  docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/observability-lab/$svc:latest
done
terraform apply -var deploy_rds=false -var enable_app_mesh=false   # fuerza el redeploy con las imágenes reales

curl http://$(terraform output -raw alb_dns_name)/orders/ord-1002 | jq
# "customer" debe venir poblado -- confirma que data-service -> Postgres-on-Fargate funciona

# 3. Ahora SÍ con RDS real (Módulo A: "acceda a ... AWS RDS")
terraform apply -var enable_app_mesh=false
# Verifica que data-service ahora lee de RDS, no del Postgres-on-Fargate:
aws rds describe-db-instances --db-instance-identifier observability-lab-customers --query 'DBInstances[0].DBInstanceStatus'
curl http://$(terraform output -raw alb_dns_name)/orders/ord-1002 | jq   # debe seguir funcionando igual desde el punto de vista del cliente

# 4. App Mesh -- SOLO si el preflight (Runbook 0) confirmó la política AppMesh en LabRole
terraform apply -var enable_app_mesh=true
istioctl_equivalent="aws appmesh"   # (no hay istioctl en AWS; verificar así)
aws appmesh list-virtual-nodes --mesh-name observability-lab-mesh
# Si el apply falla con AccessDenied en algo relacionado a AppMesh:
terraform apply -var enable_app_mesh=false   # revierte, documenta el intento y el error real en el reporte -- NO se inventa evidencia
```

## GCP -- ejecutar esto (única nube real de esta entrega)

```bash
cd iac/terraform/gcp

terraform apply -var project_id=<tu-project-id>
# Este apply es más largo (GKE + Cloud SQL + peering privado pueden tardar
# 10-15 min la primera vez) -- normal, no lo interrumpas.

$(terraform output -raw get_credentials_command)

ARTIFACT_URL=$(terraform output -raw artifact_registry_url)
gcloud auth configure-docker ${ARTIFACT_URL%%/*}
for svc in service-a service-b data-service; do
  docker build -t $ARTIFACT_URL/$svc:latest ../../../services/$svc
  docker push $ARTIFACT_URL/$svc:latest
done
kubectl rollout restart deployment -n observability-lab service-a service-b data-service

kubectl get pods -n observability-lab   # todos Running
kubectl port-forward -n observability-lab svc/service-a 8000:8000 &
curl http://localhost:8000/orders/ord-1002 | jq

# Istio (ver iac/istio/README.md para el detalle completo)
istioctl x precheck
istioctl install --set profile=demo -y
kubectl label namespace observability-lab istio-injection=enabled --overwrite
kubectl rollout restart deployment -n observability-lab service-a service-b data-service
kubectl apply -f ../../istio/peer-authentication-strict-mtls.yaml
kubectl apply -f ../../istio/destination-rules.yaml
istioctl proxy-status   # todos SYNCED
```

## Evidencia a capturar para el reporte (Módulo A)

- Captura de `curl .../orders/{id}` con `customer` poblado, en GCP.
- Trace en Cloud Trace/Jaeger mostrando los 3 spans con atributos
  `db.system.name`/`db.namespace`/`db.operation.name` de data-service.
- `gcloud sql instances describe` (Cloud SQL realmente corriendo).
- `istioctl proxy-status` (todos `SYNCED`).
- (AWS: no aplica evidencia de ejecución en esta entrega -- el `.tf` en
  `iac/terraform/aws/` es la evidencia de diseño.)
