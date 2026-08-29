# ---------------------------------------------------------------------------
# Dashboard "Golden Signals de Seguridad" (Módulo C).
#
# Nota de alcance, importante para el reporte: ni service-a, ni service-b,
# ni data-service implementan autenticación de usuario final -- son
# microservicios internos sin capa de auth. "Intentos de autenticación
# fallidos" (tal como lo pide el enunciado) no tiene una señal real que
# graficar en ESTE sistema sin inventar una. En vez de fabricar esa métrica,
# este dashboard adapta el concepto de golden signals de seguridad a lo que
# el sistema SÍ observa de verdad:
#   - Tráfico N-S rechazado a nivel de red (VPC Flow Logs, REJECT) -- el
#     panel de texto de abajo trae la consulta Athena exacta, porque el
#     destino S3 (ver vpc_flow_logs.tf, elegido para no requerir un rol IAM
#     nuevo en el Learner Lab) no expone una métrica nativa de CloudWatch
#     para graficar en vivo.
#   - Tasa de error de cliente 4xx en el ALB (proxy de tráfico
#     malformado/no autorizado contra service-a).
#   - Conexiones activas a RDS (proxy de acceso anómalo a la base de datos
#     de data-service).
# La ausencia de autenticación real queda documentada como brecha explícita
# en docs/madurez-observabilidad.md (dominio 5) con su remediación
# propuesta -- no se oculta.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "security_golden_signals" {
  count          = var.deploy_rds ? 1 : 0
  dashboard_name = "${var.project_name}-security-golden-signals"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          markdown = join("\n", [
            "## Golden Signals de Seguridad -- ${var.project_name}",
            "**Tráfico rechazado (VPC Flow Logs, REJECT)** -- no graficable en vivo desde S3; consultar con Athena:",
            "```sql",
            "SELECT date_trunc('minute', \"start\") AS minute, srcaddr, dstport, COUNT(*) AS rejected",
            "FROM vpc_flow_logs",
            "WHERE action = 'REJECT'",
            "GROUP BY 1, 2, 3 ORDER BY 1 DESC LIMIT 100;",
            "```",
            "Bucket: `${aws_s3_bucket.flow_logs.bucket}` -- ver docs/runbooks/03-modulo-c-network-security.md para crear la tabla Athena.",
          ])
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 3
        width  = 12
        height = 6
        properties = {
          title  = "ALB - errores de cliente 4xx (proxy de tráfico no autorizado/malformado)"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", aws_lb.main.arn_suffix, "TargetGroup", aws_lb_target_group.service_a.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.main.arn_suffix, "TargetGroup", aws_lb_target_group.service_a.arn_suffix, { stat = "Sum" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 3
        width  = 12
        height = 6
        properties = {
          title  = "RDS (customers) - conexiones activas"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.customers[0].id, { stat = "Maximum" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 24
        height = 6
        properties = {
          title  = "ECS - CPU y memoria por servicio (saturación como señal de seguridad: escaneos/DoS de bajo volumen)"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.service_a.name, { stat = "Average" }],
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.data_service.name, { stat = "Average" }],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.service_a.name, { stat = "Average" }],
          ]
        }
      }
    ]
  })
}
