#!/usr/bin/env bash
# Ensayo reproducible del Experimento 2 (Módulo D: error rate 10% en
# data-service), CON la fase de "warm-up" que el laboratorio integrador
# descubrió necesaria el 2026-08-29 (ver docs/runbooks/04-modulo-d-chaos.md,
# Paso 0, y docs/reporte-ejecutivo-final.md sección 8): sin unos minutos de
# tráfico limpio ANTES de inyectar el fallo, avg_over_time/stddev_over_time
# del baseline (30m en Prometheus local, 1h en la MQL de GCP) se calculan
# sobre una ventana que es en su mayoría el propio fallo -- el umbral
# "persigue" al valor real y la alerta CorrelatedDegradation nunca dispara,
# aunque el error rate real esté muy por encima de lo normal. Este script
# empaqueta exactamente la secuencia que se corrió a mano esa sesión
# (tráfico de fondo + warm-up con sondeo del baseline + fault + sondeo del
# error rate real durante el fallo) para que cualquiera -- incluida la
# persona que evalúe este laboratorio -- pueda repetirla igual.
#
# Uso:
#   ./chaos/run_experimento_d2.sh local
#   ./chaos/run_experimento_d2.sh local 120 300
#   ./chaos/run_experimento_d2.sh gke 60 1800 observability-lab http://<ip-o-dns>/orders/ord-1002
#
# Argumentos (todos opcionales salvo target):
#   1) target        local | gke
#   2) fault_s        duración del fault en segundos (default 120)
#   3) warmup_s       segundos de tráfico limpio antes del fault (default 300;
#                     en GCP, cuyo baseline usa una ventana de 1h en vez de
#                     30m, un warm-up de 300s sigue siendo mucho más corto
#                     que la ventana completa -- ver la nota de "Paso 0" en
#                     docs/runbooks/04-modulo-d-chaos.md sobre por qué esto
#                     de todos modos ayuda y qué esperar si aun así no
#                     alcanza)
#   4) namespace      requerido solo si target=gke (namespace de K8s)
#   5) load_url       URL de /orders/{id} a golpear con load_gen.py
#                     (default http://localhost:8000/orders/ord-1002)
#
# En target=local requiere Prometheus accesible en http://localhost:9091
# (ver docker-compose.yaml) -- el warm-up y el sondeo durante el fault usan
# su API HTTP directamente (igual que measure_mttd.py --backend local, pero
# aquí además se ve la evolución de error_rate/umbral en vivo, no solo el
# momento del disparo).
#
# En target=gke el warm-up genera tráfico real igual (necesario para el
# baseline de Cloud Monitoring también), pero el sondeo en vivo de
# error_rate/umbral vía curl NO aplica -- Cloud Monitoring no tiene un
# endpoint HTTP simple equivalente a /api/v1/query de Prometheus. Usa
# chaos/measure_mttd.py --backend gcp (instrucciones al final de este
# script) o la consola de Cloud Monitoring para confirmar el disparo.

set -euo pipefail

TARGET="${1:?target requerido: local|gke -- ver el encabezado de este script para uso completo}"
FAULT_DURATION="${2:-120}"
WARMUP_SECONDS="${3:-300}"
NAMESPACE="${4:-}"
LOAD_URL="${5:-http://localhost:8000/orders/ord-1002}"

if [[ "$TARGET" != "local" && "$TARGET" != "gke" ]]; then
  echo "target no soportado: $TARGET (usa local|gke)" >&2
  exit 1
fi

if [[ "$TARGET" == "gke" && -z "$NAMESPACE" ]]; then
  echo "namespace requerido como 4to argumento para target=gke" >&2
  exit 1
fi

now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
TOTAL_DURATION=$((WARMUP_SECONDS + FAULT_DURATION + 30))
OUT_CSV="d2_${TARGET}_$(date +%Y%m%d_%H%M%S).csv"

extract_value() {
  echo "$1" | grep -o '"value":\[[0-9.eE+-]*,"[^"]*"\]' | sed -E 's/.*,"([^"]*)"\].*/\1/'
}

echo "[$(now_utc)] Iniciando tráfico de fondo (${TOTAL_DURATION}s totales: ${WARMUP_SECONDS}s warm-up + ${FAULT_DURATION}s fault + 30s margen) -> ${OUT_CSV}"
python chaos/load_gen.py --url "$LOAD_URL" --duration "$TOTAL_DURATION" --out "$OUT_CSV" &
LOADGEN_PID=$!

echo "=== Warm-up: ${WARMUP_SECONDS}s de tráfico limpio antes de inyectar el fault ==="
if [[ "$TARGET" == "local" ]]; then
  warmup_iters=$((WARMUP_SECONDS / 5))
  for i in $(seq 1 "$warmup_iters"); do
    ts=$(date +%H:%M:%S)
    err_json=$(curl -s 'http://localhost:9091/api/v1/query?query=service_a:data_service_error_rate:ratio_rate2m')
    thr_json=$(curl -s 'http://localhost:9091/api/v1/query?query=service_a:data_service_error_rate:baseline_mean_30m+%2B+2*service_a:data_service_error_rate:baseline_stddev_30m')
    err=$(extract_value "$err_json"); err=${err:-NODATA}
    thr=$(extract_value "$thr_json"); thr=${thr:-NODATA}
    echo "$ts  [warmup] error_rate=$err  umbral=$thr"
    sleep 5
  done
else
  echo "(target=gke: sin sondeo en vivo del baseline -- ver el encabezado del script. Esperando ${WARMUP_SECONDS}s.)"
  sleep "$WARMUP_SECONDS"
fi

echo "=== Fin warm-up, inyectando fault ahora ==="
if [[ "$TARGET" == "local" ]]; then
  bash chaos/h5_error_rate_data_service.sh local "$FAULT_DURATION" &
else
  bash chaos/h5_error_rate_data_service.sh gke "$FAULT_DURATION" "$NAMESPACE" &
fi
H5_PID=$!

if [[ "$TARGET" == "local" ]]; then
  fault_iters=$(( (FAULT_DURATION + 20) / 5 ))
  for i in $(seq 1 "$fault_iters"); do
    ts=$(date +%H:%M:%S)
    err_json=$(curl -s 'http://localhost:9091/api/v1/query?query=service_a:data_service_error_rate:ratio_rate2m')
    thr_json=$(curl -s 'http://localhost:9091/api/v1/query?query=service_a:data_service_error_rate:baseline_mean_30m+%2B+2*service_a:data_service_error_rate:baseline_stddev_30m')
    lat_json=$(curl -s 'http://localhost:9091/api/v1/query?query=service_a:http_latency_p99:2m')
    err=$(extract_value "$err_json"); err=${err:-NODATA}
    thr=$(extract_value "$thr_json"); thr=${thr:-NODATA}
    lat=$(extract_value "$lat_json"); lat=${lat:-NODATA}
    echo "$ts  [fault] error_rate=$err  umbral=$thr  p99=$lat"
    sleep 5
  done
fi

wait "$LOADGEN_PID" "$H5_PID" 2>/dev/null || true

echo "=== Listo. CSV de load_gen: ${OUT_CSV} ==="
if [[ "$TARGET" == "local" ]]; then
  echo "Revisa http://localhost:9091/alerts -- busca 'CorrelatedDegradation' en pending/firing."
  echo "Para el MTTD exacto: python chaos/measure_mttd.py --backend local --fault-start <FAULT_START-impreso-arriba>"
else
  echo "Revisa Cloud Monitoring -> Alerting, o corre:"
  echo "  python chaos/measure_mttd.py --backend gcp --project-id <PROJECT_ID> --alarm-name <cluster_name>-correlated-degradation-data-service --fault-start <FAULT_START-impreso-arriba>"
fi
