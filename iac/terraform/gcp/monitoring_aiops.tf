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
# http_requests_total) lleguen a Cloud Monitoring -- el exporter
# `googlecloud` ya está en otel-collector/collector-config.gcp.yaml (ver
# repo), así que esto funciona sin tocar la instrumentación de las apps.
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
      Y latency_p99 por encima del SLO al mismo tiempo.

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
