variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix applied to resource names (cluster, ECR repos, ALB, etc)."
  type        = string
  default     = "observability-lab"
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs for the two public subnets (one per AZ). Public because Fargate tasks in this lab get a public IP directly; no NAT gateway to keep cost down."
  type        = list(string)
  default     = ["10.40.1.0/24", "10.40.2.0/24"]
}

variable "availability_zones" {
  description = "Two AZs to spread the public subnets across."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "image_tag" {
  description = "Tag applied to service-a/service-b images pushed to ECR (e.g. git SHA or 'latest')."
  type        = string
  default     = "latest"
}

variable "service_a_desired_count" {
  description = "Desired task count for the service-a ECS service."
  type        = number
  default     = 2
}

variable "service_b_desired_count" {
  description = "Desired task count for the service-b ECS service."
  type        = number
  default     = 2
}

variable "task_cpu" {
  description = "Fargate task-level CPU units (256 = .25 vCPU) shared by app + collector sidecar."
  type        = string
  default     = "512"
}

variable "task_memory" {
  description = "Fargate task-level memory (MiB) shared by app + collector sidecar."
  type        = string
  default     = "1024"
}

variable "otel_collector_image" {
  description = "Image reference for the OTel Collector sidecar container."
  type        = string
  default     = "otel/opentelemetry-collector-contrib:0.103.0"
}

variable "database_url" {
  description = "Fallback plain-text DATABASE_URL (postgresql://user:pass@host:5432/appdb), used only if database_url_secret_arn is unset. Dev/demo only -- prefer the secret. Default points at this module's own Postgres Fargate service via Cloud Map (namespace \"<project_name>.local\") -- if you change project_name from its default \"observability-lab\", update this default too or pass -var."
  type        = string
  default     = "postgresql://app:secret@postgres.observability-lab.local:5432/appdb"
  sensitive   = true
}

variable "db_admin_cidr" {
  description = "CIDR (e.g. \"YOUR_IP/32\") granted temporary access to Postgres' port 5432 from outside the VPC, to run scripts/init-db.sql once after the first apply (see README.md \"Seeding Postgres\"). Empty by default (no external access)."
  type        = string
  default     = ""
}

variable "database_url_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the full DATABASE_URL connection string consumed by service-a/service-b (matches app.db.DATABASE_URL). Must be created out of band (e.g. `aws secretsmanager create-secret`) against an RDS endpoint provisioned separately -- out of scope for this lab module. Left unset by default so this module has no hardcoded credentials; falls back to var.database_url."
  type        = string
  default     = ""
}

variable "tempo_endpoint" {
  description = "OTLP gRPC endpoint (host:port) for the Collector's trace exporter (otlp/tempo in otel-collector/collector-config.aws.yaml). This module does NOT deploy Tempo/Jaeger -- the default is an unresolvable placeholder: the Collector still starts and stays healthy (the OTLP exporter doesn't validate connectivity at startup, only when exporting), but trace export attempts will fail and show up as errors in the collector's CloudWatch Logs. That's expected. Point this at a real Tempo (another Fargate service, or an external one) via -var if you deploy one."
  type        = string
  default     = "tempo.invalid:4317"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for service and collector log groups."
  type        = number
  default     = 7
}
