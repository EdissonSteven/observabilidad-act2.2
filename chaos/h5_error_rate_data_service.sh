#!/usr/bin/env bash
# Módulo D, experimento 2: "error rate 10% en data-service".
#
# A diferencia del experimento 1, este SÍ es idéntico en los 3 entornos --
# FAULT_INJECT_ERROR_RATE es una variable de entorno leída por la propia
# app (ver services/data-service/app/main.py), no depende de ninguna
# capability de red ni de la plataforma de contenedores.
#
# Uso:
#   ./chaos/h5_error_rate_data_service.sh local <duración_s>
#   ./chaos/h5_error_rate_data_service.sh gke   <duración_s> <namespace>
#   ./chaos/h5_error_rate_data_service.sh ecs   <duración_s> <cluster> <service>

set -euo pipefail

TARGET="${1:?target requerido: local|gke|ecs}"
DURATION="${2:-40}"
# Sobrescribible por variable de entorno (ej. ERROR_RATE=0.30 ./chaos/h5_...).
# El umbral de las policies de correlación es 5% (var.error_rate_threshold_pct),
# así que 0.10 ya lo dobla; para el experimento combinado se usa 0.30 para
# tener margen holgado incluso si parte del tráfico no llega a data-service.
ERROR_RATE="${ERROR_RATE:-0.10}"

now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

case "$TARGET" in
  local)
    CONTAINER="${CONTAINER:-actividad22-data-service-1}" # ajustar al nombre real: docker compose ps
    echo "[$(now_utc)] FAULT_INJECT_ERROR_RATE=${ERROR_RATE} en $CONTAINER (docker-compose local)"
    docker compose stop data-service
    docker compose run -d --name data-service-chaos \
      -e FAULT_INJECT_ERROR_RATE="${ERROR_RATE}" \
      --service-ports data-service
    FAULT_START="$(now_utc)"
    sleep "$DURATION"
    docker rm -f data-service-chaos
    docker compose up -d data-service
    FAULT_END="$(now_utc)"
    ;;

  gke)
    NAMESPACE="${3:?namespace requerido para gke}"
    echo "[$(now_utc)] FAULT_INJECT_ERROR_RATE=${ERROR_RATE} vía kubectl set env (namespace $NAMESPACE)"
    kubectl set env deployment/data-service -n "$NAMESPACE" FAULT_INJECT_ERROR_RATE="${ERROR_RATE}"
    kubectl rollout status deployment/data-service -n "$NAMESPACE"
    FAULT_START="$(now_utc)"
    sleep "$DURATION"
    kubectl set env deployment/data-service -n "$NAMESPACE" FAULT_INJECT_ERROR_RATE="0"
    kubectl rollout status deployment/data-service -n "$NAMESPACE"
    FAULT_END="$(now_utc)"
    ;;

  ecs)
    CLUSTER="${3:?cluster requerido para ecs}"
    SERVICE="${4:-data-service}"
    echo "[$(now_utc)] FAULT_INJECT_ERROR_RATE=${ERROR_RATE} vía redeploy de ECS (cluster $CLUSTER, service $SERVICE)"
    echo "Ejecuta en iac/terraform/aws: terraform apply -var fault_inject_error_rate=${ERROR_RATE} -target=aws_ecs_task_definition.data_service -target=aws_ecs_service.data_service"
    read -r -p "Presiona Enter cuando el 'apply' anterior haya terminado y el nuevo deployment esté estable (aws ecs describe-services)... "
    FAULT_START="$(now_utc)"
    sleep "$DURATION"
    echo "Ahora revierte: terraform apply -var fault_inject_error_rate=0 -target=aws_ecs_task_definition.data_service -target=aws_ecs_service.data_service"
    read -r -p "Presiona Enter cuando el rollback haya terminado... "
    FAULT_END="$(now_utc)"
    ;;

  *)
    echo "Target no soportado: $TARGET" >&2
    exit 1
    ;;
esac

echo "FAULT_START=${FAULT_START}"
echo "FAULT_END=${FAULT_END}"
echo "Guarda estos dos timestamps -- los necesita chaos/measure_mttd.py."
