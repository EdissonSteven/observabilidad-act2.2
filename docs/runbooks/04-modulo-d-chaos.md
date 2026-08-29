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
   código):** `avg_over_time`/`stddev_over_time` sobre una ventana móvil
   (30m en Prometheus local, **1h** en la MQL de GCP) se contaminan si el
   propio fallo inyectado ocupa una fracción grande de esa ventana --el
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

**Consecuencia práctica para el Experimento 2 en GCP (más abajo):** dado
que la ventana de baseline en Cloud Monitoring es de **1 hora**, no de
30 minutos, un warm-up de unos pocos minutos ayuda pero es proporcionalmente
mucho más corto que en local -- si la alerta `correlated-degradation-data-service`
no dispara en el primer intento en GCP, antes de asumir que el fix no
sirve, confirma cuánto tráfico limpio real llevaba corriendo el clúster
antes del fault (mientras más tiempo de operación normal previa, mejor
calibrado el baseline).

## Experimento 1 -- latencia 200ms en service-b

```bash
# Terminal 1: tráfico de fondo (deja correr durante TODO el experimento)
python3 chaos/load_gen.py --url http://<endpoint>/orders/ord-1002 --duration 180 --out during_h4_gcp.csv

# Terminal 2: inyecta el fallo vía tc netem en GKE
./chaos/h4_latency_service_b.sh tc gke 60 observability-lab
# (el modo "env ecs ..." es el equivalente para AWS Fargate -- no se ejecuta en esta entrega)

# Anota el FAULT_START impreso, y en paralelo (Terminal 3):
python3 chaos/measure_mttd.py --backend gcp --project-id <id> --alarm-name observability-lab-correlated-degradation --fault-start <FAULT_START>
```

## Experimento 2 -- error rate 10% en data-service

**Importante -- no dispares el fault de inmediato:** ver Paso 0 arriba
(baseline envenenado si no hay tráfico limpio previo). Usa
`chaos/run_experimento_d2.sh`, que ya encadena tráfico + warm-up + fault
en el orden correcto:

```bash
./chaos/run_experimento_d2.sh gke 60 1800 observability-lab http://<endpoint>/orders/ord-1002
# fault_s=60, warmup_s=1800 (30 min -- una fracción más razonable de la
# ventana de 1h de Cloud Monitoring que los 5 min usados en el ensayo
# local; ajustar según el tiempo/crédito disponible)
```

Anota el `FAULT_START` que imprime `h5_error_rate_data_service.sh` (el
script lo muestra en su salida) y mide el MTTD real:

```bash
python chaos/measure_mttd.py --backend gcp --project-id <id> --alarm-name <cluster_name>-correlated-degradation-data-service --fault-start <FAULT_START>
```

(Comando equivalente sin el wrapper, si se prefiere correr los pasos a
mano: `python3 chaos/load_gen.py --url http://<endpoint>/orders/ord-1002 --duration 180 --out during_h5_gcp.csv &` seguido de
`./chaos/h5_error_rate_data_service.sh gke 60 observability-lab` -- pero
dejando pasar el warm-up de tráfico limpio ANTES del segundo comando.)

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
