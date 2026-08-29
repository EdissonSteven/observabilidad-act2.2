data "google_client_config" "default" {}

# ---------------------------------------------------------------------------
# Networking — dedicated VPC instead of the "default" auto-mode network.
# ---------------------------------------------------------------------------

resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.network_name}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  private_ip_google_access = true

  # VPC Flow Logs (Módulo C). A diferencia de AWS (ver
  # iac/terraform/aws/vpc_flow_logs.tf), en GCP esto no necesita ningún rol
  # IAM nuevo -- es un simple flag en la subred, y los logs van directo a
  # Cloud Logging donde SÍ se pueden convertir en métricas consultables en
  # vivo (ver monitoring_aiops.tf y security_dashboard.tf).
  log_config {
    aggregation_interval = "INTERVAL_1_MIN"
    flow_sampling        = 1.0 # 100% de las conexiones -- lab de corta duración, no producción a escala
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_router" "router" {
  name    = "${var.network_name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

# NAT lets nodes with no public IP (see node_config below) pull images/updates.
resource "google_compute_router_nat" "nat" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ---------------------------------------------------------------------------
# Artifact Registry
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = var.artifact_registry_repo_id
  description   = "Container images for service-a / service-b (observability lab)"
  format        = "DOCKER"

  depends_on = [google_project_service.artifactregistry]
}

# ---------------------------------------------------------------------------
# IAM — least-privilege service account for GKE nodes
# ---------------------------------------------------------------------------

resource "google_service_account" "gke_nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE node service account (${var.cluster_name})"

  depends_on = [google_project_service.iam]
}

resource "google_project_iam_member" "gke_nodes_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ---------------------------------------------------------------------------
# GKE cluster
# ---------------------------------------------------------------------------

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region
  project  = var.project_id

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  # Node pool is managed separately below for explicit lifecycle control.
  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Legacy ABAC is disabled by default on GKE clusters created via this
  # resource (RBAC only); left implicit rather than set to avoid confusion
  # with the deprecated `enable_legacy_abac` default of false.

  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  addons_config {
    network_policy_config {
      disabled = false
    }
  }

  # Provider v5 defaults this to true, which blocks `terraform destroy`.
  # Explicitly false since this is a disposable lab cluster (see README).
  deletion_protection = false

  depends_on = [google_project_service.container]
}

resource "google_container_node_pool" "primary_nodes" {
  name     = "${var.cluster_name}-pool"
  location = var.region
  cluster  = google_container_cluster.primary.name

  initial_node_count = var.initial_node_count

  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.node_machine_type
    service_account = google_service_account.gke_nodes.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      workload = "observability-lab"
    }
  }
}

# ---------------------------------------------------------------------------
# Kubernetes workloads — deployed straight onto the cluster just provisioned.
# For a GKE-only rollout, iac/helm/otel-collector is the alternative path for
# the collector; these kubernetes_deployment/service resources demonstrate
# provider-native IaC end to end (cluster -> workloads) in one apply.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "app" {
  metadata {
    name = var.kubernetes_namespace
  }

  depends_on = [google_container_node_pool.primary_nodes]
}

locals {
  artifact_registry_url = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repo_id}"
}

resource "kubernetes_secret" "database_url" {
  metadata {
    name      = "database-url"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  data = {
    DATABASE_URL = var.database_url
  }
}

resource "kubernetes_deployment" "service_a" {
  metadata {
    name      = "service-a"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "service-a" }
  }

  spec {
    replicas = var.service_a_replicas

    selector {
      match_labels = { app = "service-a" }
    }

    template {
      metadata {
        labels = { app = "service-a" }
      }

      spec {
        container {
          name  = "service-a"
          image = "${local.artifact_registry_url}/service-a:${var.image_tag}"

          port {
            container_port = 8000
          }

          env {
            name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
            value = "http://otel-collector.${var.kubernetes_namespace}.svc.cluster.local:4317"
          }

          env {
            name  = "SERVICE_B_URL"
            value = "http://service-b.${var.kubernetes_namespace}.svc.cluster.local:8001"
          }

          env {
            name  = "DATA_SERVICE_URL"
            value = "http://data-service.${var.kubernetes_namespace}.svc.cluster.local:8002"
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.database_url.metadata[0].name
                key  = "DATABASE_URL"
              }
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 20
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "service_a" {
  metadata {
    name      = "service-a"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    selector = { app = "service-a" }
    type     = var.expose_services_externally ? "LoadBalancer" : "ClusterIP"

    port {
      port        = 8000
      target_port = 8000
    }
  }
}

resource "kubernetes_deployment" "service_b" {
  metadata {
    name      = "service-b"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "service-b" }
  }

  spec {
    replicas = var.service_b_replicas

    selector {
      match_labels = { app = "service-b" }
    }

    template {
      metadata {
        labels = { app = "service-b" }
      }

      spec {
        container {
          name  = "service-b"
          image = "${local.artifact_registry_url}/service-b:${var.image_tag}"

          port {
            container_port = 8001
          }

          env {
            name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
            value = "http://otel-collector.${var.kubernetes_namespace}.svc.cluster.local:4317"
          }

          # Módulo D, experimento 1: modo "tc" (con securityContext.capabilities
          # NET_ADMIN, ver iac/istio/README.md y chaos/h4_latency_service_b.sh)
          # es el preferido en GKE; este env var queda como modo alternativo
          # "env" para mantener paridad exacta con el lado AWS Fargate.
          env {
            name  = "INJECT_LATENCY_MS"
            value = var.inject_latency_ms
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.database_url.metadata[0].name
                key  = "DATABASE_URL"
              }
            }
          }

          # Módulo D, experimento 1, modo "tc": sin esta capability, `tc
          # netem` dentro del pod falla con "Operation not permitted" aunque
          # la imagen ya tenga iproute2 instalado (ver
          # services/service-b/Dockerfile). Equivalente en GKE del `cap_add:
          # [NET_ADMIN]` que docker-compose usa para el mismo experimento en
          # local -- Kubernetes no lee `cap_add` de Compose, necesita este
          # bloque explícito.
          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8001
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8001
            }
            initial_delay_seconds = 10
            period_seconds        = 20
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "service_b" {
  metadata {
    name      = "service-b"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    selector = { app = "service-b" }
    type     = "ClusterIP"

    port {
      port        = 8001
      target_port = 8001
    }
  }
}

# Sourced from the sibling otel-collector/ directory (owned by the app repo,
# not this IaC module) so the same pipeline config used in docker-compose is
# what gets deployed to GKE. try() falls back to a minimal generic pipeline
# so `terraform plan` still works even before that file exists.
resource "kubernetes_config_map" "otel_collector_config" {
  metadata {
    name      = "otel-collector-config"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  data = {
    "collector-config.gcp.yaml" = try(
      file("${path.module}/../../../otel-collector/collector-config.gcp.yaml"),
      <<-YAML
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318
      processors:
        memory_limiter:
          check_interval: 5s
          limit_percentage: 80
          spike_limit_percentage: 25
        batch: {}
      exporters:
        logging:
          verbosity: normal
      service:
        pipelines:
          traces:
            receivers: [otlp]
            processors: [memory_limiter, batch]
            exporters: [logging]
          metrics:
            receivers: [otlp]
            processors: [memory_limiter, batch]
            exporters: [logging]
          logs:
            receivers: [otlp]
            processors: [memory_limiter, batch]
            exporters: [logging]
      YAML
    )
  }
}

resource "kubernetes_deployment" "otel_collector" {
  metadata {
    name      = "otel-collector"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "otel-collector" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "otel-collector" }
    }

    template {
      metadata {
        labels = { app = "otel-collector" }
      }

      spec {
        container {
          name  = "otel-collector"
          image = var.otel_collector_image
          args  = ["--config=/etc/otel/collector-config.gcp.yaml"]

          port {
            container_port = 4317
          }
          port {
            container_port = 4318
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          volume_mount {
            name       = "collector-config"
            mount_path = "/etc/otel"
          }
        }

        volume {
          name = "collector-config"
          config_map {
            name = kubernetes_config_map.otel_collector_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "otel_collector" {
  metadata {
    name      = "otel-collector"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    selector = { app = "otel-collector" }
    type     = var.expose_services_externally ? "LoadBalancer" : "ClusterIP"

    port {
      name        = "otlp-grpc"
      port        = 4317
      target_port = 4317
    }

    port {
      name        = "otlp-http"
      port        = 4318
      target_port = 4318
    }
  }
}
