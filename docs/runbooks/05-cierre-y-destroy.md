# Runbook 5 -- Cierre de la ventana de despliegue (obligatorio)

No dejes recursos de nube corriendo entre sesiones de trabajo -- ni el
Learner Lab de \$19 ni los \$300 de crédito de GCP están pensados para
correr indefinidamente. Cierra la ventana apenas termines de capturar la
evidencia del runbook que estabas ejecutando.

## AWS

```bash
cd iac/terraform/aws
terraform destroy
```

Confirmar en la Consola de AWS (ECS, EC2 -> Load Balancers, RDS, ECR,
S3 -> bucket de flow logs) que no quedó nada huérfano, especialmente si
algún `apply`/`destroy` se interrumpió a mitad de camino. El Learner Lab
además puede resetear el ambiente completo al final de la sesión de
laboratorio -- no dependas de que los recursos sobrevivan entre sesiones
de AWS Academy.

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

- [ ] `terraform destroy` sin errores en AWS
- [ ] `terraform destroy` sin errores en GCP
- [ ] Confirmado $0 en recursos activos en ambas consolas (no solo
      confiar en la salida de `destroy`)
- [ ] Toda la evidencia (CSV, capturas, salidas de comandos) ya copiada
      fuera de cualquier recurso que se vaya a borrar
- [ ] Crédito/presupuesto restante anotado (para saber cuánto margen queda
      para la siguiente ventana, si hace falta repetir algo)
