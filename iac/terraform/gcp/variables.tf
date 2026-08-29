variable "project_id" {
  description = "GCP project ID where resources are provisioned."
  type        = string
}

variable "region" {
  description = "GCP region for the network, Artifact Registry and Cloud SQL (recursos regionales). El clúster GKE usa var.zone, no esta -- ver esa variable para el porqué."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = <<-EOT
    Zona específica (dentro de var.region) donde se crea el clúster GKE y
    su node pool. Hallazgo real del primer apply que sí llegó a crear el
    clúster (2026-08-29): con `google_container_cluster.location =
    var.region` (una REGIÓN, no una zona), GKE crea un clúster REGIONAL,
    que replica el node pool en las 3 zonas de la región por defecto --
    "initial_node_count" se multiplica POR ZONA
    (https://docs.cloud.google.com/kubernetes-engine/docs/concepts/regional-clusters:
    "The default node pool created for regional Standard clusters
    consists of nine nodes (three per zone)..."). Con
    initial_node_count=2 eso son 6 nodos e2-standard-4 desde el arranque
    (hasta 12 con el autoscaling max_node_count=4 por zona) -- el apply
    falló con "Quota 'SSD_TOTAL_GB' exceeded. Limit: 250.0 in region
    us-central1" porque el disco de arranque por defecto de GKE 1.24+ es
    pd-balanced, que SÍ cuenta contra esa cuota
    (https://docs.cloud.google.com/compute/resource-usage: "This quota
    applies to... Zonal and Regional Balanced Persistent Disk"). Un
    clúster ZONAL (esta variable) usa initial_node_count como TOTAL, no
    por zona -- 3x menos nodos, consistente con el comentario ya existente
    en node_machine_type ("Kept small since this is a graded lab, not
    production"). Además se fijó node_config.disk_type = "pd-standard" en
    main.tf (cuenta contra la cuota separada DISKS_TOTAL_GB, no contra
    SSD_TOTAL_GB) como margen adicional.
  EOT
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
  default     = "observability-lab-gke"
}

variable "network_name" {
  description = "Name of the dedicated VPC created for the cluster."
  type        = string
  default     = "observability-lab-vpc"
}

variable "subnet_cidr" {
  description = "Primary CIDR range for the GKE subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary CIDR range for pod IPs (VPC-native cluster)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR range for service IPs (VPC-native cluster)."
  type        = string
  default     = "10.30.0.0/20"
}

variable "node_machine_type" {
  description = "Machine type for GKE nodes. Kept small since this is a graded lab, not production."
  type        = string
  default     = "e2-standard-4"
}

variable "min_node_count" {
  description = "Minimum node count per zone for the autoscaling node pool."
  type        = number
  default     = 1
}

variable "max_node_count" {
  description = "Maximum node count per zone for the autoscaling node pool."
  type        = number
  default     = 4
}

variable "initial_node_count" {
  description = "Initial node count per zone when the node pool is created."
  type        = number
  default     = 2
}

variable "artifact_registry_repo_id" {
  description = "Artifact Registry repository ID for service-a/service-b container images."
  type        = string
  default     = "observability-lab"
}

variable "image_tag" {
  description = "Tag applied to service-a/service-b images pushed to Artifact Registry (e.g. git SHA or 'latest')."
  type        = string
  default     = "latest"
}

variable "service_a_replicas" {
  description = "Replica count for the service-a Deployment."
  type        = number
  default     = 2
}

variable "service_b_replicas" {
  description = "Replica count for the service-b Deployment."
  type        = number
  default     = 2
}

variable "otel_collector_image" {
  description = "Image reference for the OTel Collector deployed in-cluster."
  type        = string
  default     = "otel/opentelemetry-collector-contrib:0.103.0"
}

variable "kubernetes_namespace" {
  description = "Namespace the microservices and collector are deployed into."
  type        = string
  default     = "observability-lab"
}

variable "expose_services_externally" {
  description = "If true, service-a and the OTel Collector are exposed via LoadBalancer Services. Keep false by default to avoid extra GCP LB cost in the lab."
  type        = bool
  default     = false
}

variable "database_url" {
  description = "DATABASE_URL DSN (postgresql://user:pass@host:5432/appdb) consumed by service-a/service-b, matching services/*/app/db.py. Provisioning the Postgres instance itself (e.g. Cloud SQL) is out of scope for this lab module -- point this at one created separately. Stored as a Kubernetes Secret, never as a plain env value."
  type        = string
  default     = "postgresql://app:secret@postgres.observability-lab.svc.cluster.local:5432/appdb"
  sensitive   = true
}

# ---------------------------------------------------------------------------
# data-service / Cloud SQL (Módulo A) -- ver cloudsql.tf y data_service.tf
# ---------------------------------------------------------------------------

variable "cloudsql_tier" {
  description = "Tier de la instancia Cloud SQL de data-service. db-f1-micro es la más pequeña compartida -- de laboratorio, no de producción."
  type        = string
  default     = "db-f1-micro"
}

variable "cloudsql_database_version" {
  description = "Versión de motor de Cloud SQL."
  type        = string
  default     = "POSTGRES_16"
}

variable "data_service_replicas" {
  description = "Replica count para el Deployment de data-service."
  type        = number
  default     = 1
}

variable "fault_inject_error_rate" {
  description = "Módulo D, experimento 2 (error rate en data-service): probabilidad (0-1, como string) de fallo inyectado a propósito. \"0\" en reposo -- ver chaos/h5_error_rate_data_service.sh."
  type        = string
  default     = "0"
}

variable "inject_latency_ms" {
  description = "Módulo D, experimento 1 (latencia en service-b), modo \"env\" alternativo a tc netem. \"0\" en reposo -- ver chaos/h4_latency_service_b.sh."
  type        = string
  default     = "0"
}

# ---------------------------------------------------------------------------
# AIOps (Módulo B) y Network/Security (Módulo C)
# ---------------------------------------------------------------------------

variable "latency_p99_slo_ms" {
  description = "Umbral de SLO de latencia p99 (milisegundos) para GET /orders/{id}. Mismo valor de referencia que el lado AWS (ver iac/terraform/aws/variables.tf) para poder comparar ambas nubes en el reporte."
  type        = number
  default     = 300
}

variable "alert_notification_email" {
  description = "Email suscrito a las alertas de Cloud Monitoring (Módulo B). Vacío por defecto."
  type        = string
  default     = ""
}

variable "denied_traffic_alert_threshold" {
  description = "Umbral (conexiones/segundo, tras ALIGN_RATE) de tráfico rechazado por firewall para disparar la alerta de Módulo C. Ajustar tras observar el nivel de ruido de fondo real del clúster (ver docs/runbooks/03-modulo-c-network-security.md)."
  type        = number
  default     = 5
}

variable "deploy_aiops_correlation_alerts" {
  description = <<-EOT
    Si es false (default), NO crea las 3 alert policies de
    monitoring_aiops.tf que dependen de métricas de APLICACIÓN
    (correlated_degradation, correlated_degradation_data_service,
    naive_static_threshold) -- a diferencia de anomalous_denied_traffic
    (network_security.tf), que depende de un log-based metric que el
    propio Terraform crea.

    Hallazgo real del primer apply contra un proyecto/clúster recién
    creado (2026-08-29): Google Managed Prometheus solo registra el
    descriptor de una métrica ('prometheus.googleapis.com/.../counter')
    tras ingerir el primer dato real -- sin GKE desplegado ni tráfico de
    las apps corriendo todavía, esas 3 policies fallan con "Could not
    find a metric named ...".

    Poner en true SOLO después de, en este orden: (1) este mismo apply
    con el flag en false (default), (2) desplegar los 3 microservicios +
    collector (Runbook 1) y generar tráfico real, (3) confirmar en Cloud
    Console -> Monitoring -> Metrics Explorer (modo MQL) que las 3
    métricas usadas ya aparecen con datos, y (4) validar ahí mismo la
    sintaxis MQL exacta de las 2 policies de correlación -- ver la
    ADVERTENCIA DE VALIDACIÓN al inicio de monitoring_aiops.tf, son
    consultas MQL escritas sin acceso a una consola real y DEBEN
    confirmarse contra datos reales antes de depender de ellas. Recién
    entonces: terraform apply -var deploy_aiops_correlation_alerts=true.
    Ver docs/runbooks/02-modulo-b-aiops.md, Paso 1.
  EOT
  type        = bool
  default     = false
}
