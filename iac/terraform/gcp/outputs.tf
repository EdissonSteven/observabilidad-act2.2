output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "GKE cluster API endpoint."
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "artifact_registry_url" {
  description = "Artifact Registry URL to push service-a/service-b images to."
  value       = local.artifact_registry_url
}

output "kubernetes_namespace" {
  description = "Namespace the workloads were deployed into."
  value       = kubernetes_namespace.app.metadata[0].name
}

output "service_a_cluster_ip" {
  description = "ClusterIP (or LoadBalancer IP, if exposed) for service-a."
  value       = try(kubernetes_service.service_a.status[0].load_balancer[0].ingress[0].ip, kubernetes_service.service_a.spec[0].cluster_ip)
}

output "otel_collector_endpoint" {
  description = "In-cluster OTLP gRPC endpoint for the Collector."
  value       = "otel-collector.${var.kubernetes_namespace}.svc.cluster.local:4317"
}

output "get_credentials_command" {
  description = "gcloud command to fetch kubeconfig for this cluster."
  # --zone, no --region: el clúster es zonal a propósito (ver variable
  # "zone" en variables.tf).
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${var.zone} --project ${var.project_id}"
}

output "cloudsql_customers_private_ip" {
  description = "IP privada de la instancia Cloud SQL de data-service."
  value       = google_sql_database_instance.customers.private_ip_address
}

output "cloudsql_customers_secret_id" {
  description = "ID del secreto en Secret Manager con el DATABASE_URL completo de data-service."
  value       = google_secret_manager_secret.customers_database_url.secret_id
}

output "denied_traffic_log_metric" {
  description = "Nombre del log-based metric de tráfico rechazado (Módulo C)."
  value       = google_logging_metric.denied_traffic.name
}
