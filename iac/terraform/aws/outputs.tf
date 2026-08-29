output "alb_dns_name" {
  description = "Public DNS name of the ALB fronting service-a."
  value       = aws_lb.main.dns_name
}

output "ecr_service_a_url" {
  description = "ECR repository URL for service-a images."
  value       = aws_ecr_repository.service_a.repository_url
}

output "ecr_service_b_url" {
  description = "ECR repository URL for service-b images."
  value       = aws_ecr_repository.service_b.repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "account_id" {
  description = "AWS account ID resources were provisioned in (useful for building ECR login/push commands)."
  value       = data.aws_caller_identity.current.account_id
}

output "ecr_data_service_url" {
  description = "ECR repository URL for data-service images."
  value       = aws_ecr_repository.data_service.repository_url
}

output "rds_customers_endpoint" {
  description = "Endpoint (host:port) de la instancia RDS de data-service. Vacío si deploy_rds = false."
  value       = var.deploy_rds ? aws_db_instance.customers[0].endpoint : null
}

output "rds_customers_secret_arn" {
  description = "ARN del secreto de Secrets Manager con el DATABASE_URL completo de data-service. Vacío si deploy_rds = false."
  value       = var.deploy_rds ? aws_secretsmanager_secret.customers_database_url[0].arn : null
}

output "aiops_alerts_topic_arn" {
  description = "ARN del tópico SNS de alertas de AIOps (Módulo B) -- usar en chaos/measure_mttd.py para escuchar cuándo dispara la alarma compuesta."
  value       = aws_sns_topic.aiops_alerts.arn
}

output "vpc_flow_logs_bucket" {
  description = "Bucket S3 con los VPC Flow Logs (Módulo C)."
  value       = aws_s3_bucket.flow_logs.bucket
}

output "effective_execution_role_arn" {
  description = "ARN de rol efectivamente usado como execution_role_arn en todas las task definitions (LabRole si use_academy_lab_role = true)."
  value       = local.execution_role_arn
}
