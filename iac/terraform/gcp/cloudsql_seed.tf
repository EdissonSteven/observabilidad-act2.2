# ---------------------------------------------------------------------------
# Seed de la tabla `customers` en Cloud SQL -- Hallazgo real de este
# laboratorio (2026-08-30): `google_sql_database.customersdb` (cloudsql.tf)
# crea la base de datos VACÍA -- a diferencia del Postgres del clúster
# (postgres.tf), Cloud SQL no tiene un mecanismo equivalente a
# /docker-entrypoint-initdb.d/ que aplique un script automáticamente al
# crear la instancia. Sin esto, data-service responde 500 al primer query
# con el error real observado:
#   {"message": "customer_fetch_failed", "customer_id": "cus-002",
#    "error": "relation \"customers\" does not exist\nLINE 1: SELECT id, ..."}
#
# Cloud SQL aquí usa `ipv4_enabled = false` (solo IP privada, peered a la
# VPC del clúster -- ver cloudsql.tf), por lo que NO es alcanzable desde
# Cloud Shell ni desde el proceso de `terraform apply` en sí (que corre
# fuera de la VPC) -- descarta un `null_resource` con provisioner
# `local-exec` ejecutando `psql` directamente. La alternativa real es
# ejecutar el seed DESDE DENTRO del clúster, con un Kubernetes Job de una
# sola vez (mismo patrón que un `kubectl run --rm -it --image=postgres ...`
# manual, pero declarado como IaC en vez de un paso manual no repetible).
#
# `kubernetes_job_v1` (recurso real del provider hashicorp/kubernetes,
# disponible desde >=2.9.0, compatible con el `~> 2.0` de este proyecto --
# ver versions.tf) reutiliza la misma imagen `postgres:16-alpine` ya usada
# en postgres.tf (trae el cliente `psql`) y el mismo Secret
# `kubernetes_secret.customers_database_url` (data_service.tf) que ya usa
# data-service -- ningún dato de conexión nuevo, ninguna credencial
# duplicada.
#
# El SQL en sí (scripts/init-customers-db.sql) es idempotente
# (`CREATE TABLE IF NOT EXISTS` + `INSERT ... ON CONFLICT DO NOTHING`), así
# que si este Job llegara a re-ejecutarse (p. ej. tras un
# `terraform apply -replace`) no duplica ni corrompe datos -- simplemente
# no hace nada la segunda vez.
#
# `wait_for_completion = true` hace que `terraform apply` BLOQUEE hasta que
# el seed termine de verdad, en vez de reportar éxito con el Job todavía
# corriendo -- así el siguiente paso del runbook (probar
# GET /customers/cus-002) siempre encuentra los datos ya sembrados.
# ---------------------------------------------------------------------------

resource "kubernetes_config_map" "customers_seed" {
  metadata {
    name      = "customers-seed"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  data = {
    "init-customers.sql" = file("${path.module}/../../../scripts/init-customers-db.sql")
  }
}

resource "kubernetes_job_v1" "seed_customers_db" {
  metadata {
    name      = "seed-customers-db"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "seed-customers-db" }
  }

  spec {
    backoff_limit           = 2
    active_deadline_seconds = 120

    template {
      metadata {
        labels = { app = "seed-customers-db" }
      }

      spec {
        restart_policy = "Never" # un Job de una sola vez, no un Deployment -- no debe reiniciarse en bucle

        container {
          name    = "psql-seed"
          image   = "postgres:16-alpine" # misma imagen que postgres.tf -- trae el cliente psql
          command = ["sh", "-c", "psql \"$DATABASE_URL\" -f /sql/init-customers.sql"]

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                # Mismo Secret que ya usa data-service (data_service.tf) --
                # mismo DSN, sin duplicar credenciales.
                name = kubernetes_secret.customers_database_url.metadata[0].name
                key  = "DATABASE_URL"
              }
            }
          }

          volume_mount {
            name       = "customers-seed"
            mount_path = "/sql"
          }
        }

        volume {
          name = "customers-seed"
          config_map {
            name = kubernetes_config_map.customers_seed.metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "3m"
  }

  # Debe existir la base, el usuario/password y el Secret con el DSN antes
  # de que el Job intente conectarse.
  depends_on = [
    google_sql_database.customersdb,
    google_sql_user.app,
    kubernetes_secret.customers_database_url,
  ]
}
