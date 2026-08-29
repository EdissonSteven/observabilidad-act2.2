#!/usr/bin/env bash
# Preflight de SOLO LECTURA contra el proyecto GCP -- corre esto ANTES de
# `terraform plan`/`apply` en iac/terraform/gcp. Nada aquí crea, modifica
# ni borra recursos ni habilita APIs de facturación por sí solo.
#
# Uso: ./scripts/gcp_preflight_check.sh <project_id>

set -uo pipefail

PROJECT_ID="${1:?Uso: $0 <project_id>}"
PASS=0
FAIL=0
WARN=0

ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

echo "== Identidad y proyecto =="
if gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 && gcloud projects describe "$PROJECT_ID" >/tmp/preflight_proj 2>&1; then
  ok "Proyecto $PROJECT_ID accesible como $(gcloud config get-value account 2>/dev/null)"
else
  bad "No se pudo acceder al proyecto $PROJECT_ID -- revisa 'gcloud auth login' y que el project_id sea el correcto"
fi

echo ""
echo "== Facturación (Cloud SQL/GKE fallan sin esto) =="
if gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/tmp/preflight_bill | grep -qi true; then
  ok "Facturación habilitada"
else
  bad "Facturación NO habilitada en $PROJECT_ID -- vincula el crédito de \$300 desde la consola (Billing) antes de aplicar nada"
fi

echo ""
echo "== Organización (requerida por Security Command Center) =="
ORG_COUNT="$(gcloud organizations list --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ORG_COUNT" -gt 0 ]; then
  ok "Hay $ORG_COUNT organización(es) -- Security Command Center podría habilitarse; revisar iac/terraform/gcp/network_security.tf (comentario sobre SCC) para agregar el recurso si aplica"
else
  warn "Sin organización de GCP visible (esperado en una cuenta de prueba individual) -- Security Command Center NO se puede habilitar; el Módulo C ya usa Firewall Rule Logging + log-based metrics como sustituto (network_security.tf), documentado como brecha explícita en docs/madurez-observabilidad.md"
fi

echo ""
echo "== Cloud Resource Manager API (bootstrap obligatorio, bloqueante) =="
# Hallazgo real del primer terraform apply contra un proyecto recién creado
# (2026-08-29, observabilidad-lab-507021): TODOS los recursos
# google_project_service (incluido el que intentaría habilitar esta misma
# API) fallaron con "Cloud Resource Manager API has not been used in
# project ... or it is disabled" -- Terraform usa por debajo el Service
# Usage API para gestionar el estado de otras APIs, y ese a su vez depende
# de Cloud Resource Manager para validar el proyecto. Es un problema de
# arranque que Terraform NO puede resolverse a sí mismo (a diferencia de
# las demás APIs de la sección de abajo, que sí se auto-habilitan en el
# apply) -- por eso esto sí es un [FAIL] bloqueante, no un [WARN].
if gcloud services list --enabled --project "$PROJECT_ID" --filter="config.name=cloudresourcemanager.googleapis.com" --format="value(config.name)" 2>/dev/null | grep -q "cloudresourcemanager.googleapis.com"; then
  ok "cloudresourcemanager.googleapis.com ya habilitada"
else
  bad "cloudresourcemanager.googleapis.com NO habilitada -- ningún 'terraform apply' funcionará (todas las google_project_service fallarán) hasta correr: gcloud services enable cloudresourcemanager.googleapis.com --project=$PROJECT_ID"
fi

echo ""
echo "== APIs necesarias (se habilitan solas vía google_project_service en el apply, esto solo informa el estado actual) =="
for api in container.googleapis.com compute.googleapis.com artifactregistry.googleapis.com iam.googleapis.com sqladmin.googleapis.com servicenetworking.googleapis.com monitoring.googleapis.com logging.googleapis.com secretmanager.googleapis.com; do
  if gcloud services list --enabled --project "$PROJECT_ID" --filter="config.name=$api" --format="value(config.name)" 2>/dev/null | grep -q "$api"; then
    ok "$api ya habilitada"
  else
    warn "$api NO habilitada todavía -- el 'apply' la habilita automáticamente (google_project_service, ver iac/terraform/gcp/apis.tf), primer apply puede tardar unos minutos extra por esto"
  fi
done

echo ""
echo "== Cuotas relevantes (GKE + Cloud SQL consumen IP privada/peering) =="
gcloud compute project-info describe --project "$PROJECT_ID" --format="value(quotas)" 2>/dev/null | tr ';' '\n' | grep -iE "CPUS|IN_USE_ADDRESSES" | sed 's/^/     /' || warn "No se pudo leer cuotas de Compute -- revisar manualmente en la consola si el apply falla por cuota"

echo ""
echo "== Permisos del usuario actual (rol efectivo en el proyecto) =="
gcloud projects get-iam-policy "$PROJECT_ID" --flatten="bindings[].members" --filter="bindings.members:$(gcloud config get-value account 2>/dev/null)" --format="table(bindings.role)" 2>/dev/null | sed 's/^/     /'

echo ""
echo "=================================================================="
echo "RESULTADO: $PASS OK, $WARN advertencias, $FAIL fallas"
echo "=================================================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Hay fallas -- resuélvelas (sobre todo facturación) antes de 'terraform plan'."
  exit 1
fi
echo "Sin fallas bloqueantes. Siguiente paso:"
echo "  cd iac/terraform/gcp && terraform init && terraform plan -var project_id=$PROJECT_ID"
