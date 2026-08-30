# Runbook 4 -- Módulo D: Chaos Engineering controlado + MTTD

> **ESTADO: EJECUTADO Y CERRADO (2026-08-30).** Los resultados reales, con
> las 4 preguntas del final de este runbook ya respondidas con datos
> medidos, están en **`docs/modulo-d-resultados.md`**. Este runbook queda
> como procedimiento reproducible; lee ese documento primero si lo que
> buscas son los hallazgos.
>
> **Resumen de lo que pasó:** los Experimentos 1 y 2 (de un solo síntoma)
> NO dispararon las policies de correlación, por una razón estructural que
> se confirmó midiendo -- una regla que exige `error_high AND latency_high`
> no puede activarse con un fallo que produce solo una de las dos señales.
> Se añadió el **Experimento 3 (combinado)**, que sí disparó, con
> MTTD = 282 s.
>
> **Cambios de configuración desde la redacción original de este runbook:**
> - Las 3 alert policies se migraron de MQL a **PromQL**
>   (`condition_prometheus_query_language`), por verificabilidad -- ver el
>   hallazgo 5 en la cabecera de `iac/terraform/gcp/monitoring_aiops.tf`.
> - El SLO de latencia bajó de 300 ms a **250 ms**, para que coincida con
>   una frontera real de bucket del histograma (`_SECONDS_BUCKETS` no
>   incluye 0.3). Cualquier referencia a "300 ms" más abajo está obsoleta.
> - El `duration` de las conditions bajó de 180 s a **60 s**.
> - Antes de correr NADA de este runbook, aplica
>   `iac/istio/peer-authentication-otel-collector-metrics-permissive.yaml`
>   o el mTLS STRICT de Istio bloqueará el scraping de métricas y ninguna
>   alerta podrá disparar (ver `iac/istio/README.md`).

Requiere Módulo A y B ya desplegados y con alertas activas en GCP
(Runbooks 1-2). **Alcance de esta entrega: solo GCP** -- los comandos
`env ecs ...` de abajo quedan documentados como diseño de referencia para
AWS Fargate, no se ejecutan. **Corre esto en UNA sola ventana de tiempo**
-- son los pasos que más crédito/tiempo consumen; no los repitas sin
necesidad.

## Regla operativa aprendida (léela antes de diagnosticar cualquier "sin datos")

**Valida siempre con tráfico activo.** Sin tráfico, `rate()` devuelve 0 en
todos los buckets, `histogram_quantile` produce `NaN`, y Google Managed
Prometheus DESCARTA el `NaN` (devuelve resultado vacío, no "NaN"). Durante
la depuración esto produjo varios falsos "la métrica no existe" que
desviaron el diagnóstico durante un buen rato. Si una consulta parece no
tener datos, lo primero es comprobar que `load_gen.py` esté corriendo.

Para consultar métricas sin depender de la UI de Metrics Explorer, usa la
API PromQL de Cloud Monitoring
(https://docs.cloud.google.com/stackdriver/docs/managed-prometheus/query-api-ui):

```bash
TOK=$(gcloud auth print-access-token)
API=https://monitoring.googleapis.com/v1/projects/<PROJECT_ID>/location/global/prometheus/api/v1/query
curl -s "$API" --data-urlencode 'query=http_requests_total' -H "Authorization: Bearer $TOK" | jq '.data.result | length'
```

Ojo con los nombres: en esta API se usa el nombre NATIVO de Prometheus
(`http_requests_total`); en MQL y en el selector de Metrics Explorer la
misma métrica se llama `prometheus.googleapis.com/http_requests_total/counter`.

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

## Experimento 3 -- degradación CORRELACIONADA (latencia + errores a la vez)

**Este es el experimento que efectivamente dispara las policies de
correlación.** Los Experimentos 1 y 2 no pueden hacerlo: cada uno produce
un solo síntoma, y las policies exigen los dos simultáneamente. No es un
defecto de las reglas -- es exactamente lo que las hace menos ruidosas que
`naive_static_threshold`. Ver la cabecera de
`chaos/run_experimento_d3_combinado.sh` para el razonamiento completo y la
evidencia que lo confirma.

Simula la firma real de una dependencia degradada: se vuelve lenta **y**
empieza a fallar al mismo tiempo (saturación de pool de conexiones, GC
thrashing, disco degradado).

```bash
bash chaos/run_experimento_d3_combinado.sh observabilidad-lab-507021 360 60 observability-lab http://localhost:8000/orders/ord-1002
```

Inyecta 500 ms en `service-b` (contra un SLO de 250 ms) y 30 % de error
rate en `data-service` (contra un umbral de 5 %) -- márgenes holgados a
propósito. Cada 15 s consulta Cloud Monitoring en vivo e imprime el estado
de AMBAS condiciones, con la forma exacta de las consultas que evalúan las
policies:

```
05:48:00Z [fault] ds_error=13.5% (>5%? SI)  frac_bajo_0.25s=0.02 (<0.99? SI)  http_5xx=NODATA%
```

Si las dos salen en `SI` y aun así no dispara, el problema ya no es el
experimento sino la policy. Ese log queda en `d3_combinado_*_probe.log` y
sirve directo como evidencia.

`fault_s = 360` es el mínimo prudente: debe cubrir el `duration` de 60 s,
más la ventana `rate[2m]` que lo alimenta, más el retardo de ingesta, más
el overhead de los rollouts de `kubectl set env` (~45 s).

Mide el MTTD en paralelo, con el `FAULT_START` que imprime el script:

```bash
python3 chaos/measure_mttd.py --backend gcp --project-id observabilidad-lab-507021 \
  --alarm-name observability-lab-gke-correlated-degradation-data-service \
  --fault-start <FAULT_START>
```

## Análisis de SLO y error budget (preguntas 2 y 3, automatizado)

`chaos/analyze_error_budget.py` responde las preguntas 2 y 3 de abajo desde
el CSV real, comparando la ventana limpia contra la de fallo **del mismo
CSV** (elimina la variabilidad entre corridas):

```bash
python3 chaos/analyze_error_budget.py \
  --csv d3_combinado_<STAMP>.csv \
  --loadgen-start <t0> --fault-start <t1> --fault-end <t2>
```

Cuidado con dónde pones `--fault-start`: si lo pones en el fin del rollout,
los segundos de rollout quedan dentro de la ventana "limpia" y contaminan
el baseline. Usa el instante en que se emitió el comando de inyección.

El script cuenta "petición degradada" por DOS criterios separados a
propósito: fallo HTTP (`status != 200`) y violación del SLO de latencia.
En este sistema no coinciden, y esa divergencia es el resultado central del
laboratorio -- ver `docs/modulo-d-resultados.md`.

## Preguntas a responder con datos reales (para el reporte)

> **Ya respondidas con datos medidos en `docs/modulo-d-resultados.md`.**
> Resumen: (1) MTTD = 282 s, NO cumple el objetivo de 120 s, y el piso lo
> pone la latencia del pipeline de métricas, no la config de la alerta;
> (2) sí, p50 3.3x y violación del SLO 15.71 % → 88.44 %; (3) sí, 2.31 %
> del presupuesto mensual en ~7 min -- pero 0.00 % si el SLI fuera solo
> códigos HTTP; (4) parcialmente, el contexto está en la documentación de
> la policy pero el resumen del mensaje llega con `metric: __missing__`.

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
