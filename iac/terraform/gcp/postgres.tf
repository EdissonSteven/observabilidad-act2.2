# ---------------------------------------------------------------------------
# Postgres para orders/inventory (NO para customers -- esa tiene su propia
# Cloud SQL dedicada, ver cloudsql.tf) -- Hallazgo real de este laboratorio
# (2026-08-30): var.database_url por defecto apunta a
# "postgres.observability-lab.svc.cluster.local:5432/appdb" (ver
# variables.tf) y `kubernetes_secret.database_url` en main.tf lo usa tal
# cual, pero ningún recurso de este módulo desplegaba jamás ese Postgres
# en el clúster GKE -- a diferencia de docker-compose.yaml, que sí lo
# levanta como contenedor "postgres". Sin él, service-a no tiene dónde
# leer/escribir `orders`/`inventory` y responde
# {"detail": "error consultando el pedido"} en cuanto se le pide un pedido
# real (confirmado con curl contra /orders/ord-1002 tras desplegar los 4
# microservicios).
#
# Se reutiliza exactamente scripts/init-db.sql (mismo esquema y datos de
# prueba que ya usa docker-compose -- incluye también la tabla `customers`,
# que aquí queda sin uso porque data-service lee de Cloud SQL, pero
# reutilizar el script tal cual evita mantener dos copias del esquema que
# puedan divergir) vía un ConfigMap montado en
# /docker-entrypoint-initdb.d/init.sql, igual que en docker-compose.
#
# Sin PersistentVolumeClaim a propósito: emptyDir es suficiente para un
# laboratorio desechable (los datos de prueba se re-siembran solos en cada
# reinicio del pod vía el init script) y evita aprovisionar un
# StorageClass/PersistentVolume adicional que no aporta nada aquí.
# ---------------------------------------------------------------------------

resource "kubernetes_config_map" "postgres_init" {
  metadata {
    name      = "postgres-init"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  data = {
    "init.sql" = try(
      file("${path.module}/../../../scripts/init-db.sql"),
      <<-SQL
      CREATE TABLE IF NOT EXISTS orders (
          id          VARCHAR(20) PRIMARY KEY,
          sku         VARCHAR(50) NOT NULL,
          customer_id VARCHAR(20) NOT NULL,
          quantity    INTEGER NOT NULL DEFAULT 1,
          status      VARCHAR(20) NOT NULL DEFAULT 'pending',
          created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
      );
      CREATE TABLE IF NOT EXISTS inventory (
          sku             VARCHAR(50) PRIMARY KEY,
          available_units INTEGER NOT NULL DEFAULT 0,
          warehouse       VARCHAR(50) NOT NULL DEFAULT 'WH-BOG-01'
      );
      INSERT INTO orders (id, sku, customer_id, quantity, status) VALUES
          ('ord-1002', 'sku-mouse-pro', 'cus-002', 2, 'pending')
      ON CONFLICT (id) DO NOTHING;
      INSERT INTO inventory (sku, available_units, warehouse) VALUES
          ('sku-mouse-pro', 87, 'WH-BOG-01')
      ON CONFLICT (sku) DO NOTHING;
      SQL
    )
  }
}

resource "kubernetes_deployment" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "postgres" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "postgres" }
    }

    template {
      metadata {
        labels = { app = "postgres" }
      }

      spec {
        container {
          name  = "postgres"
          image = "postgres:16-alpine" # misma imagen y tag que docker-compose.yaml

          env {
            name  = "POSTGRES_USER"
            value = "app"
          }
          env {
            name  = "POSTGRES_PASSWORD"
            value = "secret" # mismo valor de docker-compose.yaml -- solo alcanzable dentro del clúster (ClusterIP, sin IP pública)
          }
          env {
            name  = "POSTGRES_DB"
            value = "appdb"
          }

          port {
            container_port = 5432
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

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "app", "-d", "appdb"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "app", "-d", "appdb"]
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }

          volume_mount {
            name       = "postgres-init"
            mount_path = "/docker-entrypoint-initdb.d"
          }
        }

        volume {
          name = "postgres-data"
          empty_dir {}
        }

        volume {
          name = "postgres-init"
          config_map {
            name = kubernetes_config_map.postgres_init.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "postgres" {
  metadata {
    # El nombre DEBE ser "postgres" -- var.database_url por defecto
    # (variables.tf) resuelve a
    # "postgres.<namespace>.svc.cluster.local:5432", igual que el DSN que
    # ya usan service-a/service-b vía kubernetes_secret.database_url.
    name      = "postgres"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    selector = { app = "postgres" }
    type     = "ClusterIP"

    port {
      port        = 5432
      target_port = 5432
    }
  }
}
