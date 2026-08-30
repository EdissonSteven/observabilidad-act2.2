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
# Workload Identity para el otel-collector -- SIN esto, el exporter
# `googlecloud` (metrics/traces/logs a Cloud Monitoring/Trace/Logging en
# otel-collector/collector-config.gcp.yaml) no tiene con qué autenticarse:
# el clúster ya tiene workload_identity_config habilitado y los nodos usan
# `workload_metadata_config { mode = "GKE_METADATA" }`, lo que EXIGE que
# cada pod use una Kubernetes ServiceAccount vinculada a una cuenta de
# servicio de GCP -- ya no basta con los oauth_scopes del nodo. Sin este
# bloque, el collector arrancaría (una vez resuelto el crash de env vars
# de abajo) pero el exporter googlecloud fallaría en silencio con 403
# PermissionDenied, y NINGUNA métrica de las apps llegaría nunca a Cloud
# Monitoring -- bloqueando de raíz las 3 alert policies de AIOps
# (monitoring_aiops.tf, var.deploy_aiops_correlation_alerts) sin importar
# cuánto tráfico se genere después.
# ---------------------------------------------------------------------------

resource "google_service_account" "otel_collector" {
  # account_id NO deriva de var.cluster_name a propósito: los IDs de
  # cuenta de servicio de GCP tienen un máximo de 30 caracteres
  # (^[a-z](?:[-a-z0-9]{4,28}[a-z0-9])$) -- "${var.cluster_name}-otel-
  # collector" con el cluster_name por defecto ya da 36 y falla el regex
  # (hallazgo real, 2026-08-30). Un id fijo y corto es suficiente: solo
  # necesita ser único dentro del proyecto, no describir el clúster.
  account_id   = "otel-collector"
  display_name = "otel-collector Workload Identity SA (${var.cluster_name})"

  depends_on = [google_project_service.iam]
}

resource "google_project_iam_member" "otel_collector_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.otel_collector.email}"
}

resource "google_project_iam_member" "otel_collector_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.otel_collector.email}"
}

resource "google_project_iam_member" "otel_collector_trace" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.otel_collector.email}"
}

resource "google_service_account_iam_member" "otel_collector_workload_identity" {
  service_account_id = google_service_account.otel_collector.name
  role                = "roles/iam.workloadIdentityUser"
  member              = "serviceAccount:${var.project_id}.svc.id.goog[${var.kubernetes_namespace}/otel-collector]"
}

# ---------------------------------------------------------------------------
# GKE cluster
#
# `location = var.zone` (una ZONA, no var.region) a propósito -- ver el
# comentario completo en variables.tf (variable "zone") sobre el hallazgo
# real del primer apply: con la región como location, GKE crea un clúster
# REGIONAL que replica el node pool en las 3 zonas (initial_node_count se
# multiplica x3), lo que agotó la cuota SSD_TOTAL_GB del proyecto de
# prueba. Zonal = 3x menos nodos, acorde al resto del diseño ("lab
# pequeño, no producción").
# ---------------------------------------------------------------------------

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone
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
  location = var.zone
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

    # pd-standard a propósito: cuenta contra la cuota DISKS_TOTAL_GB, NO
    # contra SSD_TOTAL_GB (que es la que agotó el primer apply real -- ver
    # el comentario de variable "zone" en variables.tf). 30 GB alcanza de
    # sobra para las 3 imágenes pequeñas de este lab; margen adicional
    # junto con el cambio a clúster zonal, no una alternativa a él.
    disk_type    = "pd-standard"
    disk_size_gb = 30

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

resource "kubernetes_service_account" "otel_collector" {
  metadata {
    name      = "otel-collector"
    namespace = kubernetes_namespace.app.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.otel_collector.email
    }
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
        service_account_name = kubernetes_service_account.otel_collector.metadata[0].name

        container {
          name  = "otel-collector"
          image = var.otel_collector_image
          args  = ["--config=/etc/otel/collector-config.gcp.yaml"]

          # Hallazgo real (2026-08-30): sin estas 2 env vars el pod entraba
          # en CrashLoopBackOff -- collector-config.gcp.yaml referencia
          # ${env:ENVIRONMENT} y ${env:GCP_PROJECT_ID}; si no existen, el
          # provider de env vars del Collector (v0.103.0) las quita por
          # completo del YAML resuelto en vez de dejarlas vacías, y el
          # processor "resource" queda sin su campo "value" obligatorio:
          # "Error: failed to build pipelines: ... error creating AttrProc.
          # Either field 'value', 'from_attribute' or 'from_context'
          # setting must be specified for 0-th action". Mismo patrón que
          # ya usa docker-compose.yaml (ENVIRONMENT=local) y
          # iac/terraform/aws/main.tf (ENVIRONMENT=aws-academy).
          env {
            name  = "ENVIRONMENT"
            value = "gcp-lab"
          }
          env {
            name  = "GCP_PROJECT_ID"
            value = var.project_id
          }

          port {
            container_port = 4317
          }
          port {
            container_port = 4318
          }

          # Hallazgo real (2026-08-30): Google Managed Prometheus SÍ viene
          # habilitado por defecto en este clúster (confirmado con
          # `kubectl get crd | grep monitoring.googleapis.com` -- el CRD
          # `podmonitorings.monitoring.googleapis.com` ya existe), pero sin
          # un recurso `PodMonitoring` que le diga qué scrapear, nunca
          # colecta nada -- confirmado en la consola real: la query MQL
          # `fetch prometheus_target | metric
          # 'prometheus.googleapis.com/http_requests_total/counter'`
          # devolvía "Could not find a metric" pese a tráfico real ya
          # corrido. El manifiesto `PodMonitoring`
          # (iac/gmp/podmonitoring-otel-collector.yaml -- YAML aparte +
          # `kubectl apply`, NO gestionado por Terraform, mismo patrón que
          # iac/istio/ y por la misma razón: el recurso
          # `kubernetes_manifest` del provider sigue en beta y es conocido
          # por ser frágil con el schema de CRDs, el tipo de sorpresa que
          # ya tuvimos hoy con el bug de "Unexpected Identity Change" de
          # kubernetes_deployment) necesita un puerto de contenedor CON
          # NOMBRE para apuntarle -- un puerto numérico no es válido para
          # `PodMonitoring.spec.endpoints[].port` (documentación oficial de
          # GKE/Managed Prometheus). Puerto 8889 = el que expone el
          # exporter `prometheus` de collector-config.gcp.yaml.
          port {
            name           = "prom-metrics"
            container_port = 8889
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

    # No es requerido por PodMonitoring (que scrapea el pod directamente,
    # no el Service), pero se expone por consistencia con el resto de
    # puertos del collector y para poder hacer `kubectl port-forward` a
    # este puerto si hace falta depurar el endpoint /metrics a mano.
    port {
      name        = "prom-metrics"
      port        = 8889
      target_port = 8889
    }
  }
}
