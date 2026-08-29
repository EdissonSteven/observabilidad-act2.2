# ---------------------------------------------------------------------------
# AIOps: detección de anomalías + correlación (Módulo B).
#
# Implementa la regla pedida por el enunciado
# ("error_rate > baseline + 2σ Y latency_p99 > SLO_threshold -> alerta
# enriquecida con trace_id") usando CloudWatch Anomaly Detection nativo
# (función de metric math ANOMALY_DETECTION_BAND, que calcula un rango
# esperado a partir del patrón histórico ± N desviaciones estándar -- esto
# ES literalmente "baseline + 2σ", sin necesidad de habilitar DevOps Guru,
# que en un AWS Academy Learner Lab puede estar bloqueado a nivel de cuenta
# (confirmar con scripts/aws_preflight_check.sh antes de aplicar; si
# DevOps Guru sí está disponible, se documenta como evidencia adicional en
# el reporte, no como reemplazo de esta alarma).
#
# "Alerta enriquecida con trace_id": la alarma compuesta publica a un
# tópico SNS cuyo mensaje incluye un enlace pre-armado a CloudWatch Logs
# Insights que filtra, en la ventana exacta de la alarma, las líneas de log
# con `level=ERROR` de service-a -- cada una trae su `trace_id` en el JSON
# (mismo formato ya usado en docs/reporte-tecnico.md para la correlación
# logs<->trazas). Es una forma real y simple de enriquecimiento (deep link
# a la evidencia), preferida aquí sobre una Lambda custom de correlación
# automática -- que añadiría una pieza más para depurar con presupuesto de
# Learner Lab ya ajustado; queda documentada como mejora en
# docs/madurez-observabilidad.md (dominio 4, roadmap).
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "aiops_alerts" {
  name = "${var.project_name}-aiops-alerts"
}

resource "aws_sns_topic_subscription" "aiops_alerts_email" {
  count     = var.alert_notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.aiops_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_notification_email
}

# --- Señal 1: error_rate con detección de anomalías (baseline ± 2σ) -------

resource "aws_cloudwatch_metric_alarm" "error_rate_anomaly" {
  alarm_name          = "${var.project_name}-error-rate-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods   = 3
  threshold_metric_id  = "ad_error_rate"
  alarm_description    = "error_rate de service-a (5xx/requests) fuera de la banda de anomalía (baseline ± 2σ, CloudWatch Anomaly Detection). Módulo B."
  treat_missing_data    = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "IF(m_requests > 0, (m_5xx / m_requests) * 100, 0)"
    label       = "error_rate_pct"
    return_data = true
  }

  metric_query {
    id = "m_5xx"
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
        TargetGroup  = aws_lb_target_group.service_a.arn_suffix
      }
    }
  }

  metric_query {
    id = "m_requests"
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
        TargetGroup  = aws_lb_target_group.service_a.arn_suffix
      }
    }
  }

  metric_query {
    id          = "ad_error_rate"
    expression  = "ANOMALY_DETECTION_BAND(error_rate, 2)"
    label       = "error_rate_pct (banda esperada, 2σ)"
    return_data = false
  }
}

# --- Señal 1b: degradación silenciosa de data-service (hallazgo Módulo D) -
#
# Hallazgo real del laboratorio integrador (Módulo D, experimento 2,
# 2026-08-29, ver docs/reporte-ejecutivo-final.md sección 8 y el
# comentario equivalente en observability/prometheus/alert_rules.yml,
# donde esta misma lógica ya se validó empíricamente en local): cuando
# data-service falla, service-a lo atrapa en _fetch_customer() y responde
# 200 igual -- así que HTTPCode_Target_5XX_Count (la métrica del ALB que
# usa error_rate_anomaly arriba) NUNCA lo ve. Se necesita la métrica de
# negocio data_service_calls_total, publicada como métrica custom de
# CloudWatch vía el exporter awsemf del Collector (ver
# otel-collector/collector-config.aws.yaml) -- ese exporter y el permiso
# IAM (aws_iam_role_policy.task_cloudwatch_metrics, main.tf) se añadieron
# junto con esta alarma.
#
# CloudWatch no soporta un filtro "dimension != valor" en un metric_query
# (a diferencia de outcome!="success" en PromQL) -- se suman por separado
# los dos outcomes de fallo (http_error, unreachable) contra el total
# agregado (publicado sin dimensión `outcome`, ver metric_declarations en
# el Collector).
resource "aws_cloudwatch_metric_alarm" "data_service_error_rate_anomaly" {
  alarm_name          = "${var.project_name}-data-service-error-rate-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  threshold_metric_id = "ad_data_service_error_rate"
  alarm_description   = "data_service_error_rate (llamadas service-a -> data-service con outcome != success) fuera de la banda de anomalía (baseline ± 2σ). Cubre la degradación silenciosa que error_rate_anomaly no puede ver. Módulo B / hallazgo Módulo D."
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "data_service_error_rate"
    expression  = "IF(m_ds_total > 0, ((m_ds_http_error + m_ds_unreachable) / m_ds_total) * 100, 0)"
    label       = "data_service_error_rate_pct"
    return_data = true
  }

  metric_query {
    id = "m_ds_http_error"
    metric {
      metric_name = "data_service_calls_total"
      namespace   = "otel-lab"
      period      = 60
      stat        = "Sum"
      dimensions = {
        outcome = "http_error"
      }
    }
  }

  metric_query {
    id = "m_ds_unreachable"
    metric {
      metric_name = "data_service_calls_total"
      namespace   = "otel-lab"
      period      = 60
      stat        = "Sum"
      dimensions = {
        outcome = "unreachable"
      }
    }
  }

  metric_query {
    id = "m_ds_total"
    metric {
      metric_name = "data_service_calls_total"
      namespace   = "otel-lab"
      period      = 60
      stat        = "Sum"
      dimensions  = {} # serie agregada sin dimensión outcome, ver awsemf metric_declarations
    }
  }

  metric_query {
    id          = "ad_data_service_error_rate"
    expression  = "ANOMALY_DETECTION_BAND(data_service_error_rate, 2)"
    label       = "data_service_error_rate_pct (banda esperada, 2σ)"
    return_data = false
  }
}

# --- Señal 2: latency p99 vs. umbral fijo de SLO --------------------------

resource "aws_cloudwatch_metric_alarm" "latency_p99_slo" {
  alarm_name          = "${var.project_name}-latency-p99-slo"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  period              = 60
  threshold           = var.latency_p99_slo_ms / 1000.0
  alarm_description   = "TargetResponseTime p99 de service-a por encima del SLO (${var.latency_p99_slo_ms} ms). Módulo B."
  treat_missing_data  = "notBreaching"

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p99"
  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.service_a.arn_suffix
  }
}

# --- Correlación: AMBAS señales a la vez (Módulo B) -----------------------

resource "aws_cloudwatch_composite_alarm" "correlated_degradation" {
  alarm_name        = "${var.project_name}-correlated-degradation"
  alarm_description = <<-EOT
    Regla de correlación del Módulo B: (error_rate HTTP fuera de banda O
    data_service_error_rate fuera de banda) Y latency_p99 por encima del
    SLO al mismo tiempo. La rama data_service_error_rate se añadió tras
    el hallazgo de degradación silenciosa del Módulo D -- ver el
    comentario de aws_cloudwatch_metric_alarm.data_service_error_rate_anomaly
    arriba. Diseñada para no disparar con cada blip aislado de una sola
    señal (eso es justamente el "ruido" que se compara contra la alarma
    estática ${aws_cloudwatch_metric_alarm.naive_static_threshold.alarm_name}
    en docs/runbooks/02-modulo-b-aiops.md).

    Trace_id de las peticiones fallidas -- ver CloudWatch Logs Insights:
    fields @timestamp, message
    | filter level = "ERROR"
    | sort @timestamp desc
    | limit 20
    (log group: ${aws_cloudwatch_log_group.service_a.name})
  EOT

  alarm_rule = "(ALARM(\"${aws_cloudwatch_metric_alarm.error_rate_anomaly.alarm_name}\") OR ALARM(\"${aws_cloudwatch_metric_alarm.data_service_error_rate_anomaly.alarm_name}\")) AND ALARM(\"${aws_cloudwatch_metric_alarm.latency_p99_slo.alarm_name}\")"

  alarm_actions = [aws_sns_topic.aiops_alerts.arn]
  ok_actions    = [aws_sns_topic.aiops_alerts.arn]
}

# --- Baseline de comparación: umbral estático "ingenuo" -------------------
# Deliberadamente ruidoso -- dispara con CUALQUIER 5xx, sin correlacionar
# con latencia ni con el comportamiento histórico. Se deja activo durante
# el mismo experimento de caos que la alarma correlacionada para poder
# contar en el reporte cuántas veces disparó cada una sobre el mismo
# tráfico real (Módulo B: "demostrar reducción de alertas ruidosas").
resource "aws_cloudwatch_metric_alarm" "naive_static_threshold" {
  alarm_name          = "${var.project_name}-naive-static-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 60
  threshold           = 0
  statistic           = "Sum"
  alarm_description   = "Baseline ruidoso a propósito: cualquier 5xx dispara, sin correlación ni banda de anomalía. Usado solo para comparar tasa de falsos positivos contra la alarma compuesta (Módulo B)."
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.service_a.arn_suffix
  }

  alarm_actions = [aws_sns_topic.aiops_alerts.arn]
  ok_actions    = [aws_sns_topic.aiops_alerts.arn]
}
