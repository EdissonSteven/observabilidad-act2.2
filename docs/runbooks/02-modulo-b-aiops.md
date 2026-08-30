# Runbook 2 -- Módulo B: AIOps y correlación

> **Alcance de esta entrega: solo GCP.** Los comandos de AWS (CloudWatch)
> en el Paso 2 y Paso 3 quedan documentados como diseño de referencia, no
> se ejecutan.

## Paso 0 -- Prerrequisito real descubierto en este laboratorio: habilitar el scrape de Managed Prometheus

Hallazgo real (2026-08-30): con el clúster, las 3 apps y hasta 1286
requests reales de tráfico ya corridos, la query MQL de abajo seguía
devolviendo `Could not find a metric named
'prometheus.googleapis.com/http_requests_total/counter'` y "No hay datos
disponibles" en la consola. Causa raíz: Google Managed Prometheus viene
habilitado por defecto en el clúster (confirmado con `kubectl get crd |
grep monitoring.googleapis.com`), pero sin un recurso `PodMonitoring` que
le diga qué scrapear, nunca colecta nada -- no importa cuánto tráfico se
genere. Ver `iac/gmp/README.md` para el detalle completo.

Antes de seguir con el Paso 1, aplica esto UNA VEZ (ya viene con el
`terraform apply` de Runbook 1, que ahora nombra el puerto 8889 del
otel-collector):

```bash
kubectl apply -f iac/gmp/podmonitoring-otel-collector.yaml
```

Dale ~2-3 min después de generar tráfico antes de validar en consola (el
scraping directo es más rápido que el delay de ~10 min de las métricas
basadas en logs, pero no es instantáneo).

## Paso 1 -- Validar el MQL de GCP contra datos reales ANTES de aplicar la alerta

Las 3 alert policies que dependen de métricas de aplicación
(`correlated_degradation`, `correlated_degradation_data_service`,
`naive_static_threshold`) están gateadas detrás de
`var.deploy_aiops_correlation_alerts` (default `false`) precisamente para
forzar este paso -- el primer `terraform apply` real (2026-08-29) confirmó
que sin esto fallan con "Could not find a metric": Google Managed
Prometheus no registra el descriptor de una métrica hasta que llega el
primer dato real (y, como se documentó arriba, hasta que existe el
`PodMonitoring`). Además, las 2 policies de correlación ahora son UNA sola
consulta MQL cada una (la API de GCP no permite más de 1 condition por
policy cuando el tipo es `condition_monitoring_query_language` -- ver la
cabecera de `iac/terraform/gcp/monitoring_aiops.tf`), escrita combinando
ambas señales con la sintaxis oficial de fan-out `{ ; } | join`, pero
**sin poder probarla contra una consola real todavía** -- confírmalo aquí
antes de confiar en ella.

Nota (2026-08-30): MQL ya no es el modo recomendado por Google para
paneles/alertas nuevas (soporte de escritura de queries terminado en
julio 2025, ver banner de la propia consola) -- PromQL es lo que
recomiendan ahora. Las policies de este repo siguen en MQL porque ya
estaban escritas y crearlas vía Terraform/API sigue funcionando sin
problema; se documenta como riesgo conocido de obsolescencia a futuro,
no como algo que haya que migrar para esta entrega.

Con el clúster y las 3 apps ya desplegados (Runbook 1, con
`deploy_aiops_correlation_alerts` en su default `false`) y tráfico real
corriendo:

```bash
# Genera tráfico de fondo unos minutos para que existan datos
python3 chaos/load_gen.py --url http://<ip-o-alb>/orders/ord-1002 --duration 300 --out /tmp/warmup.csv
```

En Cloud Console -> Monitoring -> Metrics Explorer -> modo MQL, pega la
consulta completa de `correlated_degradation` (la de
`correlated_degradation_data_service` es análoga, cambiando la métrica y
el filtro de `outcome`). Si no corre tal cual:
1. Usa el autocompletado de la consola para encontrar el nombre real de la
   métrica (`prometheus.googleapis.com/http_requests_total/...` puede
   variar según cómo Managed Prometheus la registró).
2. Ajusta la sintaxis en el editor hasta que la consulta devuelva el
   booleano combinado esperado (revisa en particular si
   `mean_prev_by`/`stddev_prev_by` aplicados antes del `join` y el `&&`
   final tras el `join` se comportan como se espera -- es la parte del
   archivo marcada como no probada).
3. Copia la versión que SÍ funciona de vuelta a `monitoring_aiops.tf`
   antes de aplicar la alerta. Si el `join`/`&&` combinado simplemente no
   funciona pese a ajustes, el fallback documentado y honesto es volver a
   2 policies independientes (una MQL para error_rate, otra
   `condition_threshold` para latency) sin AND real entre ellas -- deja
   constancia en el reporte de cuál de las dos versiones se terminó
   aplicando y por qué.

## Paso 2 -- Aplicar las alertas (GCP)

```bash
cd iac/terraform/gcp
terraform apply -var project_id=<tu-project-id> -var alert_notification_email=<tu-email> -var deploy_aiops_correlation_alerts=true
```

Esto crea (o actualiza) las 3 policies gateadas -- `correlated_degradation`,
`correlated_degradation_data_service` y `naive_static_threshold` -- sin
tocar el resto del stack (ya aplicado en Runbook 1). No hace falta
`-target`: al pasar el flag en `true`, esas 3 son las únicas que cambian
de `count = 0` a `count = 1` en el plan.

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
