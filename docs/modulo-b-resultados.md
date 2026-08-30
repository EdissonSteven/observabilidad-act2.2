# Módulo B -- Resultados de AIOps y reducción de ruido de alertas (GCP real)

Ejecutado el 2026-08-30 contra `observabilidad-lab-507021`. Todos los
números salen de artefactos reales en `docs/evidencia/modulo-b/`.

## Lo que se construyó

Tres alert policies en Cloud Monitoring, todas en **PromQL**
(`condition_prometheus_query_language`), aplicadas vía Terraform:

| Policy | Señal | Diseño |
|---|---|---|
| `naive-static-5xx` | `rate(http_requests_total{status="500"}[2m]) > 0` | Deliberadamente ingenua: dispara ante CUALQUIER 5xx |
| `correlated-degradation` | error rate 5xx > 5 % **AND** latencia p99 > SLO | Correlación de dos señales |
| `correlated-degradation-data-service` | error rate de `data_service_calls_total` > 5 % **AND** latencia p99 > SLO | Segunda vía de error: degradación silenciosa |

La tercera existe porque `service-a` atrapa los fallos de `data-service` en
`_fetch_customer()` y responde 200 igual -- `http_requests_total` nunca ve
un 5xx en ese caso. Sin esa policy, ese modo de fallo es invisible.

## El experimento de comparación de ruido

Para medir reducción de ruido hace falta un fallo que produzca 5xx reales.
Los experimentos del Módulo D no sirven: ni el de latencia ni el de error
rate de `data-service` generan un solo 5xx en `service-a`. El único fallo de
este sistema que sí los produce es la caída de la base de datos que
`service-a` consulta directamente -- de ahí `chaos/h6_blip_postgres.sh`,
que borra el pod de Postgres y deja que Kubernetes lo recree.

**Cronología medida:**

| Momento (UTC) | Evento |
|---|---|
| 14:23:30 | Se borra el pod de Postgres (`BLIP_START`) |
| 14:23:47 | Postgres vuelve a estar Ready -- **el incidente terminó** (17 s) |
| 14:27:00 | `naive-static-5xx` dispara |
| 14:32:11 | `naive-static-5xx` se cierra (duración: 5 min 11 s) |

**Tráfico:** 1937 peticiones, **127 respuestas HTTP 500** confirmadas
(`HTTP Error 500: Internal Server Error` en la columna `note` del CSV).
Latencia sin degradación apreciable: p50 213.2 ms, p95 275.5 ms,
p99 386.4 ms, máximo 593.7 ms -- muy lejos del timeout de 10 s del
generador. Fallo rápido, no colgado.

## Resultado: 1 contra 0

| Policy | ¿Disparó? | ¿Fue correcto? |
|---|---|---|
| `naive-static-5xx` | **Sí** | Técnicamente sí, operativamente no -- ver abajo |
| `correlated-degradation` | **No** | Sí: la latencia nunca se degradó |
| `correlated-degradation-data-service` | **No** | Sí: `data-service` no falló |

**Reducción de ruido medida: 100 % en este escenario** (1 alerta ingenua
frente a 0 correlacionadas, sobre el mismo incidente y la misma ventana de
tráfico).

### Por qué la alerta ingenua fue ruido, con números

No es una opinión sobre su diseño: es lo que muestra la cronología.

- **Disparó 3 min 13 s DESPUÉS de que el incidente se hubiera resuelto
  solo.** Postgres estaba sano desde las 14:23:47; la alerta abrió a las
  14:27:00.
- **Permaneció abierta 5 min 11 s, el 100 % de ese tiempo sobre un sistema
  ya sano.**
- Kubernetes recuperó el pod en **17 segundos**. Ninguna intervención
  humana habría llegado a tiempo, y ninguna habría sido necesaria.

Una alerta cuya ventana de vida no se solapa ni un segundo con la del
incidente que la provocó no puede accionarse. Es la definición operativa de
falso positivo, aunque el evento que la disparó fuera real.

### Por qué las correlacionadas acertaron al callar

El error rate durante el blip superó el umbral (127 respuestas 500 sobre
1937 peticiones; la alerta ingenua registró un `rate` de 0.3417 err/s), así
que la rama de error de `correlated-degradation` **sí estaba activa**. No
disparó porque la rama de latencia no lo estaba: el fallo fue rápido y el
p99 no se movió.

Esto resuelve una duda metodológica que había quedado abierta: si la
condición de latencia estuviera satisfecha de forma permanente -- porque el
sistema viviera crónicamente por encima de su umbral --, la "correlación"
sería nominal y la policy se comportaría como una regla de una sola señal.
**Queda descartado por este experimento:** con la rama de error activa y la
policy en silencio, la única explicación es que la rama de latencia evaluó
correctamente como falsa.

## Censo completo de alertas del laboratorio

La lista de TODAS las alertas que dispararon en este sistema, en toda su
vida operativa. No es una muestra ni una extrapolación: es el inventario
completo, obtenido con

```bash
gcloud alpha monitoring alerts list --project=<PROJECT_ID> --format=json \
  | jq -r 'sort_by(.openTime) | .[] | "\(.openTime)  \(.closeTime // "ABIERTA")  \(.state)  \(.policy.displayName)"'
```

| # | Apertura (UTC) | Cierre | Duración | Policy | ¿Accionable? |
|---|---|---|---|---|---|
| 1 | 05:02:59 | 05:03:30 | **31 s** | `anomalous-denied-traffic` | **No** -- ráfaga de escaneo de internet |
| 2 | 05:51:07 | 06:00:59 | 9 m 52 s | `correlated-degradation-data-service` | **Sí** -- incidente real inyectado (Exp. 3) |
| 3 | 07:58:17 | 08:00:08 | 1 m 51 s | `anomalous-denied-traffic` | **No** -- ráfaga de escaneo |
| 4 | 14:27:06 | 14:32:17 | 5 m 11 s | `naive-static-5xx` | **No** -- disparó 3 min tras resolverse el incidente |

**3 de 4 alertas (75 %) no eran accionables.** Y la única que sí lo era
llegó 282 segundos tarde (ver `docs/modulo-d-resultados.md`).

La primera duró **31 segundos**: se abrió y se cerró antes de que nadie
alcanzara a leer el correo. Las dos de tráfico rechazado se resolvieron
solas en menos de dos minutos cada una, porque el "incidente" era ruido de
fondo de internet que existe permanentemente contra cualquier IP pública
(ver `docs/modulo-c-resultados.md`).

Este censo es probablemente el dato más elocuente de toda la entrega. Un
sistema con instrumentación completa de los 3 pilares, service mesh, y tres
policies diseñadas con criterio, produjo mayoritariamente ruido -- no por
falta de telemetría, sino porque las reglas preguntaban por volúmenes y
umbrales absolutos en vez de por las condiciones que hacen accionable un
incidente.

---

## El otro lado del trade-off: la correlación cambia ruido por ceguera

La lectura completa no es "la correlacionada es mejor". Es que **cada regla
falla de una manera distinta, y hay que elegir cuál se prefiere.**

En este experimento la correlación acertó, porque un blip transitorio ya
resuelto no merece despertar a nadie. Pero el mismo mecanismo que produjo
ese acierto produciría un **falso negativo** ante una caída de base de datos
que no se recupere sola: errores masivos, latencia sin degradar (el fallo es
rápido), y la alerta correlacionada en silencio mientras el servicio está
caído.

La conjunción `error AND latencia` no distingue "fallo transitorio ya
resuelto" de "fallo grave que falla rápido". Suprime ambos.

**Implicación de diseño:** una regla correlacionada no debe sustituir a la
ingenua, sino complementarla con severidades distintas -- la ingenua como
señal informativa de baja prioridad (registro, no paginación), la
correlacionada como señal accionable. Hoy ambas notifican al mismo canal con
`No severity`, lo que anula la distinción. Está en el roadmap del Módulo E.

## Hallazgos metodológicos

**1. El campo se llama `openTime`, no `open_time`.** Confirmado con
`gcloud alpha monitoring alerts list --format=json | jq '.[0] | keys'`, que
devuelve `["closeTime", "metric", "name", "openTime", "policy", "resource",
"state"]`. Varias consultas de verificación escritas como
`jq 'select(.open_time >= "...")'` devolvieron vacío y se interpretaron como
"ninguna alerta disparó", cuando las alertas sí estaban ahí: comparar `null`
contra una cadena descarta todo **en silencio, sin error**. Se descubrió al
listar sin filtro.

Es el mismo patrón que atraviesa todo el laboratorio, esta vez en la propia
herramienta de verificación: una consulta que responde "no hay nada" cuando
lo correcto sería "no sé preguntarlo". Un filtro mal escrito sobre un campo
inexistente es indistinguible de un resultado negativo legítimo.

(`chaos/measure_mttd.py` no tiene este defecto: consulta
`incident.get("open_time") or incident.get("openTime")`, cubriendo ambos.)

**2. Un experimento puede fallar en silencio pareciendo exitoso.** El primer
intento del blip (14:07) se ejecutó completo -- el script no dio error, el
pod se borró, los timestamps se registraron, el CSV se generó -- pero el
`kubectl port-forward` estaba caído tras un reciclaje de Cloud Shell, así
que **ningún tráfico llegó al clúster**. La conclusión aparente ("la
correlacionada no disparó") habría sido un hallazgo completamente falso: no
hubo nada que detectar. Lo delató una comprobación externa -- un `NaN` en
una consulta que no tenía por qué darlo.
*Mejora pendiente:* `h6_blip_postgres.sh` debería verificar que el tráfico
llega a Cloud Monitoring ANTES de inyectar el fallo, como ya hace
`run_experimento_d3_combinado.sh` con su sondeo en vivo.

**3. Discrepancia sin resolver: 127 contra 41.** El CSV registra 127
respuestas 500 client-side, pero
`sum(increase(http_requests_total{status="500"}[2h]))` en Cloud Monitoring
devuelve **41**. La ventana cubre el blip de sobra. Con un intervalo de
scrape de 30 s y los errores concentrados en ~20 s, la hipótesis más
plausible es pérdida de resolución en el muestreo, pero **no está
confirmada** y queda como pregunta abierta. Si se confirma, significa que el
pipeline no captura todos los eventos de una ráfaga corta -- relevante para
cualquier SLO calculado sobre estas métricas.

## Evidencia

En `docs/evidencia/modulo-b/`:

- `h6_blip_20260830_142230.csv` -- 1937 peticiones, 127 con 500.
- Capturas de los correos de `naive-static-5xx`: el par **disparo (14:27,
  valor 0.3417) + recuperación (duración 5 min 11 s)**.
- Salida de `gcloud alpha monitoring alerts list` mostrando que
  `correlated-degradation` no aparece en la ventana.

Reproducible con:

```bash
bash chaos/h6_blip_postgres.sh observability-lab 420
# esperar ~5 min y luego:
gcloud alpha monitoring alerts list --project=<PROJECT_ID> --format=json \
  | jq -r '.[] | "\(.openTime // .open_time // "?")  \(.state)  \(.policy.displayName)"'
```
