# ---------------------------------------------------------------------------
# data-service -- tercer microservicio (Módulo A), mismo patrón Deployment/
# Service que kubernetes_deployment.service_a/service_b en main.tf.
# ---------------------------------------------------------------------------

resource "kubernetes_secret" "customers_database_url" {
  metadata {
    name      = "customers-database-url"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  data = {
    DATABASE_URL = format(
      "postgresql://%s:%s@%s:5432/%s",
      google_sql_user.app.name,
      random_password.cloudsql_customers.result,
      google_sql_database_instance.customers.private_ip_address,
      google_sql_database.customersdb.name,
    )
  }
}

resource "kubernetes_deployment" "data_service" {
  metadata {
    name      = "data-service"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "data-service" }
  }

  spec {
    replicas = var.data_service_replicas

    selector {
      match_labels = { app = "data-service" }
    }

    template {
      metadata {
        labels = { app = "data-service" }
      }

      spec {
        container {
          name  = "data-service"
          image = "${local.artifact_registry_url}/data-service:${var.image_tag}"

          port {
            container_port = 8002
          }

          env {
            name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
            value = "http://otel-collector.${var.kubernetes_namespace}.svc.cluster.local:4317"
          }

          env {
            name  = "CLOUD_PROVIDER"
            value = "gcp"
          }

          # Módulo D, experimento 2: "0" en reposo. El runbook de chaos
          # (chaos/h5_error_rate_data_service.sh) lo sube a "0.10" con
          # `kubectl set env` durante la ventana cronometrada -- eso
          # dispara un rollout nuevo del Deployment, igual que en ECS
          # Fargate (ver el comentario equivalente en
          # iac/terraform/aws/data_service_ecs.tf), así que el tiempo de
          # ese rollout entra en la ventana medida del experimento.
          env {
            name  = "FAULT_INJECT_ERROR_RATE"
            value = var.fault_inject_error_rate
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.customers_database_url.metadata[0].name
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
              port = 8002
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8002
            }
            initial_delay_seconds = 10
            period_seconds        = 20
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "data_service" {
  metadata {
    name      = "data-service"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    selector = { app = "data-service" }
    type     = "ClusterIP"

    port {
      port        = 8002
      target_port = 8002
    }
  }
}
