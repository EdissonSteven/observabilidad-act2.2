#!/usr/bin/env bash
# Experimento 4 (Módulo B, Runbook 2 Paso 3): BLIP transitorio de Postgres.
#
# ---------------------------------------------------------------------------
# QUÉ DEMUESTRA Y POR QUÉ HACE FALTA
# ---------------------------------------------------------------------------
# El Módulo B pide cuantificar la "reducción de alertas ruidosas" de la regla
# correlacionada frente a un umbral estático ingenuo. Los Experimentos 1-3 NO
# sirven para eso, por un hallazgo real (2026-08-30, leyendo
# services/service-a/app/main.py):
#
#   service-a NUNCA devuelve 5xx por fallos de sus dependencias. Tanto
#   _check_inventory() (service-b) como _fetch_customer() (data-service)
#   atrapan httpx.HTTPStatusError y httpx.RequestError y devuelven 200 con un
#   campo `error` en el cuerpo. El ÚNICO 500 que produce service-a está en
#   main.py:145 -- cuando falla la consulta del pedido a Postgres.
#
# Por eso `naive_static_threshold` (que vigila http_requests_total{status=500})
# se mantuvo en NODATA durante todo el Experimento 3, pese a que el 30 % de
# las llamadas a data-service estaba fallando. No es un fallo de la alerta:
# es que en este sistema los fallos de dependencias son invisibles a nivel de
# código HTTP. La misma degradación silenciosa que documenta el Módulo D.
#
# Este experimento provoca el ÚNICO fallo que sí genera 5xx: un reinicio del
# pod de Postgres. Es un escenario realista y deliberadamente BENIGNO -- un
# pod que se reinicia (actualización, reprogramación por el scheduler,
# OOMKill puntual) es justo el tipo de evento transitorio que NO debería
# despertar a nadie de guardia.
#
# COMPORTAMIENTO ESPERADO (la hipótesis que este experimento pone a prueba):
#
#   naive_static_threshold   -> DISPARA. Su condición es `rate(5xx) > 0`, y
#     tras el blip la ventana rate[2m] arrastra los errores durante ~2 min,
#     mucho más que los 60 s de su `duration`.
#
#   correlated_degradation   -> NO dispara. Exige error_rate > 5 % Y latencia
#     degradada. Con Postgres caído la consulta falla RÁPIDO, así que la
#     latencia no sube -- la rama de latencia queda en falso y el AND no se
#     cumple. (Mismo mecanismo que hace al Exp. 2 incapaz de disparar, ver
#     chaos/run_experimento_d3_combinado.sh.)
#
# Si eso se confirma, la comparación pedida por el Módulo B queda medida: 1
# alerta ruidosa frente a 0, sobre exactamente el mismo evento y la misma
# ventana de tráfico.
#
# HONESTIDAD SOBRE EL TRADE-OFF: el mismo mecanismo que evita este falso
# positivo produce un FALSO NEGATIVO si Postgres cae de verdad y no se
# recupera -- una caída total tampoco eleva la latencia, así que la regla
# correlacionada tampoco la vería. La correlación no es gratis: cambia ruido
# por ceguera ante fallos que producen errores SIN degradar latencia. Esa es
# la conclusión honesta para el reporte, no "la correlacionada es mejor".
# La cobertura de ese hueco es `naive_static_threshold` con un umbral
# sensato (no `> 0`), o una tercera regla sobre disponibilidad absoluta.
#
# Uso:
#   bash chaos/h6_blip_postgres.sh [namespace] [segundos_de_trafico]
#
# Ejemplo real:
#   bash chaos/h6_blip_postgres.sh observability-lab 420
#
# Requiere kubectl con credenciales del clúster y un port-forward activo a
# service-a en localhost:8000.
set -euo pipefail

NAMESPACE="${1:-observability-lab}"
TRAFFIC_S="${2:-420}"
LOAD_URL="${3:-http://localhost:8000/orders/ord-1002}"

now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_CSV="h6_blip_${STAMP}.csv"

echo "=============================================================="
echo " Experimento 4 -- blip de Postgres (comparacion de ruido, Modulo B)"
echo "=============================================================="
echo " namespace : $NAMESPACE"
echo " trafico   : ${TRAFFIC_S}s -> $OUT_CSV"
echo "=============================================================="

echo "[$(now_utc)] Iniciando trafico de fondo"
python3 chaos/load_gen.py --url "$LOAD_URL" --duration "$TRAFFIC_S" --out "$OUT_CSV" &
LOADGEN_PID=$!

echo "=== 60s de trafico limpio antes del blip ==="
sleep 60

BLIP_START="$(now_utc)"
echo ""
echo "BLIP_START=${BLIP_START}"
echo "[$(now_utc)] Borrando el pod de Postgres (Kubernetes lo recrea solo)"
# `delete pod` y NO `scale --replicas=0`: se quiere un blip transitorio con
# recuperacion automatica, no una caida sostenida. El Deployment recrea el
# pod inmediatamente; la ventana de error dura lo que tarde en estar Ready.
kubectl delete pod -n "$NAMESPACE" -l app=postgres --wait=false

echo "[$(now_utc)] Esperando a que Postgres vuelva a estar Ready..."
sleep 5
kubectl wait --for=condition=ready pod -l app=postgres -n "$NAMESPACE" --timeout=180s || \
  echo "AVISO: el pod no reporto Ready en 180s -- revisa 'kubectl get pods -n $NAMESPACE'"
BLIP_END="$(now_utc)"
echo "BLIP_END=${BLIP_END}"

echo ""
echo "=== Blip terminado. Dejando correr el trafico para ver el efecto ==="
wait "$LOADGEN_PID" 2>/dev/null || true

echo ""
echo "=============================================================="
echo " BLIP_START = ${BLIP_START}"
echo " BLIP_END   = ${BLIP_END}"
echo " CSV        = ${OUT_CSV}"
echo ""
echo " Ahora cuenta los disparos de CADA policy sobre esta misma ventana:"
echo ""
echo "   gcloud alpha monitoring alerts list --project=<PROJECT_ID> \\"
echo "     --filter='state=OPEN OR state=CLOSED' --sort-by=open_time --format=json \\"
echo "     | jq -r '.[] | select(.open_time >= \"${BLIP_START}\") | \"\\(.policy.displayName)  \\(.open_time)\"'"
echo ""
echo " Esperado: aparece observability-lab-gke-naive-static-5xx y NO"
echo " aparecen las dos correlated-degradation. Ese 1-vs-0 ES la medicion"
echo " de reduccion de ruido que pide el Modulo B."
echo "=============================================================="
