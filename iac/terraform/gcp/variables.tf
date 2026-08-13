variable "project_id" {
  description = "GCP project ID where resources are provisioned."
  type        = string
}

variable "region" {
  description = "GCP region for the cluster, network, and Artifact Registry."
  type        = string
  default     = "us-central1"
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
