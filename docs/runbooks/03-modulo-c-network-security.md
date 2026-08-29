# Runbook 3 -- Módulo C: Network & Security Observability

> **Alcance de esta entrega: solo GCP.** La sección "AWS" queda documentada
> como diseño de referencia (misma lógica de consulta, distinto motor);
> no se ejecuta.

## AWS -- NO EJECUTAR -- consultar VPC Flow Logs desde S3 con Athena (diseño de referencia)

```bash
BUCKET=$(cd iac/terraform/aws && terraform output -raw vpc_flow_logs_bucket)

aws athena start-query-execution \
  --query-string "CREATE EXTERNAL TABLE IF NOT EXISTS vpc_flow_logs (
    version int, account_id string, interface_id string, srcaddr string,
    dstaddr string, srcport int, dstport int, protocol bigint, packets bigint,
    bytes bigint, start bigint, \`end\` bigint, action string, log_status string
  )
  PARTITIONED BY (year string, month string, day string, hour string)
  STORED AS PARQUET
  LOCATION 's3://${BUCKET}/AWSLogs/'
  " \
  --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/"

# Repara particiones y consulta tráfico rechazado
aws athena start-query-execution --query-string "MSCK REPAIR TABLE vpc_flow_logs" --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/"
aws athena start-query-execution --query-string "SELECT srcaddr, dstport, COUNT(*) FROM vpc_flow_logs WHERE action='REJECT' GROUP BY 1,2 ORDER BY 3 DESC LIMIT 20" --result-configuration "OutputLocation=s3://${BUCKET}/athena-results/"
```

Revisa el resultado con `aws athena get-query-results --query-execution-id <id>`.

## GCP -- ejecutar esto -- confirmar el log-based metric y el dashboard

```bash
# Genera algo de tráfico que dispare la regla deny-all-logged (por ejemplo,
# un puerto no expuesto por ningún Service):
kubectl run probe --image=busybox --rm -it --restart=Never -- wget -T 2 http://10.20.0.1:9999 || true

gcloud logging read 'jsonPayload.disposition="DENIED"' --project <tu-project-id> --limit 10

# Dashboard: Cloud Console -> Monitoring -> Dashboards -> "<cluster_name> - Golden Signals de Seguridad"
```

## GCP -- confirmar el resultado del preflight sobre Security Command Center

Revisa la salida de `scripts/gcp_preflight_check.sh` del Runbook 0. Si
confirma que SCC no está disponible (esperado en cuenta individual sin
Organización), el reporte documenta esto como brecha explícita (ya
redactado en `docs/madurez-observabilidad.md`, dominio 5) -- no hace falta
reintentar. (El equivalente `scripts/aws_preflight_check.sh` no se
ejecuta en esta entrega -- alcance GCP-only.)

## Evidencia a capturar

- Captura del log-based metric de GCP con datos reales (aunque sea 0
  filas de tráfico rechazado -- eso también es un resultado válido si no
  hubo tráfico anómalo durante la ventana).
- Captura del dashboard "Golden Signals de Seguridad" en GCP.
- Salida completa (copiada, no resumida) de `scripts/gcp_preflight_check.sh`,
  como evidencia de qué se intentó y qué se documentó como brecha.
- (AWS: la consulta Athena y su script de preflight quedan como diseño no
  ejecutado -- citar el `.tf`/script, no inventar un resultado.)
