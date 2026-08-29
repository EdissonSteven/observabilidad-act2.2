# ---------------------------------------------------------------------------
# AIOps: detección de anomalías + correlación (Módulo B).
#
# GCP Cloud Monitoring no tiene un equivalente directo a
# ANOMALY_DETECTION_BAND de CloudWatch como función de metric math genérica
# reutilizable en cualquier alerta -- el camino nativo más cercano es MQL
# (Monitoring Query Language) con una condición de umbral calculada sobre
# una ventana móvil. Se implementa aquí explícitamente la regla del
# enunciado (baseline + 2σ Y latency_p99 > SLO) en MQL en vez de depender
# de un producto de ML de caja negra -- más transparente para el reporte
# (se puede mostrar y explicar la fórmula exacta), y evita depender de una
# feature que pueda no estar disponible en un proyecto de prueba nuevo.
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
# ---------------------------------------------------------------------------

resource "google_project_service" "monitoring" {
  project            = var.project_id
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
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

# --- Señal correlacionada: error_rate anómalo Y latency_p99 > SLO ---------
#
# MQL: error_rate = ratio de series con status>=500 sobre el total,
# comparado contra su propia media móvil de 1h + 2 desviaciones estándar
# (esto ES la banda "baseline + 2σ" calculada explícitamente, no una caja
# negra). latency_p99 usa el histograma OTel ya expuesto por el Collector.
resource "google_monitoring_alert_policy" "correlated_degradation" {
  project      = var.project_id
  display_name = "${var.cluster_name}-correlated-degradation"
  combiner     = "AND" # ambas condiciones deben cumplirse -- es la "correlación" del Módulo B

  conditions {
    display_name = "error_rate fuera de baseline + 2 sigma"
    condition_monitoring_query_language {
      query    = <<-MQL
        fetch prometheus_target
        | metric 'prometheus.googleapis.com/http_requests_total/counter'
        | filter (resource.namespace == '${var.kubernetes_namespace}')
        | align rate(1m)
        | group_by [metric.status], [val: sum(value.http_requests_total)]
        | { ident
          | filter metric.status == '500' | group_by [], [error: sum(val)]
          ; ident
          | group_by [], [total: sum(val)] }
        | join
        | value [ratio: val(0).error / val(1).total * 100]
        | condition ratio > mean_prev_by(1h) + 2 * stddev_prev_by(1h)
      MQL
      duration = "180s"
      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "latency_p99 > SLO (${var.latency_p99_slo_ms} ms)"
    condition_monitoring_query_language {
      query    = <<-MQL
        fetch prometheus_target
        | metric 'prometheus.googleapis.com/http_request_duration_seconds/histogram'
        | filter (resource.namespace == '${var.kubernetes_namespace}')
        | align delta(1m)
        | every 1m
        | group_by [], [val: percentile(value.http_request_duration_seconds, 99)]
        | condition val > ${var.latency_p99_slo_ms / 1000.0} '1'
      MQL
      duration = "180s"
      trigger {
        count = 1
      }
    }
  }

  documentation {
    content = <<-EOT
      Regla de correlación del Módulo B: error_rate fuera de baseline ± 2σ
      Y latency_p99 por encima del SLO al mismo tiempo. Esta policy cubre
      la señal de error HTTP (5xx vistos por service-a). Ver
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
  project      = var.project_id
  display_name = "${var.cluster_name}-correlated-degradation-data-service"
  combiner     = "AND"

  conditions {
    display_name = "data_service_error_rate fuera de baseline + 2 sigma"
    condition_monitoring_query_language {
      query    = <<-MQL
        fetch prometheus_target
        | metric 'prometheus.googleapis.com/data_service_calls_total/counter'
        | filter (resource.namespace == '${var.kubernetes_namespace}')
        | align rate(1m)
        | group_by [metric.outcome], [val: sum(value.data_service_calls_total)]
        | { ident
          | filter metric.outcome != 'success' | group_by [], [error: sum(val)]
          ; ident
          | group_by [], [total: sum(val)] }
        | join
        | value [ratio: val(0).error / val(1).total * 100]
        | condition ratio > mean_prev_by(1h) + 2 * stddev_prev_by(1h)
      MQL
      duration = "180s"
      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "latency_p99 > SLO (${var.latency_p99_slo_ms} ms)"
    condition_monitoring_query_language {
      query    = <<-MQL
        fetch prometheus_target
        | metric 'prometheus.googleapis.com/http_request_duration_seconds/histogram'
        | filter (resource.namespace == '${var.kubernetes_namespace}')
        | align delta(1m)
        | every 1m
        | group_by [], [val: percentile(value.http_request_duration_seconds, 99)]
        | condition val > ${var.latency_p99_slo_ms / 1000.0} '1'
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
      para el hallazgo completo): data_service_error_rate fuera de
      baseline ± 2σ Y latency_p99 por encima del SLO al mismo tiempo.
      Dispara ante degradación silenciosa de data-service (500/timeout
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
        | condition val > 0 '1'
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
