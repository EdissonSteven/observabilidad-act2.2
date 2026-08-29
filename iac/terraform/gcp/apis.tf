# ---------------------------------------------------------------------------
# APIs base del proyecto -- bootstrap explícito.
#
# Hallazgo real del primer `terraform apply` contra un proyecto GCP recién
# creado (observabilidad-lab-507021, 2026-08-29): container.googleapis.com,
# compute.googleapis.com, artifactregistry.googleapis.com e
# iam.googleapis.com NO tenían ningún recurso `google_project_service` que
# las habilitara (a diferencia de sqladmin/servicenetworking/secretmanager
# en cloudsql.tf y monitoring en monitoring_aiops.tf) -- el apply falló con
# "has not been used in project ... or it is disabled" en
# google_compute_network.vpc, google_artifact_registry_repository.images y
# google_service_account.gke_nodes. Se agregan aquí explícitamente, con
# depends_on desde los recursos que las necesitan (ver main.tf).
#
# cloudresourcemanager.googleapis.com es un caso aparte y es la causa raíz
# real de por qué TODOS los `google_project_service` de este módulo (los
# de aquí y los ya existentes en cloudsql.tf/monitoring_aiops.tf) fallaron
# en el primer apply: en un proyecto que nunca la habilitó, el propio
# Service Usage API que Terraform usa por debajo para gestionar el estado
# de otras APIs depende de Cloud Resource Manager para validar el
# proyecto -- es un problema de arranque ("chicken-and-egg") que Terraform
# no puede resolverse a sí mismo. Hay que habilitar esta UNA API
# manualmente, una sola vez por proyecto nuevo, ANTES del primer
# `terraform apply`:
#   gcloud services enable cloudresourcemanager.googleapis.com --project=<project_id>
# (agregado también como chequeo bloqueante en scripts/gcp_preflight_check.sh
# y documentado en docs/runbooks/00-validacion-local-y-preflight.md, Paso 5).
# Se declara igual aquí para que quede gestionada por Terraform de ahí en
# adelante -- una vez habilitada a mano, este bloque es un no-op en
# aplicaciones posteriores.
# ---------------------------------------------------------------------------

resource "google_project_service" "cloudresourcemanager" {
  project            = var.project_id
  service            = "cloudresourcemanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.cloudresourcemanager]
}

resource "google_project_service" "container" {
  project            = var.project_id
  service            = "container.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.cloudresourcemanager]
}

resource "google_project_service" "artifactregistry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.cloudresourcemanager]
}

resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.cloudresourcemanager]
}
