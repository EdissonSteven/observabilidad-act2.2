# Runbook 5 -- Cierre de la ventana de despliegue (obligatorio)

No dejes recursos de nube corriendo entre sesiones de trabajo -- los
\$300 de crédito de GCP no están pensados para correr indefinidamente.
Cierra la ventana apenas termines de capturar la evidencia del runbook
que estabas ejecutando.

## AWS -- no aplica en esta entrega

No se ejecutó ningún `terraform apply` en AWS (alcance GCP-only, ver
`docs/reporte-ejecutivo-final.md`), así que no hay nada que destruir ahí.
Si en algún momento cambias de decisión y aplicas algo en AWS, entonces sí
corre `cd iac/terraform/aws && terraform destroy` y confirma en la
Consola de AWS (ECS, EC2 -> Load Balancers, RDS, ECR, S3) que no quedó
nada huérfano.

## GCP

```bash
istioctl uninstall --purge -y   # si se instaló Istio
kubectl delete namespace istio-system

cd iac/terraform/gcp
terraform destroy
```

Confirmar en la Consola de GCP (Kubernetes Engine, SQL, VPC network) que
no quedó nada huérfano -- en particular la conexión de peering privado de
Cloud SQL (`google_service_networking_connection`) a veces requiere una
segunda pasada de `destroy` si Cloud SQL no terminó de borrarse a tiempo
en la primera.

## Checklist final antes de cerrar la ventana

- [ ] `terraform destroy` sin errores en GCP
- [ ] Confirmado $0 en recursos activos en la Consola de GCP (no solo
      confiar en la salida de `destroy`)
- [ ] Toda la evidencia (CSV, capturas, salidas de comandos) ya copiada
      fuera de cualquier recurso que se vaya a borrar
- [ ] Crédito restante de GCP anotado (para saber cuánto margen queda
      para la siguiente ventana, si hace falta repetir algo)
- [ ] Confirmado que no se aplicó nada en AWS (N/A por decisión de alcance)
