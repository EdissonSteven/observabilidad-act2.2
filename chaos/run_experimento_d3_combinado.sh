#!/usr/bin/env bash
# Experimento 3 (Módulo D): degradación CORRELACIONADA -- latencia elevada
# en service-b Y error rate elevado en data-service AL MISMO TIEMPO.
#
# ---------------------------------------------------------------------------
# POR QUÉ EXISTE ESTE EXPERIMENTO (hallazgo real, 2026-08-30)
# ---------------------------------------------------------------------------
# Los Experimentos 1 y 2 se ejecutaron contra GKE real y NINGUNO logró
# disparar las policies de correlación, pese a que el fallo inyectado era
# real y medible en los CSV de load_gen.py. Hubo varias causas encadenadas
# (ver el bloque "HALLAZGO 5" de iac/terraform/gcp/monitoring_aiops.tf para
# la historia completa: mTLS de Istio cortando el scraping, histogram_quantile
# interpolando sobre un SLO que no coincidía con ninguna frontera de bucket,
# y rate() devolviendo NaN sin tráfico). Pero una de ellas es ESTRUCTURAL y
# sobrevive a todas las correcciones, y es la razón de ser de este script.
#
# Ambas policies de correlación (`correlated_degradation` y
# `correlated_degradation_data_service`) evalúan, en PromQL:
#
#     (error_rate > umbral) and (fraccion_bajo_SLO < 0.99)
#
# es decir, exigen señal de error Y señal de latencia AL MISMO TIEMPO. Los
# umbrales reales (ver variables.tf) son:
#
#   - var.latency_p99_slo_ms       = 250 -> bucket le="0.25"; se exige que
#                                           MENOS del 99 % de las peticiones
#                                           esté por debajo de 250 ms
#   - var.error_rate_threshold_pct = 5   -> error_rate > 5 %
#
# Y cada experimento de un solo síntoma produce solo UNA de las dos señales:
#
#   * Experimento 1 (h4, latencia 200 ms en service-b): sube la latencia
#     pero no genera errores -- service-a llama a service-b con un timeout
#     httpx de 5 s (services/service-a/app/main.py), muy por encima de los
#     200 ms inyectados, así que ninguna petición falla. La rama de error es
#     siempre falsa -> el AND nunca se cumple.
#
#   * Experimento 2 (h5, error rate en data-service): la inyección de fallo
#     de data-service es un *fast-fail* -- devuelve 500 ANTES de tocar la
#     base de datos y sin retardo artificial, o sea que es MÁS RÁPIDA que
#     una respuesta normal. Sube la rama de error pero NO sube (incluso baja)
#     la latencia -> la rama de latencia es falsa -> el AND tampoco se cumple.
#
# Conclusión honesta: un fallo de UN SOLO síntoma no puede activar una regla
# de correlación de DOS síntomas. Eso no es un defecto de la regla -- es
# exactamente su propósito, y es justamente lo que la hace menos ruidosa que
# `naive_static_threshold` (que sí dispara con un solo 500 suelto). Para
# probar de verdad una policy llamada "correlated degradation" hace falta un
# fallo correlacionado: este script.
#
# Escenario que simula: una dependencia degradada que simultáneamente se
# vuelve lenta y empieza a fallar -- la firma típica de un incidente real
# (saturación de pool de conexiones, GC thrashing, disco degradado), y
# precisamente el caso que la correlación busca distinguir del ruido.
#
# ---------------------------------------------------------------------------
# SONDEO EN VIVO CONTRA CLOUD MONITORING
# ---------------------------------------------------------------------------
# chaos/run_experimento_d2.sh afirmaba en su encabezado que "Cloud Monitoring
# no tiene un endpoint HTTP simple equivalente a /api/v1/query de Prometheus".
# Eso resultó ser FALSO y se comprobó en vivo el 2026-08-30: Google Managed
# Service for Prometheus expone una API compatible con PromQL en
# https://monitoring.googleapis.com/v1/projects/PROJECT_ID/location/global/prometheus/api/v1/query
# (documentado en https://docs.cloud.google.com/stackdriver/docs/managed-prometheus/query-api-ui).
# Este script la usa para mostrar en vivo, cada 15 s, si `error_high` y
# `latency_high` son verdaderos -- de modo que si la alerta NO dispara se
# pueda ver EN EL MOMENTO cuál de las dos condiciones faltó, en vez de
# deducirlo después.
#
# OJO con los nombres: en esta API PromQL se usa el nombre NATIVO de
# Prometheus (`http_requests_total`), mientras que en MQL / Metrics Explorer
# la misma métrica se llama `prometheus.googleapis.com/http_requests_total/counter`.
#
# ---------------------------------------------------------------------------
# Uso:
#   bash chaos/run_experimento_d3_combinado.sh <project_id> [fault_s] [warmup_s] [namespace] [load_url]
#
# Ejemplo real:
#   bash chaos/run_experimento_d3_combinado.sh observabilidad-lab-507021 360 60 observability-lab http://localhost:8000/orders/ord-1002
#
# Argumentos:
#   1) project_id   (requerido) proyecto de GCP
#   2) fault_s      duración del fault en segundos (default 360). DEBE ser
#                   holgadamente mayor que los 60 s de `duration` de la
#                   condition MÁS la ventana rate[2m] que la alimenta MÁS el
#                   retardo de ingesta (~30-60 s) MÁS el overhead de los
#                   rollouts de kubectl set env (~40-60 s por deployment).
#                   360 s deja margen cómodo para medir un MTTD limpio.
#   3) warmup_s     tráfico limpio antes del fault (default 60). Con umbral
#                   estático ya no hace falta un baseline largo -- ver la
#                   corrección del Paso 0 en docs/runbooks/04-modulo-d-chaos.md.
#   4) namespace    namespace de K8s (default observability-lab)
#   5) load_url     URL de /orders/{id} (default http://localhost:8000/orders/ord-1002,
#                   asumiendo kubectl port-forward activo hacia service-a)
#
# Requiere: kubectl con credenciales del clúster, gcloud autenticado, jq.
set -euo pipefail

PROJECT_ID="${1:?project_id requerido -- ej: observabilidad-lab-507021}"
FAULT_DURATION="${2:-360}"
WARMUP_SECONDS="${3:-60}"
NAMESPACE="${4:-observability-lab}"
LOAD_URL="${5:-http://localhost:8000/orders/ord-1002}"

# Márgenes holgados sobre los umbrales reales de variables.tf:
#   500 ms inyectados vs SLO de 250 ms  -> TODAS las peticiones se van por
#     encima del bucket le=0.25, así que la fracción se desploma de ~1.0 a
#     ~0 (umbral: < 0.99). Sin ambigüedad.
#   30 % de error rate vs umbral de 5 %  -> 6x el umbral.
export LATENCY_MS="${LATENCY_MS:-500}"
export ERROR_RATE="${ERROR_RATE:-0.30}"

# Deben coincidir con iac/terraform/gcp/variables.tf:
#   SLO_LE            = latency_p99_slo_ms / 1000  (frontera de bucket real)
#   ERR_THRESHOLD_PCT = error_rate_threshold_pct
SLO_LE="${SLO_LE:-0.25}"
ERR_THRESHOLD_PCT="${ERR_THRESHOLD_PCT:-5}"

for bin in kubectl gcloud jq python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "falta '$bin' en el PATH" >&2; exit 1; }
done

now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
TOTAL_DURATION=$((WARMUP_SECONDS + FAULT_DURATION + 60))
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_CSV="d3_combinado_${STAMP}.csv"
PROBE_LOG="d3_combinado_${STAMP}_probe.log"

PROM_API="https://monitoring.googleapis.com/v1/projects/${PROJECT_ID}/location/global/prometheus/api/v1/query"
# El token dura ~1 h, muy por encima de la duración del experimento: se pide
# una sola vez en vez de en cada iteración del sondeo (que sería lento).
ACCESS_TOKEN="$(gcloud auth print-access-token)"

# Ventana [2m] y forma EXACTA de las consultas de las alert policies
# (iac/terraform/gcp/monitoring_aiops.tf) -- a propósito: lo que este script
# imprime es literalmente lo que la policy está evaluando, así que si las dos
# condiciones salen en SI y aun así no dispara, el problema ya no es el
# experimento sino la policy.
Q_ERROR_RATE="100 * sum(rate(data_service_calls_total{namespace=\"${NAMESPACE}\",outcome!=\"success\"}[2m])) / sum(rate(data_service_calls_total{namespace=\"${NAMESPACE}\"}[2m]))"
# Fracción de peticiones bajo el bucket del SLO (250ms). < 0.99 equivale a
# "p99 > 250ms", pero es un conteo exacto sin la interpolación de
# histogram_quantile -- ver hallazgo 5 en monitoring_aiops.tf.
Q_LAT_FRAC="sum(rate(http_request_duration_seconds_bucket{namespace=\"${NAMESPACE}\",le=\"${SLO_LE}\"}[2m])) / sum(rate(http_request_duration_seconds_count{namespace=\"${NAMESPACE}\"}[2m]))"
Q_HTTP_ERR_RATE="100 * sum(rate(http_requests_total{namespace=\"${NAMESPACE}\",status=\"500\"}[2m])) / sum(rate(http_requests_total{namespace=\"${NAMESPACE}\"}[2m]))"

promql() {
  # Devuelve el valor escalar de una consulta instantánea, o "NODATA".
  # --data-urlencode (no -d) porque las consultas traen {}, "", != y espacios.
  curl -s "$PROM_API" \
    --data-urlencode "query=$1" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    | jq -r '.data.result[0].value[1] // "NODATA"' 2>/dev/null || echo "NODATA"
}

probe_once() {
  local tag="$1" ts err latfrac httperr eflag lflag
  ts=$(date -u +%H:%M:%SZ)
  err=$(promql "$Q_ERROR_RATE")
  latfrac=$(promql "$Q_LAT_FRAC")
  httperr=$(promql "$Q_HTTP_ERR_RATE")
  # Réplica exacta de las dos condiciones de la policy, para ver cuál falta.
  # NaN/VACIO (sin tráfico, denominador 0) cuentan como "no" -- igual que en
  # PromQL, donde toda comparación con NaN es falsa.
  eflag=$(python3 -c "
try: print('SI' if float('$err') > ${ERR_THRESHOLD_PCT} else 'no')
except Exception: print('-')
")
  lflag=$(python3 -c "
try: print('SI' if float('$latfrac') < 0.99 else 'no')
except Exception: print('-')
")
  printf '%s [%s] ds_error=%s%% (>%s%%? %s)  frac_bajo_%ss=%s (<0.99? %s)  http_5xx=%s%%\n' \
    "$ts" "$tag" "$err" "$ERR_THRESHOLD_PCT" "$eflag" "$SLO_LE" "$latfrac" "$lflag" "$httperr" \
    | tee -a "$PROBE_LOG"
}

echo "=============================================================="
echo " Experimento 3 -- degradación CORRELACIONADA (latencia + errores)"
echo "=============================================================="
echo " project_id    : $PROJECT_ID"
echo " namespace     : $NAMESPACE"
echo " latencia      : ${LATENCY_MS} ms en service-b   (SLO = bucket le=${SLO_LE}s)"
echo " error rate    : ${ERROR_RATE} en data-service   (umbral = ${ERR_THRESHOLD_PCT} %)"
echo " warm-up       : ${WARMUP_SECONDS}s"
echo " fault         : ${FAULT_DURATION}s  (condition duration = 60s)"
echo " CSV load_gen  : $OUT_CSV"
echo " log de sondeo : $PROBE_LOG"
echo "=============================================================="

echo "[$(now_utc)] Iniciando tráfico de fondo (${TOTAL_DURATION}s) -> ${OUT_CSV}"
python3 chaos/load_gen.py --url "$LOAD_URL" --duration "$TOTAL_DURATION" --out "$OUT_CSV" &
LOADGEN_PID=$!

echo ""
echo "=== Warm-up: ${WARMUP_SECONDS}s de tráfico limpio (baseline para el CSV) ==="
warm_iters=$(( WARMUP_SECONDS / 15 )); [[ $warm_iters -lt 1 ]] && warm_iters=1
for _ in $(seq 1 "$warm_iters"); do
  probe_once "warmup"
  sleep 15
done

echo ""
echo "=== Inyectando AMBOS fallos simultáneamente ==="
FAULT_START="$(now_utc)"
echo "FAULT_START=${FAULT_START}"
echo "FAULT_START=${FAULT_START}" >> "$PROBE_LOG"

bash chaos/h4_latency_service_b.sh env gke "$FAULT_DURATION" "$NAMESPACE" &
H4_PID=$!
bash chaos/h5_error_rate_data_service.sh gke "$FAULT_DURATION" "$NAMESPACE" &
H5_PID=$!

echo ""
echo "=== Sondeando ambas condiciones en vivo contra Cloud Monitoring ==="
echo "(si la alerta no dispara, este log muestra CUÁL de las dos condiciones faltó)"
fault_iters=$(( (FAULT_DURATION + 60) / 15 ))
for _ in $(seq 1 "$fault_iters"); do
  probe_once "fault"
  sleep 15
done

wait "$LOADGEN_PID" "$H4_PID" "$H5_PID" 2>/dev/null || true

echo ""
echo "=============================================================="
echo " Listo. Evidencia generada:"
echo "   - $OUT_CSV       (latencia por request, load_gen)"
echo "   - $PROBE_LOG     (evolución de ambas condiciones)"
echo ""
echo " FAULT_START = ${FAULT_START}"
echo ""
echo " Mide el MTTD real (corre esto EN PARALELO la próxima vez):"
echo "   python3 chaos/measure_mttd.py --backend gcp \\"
echo "     --project-id ${PROJECT_ID} \\"
echo "     --alarm-name observability-lab-gke-correlated-degradation-data-service \\"
echo "     --fault-start ${FAULT_START}"
echo "=============================================================="
