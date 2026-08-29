# ---------------------------------------------------------------------------
# Cloud SQL for PostgreSQL -- base de datos real de `data-service` (Módulo
# A: "acceda a GCP Cloud SQL"). Misma decisión de alcance que en el lado
# AWS (ver iac/terraform/aws/rds.tf): `orders`/`inventory` siguen en el
# Postgres del clúster ya definido en main.tf; Cloud SQL es la base PROPIA
# de data-service (tabla `customers`).
#
# IP privada (sin IP pública) vía VPC peering con Service Networking --
# el patrón recomendado por GCP para que el pod de data-service en GKE
# hable con Cloud SQL sin pasar por el Cloud SQL Auth Proxy ni exponer la
# instancia a Internet. Requiere reservar un rango de IP y una conexión de
# peering contra la MISMA VPC que el clúster GKE (google_compute_network.vpc
# de main.tf) -- una sola vez por VPC.
#
# db-f1-micro (compartida, 0.6 GB RAM) es la instancia más pequeña de Cloud
# SQL -- de laboratorio, no de producción. Con $300 de crédito de prueba
# hay margen de sobra para mantenerla corriendo varios días, pero el
# runbook igual documenta apagar/destruir al terminar cada ventana de
# evidencia (buena práctica, no solo por costo).
# ---------------------------------------------------------------------------

resource "google_project_service" "sqladmin" {
  project            = var.project_id
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "servicenetworking" {
  project            = var.project_id
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_global_address" "private_ip_range" {
  name          = "${var.network_name}-sql-peering"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id

  depends_on = [google_project_service.servicenetworking]
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}

resource "random_password" "cloudsql_customers" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_sql_database_instance" "customers" {
  name             = "${var.cluster_name}-customers"
  project          = var.project_id
  region           = var.region
  database_version = var.cloudsql_database_version

  # Laboratorio desechable: sin protección de borrado, sin standby de alta
  # disponibilidad, backups deshabilitados -- ver el mismo razonamiento en
  # rds.tf del lado AWS.
  deletion_protection = false

  settings {
    tier              = var.cloudsql_tier
    availability_type = "ZONAL" # sin HA -- de laboratorio
    disk_size         = 10
    disk_autoresize   = false

    backup_configuration {
      enabled = false
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

resource "google_sql_database" "customersdb" {
  name     = "customersdb"
  project  = var.project_id
  instance = google_sql_database_instance.customers.name
}

resource "google_sql_user" "app" {
  name     = "app"
  project  = var.project_id
  instance = google_sql_database_instance.customers.name
  password = random_password.cloudsql_customers.result
}

# DSN completo en Secret Manager -- mismo patrón que Secrets Manager en AWS
# (rds.tf): nunca como env var plana ni en el state legible por cualquiera
# con acceso al proyecto sin permisos explícitos de Secret Manager.
resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_secret_manager_secret" "customers_database_url" {
  project   = var.project_id
  secret_id = "${var.cluster_name}-customers-database-url"

  replication {
    auto {}
  }

  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "customers_database_url" {
  secret = google_secret_manager_secret.customers_database_url.id
  secret_data = format(
    "postgresql://%s:%s@%s:5432/%s",
    google_sql_user.app.name,
    random_password.cloudsql_customers.result,
    google_sql_database_instance.customers.private_ip_address,
    google_sql_database.customersdb.name,
  )
}
