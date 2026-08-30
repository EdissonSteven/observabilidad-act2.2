# Runbook 4 -- Módulo D: Chaos Engineering controlado + MTTD

Requiere Módulo A y B ya desplegados y con alertas activas en GCP
(Runbooks 1-2). **Alcance de esta entrega: solo GCP** -- los comandos
`env ecs ...` de abajo quedan documentados como diseño de referencia para
AWS Fargate, no se ejecutan. **Corre esto en UNA sola ventana de tiempo**
-- son los pasos que más crédito/tiempo consumen; no los repitas sin
necesidad.

## Paso 0 -- Ensayo local antes de gastar presupuesto de GCP (recomendado)

Antes de correr el Experimento 2 contra GCP, se ensayó completo en local
(docker-compose), sesión del 2026-08-29 documentada en
`docs/reporte-ejecutivo-final.md` sección 8. Encontró y corrigió dos
problemas ANTES de tocar la nube real:

1. **Falso negativo de la alerta (bug de arquitectura):** cuando
   data-service falla, service-a lo atrapa en `_fetch_customer()` y
   responde 200 igual -- `http_requests_total` nunca ve un 5xx para este
   caso. Se corrigió añadiendo la señal `data_service_calls_total` a
   `observability/prometheus/alert_rules.yml` y a las dos policies/alarmas
   de nube (`iac/terraform/gcp/monitoring_aiops.tf`,
   `iac/terraform/aws/cloudwatch_aiops.tf`).
2. **Baseline envenenado por el propio experimento (metodológico, no de
   código) -- SOLO APLICA A PROMETHEUS LOCAL:** `avg_over_time`/
   `stddev_over_time` sobre una ventana móvil de 30m se contaminan si el
   propio fallo inyectado ocupa una fracción grande de esa ventana -- el
   umbral "persigue" al valor real y la alerta nunca dispara, aunque el
   error rate esté muy por encima de lo normal. Requiere dejar correr
   tráfico limpio ANTES de inyectar el fallo, el tiempo suficiente para
   que el baseline se asiente. Además se blindó la fórmula con
   `clamp_min(..., 1e-9)` en el denominador para que "sin tráfico" no
   produzca `NaN` (que también envenena el baseline, de forma más sutil
   y persistente: un solo `NaN` dentro de la ventana hace `NaN` todo el
   agregado, y `valor > NaN` siempre es `false`).

Repetir el ensayo local (opcional pero recomendado antes de gastar
presupuesto real):

```bash
bash chaos/run_experimento_d2.sh local
# o con duración/warm-up explícitos:
bash chaos/run_experimento_d2.sh local 120 300
```

El script deja correr tráfico limpio primero (default 300s), sondeando
en vivo `error_rate`/`umbral`, y solo entonces dispara el fault -- ver
`chaos/run_experimento_d2.sh` para el detalle completo y las referencias.
Verifica en `http://localhost:9091/alerts` que `CorrelatedDegradation`
pase de `inactive` a `pending` a `firing`.

**CORRECCIÓN IMPORTANTE para el Experimento 2 en GCP (2026-08-30):** el
párrafo anterior sobre una ventana de baseline de "1 hora" en la MQL de
GCP describía el diseño ORIGINAL (baseline dinámico media+2σ con
`mean_prev_by`/`stddev_prev_by`), que se abandonó -- ver
`variables.tf`/`error_rate_threshold_pct` y la cabecera de
`monitoring_aiops.tf` (hallazgo 3) para el porqué (esas funciones no
existen en MQL). Las 3 policies de GCP que están APLICADAS ahora mismo
(`correlated_degradation`, `correlated_degradation_data_service`,
`naive_static_threshold`) usan un **umbral ESTÁTICO** sobre una tasa
instantánea (`align rate(1m)`), sin ninguna ventana de baseline que deba
"asentarse" -- **el warm-up largo (1800s=30min) del ejemplo de más abajo
YA NO ES NECESARIO en GCP** y solo aplica en el sentido de "quiero ver
tráfico limpio antes del fallo para el gráfico/reporte", no como
requisito técnico. Un warm-up corto (60-120s) es suficiente para el
Experimento 2 en GCP; el warm-up largo sigue siendo válido/recomendado
solo si en algún momento se repite el ensayo LOCAL (Prometheus SÍ usa el
baseline dinámico real de 30 min).

## Experimento 1 -- latencia 200ms en service-b

**Hallazgo real (2026-08-30) sobre el modo "tc":** la imagen de service-b
(`services/service-b/Dockerfile`) no traía `iproute2` (el paquete que da
el binario `tc`) -- el modo `tc gke` habría fallado en el pod real con
`tc: command not found`. Ya se agregó al Dockerfile, pero usarlo requiere
reconstruir y volver a subir la imagen a Artifact Registry antes de poder
usarlo (`docker build` + `docker push` + `kubectl rollout restart`). Para
no perder tiempo en un rebuild, el modo recomendado AHORA es `env`
(`INJECT_LATENCY_MS`, vía `kubectl set env` -- no requiere ningún cambio
de imagen, ya está soportado por el código de `service-b` desde antes).
Si más adelante hay tiempo/interés en el fallo de red "genuino" (`tc`),
reconstruye la imagen primero.

Nombres de alert policy confirmados en la consola real (ver
`gcloud alpha monitoring policies list`, 2026-08-30):
`observability-lab-gke-correlated-degradation`,
`observability-lab-gke-correlated-degradation-data-service`,
`observability-lab-gke-naive-static-5xx` (con el `-gke` del
`cluster_name`, que un ejemplo anterior de este runbook omitía).

```bash
# Terminal 1: tráfico de fondo (deja correr durante TODO el experimento)
python3 chaos/load_gen.py --url http://localhost:8000/orders/ord-1002 --duration 180 --out during_h4_gcp.csv

# Terminal 2: inyecta el fallo (modo env -- no requiere rebuild de imagen)
./chaos/h4_latency_service_b.sh env gke 60 observability-lab
# (el modo "tc gke ..." queda disponible tras reconstruir la imagen; "env ecs ..." es el equivalente para AWS Fargate -- no se ejecuta en esta entrega)

# Anota el FAULT_START impreso, y en paralelo (Terminal 3):
python3 chaos/measure_mttd.py --backend gcp --project-id observabilidad-lab-507021 --alarm-name observability-lab-gke-correlated-degradation --fault-start <FAULT_START>
```

## Experimento 2 -- error rate 10% en data-service

**Nota (2026-08-30): el aviso original de "no dispares el fault de
inmediato" era por el baseline dinámico (media+2σ) que ya NO se usa en
GCP** -- ver la corrección en el Paso 0 de arriba. Un warm-up corto ya es
suficiente aquí; se deja el wrapper igual porque sigue siendo útil para
tener tráfico limpio de referencia en el CSV/gráfico del reporte, no por
necesidad técnica del umbral estático.

```bash
./chaos/run_experimento_d2.sh gke 60 90 observability-lab http://localhost:8000/orders/ord-1002
# fault_s=60, warmup_s=90 (suficiente para tener tráfico limpio de
# referencia en el CSV -- ya NO hace falta 1800s, ver nota de arriba)
```

Anota el `FAULT_START` que imprime `h5_error_rate_data_service.sh` (el
script lo muestra en su salida) y mide el MTTD real:

```bash
python3 chaos/measure_mttd.py --backend gcp --project-id observabilidad-lab-507021 --alarm-name observability-lab-gke-correlated-degradation-data-service --fault-start <FAULT_START>
```

(Comando equivalente sin el wrapper, si se prefiere correr los pasos a
mano: `python3 chaos/load_gen.py --url http://localhost:8000/orders/ord-1002 --duration 180 --out during_h5_gcp.csv &` seguido de
`./chaos/h5_error_rate_data_service.sh gke 60 observability-lab` -- pero
dejando pasar el warm-up corto de tráfico limpio ANTES del segundo
comando.)

`measure_mttd.py --backend gcp` ahora sondea en vivo (cada 5s, hasta
`--timeout-s`, default 900s=15min) usando `gcloud alpha monitoring alerts
list` -- corre el comando de arriba EN PARALELO al fault (no después), y
se queda esperando hasta ver el incidente `OPEN` o hasta agotar el
timeout.

## Preguntas a responder con datos reales (para el reporte)

1. **¿MTTD < 2 minutos?** Compara el `MTTD=...s` impreso por
   `measure_mttd.py` contra 120s, en CADA experimento y CADA nube donde se
   ejecutó.
2. **¿Se degradó el SLO?** Compara `during_h4_<nube>.csv`/`during_h5_<nube>.csv`
   contra una corrida de baseline sin fallo (mismo `load_gen.py`, sin el
   script de chaos corriendo) -- p50/p95/p99 antes/durante, igual que la
   tabla ya usada en `GameDay_Plan.pdf` de la actividad anterior.
3. **¿Se consumió el error budget?** Con SLO de disponibilidad asumido
   (ej. 99.5% mensual -> error budget de 0.5%), calcula qué fracción de
   ese presupuesto mensual consumió la ventana del experimento:
   `(peticiones_fallidas_o_degradadas / peticiones_totales_del_mes_asumido) / 0.005`.
   Documentar el supuesto de tráfico mensual usado para el cálculo
   (no hay tráfico de producción real que medir).
4. **¿La alerta fue accionable?** ¿El mensaje de la alerta (SNS/notification
   channel) traía suficiente contexto (trace_id/enlace a logs) para que
   alguien sin este contexto supiera qué mirar primero? Responder con la
   captura real del mensaje recibido, no en abstracto.

## Evidencia a capturar

- Los 2 CSV de `load_gen.py` (uno por experimento, en GCP).
- La salida completa de `measure_mttd.py` (incluye el MTTD calculado).
- Gráfico de latencia real por request durante cada experimento (reutilizar
  el script de matplotlib ya usado para `GameDay_Plan.pdf` si sigue
  disponible, o generar uno nuevo a partir de los CSV de arriba).
- Captura del mensaje de alerta recibido (email/SNS/notification channel).
