#!/usr/bin/env bash
# Módulo D, experimento 1: "inyección de latencia en service-b (200ms)".
#
# Dos modos, porque el método de red real (tc netem) no funciona en los 3
# entornos por igual -- ver el comentario extenso en
# services/service-b/app/main.py:
#   tc    -- tc netem real (docker-compose local, o GKE con NET_ADMIN en el
#            Pod). Preferido: es un fallo de red genuino, no un sleep en el
#            código de la app.
#   env   -- INJECT_LATENCY_MS vía variable de entorno. Único modo viable en
#            AWS ECS Fargate (NET_ADMIN no es una capability que Fargate
#            permita añadir a un contenedor).
#
# Uso:
#   ./chaos/h4_latency_service_b.sh tc local <duración_s>
#   ./chaos/h4_latency_service_b.sh tc gke   <duración_s> <namespace>
#   ./chaos/h4_latency_service_b.sh env ecs  <duración_s> <cluster> <service>
#   ./chaos/h4_latency_service_b.sh env gke  <duración_s> <namespace>
#
# En todos los casos el script imprime el timestamp UTC exacto de inicio y
# fin de la ventana de fallo -- pégalo en chaos/measure_mttd.py para
# calcular el MTTD real contra la alerta que corresponda.

set -euo pipefail

MODE="${1:?modo requerido: tc|env}"
TARGET="${2:?target requerido: local|gke|ecs}"
DURATION="${3:-40}"
LATENCY_MS=200

now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

case "$MODE-$TARGET" in
  tc-local)
    CONTAINER="${CONTAINER:-actividad22-service-b-1}" # ajustar al nombre real: docker compose ps
    echo "[$(now_utc)] tc netem +${LATENCY_MS}ms en $CONTAINER (docker-compose local)"
    docker exec -u root "$CONTAINER" tc qdisc add dev eth0 root netem delay ${LATENCY_MS}ms || \
      docker exec -u root "$CONTAINER" tc qdisc change dev eth0 root netem delay ${LATENCY_MS}ms
    FAULT_START="$(now_utc)"
    sleep "$DURATION"
    docker exec -u root "$CONTAINER" tc qdisc del dev eth0 root
    FAULT_END="$(now_utc)"
    ;;

  tc-gke)
    NAMESPACE="${4:?namespace requerido para tc-gke}"
    POD="$(kubectl get pod -n "$NAMESPACE" -l app=service-b -o jsonpath='{.items[0].metadata.name}')"
    echo "[$(now_utc)] tc netem +${LATENCY_MS}ms en pod $POD (GKE, namespace $NAMESPACE)"
    echo "NOTA: el Pod de service-b debe tener securityContext.capabilities.add=[\"NET_ADMIN\"] -- ver iac/istio/README.md; si no lo tiene, usa el modo 'env' en su lugar."
    kubectl exec -n "$NAMESPACE" "$POD" -c service-b -- tc qdisc add dev eth0 root netem delay ${LATENCY_MS}ms
    FAULT_START="$(now_utc)"
    sleep "$DURATION"
    kubectl exec -n "$NAMESPACE" "$POD" -c service-b -- tc qdisc del dev eth0 root
    FAULT_END="$(now_utc)"
    ;;

  env-ecs)
    CLUSTER="${4:?cluster requerido para env-ecs}"
    SERVICE="${5:-service-b}"
    echo "[$(now_utc)] INJECT_LATENCY_MS=${LATENCY_MS} vía redeploy de ECS (cluster $CLUSTER, service $SERVICE)"
    echo "Ejecuta en iac/terraform/aws: terraform apply -var inject_latency_ms=${LATENCY_MS} -target=aws_ecs_task_definition.service_b -target=aws_ecs_service.service_b"
    read -r -p "Presiona Enter cuando el 'apply' anterior haya terminado y el nuevo deployment esté estable (aws ecs describe-services)... "
    FAULT_START="$(now_utc)"
    sleep "$DURATION"
    echo "Ahora revierte: terraform apply -var inject_latency_ms=0 -target=aws_ecs_task_definition.service_b -target=aws_ecs_service.service_b"
    read -r -p "Presiona Enter cuando el rollback haya terminado... "
    FAULT_END="$(now_utc)"
    ;;

  env-gke)
    NAMESPACE="${4:?namespace requerido para env-gke}"
    echo "[$(now_utc)] INJECT_LATENCY_MS=${LATENCY_MS} vía kubectl set env (namespace $NAMESPACE)"
    kubectl set env deployment/service-b -n "$NAMESPACE" INJECT_LATENCY_MS="${LATENCY_MS}"
    kubectl rollout status deployment/service-b -n "$NAMESPACE"
    FAULT_START="$(now_utc)"
    sleep "$DURATION"
    kubectl set env deployment/service-b -n "$NAMESPACE" INJECT_LATENCY_MS="0"
    kubectl rollout status deployment/service-b -n "$NAMESPACE"
    FAULT_END="$(now_utc)"
    ;;

  *)
    echo "Combinación no soportada: $MODE-$TARGET" >&2
    exit 1
    ;;
esac

echo "FAULT_START=${FAULT_START}"
echo "FAULT_END=${FAULT_END}"
echo "Guarda estos dos timestamps -- los necesita chaos/measure_mttd.py."
