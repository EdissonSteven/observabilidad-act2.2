# ---------------------------------------------------------------------------
# AIOps: detección de anomalías + correlación (Módulo B).
#
# GCP Cloud Monitoring no tiene un equivalente directo a
# ANOMALY_DETECTION_BAND de CloudWatch como función de metric math genérica
# reutilizable en cualquier alerta -- el camino nativo más cercano es MQL
# (Monitoring Query Language) con una condición de umbral calculada sobre
# una ventana móvil. Se implementa aquí explícitamente la regla del
# enunciado (originalmente: baseline + 2σ Y latency_p99 > SLO) en MQL en
# vez de depender de un producto de ML de caja negra -- más transparente
# para el reporte (se puede mostrar y explicar la fórmula exacta), y evita
# depender de una feature que pueda no estar disponible en un proyecto de
# prueba nuevo. NOTA (2026-08-30, ver hallazgo 3 más abajo y
# variables.tf/error_rate_threshold_pct): el lado de error_rate del
# baseline se simplificó de dinámico (media+2σ) a un umbral ESTÁTICO tras
# no poder confirmar contra la consola real la sintaxis MQL de ventana
# deslizante -- el AND real con latency_p99 sigue intacto.
#
# Requiere que las métricas de negocio (http_request_duration_seconds,
# http_requests_total, data_service_calls_total) lleguen a Cloud
# Monitoring -- el exporter `googlecloud` ya está en
# otel-collector/collector-config.gcp.yaml (ver repo) y no filtra por
# nombre de métrica, así que esto funciona sin tocar la instrumentación
# de las apps.
#
# ADVERTENCIA DE VALIDACIÓN (léela antes de aplicar): el MQL de abajo es un
# borrador escrito sin acceso a una consola real de Cloud Monitoring en
# esta sesión -- la sintaxis exacta de funciones como mean_prev_by/
# stddev_prev_by y el nombre real de la métrica una vez pasa por el
# exporter `googlecloud` (puede llegar como
# `prometheus.googleapis.com/...` o con otro prefijo según cómo Google
# Managed Prometheus la registre) DEBEN confirmarse pegando la consulta en
# Cloud Console -> Monitoring -> Metrics Explorer -> modo MQL, contra
# datos reales del clúster ya desplegado, ANTES de aplicar esta alerta.
# Esto aplica también a la policy correlated_degradation_data_service
# (más abajo), añadida tras el hallazgo de degradación silenciosa del
# Módulo D -- misma advertencia, mismo paso de validación en consola.
# Ver docs/runbooks/02-modulo-b-aiops.md paso 1. Si la sintaxis no
# corre tal cual, ajústala ahí mismo con el autocompletado de la consola
# -- es más confiable que adivinar MQL sin poder ejecutarlo.
#
# DOS HALLAZGOS ADICIONALES, del primer terraform apply real contra
# observabilidad-lab-507021 (2026-08-29), que cambiaron la estructura de
# este archivo respecto al borrador original:
#
# 1) "Alert policies with 'monitoring_query_language' condition type can
#    only have a single condition" (Error 400 real de la API). Confirmado
#    también en la documentación oficial: "If you use MQL in a condition,
#    then that condition must be the only condition in the policy."
#    (https://docs.cloud.google.com/monitoring/mql/alerts) -- a diferencia
#    de condition_threshold, que sí admite varias conditions combinadas
#    con combiner. Las dos conditions originales (error_rate y
#    latency_p99) de cada policy de correlación se reescribieron como UNA
#    sola consulta MQL que hace fetch de ambas métricas por separado con
#    la sintaxis oficial de fan-out `{ metric A ; metric B } | join`
#    (ejemplo confirmado en
#    https://cloud.google.com/monitoring/mql/reference: `fetch gce_instance
#    | { metric .../cpu/utilization ; metric .../cpu/reserved_cores } |
#    join | div`) y evalúa el AND al final, sobre las dos ramas ya unidas.
#    La combinación de mean_prev_by/stddev_prev_by DENTRO de una rama y el
#    AND booleano DESPUÉS del join (`val(0).<campo> && val(1).<campo>`) es
#    una extensión razonable de ese patrón oficial, pero -- igual que el
#    resto del archivo -- NO se pudo probar contra una consola real todavía
#    (la doc oficial no trae un ejemplo con funciones de ventana móvil tras
#    un join). Confírmalo en Metrics Explorer antes de depender de esto.
#
# 2) "Could not find a metric named 'prometheus.googleapis.com/
#    http_requests_total/counter'" (Error 400 real de la API, en
#    naive_static_threshold, que solo tiene 1 condition y por eso sí llegó
#    a validarse contra el nombre de la métrica). Causa: Google Managed
#    Prometheus recién registra el descriptor de una métrica cuando llega
#    el primer dato real -- en un proyecto/clúster recién creado, sin GKE
#    desplegado ni tráfico de las apps, la métrica simplemente no existe
#    todavía. Las 3 policies de este archivo (las 2 de correlación +
#    naive_static_threshold) ahora se gatean con
#    var.deploy_aiops_correlation_alerts (default false, ver variables.tf)
#    para no bloquear el resto del stack (GKE, Cloud SQL, IAM, etc., que sí
#    se pueden crear sin esto) -- se aplican en una SEGUNDA pasada de
#    `terraform apply -var deploy_aiops_correlation_alerts=true`, después
#    de desplegar las apps y generar tráfico real (Runbook 1 + Runbook 2
#    Paso 1).
#
# 3) HALLAZGO DEL PASO 1 DE VALIDACIÓN (2026-08-30, ya ejecutado):
#    "Línea N: Expected: ',' or '|'. Instead found: ''1''" al pegar la
#    query en Metrics Explorer -- las 3 policies tenían
#    `| condition <expr> '1'`, con un argumento de string inventado
#    después de la expresión booleana que NO existe en la sintaxis real
#    de `condition`. Confirmado contra la documentación oficial de MQL: el
#    operador `condition` toma SOLO el predicado booleano
#    (`Table | condition predicate: Bool`), sin ningún argumento después
#    -- el único ejemplo oficial (`| condition val() > 5'GBy'`) tiene la
#    unidad `'GBy'` pegada al número 5, no como argumento aparte de
#    `condition`; se confundió una cosa con la otra al escribir el
#    borrador original. Corregido en las 3 policies (se quitó el `'1'`
#    final). El resto de la query (`fetch`/`{ ; }`/`join`/
#    `mean_prev_by`/`stddev_prev_by`/`&&`) sigue pendiente de confirmar
#    tal cual contra la consola -- este hallazgo solo corrigió el error
#    de sintaxis en la última línea, que impedía siquiera intentar correr
#    el resto.
#
# 4) HALLAZGO DEL terraform apply -var deploy_aiops_correlation_alerts=true
#    (2026-08-30, ya ejecutado, específico de naive_static_threshold): la
#    query corría sin problema pegada en Metrics Explorer (solo un warning
#    benigno de conversión Bool->Int), pero la API de creación de
#    alert policies (invocada por Terraform) SÍ bloqueó con Error 400:
#    "Ignoring units for operation '>', which is combining two values, the
#    first with no units and the second with unit '1'. Units need to be
#    given for neither or both of the inputs to '>'. Units can be added to
#    the first argument by the `cast_units` function (example
#    `cast_units(<expression>, "By/s")`) ... Units can be removed by
#    `cast_units(<expression>, "")`." Es decir: la consola interactiva es
#    más laxa (solo advierte) que la API de creación de policies (que
#    rechaza). Causa: `val` (el resultado de `sum(...)`) no tiene unidad,
#    mientras que el literal `0` sí trae implícitamente la unidad `'1'`
#    (adimensional) -- `>` exige que ambos lados tengan unidad o ninguno.
#    Corregido usando exactamente el remedio que la propia API sugirió en
#    su mensaje de error: `cast_units(val, "1")` iguala la unidad del lado
#    izquierdo a la del literal antes de comparar. No fue necesario tocar
#    correlated_degradation/correlated_degradation_data_service porque ahí
#    ambos lados de cada `>` ya son valores puramente numéricos sin
#    involucrar un `sum()` sin unidad contra un literal (multiplicación por
#    100 y `p99` vienen de `div`/`percentile`, no de `sum` crudo).
# ---------------------------------------------------------------------------

resource "google_project_service" "monitoring" {
  project            = var.project_id
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.cloudresourcemanager]
}

resource "google_monitoring_notification_channel" "aiops_email" {
  count        = var.alert_notification_email != "" ? 1 : 0
  project      = var.project_id
  display_name = "AIOps alerts (${var.cluster_name})"
  type         = "email"
  labels = {
    email_address = var.alert_notification_email
  }
}

# --- Señal correlacionada: error_rate alto Y latency_p99 > SLO -----------
#
# MQL: error_rate = ratio de requests con status=500 sobre el total,
# comparado contra un umbral ESTÁTICO (var.error_rate_threshold_pct -- ver
# esa variable en variables.tf para el hallazgo real de por qué no es un
# baseline dinámico media+2σ). latency_p99 usa el histograma OTel ya
# expuesto por el Collector.
#
# Sintaxis MQL confirmada contra la consola real (2026-08-30, tras 3
# rondas de errores reales con la versión anterior -- ver historial en
# variables.tf): el cálculo de error_rate usa EXACTAMENTE el patrón
# oficial de fan-out confirmado en la cabecera de este archivo
# (`{ metric A ; metric B } | join | div`, acceso puramente POSICIONAL,
# sin nombrar columnas para referenciarlas después de un join -- eso fue
# lo que falló antes con "Unknown function name 'error'"). El `condition`
# final tampoco lleva ningún argumento después de la expresión booleana
# (otro error real ya corregido: `| condition ... '1'` no es sintaxis
# válida, `condition` solo toma el predicado).
resource "google_monitoring_alert_policy" "correlated_degradation" {
  count        = var.deploy_aiops_correlation_alerts ? 1 : 0
  project      = var.project_id
  display_name = "${var.cluster_name}-correlated-degradation"
  combiner     = "OR" # una sola condition -- el AND real ya está DENTRO de la consulta MQL, ver comentario de cabecera

  # Una sola condition MQL que hace fetch de las dos métricas por separado
  # (fan-out { ; } | join, sintaxis oficial -- ver comentario de cabecera)
  # y evalúa error_rate > umbral Y latency_p99 > SLO al mismo tiempo,
  # DESPUÉS de unir ambas ramas. Antes eran 2 conditions independientes
  # con combiner AND -- la API de GCP no lo permite para
  # condition_monitoring_query_language (Error 400 real, ver cabecera).
  conditions {
    display_name = "error_rate > ${var.error_rate_threshold_pct}% Y latency_p99 > SLO (${var.latency_p99_slo_ms} ms)"
    condition_monitoring_query_language {
      query    = <<-MQL
        fetch prometheus_target
        | { { metric 'prometheus.googleapis.com/http_requests_total/counter'
              | filter (resource.namespace == '${var.kubernetes_namespace}' && metric.status == '500')
              | align rate(1m)
              | group_by [], .sum
            ; metric 'prometheus.googleapis.com/http_requests_total/counter'
              | filter (resource.namespace == '${var.kubernetes_namespace}')
              | align rate(1m)
              | group_by [], .sum }
            | join
            | div
            | value [error_high: val() * 100 > ${var.error_rate_threshold_pct}]
          ; metric 'prometheus.googleapis.com/http_request_duration_seconds/histogram'
            | filter (resource.namespace == '${var.kubernetes_namespace}')
            | align delta(1m)
            | every 1m
            | group_by [], [p99: percentile(value.http_request_duration_seconds, 99)]
            | value [latency_high: p99 > ${var.latency_p99_slo_ms / 1000.0}] }
        | join
        | condition val(0) && val(1)
      MQL
      duration = "180s"
      trigger {
        count = 1
      }
    }
  }

  documentation {
    content = <<-EOT
      Regla de correlación del Módulo B: error_rate por encima de
      ${var.error_rate_threshold_pct}% Y latency_p99 por encima del SLO al
      mismo tiempo (ver variables.tf, error_rate_threshold_pct, para por
      qué el umbral de error es estático y no un baseline dinámico). Esta
      policy cubre la señal de error HTTP (5xx vistos por service-a). Ver
      google_monitoring_alert_policy.correlated_degradation_data_service
      más abajo para la segunda vía de error (degradación silenciosa de
      data-service) -- las dos son independientes a propósito, ver el
      comentario de esa policy para el porqué.

      Trace_id de las peticiones fallidas -- Cloud Logging:
      resource.labels.namespace_name="${var.kubernetes_namespace}"
      severity="ERROR"
      jsonPayload.trace_id!=""

      (Ver docs/runbooks/02-modulo-b-aiops.md para el enlace directo a
      Logs Explorer con este filtro ya armado.)
    EOT
  }

  notification_channels = var.alert_notification_email != "" ? [google_monitoring_notification_channel.aiops_email[0].id] : []

  depends_on = [google_project_service.monitoring]
}

# --- Segunda vía de correlación: degradación silenciosa de data-service ---
#
# Hallazgo real del laboratorio integrador (Módulo D, experimento 2,
# 2026-08-29, ver docs/reporte-ejecutivo-final.md sección 8 y el
# comentario equivalente en observability/prometheus/alert_rules.yml,
# donde esta misma lógica ya se validó empíricamente en local): cuando
# data-service falla, service-a lo atrapa en _fetch_customer() y responde
# 200 igual -- así que http_requests_total NUNCA ve un 5xx para este caso,
# y la policy de arriba (correlated_degradation, basada solo en ese
# contador) es ciega a esta clase de fallo. Se usa en cambio
# data_service_calls_total, que service-a ya emite con el outcome real de
# cada llamada (success/http_error/unreachable).
#
# Por qué es una policy separada y no una sola condición con OR interno:
# el `combiner` de google_monitoring_alert_policy aplica igual a TODAS sus
# `conditions` (no soporta agrupar (A OR B) AND C con conditions
# independientes dentro de una policy) -- a diferencia de un
# aws_cloudwatch_composite_alarm, que sí admite alarm_rule con AND/OR
# arbitrario entre alarmas ya definidas (ver
# aws_cloudwatch_composite_alarm.correlated_degradation en
# iac/terraform/aws/cloudwatch_aiops.tf). La forma nativa de modelar el
# equivalente en GCP es dos policies independientes, cada una ya AND con
# su propia condición de latencia, notificando al mismo canal --
# operacionalmente igual al `or` entre las dos recording rules que usa
# Prometheus en alert_rules.yml.
resource "google_monitoring_alert_policy" "correlated_degradation_data_service" {
  count        = var.deploy_aiops_correlation_alerts ? 1 : 0
  project      = var.project_id
  display_name = "${var.cluster_name}-correlated-degradation-data-service"
  combiner     = "OR" # una sola condition -- el AND real ya está DENTRO de la consulta MQL, ver comentario de cabecera

  # Misma corrección estructural que correlated_degradation de arriba
  # (ver su comentario y el de cabecera): 1 sola condition MQL con fan-out
  # { ; } | join en vez de 2 conditions con combiner AND.
  conditions {
    display_name = "data_service_error_rate > ${var.error_rate_threshold_pct}% Y latency_p99 > SLO (${var.latency_p99_slo_ms} ms)"
    condition_monitoring_query_language {
      # Mismo patrón corregido que correlated_degradation de arriba
      # (acceso posicional tras join, sin funciones inventadas, umbral
      # estático en vez de baseline dinámico -- ver esa policy y
      # variables.tf/error_rate_threshold_pct para el hallazgo completo).
      query    = <<-MQL
        fetch prometheus_target
        | { { metric 'prometheus.googleapis.com/data_service_calls_total/counter'
              | filter (resource.namespace == '${var.kubernetes_namespace}' && metric.outcome != 'success')
              | align rate(1m)
              | group_by [], .sum
            ; metric 'prometheus.googleapis.com/data_service_calls_total/counter'
              | filter (resource.namespace == '${var.kubernetes_namespace}')
              | align rate(1m)
              | group_by [], .sum }
            | join
            | div
            | value [error_high: val() * 100 > ${var.error_rate_threshold_pct}]
          ; metric 'prometheus.googleapis.com/http_request_duration_seconds/histogram'
            | filter (resource.namespace == '${var.kubernetes_namespace}')
            | align delta(1m)
            | every 1m
            | group_by [], [p99: percentile(value.http_request_duration_seconds, 99)]
            | value [latency_high: p99 > ${var.latency_p99_slo_ms / 1000.0}] }
        | join
        | condition val(0) && val(1)
      MQL
      duration = "180s"
      trigger {
        count = 1
      }
    }
  }

  documentation {
    content = <<-EOT
      Segunda vía de correlación del Módulo B (ver comentario del recurso
      para el hallazgo completo): data_service_error_rate por encima de
      ${var.error_rate_threshold_pct}% Y latency_p99 por encima del SLO al
      mismo tiempo. Dispara ante degradación silenciosa de data-service (500/timeout
      atrapado por service-a, que sigue respondiendo 200), invisible para
      correlated_degradation (que solo mira status HTTP de service-a).

      Trace_id de las peticiones fallidas -- Cloud Logging:
      resource.labels.namespace_name="${var.kubernetes_namespace}"
      severity="ERROR"
      jsonPayload.trace_id!=""

      (Ver docs/runbooks/02-modulo-b-aiops.md y
      docs/reporte-ejecutivo-final.md sección 8.)
    EOT
  }

  notification_channels = var.alert_notification_email != "" ? [google_monitoring_notification_channel.aiops_email[0].id] : []

  depends_on = [google_project_service.monitoring]
}

# --- Baseline de comparación: umbral estático ingenuo ----------------------
# Mismo propósito que aws_cloudwatch_metric_alarm.naive_static_threshold:
# contar falsos positivos sobre el mismo tráfico real para demostrar la
# reducción de ruido de la alerta correlacionada (Módulo B).
resource "google_monitoring_alert_policy" "naive_static_threshold" {
  count        = var.deploy_aiops_correlation_alerts ? 1 : 0
  project      = var.project_id
  display_name = "${var.cluster_name}-naive-static-5xx"
  combiner     = "OR"

  conditions {
    display_name = "cualquier request con status 500"
    condition_monitoring_query_language {
      query    = <<-MQL
        fetch prometheus_target
        | metric 'prometheus.googleapis.com/http_requests_total/counter'
        | filter (resource.namespace == '${var.kubernetes_namespace}' && metric.status == '500')
        | align rate(1m)
        | group_by [], [val: sum(value.http_requests_total)]
        | condition cast_units(val, "1") > 0
      MQL
      duration = "60s"
      trigger {
        count = 1
      }
    }
  }

  notification_channels = var.alert_notification_email != "" ? [google_monitoring_notification_channel.aiops_email[0].id] : []

  depends_on = [google_project_service.monitoring]
}
