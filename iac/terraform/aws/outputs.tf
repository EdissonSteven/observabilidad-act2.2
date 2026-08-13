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
