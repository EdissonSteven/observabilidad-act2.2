# Runbook 2 -- Módulo B: AIOps y correlación

> **Alcance de esta entrega: solo GCP.** Los comandos de AWS (CloudWatch)
> en el Paso 2 y Paso 3 quedan documentados como diseño de referencia, no
> se ejecutan.

## Paso 1 -- Validar el MQL de GCP contra datos reales ANTES de aplicar la alerta

La consulta MQL en `iac/terraform/gcp/monitoring_aiops.tf` es un borrador
sin probar contra una consola real (ver la advertencia en ese archivo).
Con el clúster ya desplegado (Runbook 1) y tráfico real corriendo:

```bash
# Genera tráfico de fondo unos minutos para que existan datos
python3 chaos/load_gen.py --url http://<ip-o-alb>/orders/ord-1002 --duration 300 --out /tmp/warmup.csv
```

En Cloud Console -> Monitoring -> Metrics Explorer -> modo MQL, pega la
consulta de la primera condición de `correlated_degradation` (sin el
`terraform apply` todavía). Si no corre tal cual:
1. Usa el autocompletado de la consola para encontrar el nombre real de la
   métrica (`prometheus.googleapis.com/http_requests_total/...` puede
   variar según cómo Managed Prometheus la registró).
2. Ajusta la sintaxis en el editor hasta que la consulta devuelva datos
   sensatos.
3. Copia la versión que SÍ funciona de vuelta a `monitoring_aiops.tf`
   antes de aplicar la alerta.

## Paso 2 -- Aplicar las alertas (GCP)

```bash
cd iac/terraform/gcp && terraform apply -var project_id=<tu-project-id> -var alert_notification_email=<tu-email> -target=google_monitoring_alert_policy.correlated_degradation -target=google_monitoring_alert_policy.naive_static_threshold
```

(El bloque equivalente de AWS -- `aws_cloudwatch_metric_alarm.*`,
`aws_cloudwatch_composite_alarm.correlated_degradation` -- no se aplica en
esta entrega; queda como diseño en `iac/terraform/aws/cloudwatch_aiops.tf`.)

## Paso 3 -- Demostrar la reducción de alertas ruidosas

Con ambas alertas de GCP activas (la correlacionada y la ingenua
estática), corre tráfico con algo de ruido de fondo normal (sin caos)
durante ~10 min y cuenta cuántas veces disparó cada una:

```bash
# Cloud Console -> Monitoring -> Alerting -> filtrar por policy, contar incidentes
```

Anota en el reporte: N disparos de la ingenua vs. M de la correlacionada
sobre la MISMA ventana de tráfico -- esa diferencia (N > M) es la
"reducción de alertas ruidosas" que pide el Módulo B, con datos reales, no
estimados.

## Paso 4 -- Ejecutar el experimento de caos y confirmar que la correlacionada SÍ dispara

Ver Runbook 4 (Módulo D) -- los experimentos de caos son el estímulo real
que debe hacer disparar `correlated_degradation`/`CorrelatedDegradation`.
Este runbook (B) se enfoca en tener la alerta lista; el runbook de Módulo D
mide el MTTD real.

## Evidencia a capturar

- Query MQL validada (captura de la consola, no solo el código).
- Conteo de disparos: alerta ingenua vs. correlacionada, misma ventana.
- Captura del incidente de Cloud Monitoring con el trace_id enlazado
  (Cloud Logging).
