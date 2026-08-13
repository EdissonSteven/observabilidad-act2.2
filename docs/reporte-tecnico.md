---
title: "Pipeline de Observabilidad End-to-End con OpenTelemetry"
subtitle: "Actividad 2.2 — Instrumentación, Collector, Correlación Cross-Signal y Análisis de Overhead"
---

# Pipeline de Observabilidad End-to-End con OpenTelemetry

**Reporte técnico — Actividad 2.2**

> Implementación de un pipeline de observabilidad basado en OpenTelemetry que
> captura métricas (Prometheus), logs estructurados (Loki) y trazas
> distribuidas (Jaeger/Tempo) desde dos microservicios (`service-a` →
> `service-b`), con correlación cross-signal a través de `trace_id` y un
> análisis cuantitativo del overhead de la instrumentación.

---

## 1. Resumen ejecutivo

Este documento describe el diseño, la implementación y los resultados de un
laboratorio de observabilidad end-to-end. El sistema instrumentado consta de
dos microservicios FastAPI (Python) — `service-a` (orquestador de pedidos) y
`service-b` (inventario) — con dependencia HTTP entre sí y acceso propio a
PostgreSQL cada uno. Ambos emiten los tres pilares de la observabilidad
(métricas, logs, trazas) a través del SDK de OpenTelemetry hacia un OTel
Collector, que enruta cada señal a su backend correspondiente: Jaeger y Tempo
para trazas, Prometheus para métricas y Loki para logs, todos visualizados y
correlacionados en Grafana.

Todo el stack se ejecutó localmente con Docker Compose para generar evidencia
real y reproducible (trazas, métricas, logs correlacionados y resultados de
benchmark), mientras que la infraestructura para GCP GKE y AWS ECS Fargate se
entrega como código Terraform y Helm listo para desplegar, pero
deliberadamente no ejecutado en un clúster real (ver sección 7 para la
justificación).

Los hallazgos principales:

- La propagación de contexto W3C TraceContext funciona correctamente entre
  `service-a` y `service-b`: un mismo `trace_id` conecta los spans de ambos
  servicios, sus registros de log y permite navegar entre ellos en Grafana.
- El overhead medido del SDK de OTel en este laboratorio es mayor que las
  cifras de referencia de la industria (p99 +37.0% en vez de +3-8%), y la
  causa raíz identificada no es el SDK en sí, sino que el código de acceso a
  base de datos es síncrono dentro de rutas `async def`, lo que bloquea el
  *event loop* y amplifica cualquier trabajo adicional bajo concurrencia (ver
  sección 6.3).
- Durante el desarrollo se encontraron y corrigieron dos problemas no
  triviales de instrumentación real (ver sección 8, "Lecciones aprendidas"),
  documentados aquí porque son el tipo de detalle que solo aparece al
  ejecutar el sistema de verdad, no al leer la documentación de OTel.

---

## 2. Arquitectura objetivo

```
Cliente / k6  ──HTTP GET /orders/{id}──▶  service-a :8000
                                             │  │
                            fetch order      │  │ call.service-b (traceparent)
                            (Postgres)       │  ▼
                                             │  service-b :8001 ──▶ Postgres
                                             │
                            OTLP gRPC :4317  ▼
                                     OTel Collector
                    ┌────────────┬───────────┴───────────┬─────────────┐
                    ▼            ▼                        ▼             
                 Jaeger        Tempo                  Prometheus       Loki
              (trazas, UI)  (trazas, alt.)          (métricas :8889) (logs)
                    └────────────┴────────────┬───────────┴─────────────┘
                                               ▼
                                          Grafana :3001
                              (dashboard 6 paneles + Explore
                               correlación trace_id ↔ logs ↔ métricas)
```

**Componentes y puertos (stack local):**

| Componente | Rol | Puerto host |
|---|---|---|
| `service-a` | Orquestador de pedidos (FastAPI) | 8000 (API), 9090 (métricas) |
| `service-b` | Inventario (FastAPI) | 8001 (API), 9092 (métricas) |
| PostgreSQL | Persistencia de `orders` e `inventory` | 5433 |
| OTel Collector | Receptor OTLP, pipeline de procesamiento, ruteo | 4317/4318 (OTLP), 8888/8889 (métricas), 13133 (health), 55679 (zpages) |
| Jaeger | Backend de trazas (UI) | 16686 |
| Tempo | Backend de trazas alternativo (Grafana-nativo) | 3200 |
| Prometheus | Backend de métricas | 9091 |
| Loki | Backend de logs | 3100 |
| Grafana | Visualización y correlación | 3001 (admin/admin) |

El repositorio completo está organizado así:

```
services/service-a/, services/service-b/   Código de instrumentación OTel SDK
otel-collector/                             Config del Collector (local + gcp + aws)
observability/                              Prometheus, Tempo, Loki, Grafana (dashboards + datasources)
scripts/init-db.sql                         Esquema y datos de prueba de PostgreSQL
benchmark/                                  k6-load-test.js, analyze_overhead.py, results/
iac/terraform/{gcp,aws}/                    Infraestructura para GKE y ECS Fargate
iac/helm/otel-collector/                    Helm chart del Collector para GKE
docker-compose.yaml                         Stack local completo
docker-compose.baseline.yml                 Overlay para el benchmark (SDK desactivado)
```

---

## 3. Fase 1 — Instrumentación con OTel SDK

### 3.1 Decisiones de diseño

**`Resource`: identidad de cada señal.** Cada proceso construye un
`Resource` (`services/service-a/app/telemetry.py`) con `service.name`,
`service.version`, `deployment.environment` y `cloud.provider`. Este objeto
viaja adjunto a *cada* traza, métrica y log emitidos — es lo que le permite a
Jaeger, Prometheus y Loki (y, en un despliegue real, a Cloud Trace/Cloud
Monitoring/Cloud Logging o X-Ray/CloudWatch) saber de qué servicio vino cada
dato.

**`BatchSpanProcessor` en vez de `SimpleSpanProcessor`.** Los spans se
agrupan en memoria (hasta 512, cada 5s) antes de enviarse al Collector, en
vez de hacer un request de red por span. Es la opción correcta para
cualquier entorno con tráfico sostenido; `SimpleSpanProcessor` solo se
justifica en debugging puntual.

**Doble exportación de métricas.** Cada servicio registra dos
`MetricReader` simultáneos sobre el mismo `MeterProvider`:
`PrometheusMetricReader` (expone `/metrics` para scraping directo, tal como
pide la actividad: "OTel → Prometheus endpoint") y
`PeriodicExportingMetricReader` con `OTLPMetricExporter` (push al Collector
cada 15s, la ruta que en GCP/AWS reales alimentaría Cloud Monitoring o
CloudWatch Metrics vía OTLP).

**Logs: dos caminos, no uno.** El logger de cada servicio tiene dos
handlers:

1. `StreamHandler` con formato JSON (`python-json-logger`) hacia stdout, con
   un `logging.Filter` (`TraceContextFilter`) que inyecta `trace_id`/`span_id`
   del span activo en cada línea. Este es el camino usado para
   `docker compose logs | grep trace_id` (ver sección 8).
2. `LoggingHandler` del SDK de logs de OTel (`opentelemetry.sdk._logs`), que
   exporta cada registro vía OTLP al Collector → Loki. Este handler adjunta
   `trace_id`/`span_id` automáticamente a partir del span activo, sin código
   adicional — es el camino real que arma la correlación logs↔trazas en
   Grafana Explore (sección 5.2).

**Auto-instrumentación vs. spans custom.** Se usan tres instrumentadores
automáticos: `FastAPIInstrumentor` (spans por endpoint HTTP),
`HTTPXClientInstrumentor` (inyecta el header W3C `traceparent` en la llamada
saliente de `service-a` a `service-b` — sin esto no habría propagación) y
`Psycopg2Instrumentor` (spans por query SQL). Sobre esa base, el código de
negocio añade spans custom para las operaciones que sí importan
diagnósticamente:

```python
# services/service-a/app/main.py
with tracer.start_as_current_span(
    "order.fetch_from_db",
    kind=trace.SpanKind.CLIENT,
    attributes={"db.system": "postgresql", "db.operation": "SELECT", "order.id": order_id},
) as span:
    ...
    span.set_attribute("order.status", row["status"])
```

```python
# services/service-a/app/main.py
with tracer.start_as_current_span(
    "order.check_inventory",
    kind=trace.SpanKind.CLIENT,
    attributes={"peer.service": "service-b", "order.sku": sku},
) as span:
    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await client.get(f"{SERVICE_B_URL}/inventory/{sku}")
    ...
```

`service-b` añade además un span de negocio anidado
(`inventory.reserve` → `inventory.validate_availability`) que no corresponde
a I/O externo, sino a una decisión de negocio (¿hay stock suficiente?) —
exactamente el tipo de span que la auto-instrumentación nunca podría generar
por sí sola, porque no sabe qué significa "reservar stock" para este dominio.

### 3.2 Propagación de contexto (W3C TraceContext) — evidencia real

Request de prueba:

```
$ curl http://localhost:8000/orders/ord-1002
{
  "order": {"id": "ord-1002", "sku": "sku-mouse-pro", "quantity": 2, "status": "pending"},
  "inventory": {"sku": "sku-mouse-pro", "available_units": 87, "warehouse": "WH-BOG-01"},
  "trace_id": "556bbf3c92ea635011439f23911d6876"
}
```

Árbol de spans real, recuperado de la API de Jaeger para ese `trace_id`:

```
GET /orders/{order_id}                 service-a   (span raíz)
├── order.fetch_from_db                service-a   (custom)
├── order.check_inventory              service-a   (custom)
│   └── GET                            service-a   (httpx auto-instr., cliente saliente)
│       └── GET /inventory/{sku}       service-b   (servidor, continúa el mismo trace_id)
│           └── inventory.fetch_stock  service-b   (custom)
```

El span `GET /inventory/{sku}` de `service-b` aparece como hijo directo del
span `GET` (cliente httpx) de `service-a`, bajo el mismo `trace_id` —
confirma que el header `traceparent` se propagó correctamente entre
procesos, sin ningún código manual de propagación (`HTTPXClientInstrumentor`
lo hace por sí solo).

La misma correlación se verificó en Loki: el log `order_fetched` de
`service-a` para este request lleva el campo `traceid` (nombre que usa el
esquema nativo de `LogRecord` de OTel) con el valor
`556bbf3c92ea635011439f23911d6876` — idéntico al `trace_id` de la traza.

---

## 4. Fase 2 — OTel Collector

### 4.1 Pipeline

`otel-collector/collector-config.local.yaml` define tres pipelines
(traces, metrics, logs) que comparten receiver (`otlp`, gRPC :4317 / HTTP
:4318) y processors comunes:

```
memory_limiter → resource → filter/health → batch
```

**Orden de los processors, y por qué importa:**

- `memory_limiter` va primero: si hay un pico de telemetría, el Collector
  empieza a *rechazar* datos antes de agotar la memoria del contenedor y
  caerse. Un Collector caído es peor que datos perdidos puntualmente,
  porque deja ciego al sistema completo durante el incidente que
  precisamente se quería diagnosticar.
- `filter/health` descarta spans del endpoint `/health` antes de llegar a
  `batch`, para no ensuciar Jaeger con ruido de *healthchecks* (cada 10s por
  contenedor).
- `batch` va último: agrupa todo lo que sobrevivió a los filtros antes de
  exportar, minimizando el número de conexiones salientes al backend.

### 4.2 Exporters (variante local)

| Señal | Exporter | Backend |
|---|---|---|
| Traces | `otlp/jaeger`, `otlp/tempo` | Jaeger + Tempo (ambos, para demostrar portabilidad) |
| Metrics | `prometheus` (`resource_to_telemetry_conversion: true`) | Prometheus scrapea `:8889` |
| Logs | `loki` | Loki vía API push |

Las variantes `collector-config.gcp.yaml` y `collector-config.aws.yaml`
sustituyen estos exporters por `googlecloud` (Cloud Logging/Trace) y
`awscloudwatchlogs` respectivamente, y añaden el processor
`resourcedetection` (detecta automáticamente `project_id`/zona en GCP o
metadata de la task en ECS). No se ejecutan en este laboratorio — ver
sección 7.

---

## 5. Fase 3 — Backends y visualización

### 5.1 Trazas

Jaeger UI (`http://localhost:16686`) muestra el flame graph completo
descrito en 3.2 — ver captura
[`docs/screenshots/01-jaeger-trace-service-a-service-b.png`](screenshots/01-jaeger-trace-service-a-service-b.png):
10 spans, `service-a` y `service-b` bajo el mismo `trace_id`, duración total
23.94ms. Tempo recibe la misma traza en paralelo (mismo `trace_id`, mismos
spans) para demostrar que el pipeline es portable entre backends de trazas
sin cambiar el código de instrumentación — solo el exporter del Collector
cambia.

### 5.2 Correlación logs ↔ trazas en Grafana

El datasource Loki (`observability/grafana/provisioning/datasources/datasources.yaml`)
define un `derivedFields` que detecta el patrón `"traceid":"([0-9a-f]{32})"`
en cada línea de log y ofrece un enlace directo a Jaeger con ese `trace_id`.
En la dirección inversa, el datasource Jaeger define `tracesToLogsV2` con
una consulta LogQL explícita:

```
{service_name="${__span.tags["service.name"]}"} | json | traceid="${__span.traceId}"
```

que arma la consulta desde el span seleccionado. Deliberadamente `trace_id`
**no** es un label indexado de Loki (sería alta cardinalidad — un label
nuevo por cada request); se filtra con `| json` sobre el cuerpo del log, que
es la práctica recomendada por Grafana Labs para este patrón.

Panel de Grafana Explore: buscar `{service_name="service-a"}` en Loki,
localizar la línea `order_fetched` con `"traceid":"556bbf3c..."`, click en
"Ver traza en Jaeger" → salta directo al flame graph de la sección 3.2. Este
es el flujo que reduce el diagnóstico de horas (correlacionar logs y trazas
a mano por timestamp) a minutos. Evidencia real en
[`docs/screenshots/03-grafana-explore-logs-trazas-correlacion.png`](screenshots/03-grafana-explore-logs-trazas-correlacion.png):
el log `inventory_checked` expandido muestra el campo `traceid` y, en la
sección "Links", el botón "Ver traza en Jaeger" generado por el
`derivedFields` del datasource.

### 5.3 Dashboard Grafana — 6 paneles

`observability/grafana/dashboards/otel-lab-dashboard.json`, provisionado
automáticamente en la carpeta "OTel Lab" — ver captura
[`docs/screenshots/02-grafana-dashboard-6-paneles.png`](screenshots/02-grafana-dashboard-6-paneles.png)
con tráfico real: 100% disponibilidad, 0% error rate, p95 ~48ms:

| # | Panel | Query Prometheus (resumida) | SLO |
|---|---|---|---|
| 1 | Disponibilidad | `sum(rate(http_requests_total{status=~"2.."}[5m])) / sum(rate(http_requests_total[5m]))` | ≥ 99.5% |
| 2 | Latencia p95/p99 | `histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))` | < 500ms |
| 3 | Error rate | `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(...))` | ≤ 0.5% |
| 4 | Throughput | `sum(rate(http_requests_total[5m])) by (job)` | referencial |
| 5 | CPU: apps vs. Collector | `rate(process_cpu_seconds_total[5m])` (apps) y `rate(otelcol_process_cpu_seconds[5m])` (Collector) | overhead < 5% |
| 6 | Salud del Collector | `rate(otelcol_exporter_sent_spans[5m])` vs. `rate(otelcol_exporter_send_failed_spans[5m])` | 0 rechazados |

Nota de implementación: las métricas de auto-telemetría del Collector (Go)
usan nombres **sin** el sufijo `_total` que sí llevan las métricas de
`prometheus_client` (Python) — p. ej. `otelcol_exporter_sent_spans`, no
`otelcol_exporter_sent_spans_total`. Se detectó inspeccionando
`http://localhost:8888/metrics` directamente; los paneles 5 y 6 usan los
nombres reales verificados, no los que aparecen (incorrectos) en varias
guías de referencia.

---

## 6. Fase 4 — Análisis de overhead

### 6.1 Método

Se implementó un baseline real, no solo "apagar el Collector". La variable
de entorno `OTEL_SDK_DISABLED=true` (`services/*/app/telemetry.py`) hace que
el proceso **no registre** ningún `TracerProvider`/`MeterProvider` ni
instrumente ninguna librería. Como `trace.get_tracer()` y
`metrics.get_meter()` de la API de OTel devuelven implementaciones *no-op*
cuando no hay un provider registrado, el código de negocio (los `with
tracer.start_as_current_span(...)` de `main.py`) se ejecuta sin cambios,
pero sin crear spans, sin instrumentación automática y sin exportar nada.
Esto sí mide el costo real del SDK, a diferencia de solo detener el
Collector (que dejaría intacto el costo de creación/serialización de spans
en el proceso, solo fallaría el envío por red).

```bash
# Con OTel SDK
docker compose up -d --force-recreate service-a service-b

# Baseline (SDK desactivado vía overlay)
docker compose -f docker-compose.yaml -f docker-compose.baseline.yml \
  up -d --force-recreate service-a service-b
```

Carga: k6 (`benchmark/k6-load-test.js`), 60 VUs constantes durante 5
minutos contra `GET /orders/{id}` (recorre ambos servicios y ambas
consultas a PostgreSQL), tras 20s de *warm-up*.

### 6.2 Resultados reales

Ejecutado el 2026-08-06 contra el stack local (Docker Desktop, host
compartido con otros contenedores — ver limitaciones en 6.4):

| Métrica | Sin OTel (baseline) | Con OTel SDK | Overhead |
|---|---|---|---|
| Latencia promedio | 1059.92 ms | 1212.87 ms | +14.4% |
| Latencia p95 | 1290.05 ms | 1607.40 ms | +24.6% |
| Latencia p99 | 1399.94 ms | 1918.36 ms | +37.0% |
| Error rate | 0.00% | 0.00% | +0.0% |
| Throughput | 43.39 req/s | 38.84 req/s | -10.5% |

Latencia adicional en p99: **+518.42 ms (+37.0%)**. Total de requests:
13 902 (baseline) y 12 463 (con OTel) en sus respectivas ventanas de 5
minutos.

Memoria RSS por contenedor (muestreada con `docker stats` durante ráfagas
cortas de carga, contenedor recién reiniciado en ambos casos para que la
comparación parta del mismo estado):

| Proceso | Sin OTel | Con OTel | Overhead |
|---|---|---|---|
| `service-a` | ≈ 63 MB | ≈ 67 MB | ≈ +6.5% |
| `service-b` | ≈ 51 MB | ≈ 58 MB | ≈ +12.5% |
| `otel-collector` | — (no existe en baseline) | ≈ 70 MB | proceso adicional |

Los porcentajes de CPU muestreados con `docker stats` resultaron **con
demasiado ruido para reportarse como cifra confiable** (variaban 15-38% entre
muestras de 2 segundos, sin una dirección consistente): Docker Desktop en
Windows corre los contenedores dentro de una VM compartida con scheduling de
CPU que no es determinístico bajo ráfagas cortas. Para una medición de CPU
rigurosa se necesitaría un perfilado continuo sobre toda la ventana de 5
minutos (p. ej. `docker stats` muestreado cada segundo y promediado, o
`cgroup cpu.stat` antes/después), no snapshots puntuales — queda como
trabajo futuro (sección 9).

### 6.3 Interpretación: por qué el overhead es más alto que la referencia de la industria

El material de la actividad cita un overhead de referencia de p99 < 10ms
como aceptable. Lo medido aquí (+518ms en p99) es un orden de magnitud
mayor. La causa identificada **no es el SDK de OTel en sí**, sino una
decisión de arquitectura de la aplicación: `services/*/app/main.py` y
`db.py` usan `psycopg2` (síncrono) y `time.sleep()` dentro de funciones
`async def`, sin desviarlos a un *thread pool* (`run_in_executor`) ni usar
un driver async (`asyncpg`). Cada consulta bloquea el *único* hilo del
event loop de `uvicorn` durante 8-150ms.

Bajo 60 VUs concurrentes, ese bloqueo ya genera una cola de requests
esperando el hilo (de ahí la latencia base alta, ~1060ms, incluso sin OTel).
Cuando se añade el trabajo síncrono adicional de OTel en el mismo hilo
(construir spans, serializar atributos, encolar en el `BatchSpanProcessor`,
formatear el log JSON con `trace_id`), ese costo no se suma de forma lineal
al de un sistema no saturado: se **amplifica** por el efecto de cola,
porque cada solicitud adicional en el hilo retrasa a todas las que están
detrás. Esto explica por qué el overhead crece con el percentil (p50 +14%,
p95 +25%, p99 +37%): las colas más largas (percentiles altos) son las que
más sufren cualquier trabajo extra por request.

**Conclusión de diseño:** en un servicio con I/O verdaderamente asíncrono
(p. ej. `asyncpg` en vez de `psycopg2`, o `run_in_executor` para el trabajo
síncrono), se esperaría que el overhead de OTel se acerque mucho más a la
cifra de referencia de la industria (3-8%), porque el event loop dejaría de
ser el cuello de botella compartido que amplifica cualquier costo adicional.
Este hallazgo es, en sí mismo, un ejemplo de cómo la observabilidad expone
problemas de diseño que de otra forma pasarían inadvertidos con baja
concurrencia.

### 6.4 Limitaciones del benchmark

- Ejecutado en una laptop de desarrollo (Docker Desktop / Windows) con
  otros contenedores activos simultáneamente (ver sección 6.2) — no es un
  entorno aislado de benchmarking. Los valores *absolutos* de latencia no
  son representativos de un despliegue real en GKE/ECS; los valores
  *relativos* (overhead %) siguen siendo la evidencia principal de este
  informe.
- Solo se ejecutó una repetición por modo (no N corridas con intervalo de
  confianza). Para una decisión de producción se recomienda repetir cada
  escenario 3-5 veces.

---

## 7. Infraestructura como código (IaC) y despliegue cloud

### 7.1 Decisión: stack local ejecutado, IaC de nube lista pero no aplicada

Todo el pipeline (instrumentación, Collector, backends, dashboard,
benchmark) se ejecutó y verificó **localmente** con Docker Compose. La
infraestructura para GCP GKE y AWS ECS Fargate se entrega como Terraform y
Helm completos y sintácticamente correctos en `iac/`, pero
**deliberadamente no se ejecutó `terraform apply`** contra una cuenta real,
para no incurrir en costos ni requerir credenciales de nube en esta entrega.
Esta decisión se tomó explícitamente al inicio del laboratorio y se
documenta aquí para que quede claro que no es un olvido.

### 7.2 GCP — GKE (`iac/terraform/gcp/`)

Clúster GKE regional (VPC dedicada, no la red `default`), Workload Identity
habilitado, `release_channel = REGULAR`, node pool con autoscaling (1-4
nodos `e2-standard-4`). Artifact Registry para las imágenes. Los
Deployments de `service-a`, `service-b` y `otel-collector` se declaran con
el provider `kubernetes` de Terraform, encadenado a los outputs del propio
clúster (mismo archivo, sin *hand-off* manual a `kubectl`). Credenciales de
base de datos vía `kubernetes_secret`, nunca en texto plano en el
Deployment.

### 7.3 AWS — ECS Fargate (`iac/terraform/aws/`)

VPC mínima de 2 AZs, ECR por servicio, cluster ECS Fargate con Container
Insights, ALB público hacia `service-a:8000` con healthcheck en `/health`.
El OTel Collector corre como **sidecar** dentro de cada task definition (en
vez de un servicio ECS propio con Service Connect) — trade-off documentado
en el propio `main.tf`: más simple para un laboratorio (sin descubrimiento
de servicios adicional, exportación por `localhost`), a costa de correr N
procesos Collector en vez de uno compartido; a mayor escala, un Collector
compartido sería la elección correcta. `service-b` se descubre vía Cloud Map
(`service-b.<namespace>.local`). `DATABASE_URL` viaja vía AWS Secrets
Manager (`secrets` de la task definition), con un fallback de variable
plana solo para demo.

### 7.4 Helm (`iac/helm/otel-collector/`)

Chart propio (no el chart comunitario de `open-telemetry/opentelemetry-helm-charts`,
para demostrar comprensión del recurso, no solo su consumo) con
Deployment + Service + ConfigMap parametrizados vía `values.yaml` — misma
forma de pipeline (`otlp` → `memory_limiter`/`batch`/`resource` →
exporters) que la variante local, pero con exporters dejados como
placeholders para que cada entorno los sobrescriba sin tocar el chart.
Validado con `helm lint` y `helm template` (sin clúster real disponible en
este entorno de desarrollo).

---

## 8. Lecciones aprendidas (troubleshooting real)

Tres problemas de instrumentación reales aparecieron solo al ejecutar el
sistema, no al leer la documentación de OTel — se documentan porque son
justamente el tipo de conocimiento que un ejercicio puramente teórico no
puede enseñar.

**1. `FastAPIInstrumentor().instrument()` global no propagaba el trace_id.**
El patrón "instrumentar antes de crear la app" (llamar
`FastAPIInstrumentor().instrument(tracer_provider=...)` sin argumento
`app`, confiando en que parchea `FastAPI.__init__` globalmente) resultó
poco fiable en la práctica: cada span de negocio (`order.fetch_from_db`,
`order.check_inventory`) terminaba como *raíz* de su propio trace en vez de
colgar del span del servidor HTTP, y `trace_id` en la respuesta JSON salía
en `00000000000000000000000000000000` (span inválido). La corrección fue
usar el patrón explícito `FastAPIInstrumentor.instrument_app(app, ...)`
justo después de `app = FastAPI(...)` en `main.py` — documentado con un
comentario en `telemetry.py` para que no se repita el error.

**2. El filtro de `/health` en el Collector no bastaba.** El middleware ASGI
de FastAPI genera spans internos por cada evento (`http send`, `http
receive`) además del span raíz del endpoint. El processor
`filter/health` del Collector (que descarta por el atributo
`http.target == "/health"`) solo alcanza al span raíz — los spans internos
de evento no llevan ese atributo, así que igual llegaban a Jaeger como
trazas huérfanas (con `trace_id` propio, sin span padre visible). La
solución correcta es evitar que esos spans se **creen**, no filtrarlos
después: `FastAPIInstrumentor.instrument_app(app, excluded_urls="/health",
...)`. El processor `filter/health` del Collector se dejó como segunda capa
de defensa (para servicios que no puedan excluir por SDK), pero ya no es la
única línea de defensa.

**3. Los histogramas de latencia daban un p95 fantasma de ~4.75 segundos.**
Al poblar el dashboard con tráfico real, el panel "Latencia p95" mostraba
consistentemente ~4750ms, aunque una petición manual cronometrada tardaba
43ms. Causa: `meter.create_histogram(...)` se llamó sin especificar
*bucket boundaries* explícitos, así que el SDK usa los valores por defecto
`(0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000)`
— pensados para mediciones en **milisegundos**. Pero el código mide en
**segundos** (`duration = time.time() - start`, valores como `0.043`), así
que absolutamente todas las observaciones caían en el primer bucket no vacío
(`le=5.0`, es decir, "≤ 5 segundos") sin ningún bucket intermedio que las
distinguiera. Con un único escalón informativo, `histogram_quantile`
interpola linealmente entre 0 y 5.0 para estimar el percentil 95, dando
~4.75 — un artefacto matemático, no una medición real. Verificado
inspeccionando los buckets crudos vía la API de Prometheus
(`http_request_duration_seconds_bucket`): 691 observaciones repartidas en
`le=0.0 → 0` y `le=5.0 → 691`, sin nada entre medio.

La corrección fue registrar un `View` con
`ExplicitBucketHistogramAggregation` sobre todos los instrumentos
`*_seconds`, con los boundaries clásicos de Prometheus en segundos
(`0.005, 0.01, 0.025, ..., 7.5, 10`) — ver `services/*/app/telemetry.py`.
Tras el fix, el mismo tráfico mostró 25 de 30 requests entre 25-50ms y un
p95 real de ~48ms, coherente con la medición manual.

Este bug es fácil de cometer y fácil de no notar: el dashboard "funcionaba"
(mostraba un número, con unidad, con color) — solo estaba mal. Es un
recordatorio de que un panel con datos no es lo mismo que un panel con datos
*correctos*, y de que vale la pena cruzar al menos una vez el número que
muestra un dashboard contra una medición manual independiente.

---

## 9. Trabajo futuro

- Migrar el acceso a PostgreSQL a `asyncpg` (o `run_in_executor`) para
  eliminar el bloqueo del event loop identificado en 6.3 y repetir el
  benchmark — la hipótesis es que el overhead relativo de OTel bajaría a un
  solo dígito porcentual.
- `tail_sampling` en el Collector (muestrear el 100% de las trazas con
  error o latencia alta, y un porcentaje menor del resto) para reducir
  volumen sin perder señal, una vez el sistema tenga tráfico de producción
  real.
- Ejecutar el benchmark en un entorno aislado (no una laptop de desarrollo
  compartida) y con múltiples repeticiones, para obtener intervalos de
  confianza sobre el overhead de CPU.
- Aplicar el Terraform de `iac/` contra un proyecto GCP/cuenta AWS de
  prueba y capturar las mismas evidencias (trazas, dashboard) que aquí se
  capturaron localmente, para confirmar paridad de comportamiento entre
  ambas nubes.

---

## 10. Referencias

- OpenTelemetry Project. (2024). *Python API & SDK*. https://opentelemetry-python.readthedocs.io/
- OpenTelemetry Project. (2024). *Collector Configuration*.
- Jaeger Tracing. *Architecture Documentation*. https://www.jaegertracing.io/docs/architecture/
- Grafana Labs. *Linking Traces, Logs and Metrics*. https://grafana.com/docs/grafana/latest/explore/trace-integration/
- Grafana Labs. *Loki: Best Practices for Labels* (cardinalidad de labels).
- k6 / Grafana. *Load Testing Documentation*. https://k6.io/docs/
- W3C. *Trace Context Specification*. https://www.w3.org/TR/trace-context/
