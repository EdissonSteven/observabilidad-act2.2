# Módulo D -- Resultados del Chaos Engineering controlado (GCP real)

Ejecutado el 2026-08-30 contra el proyecto `observabilidad-lab-507021`
(clúster `observability-lab-gke`, namespace `observability-lab`). Todos los
números de este documento salen de artefactos reales guardados en
`docs/evidencia/modulo-d/`; ninguno es estimado.

## Experimentos ejecutados

| # | Fallo inyectado | ¿Disparó la alerta? |
|---|---|---|
| 1 | Latencia +200 ms en `service-b` (`INJECT_LATENCY_MS`) | No |
| 2 | Error rate 10 % en `data-service` (`FAULT_INJECT_ERROR_RATE`) | No |
| 3 | **Ambos simultáneos** (500 ms + 30 %) | **Sí** |

Que los dos primeros no dispararan **no fue un defecto de configuración**.
Las policies de correlación evalúan `(error_rate > 5 %) and (latencia p99 >
SLO)`; un fallo de un solo síntoma no puede satisfacer una conjunción de dos
síntomas. Esto se confirmó midiendo, no deduciendo: al analizar el CSV del
Experimento 2 con `chaos/analyze_error_budget.py`, la latencia durante el
fallo fue **idéntica** al baseline (p50 216.6 → 218.1 ms; p99 379.2 → 386.4
ms). La inyección de error de `data-service` es un *fast-fail* que devuelve
500 antes de tocar la base de datos, así que es más rápida que una respuesta
normal y nunca eleva la latencia.

De ahí el Experimento 3 (`chaos/run_experimento_d3_combinado.sh`), que
reproduce la firma real de una dependencia degradada: se vuelve lenta **y**
empieza a fallar a la vez.

## Pregunta 1 -- ¿MTTD < 2 minutos?

**No. MTTD medido = 282 s** (243 s si se mide desde la activación efectiva
del fallo). El objetivo de 120 s no se cumple.

Medición con `chaos/measure_mttd.py --backend gcp`, que sondea
`gcloud alpha monitoring alerts list` cada 5 s:

```
INCIDENTE ABIERTO: projects/observabilidad-lab-507021/alerts/0.oc1an6mel1ey
fault_start=2026-08-30T05:46:25+00:00 fired_at=2026-08-30T05:51:07+00:00 MTTD=282.0s
```

Corroborado de forma independiente por el correo de notificación recibido,
cuyo *Start time* es `Aug 30, 2026 at 5:51AM UTC`.

### Descomposición del MTTD

| Tramo | Duración | Causa |
|---|---|---|
| Rollout de `kubectl set env` | ~47 s | El fallo no está vivo hasta que los pods se reemplazan |
| Ramp de la ventana `rate[2m]` | ~60 s | El error rate cruza el 5 % recién a las 05:48:00 |
| `duration = 60 s` de la condition | 60 s | La condición debe sostenerse antes de abrir incidente |
| **Latencia del pipeline de métricas** | **~117 s** | Intervalo de scrape (30 s) + ingesta de GMP + cadencia de evaluación |

Los tres primeros tramos están medidos directamente (marcas de tiempo de los
scripts y del log de sondeo). El cuarto es el residuo: la condición quedó
satisfecha y sostenida alrededor de las 05:49:10, pero el incidente abrió a
las 05:51:07.

**Hallazgo principal:** el piso del MTTD no lo pone la configuración de la
alerta sino la latencia del pipeline de observabilidad. Durante la depuración
se bajó el `duration` de 180 s a 60 s y aun así el MTTD es de 282 s. Seguir
bajándolo no ayudaría: el cuello de botella está aguas arriba. La palanca
efectiva sería reducir el `interval` del `PodMonitoring` de 30 s a 10 s
(ver roadmap del Módulo E).

## Pregunta 2 -- ¿Se degradó el SLO?

**Sí, de forma inequívoca.** Comparación de la ventana limpia contra la
ventana de fallo del mismo CSV (`d3_combinado_20260830_054521.csv`), lo que
elimina la variabilidad entre corridas:

| Métrica | Antes (limpio) | Durante el fallo | Factor |
|---|---|---|---|
| Peticiones | 261 | 623 | |
| p50 | 223.7 ms | 745.5 ms | **3.3x** |
| p95 | 316.3 ms | 802.5 ms | 2.5x |
| p99 | 564.1 ms | 920.5 ms | 1.6x |
| Máximo | 626.2 ms | 1148.8 ms | 1.8x |
| Violación del SLO (>250 ms) | 15.71 % | **88.44 %** | |
| Fallos HTTP (status != 200) | 0 | **0** | |

Acotando a la ventana en que el fallo estuvo plenamente activo (después de
que terminaran los rollouts), la violación del SLO llega al **100.00 %**: las
502 peticiones de ese tramo incumplieron el umbral, ninguna se salvó.

Tres observaciones que no eran obvias antes de medir:

**El p50 es el mejor indicador aquí, no el p99.** Se triplicó (3.3x) mientras
el p99 apenas se movió (1.6x). Al inyectar un retardo fijo a *todas* las
peticiones, la distribución se desplaza en bloque; la cola ya estaba alta de
base. Un dashboard que solo vigilara p99 habría subestimado este incidente.

**El sistema ya violaba su propio SLO en reposo.** Con tráfico limpio, el
15.71 % de las peticiones superaba los 250 ms y el p99 basal era 564 ms, más
del doble del SLO. O el umbral de 250 ms es demasiado ambicioso para una
arquitectura de 3 saltos con Cloud SQL, o hay latencia base que optimizar.
Cualquiera de las dos conclusiones exige acción y ninguna se había detectado
antes de este experimento.

**El throughput colapsó un 69 %,** de 4.14 req/s a 1.27 req/s. El generador
es de lazo cerrado, así que respuestas más lentas producen menos peticiones.
Ningún SLI de latencia ni de errores captura esta pérdida de capacidad; haría
falta un SLI de throughput.

## Pregunta 3 -- ¿Se consumió el error budget?

**Sí: 2.31 % del presupuesto mensual en un incidente de ~7 minutos.**

Cálculo con `chaos/analyze_error_budget.py`, aplicando la fórmula del
runbook `(peticiones_degradadas / peticiones_totales_del_mes) / (1 - SLO)`:

- **Supuesto de tráfico mensual: 4 773 153 peticiones**, extrapolado del
  ritmo observado (1.84 req/s sobre 480 s) a 30 días. No hay tráfico de
  producción real que medir; el supuesto se declara explícitamente.
- SLO de disponibilidad asumido: 99.5 % mensual → error budget = 23 866
  peticiones.
- Peticiones degradadas (violación del SLO de latencia): **551**.
- **Consumo: 2.31 %** del presupuesto mensual.

A ese ritmo, unos **43 incidentes** como este agotarían el presupuesto del
mes.

Salvedad metodológica: el cálculo es sensible al supuesto de tráfico, y en
este caso el propio incidente redujo el throughput un 69 %. Menos peticiones
durante el fallo significa menos peticiones degradadas contadas, así que
2.31 % es probablemente una **subestimación** -- con tráfico constante el
consumo habría sido mayor.

### El resultado central del laboratorio

Sobre exactamente el mismo incidente, según qué SLI se elija:

| Criterio de "petición degradada" | Peticiones | Error budget consumido |
|---|---|---|
| Violación del SLO de latencia (>250 ms) | 551 | **2.31 %** |
| Fallo HTTP (`status != 200`) | **0** | **0.00 %** |

Durante un incidente en el que el 30 % de las llamadas a `data-service`
fallaba y el 88 % de las peticiones violaba el SLO de latencia, un SLO de
disponibilidad basado únicamente en códigos HTTP habría reportado **100 % de
éxito y 0 % de error budget consumido**. El reporte mensual habría salido
impecable y el equipo de guardia no se habría enterado.

La causa es arquitectónica y está en el código: `service-a` atrapa el fallo
de `data-service` en `_fetch_customer()` y responde 200 igual (degradación
silenciosa). Este contraste es la justificación empírica de la métrica
`data_service_calls_total`, de la regla de correlación, y de la premisa de
que observabilidad no es "tener métricas" sino "tener las métricas
correctas".

## Pregunta 4 -- ¿La alerta fue accionable?

**Parcialmente.** El contexto necesario está, pero el resumen no es
interpretable. Evidencia: captura del correo real recibido, en
`docs/evidencia/modulo-d/`.

**Lo que funciona.** El nombre de la policy identifica el componente que
falla. La condición aparece en lenguaje humano con ambos umbrales explícitos
(`data_service_error_rate > 5% Y latencia p99 > SLO (250 ms)`). El bloque de
documentación explica el mecanismo de la degradación silenciosa, entrega el
filtro exacto de Cloud Logging para obtener los `trace_id`, y apunta a los
runbooks. Alguien de guardia sin contexto previo sabría qué componente mirar
y dónde buscar las trazas.

**Lo que falla.** El resumen del mensaje es:

```
A PromQL query was observed at 21.056510536161806
metric : __missing__
value : 21.056510536161806
```

`21.05` de qué. Es el error rate en porcentaje, pero nada lo indica. Y
`metric: __missing__` es literalmente la ausencia de la etiqueta. Comparado
con la alerta de Módulo C (*"is above threshold of 5 with a value of 7.43"*),
que sí referencia el umbral, este mensaje es notablemente peor.

La causa está identificada: las consultas usan `sum(...)` sin `by`, lo que
descarta todas las labels. La serie resultante no tiene etiquetas, así que
Cloud Monitoring no tiene con qué nombrar la métrica y recurre a su plantilla
genérica.

**Es un trade-off de la migración a PromQL**, adoptada por verificabilidad
(permite probar cada consulta con `curl` antes de aplicar el Terraform) a
costa de la calidad del mensaje. Faltan además el `trace_id` en el propio
mensaje -- solo están las instrucciones para buscarlo --, un enlace clicable
a Logs Explorer con el filtro preaplicado, y la severidad (`No severity`).

Correcciones concretas, propuestas para el roadmap del Módulo E: agregar
`by (namespace)` a las agregaciones para conservar una label, usar el campo
`labels` de `condition_prometheus_query_language` para contexto estático, y
asignar `severity`.

## Discriminación entre policies

Durante todo el Experimento 3, `http_5xx_rate` se mantuvo sin datos y el
generador de carga registró **884 peticiones con 0 errores HTTP**. En
consecuencia:

- `observability-lab-gke-correlated-degradation` (basada en 5xx HTTP): **no
  disparó** -- correcto, no hubo 5xx que ver.
- `observability-lab-gke-correlated-degradation-data-service` (basada en
  `data_service_calls_total`): **disparó** -- correcto, detectó la
  degradación silenciosa.

Las dos policies discriminaron exactamente como fueron diseñadas. Esto valida
la decisión de mantenerlas como policies independientes en vez de fusionarlas
(ver el comentario del recurso en `iac/terraform/gcp/monitoring_aiops.tf`).

## Evidencia

En `docs/evidencia/modulo-d/`:

- `d3_combinado_20260830_054521.csv` -- latencia por petición del
  Experimento 3.
- `d3_combinado_20260830_054521_probe.log` -- evolución de ambas condiciones
  de la alerta cada 15 s, consultada en vivo contra la API PromQL de Cloud
  Monitoring.
- Captura del correo de alerta recibido.
- `d2_gke_20260830_040014.csv` -- Experimento 2, base de la comprobación de
  que un *fast-fail* no eleva la latencia.

Reproducible con:

```bash
bash chaos/run_experimento_d3_combinado.sh <project_id> 360 60 observability-lab <url>
python3 chaos/measure_mttd.py --backend gcp --project-id <project_id> \
  --alarm-name observability-lab-gke-correlated-degradation-data-service \
  --fault-start <FAULT_START>
python3 chaos/analyze_error_budget.py --csv <csv> \
  --loadgen-start <t0> --fault-start <t1> --fault-end <t2>
```
