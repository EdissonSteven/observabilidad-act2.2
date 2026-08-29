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

variable "data_service_desired_count" {
  description = "Desired task count for the data-service ECS service."
  type        = number
  default     = 1
}

variable "fault_inject_error_rate" {
  description = "Módulo D, experimento 2 (error rate en data-service): probabilidad (0-1, como string porque los env vars de ECS son siempre string) de que data-service devuelva 500 a propósito. \"0\" en reposo; el runbook de chaos lo sube a \"0.10\" solo durante la ventana cronometrada del experimento -- ver chaos/h5_error_rate_data_service.sh."
  type        = string
  default     = "0"
}

variable "inject_latency_ms" {
  description = "Módulo D, experimento 1 (latencia en service-b), modo \"env\" -- fallback cuando tc netem no es viable porque Fargate no permite añadir NET_ADMIN. \"0\" en reposo; ver chaos/h4_latency_service_b.sh y el comentario en services/service-b/app/main.py."
  type        = string
  default     = "0"
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

# ---------------------------------------------------------------------------
# AWS Academy / Vocareum Learner Lab compatibility
#
# Un Learner Lab da un `LabRole` fijo y BLOQUEA `iam:CreateRole`,
# `iam:CreatePolicy` y similares para el usuario del lab -- por lo que los
# `aws_iam_role.execution`/`aws_iam_role.task` que este módulo creaba
# originalmente (pensado para una cuenta AWS normal) fallarían con
# AccessDenied en el primer `apply` dentro de un Learner Lab. Con
# `use_academy_lab_role = true` (default, porque el laboratorio integrador
# se ejecuta contra un Learner Lab confirmado) el módulo NO crea roles
# nuevos: reutiliza el `LabRole` ya provisto para ejecución Y tarea de ECS.
# Verificar con scripts/aws_preflight_check.sh ANTES de aplicar.
# ---------------------------------------------------------------------------

variable "use_academy_lab_role" {
  description = "Si es true, no se crean aws_iam_role propios -- se reutiliza el LabRole del Learner Lab (academy_lab_role_name) como execution_role_arn y task_role_arn. Ponlo en false solo si tienes una cuenta AWS normal con permisos para crear roles IAM."
  type        = bool
  default     = true
}

variable "academy_lab_role_name" {
  description = "Nombre del rol IAM ya provisto por AWS Academy Learner Lab (verificar con `aws iam get-role --role-name LabRole`, o el nombre que confirme scripts/aws_preflight_check.sh). Solo se usa si use_academy_lab_role = true."
  type        = string
  default     = "LabRole"
}

# ---------------------------------------------------------------------------
# RDS (data-service) -- ver rds.tf para la justificación de alcance.
# ---------------------------------------------------------------------------

variable "deploy_rds" {
  description = "Si es true, crea la instancia RDS PostgreSQL de data-service (rds.tf) y la wiring de ECS asociada. Ponlo en false para un `terraform plan`/`apply` de solo el resto del stack (útil para validar permisos del Learner Lab sin comprometer presupuesto en RDS todavía)."
  type        = bool
  default     = true
}

variable "rds_instance_class" {
  description = "Clase de instancia RDS para la base de datos de data-service. db.t3.micro es la más pequeña de uso general -- explícitamente de laboratorio, no de producción."
  type        = string
  default     = "db.t3.micro"
}

variable "rds_engine_version" {
  description = "Versión de PostgreSQL en RDS. Verificar con `aws rds describe-db-engine-versions --engine postgres` que la versión esté disponible en la región/Learner Lab antes de aplicar."
  type        = string
  default     = "16.4"
}

# ---------------------------------------------------------------------------
# AIOps (Módulo B) -- ver cloudwatch_aiops.tf
# ---------------------------------------------------------------------------

variable "latency_p99_slo_ms" {
  description = "Umbral de SLO de latencia p99 (milisegundos) para GET /orders/{id} vía el ALB. Referencia: p99 real de baseline en la Actividad 2.2 fue 65.8 ms (ver GameDay_Plan.pdf validado); se deja margen para tráfico real de 3 saltos con data-service añadido."
  type        = number
  default     = 300
}

variable "alert_notification_email" {
  description = "Email suscrito al tópico SNS de alertas de AIOps. Vacío por defecto (sin suscripción) -- pásalo con -var para recibir las alertas reales durante la ventana del experimento de caos."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# App Mesh (Módulo A) -- ver appmesh.tf. Deshabilitado por defecto: es la
# pieza de mayor riesgo (Envoy sidecar + permisos IAM) -- activar solo
# después de validar el resto del stack.
# ---------------------------------------------------------------------------

variable "enable_app_mesh" {
  description = "Si es true, añade el mesh, virtual nodes/routers/services de App Mesh Y el sidecar Envoy + proxy_configuration a las task definitions de service-a/service-b/data-service. Requiere que el rol de tarea tenga la política administrada AWSAppMeshEnvoyAccess -- confirmar con scripts/aws_preflight_check.sh antes de activar."
  type        = bool
  default     = false
}

variable "envoy_image_account_id" {
  description = "ID de cuenta AWS que publica la imagen pública de Envoy para App Mesh en la región elegida (tabla oficial: https://docs.aws.amazon.com/app-mesh/latest/userguide/envoy.html). Default correcto para us-east-1 -- cámbialo si cambias aws_region."
  type        = string
  default     = "840364872350"
}

variable "envoy_image_tag" {
  description = "Tag de la imagen de Envoy de App Mesh a usar (ver la misma tabla oficial que envoy_image_account_id)."
  type        = string
  default     = "v1.29.9.0-prod"
}
