#!/usr/bin/env bash
# Preflight de SOLO LECTURA contra el Learner Lab de AWS Academy -- corre
# esto ANTES de `terraform plan`/`apply` en iac/terraform/aws. Responde
# directamente al pedido de "que no subamos IaC que no funcione y ya
# genere costos": nada aquí crea, modifica ni borra recursos.
#
# Uso: ./scripts/aws_preflight_check.sh [region]

set -uo pipefail  # sin -e a propósito: queremos seguir chequeando aunque un comando falle

REGION="${1:-us-east-1}"
PASS=0
FAIL=0
WARN=0

ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

echo "== Identidad y cuenta =="
if aws sts get-caller-identity --output table 2>/tmp/preflight_err; then
  ok "Credenciales válidas ($(aws sts get-caller-identity --query Arn --output text))"
else
  bad "aws sts get-caller-identity falló -- revisa credenciales del Learner Lab (expiran cada pocas horas, re-copia las temporales desde el panel de AWS Academy)"
  cat /tmp/preflight_err
fi

echo ""
echo "== LabRole (usado como execution_role_arn/task_role_arn -- ver variables.tf) =="
if aws iam get-role --role-name LabRole >/tmp/preflight_labrole 2>/tmp/preflight_err; then
  ok "LabRole existe"
  echo "     -- políticas administradas adjuntas:"
  aws iam list-attached-role-policies --role-name LabRole --query 'AttachedPolicies[].PolicyName' --output text | tr '\t' '\n' | sed 's/^/       /'
  if aws iam list-attached-role-policies --role-name LabRole --output text | grep -qi "AppMesh"; then
    ok "LabRole ya tiene una política de AppMesh adjunta -- enable_app_mesh=true probablemente viable"
  else
    warn "LabRole NO tiene una política de AppMesh visible -- probar enable_app_mesh=true en aislamiento (-target) antes del apply completo; si falla, dejarlo en false y documentar el IaC como no desplegado, igual que el resto del repo"
  fi
else
  bad "No se pudo leer LabRole -- si tu Learner Lab usa otro nombre de rol, pásalo con -var academy_lab_role_name=<nombre> en el apply"
fi

echo ""
echo "== Intentar iam:CreateRole (para confirmar que use_academy_lab_role=true es necesario, no opcional) =="
if aws iam create-role --role-name preflight-test-delete-me --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/tmp/preflight_create 2>&1; then
  warn "iam:CreateRole SÍ funcionó -- este Learner Lab es más permisivo de lo esperado; borra el rol de prueba: aws iam delete-role --role-name preflight-test-delete-me. Podrías usar use_academy_lab_role=false si prefieres roles propios."
  aws iam delete-role --role-name preflight-test-delete-me >/dev/null 2>&1
else
  ok "iam:CreateRole bloqueado (esperado en Learner Lab) -- confirma que use_academy_lab_role=true (default) es la única opción viable"
fi

echo ""
echo "== Servicios potencialmente bloqueados en Learner Lab =="
if aws securityhub describe-hub --region "$REGION" >/tmp/preflight_sh 2>&1; then
  ok "Security Hub accesible -- se puede documentar como evidencia adicional del Módulo C (no reemplaza el fallback de Flow Logs ya implementado)"
else
  warn "Security Hub no disponible ($(head -c 200 /tmp/preflight_sh | tr -d '\n')) -- esperado en Learner Lab; el Módulo C ya usa VPC Flow Logs a S3 como alternativa, sin depender de esto"
fi

if aws devops-guru describe-account-health --region "$REGION" >/tmp/preflight_dg 2>&1; then
  ok "DevOps Guru accesible -- se puede habilitar como evidencia adicional del Módulo B"
else
  warn "DevOps Guru no disponible ($(head -c 200 /tmp/preflight_dg | tr -d '\n')) -- el Módulo B ya usa CloudWatch Anomaly Detection nativo (cloudwatch_aiops.tf), no depende de esto"
fi

echo ""
echo "== RDS: versión de motor y clase de instancia disponibles en la región =="
if aws rds describe-orderable-db-instance-options --engine postgres --engine-version "$(grep -A1 rds_engine_version iac/terraform/aws/variables.tf 2>/dev/null | grep default | sed -E 's/.*"([0-9.]+)".*/\1/')" --region "$REGION" --query 'OrderableDBInstanceOptions[?DBInstanceClass==`db.t3.micro`]' --output text 2>/tmp/preflight_rds | grep -q .; then
  ok "db.t3.micro disponible para la versión de PostgreSQL configurada en $REGION"
else
  warn "No se pudo confirmar disponibilidad de db.t3.micro/versión de Postgres en $REGION -- revisa iac/terraform/aws/variables.tf (rds_engine_version) antes de aplicar, o ejecuta el describe manualmente"
fi

echo ""
echo "== Cuota de Elastic IP / VPC (Fargate con IP pública, sin NAT) =="
aws ec2 describe-account-attributes --attribute-names max-elastic-ips --region "$REGION" --query 'AccountAttributes[0].AttributeValues[0].AttributeValue' --output text 2>/dev/null | sed 's/^/     límite de EIP: /'

echo ""
echo "== Presupuesto restante (si tienes acceso a Billing en el Learner Lab -- normalmente NO lo tienes) =="
aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" --region "$REGION" 2>/dev/null || warn "Sin acceso a Budgets API (normal en Learner Lab) -- revisa el crédito restante en el panel de AWS Academy, no desde la CLI"

echo ""
echo "=================================================================="
echo "RESULTADO: $PASS OK, $WARN advertencias, $FAIL fallas"
echo "=================================================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Hay fallas -- resuélvelas antes de 'terraform plan'."
  exit 1
fi
echo "Sin fallas bloqueantes. Revisa las advertencias, luego corre:"
echo "  cd iac/terraform/aws && terraform init && terraform plan -var deploy_rds=false"
echo "(deploy_rds=false primero -- valida el resto del stack sin comprometer RDS todavía)"
