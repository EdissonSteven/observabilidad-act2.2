# Pipeline de Observabilidad End-to-End con OpenTelemetry

Este repo cubre dos entregas sobre la misma base de código:

1. **Actividad 2.2** (base): dos microservicios FastAPI (`service-a` →
   `service-b`) instrumentados con OpenTelemetry SDK (trazas, métricas,
   logs), un OTel Collector, y backends Jaeger/Tempo (trazas), Prometheus
   (métricas) y Loki (logs), correlacionados en Grafana vía `trace_id`.
   Reporte técnico completo en
   [`docs/reporte-tecnico.md`](docs/reporte-tecnico.md).
2. **Laboratorio integrador (Módulos A-E)** (extensión): añade un tercer
   microservicio `data-service` con base de datos gestionada (Cloud
   SQL/RDS) y OTel DB Semantic Conventions, service mesh (Istio/App Mesh),
   AIOps con alertas de correlación, Network & Security Observability,
   2 experimentos de Chaos Engineering con medición de MTTD, y un
   framework de madurez de observabilidad de 8 dominios.
   **El punto de entrada de esta segunda entrega es
   [`docs/runbooks/00-validacion-local-y-preflight.md`](docs/runbooks/00-validacion-local-y-preflight.md)**
   -- de ahí en adelante los runbooks `01`-`05` cubren, en orden, la
   validación local con el tercer servicio, el despliegue real en la nube
   y su validación, y el cierre/destroy. El reporte ejecutivo de esta
   entrega es [`docs/reporte-ejecutivo-final.md`](docs/reporte-ejecutivo-final.md)
   y el framework de madurez [`docs/madurez-observabilidad.md`](docs/madurez-observabilidad.md).
   **Decisión de alcance:** el despliegue real de esta entrega se hace
   solo en **GCP**; el Terraform de AWS es diseño completo y validado
   sintácticamente pero no se despliega (ver la nota al inicio de
   `docs/reporte-ejecutivo-final.md`).

El resto de este README documenta el Quickstart local de la Actividad
2.2 base (`service-a`/`service-b`, sin `data-service`) -- sigue siendo
válido tal cual, y es el primer paso del Runbook 0 de la segunda entrega
antes de sumar el tercer servicio.

## Quickstart

Requisitos: Docker + Docker Compose.

```bash
docker compose up -d --build
docker compose ps        # todo debe quedar "healthy" o "running" (~30-60s)
```

Accesos:

| Servicio | URL |
|---|---|
| `service-a` (Swagger) | http://localhost:8000/docs |
| `service-b` (Swagger) | http://localhost:8001/docs |
| Jaeger UI | http://localhost:16686 |
| Grafana (`admin`/`admin`) | http://localhost:3001 |
| Prometheus | http://localhost:9091 |
| Tempo | http://localhost:3200 |
| OTel Collector (health) | http://localhost:13133/ |

## Verificación end-to-end

```bash
# 1. Generar un request que atraviesa ambos servicios + Postgres
curl http://localhost:8000/orders/ord-1001
# La respuesta incluye "trace_id": "..." -- cópialo para los pasos 2 y 3.

# 2. Ver la traza completa en Jaeger
#    http://localhost:16686 -> Service: service-a -> Find Traces
#    Debe verse un único árbol con spans de service-a Y service-b
#    (confirma la propagación W3C TraceContext).

# 3. Ver los logs correlacionados en Grafana
#    http://localhost:3001 -> Explore -> datasource Loki
#    Query: {service_name="service-a"} | json | traceid="<trace_id del paso 1>"
#    Cada línea trae un botón "Ver traza en Jaeger" que salta al flame graph.

# 4. Dashboard de métricas
#    http://localhost:3001 -> Dashboards -> carpeta "OTel Lab"
#    6 paneles: disponibilidad, latencia p95/p99, error rate, throughput,
#    CPU (apps vs. Collector), salud del Collector.

# 5. Grep manual de logs (alternativa rápida sin Grafana)
docker compose logs service-a | grep trace_id
```

IDs de pedido de prueba: `ord-1001` a `ord-1005` (ver `scripts/init-db.sql`).

## Benchmark de overhead (Fase 4)

```bash
# Con OTel SDK (modo por defecto)
docker compose up -d --force-recreate service-a service-b

docker run --rm --network actividad22_otel-net \
  -v "$(pwd)/benchmark:/scripts:ro" -v "$(pwd)/benchmark/results:/results" \
  grafana/k6 run --env MODE=otel --env BASE_URL=http://service-a:8000 /scripts/k6-load-test.js

# Baseline: SDK de OTel desactivado (no solo "apagar el Collector" -- ver
# docs/reporte-tecnico.md sección 6.1 para por qué esto es lo correcto)
docker compose -f docker-compose.yaml -f docker-compose.baseline.yml \
  up -d --force-recreate service-a service-b

docker run --rm --network actividad22_otel-net \
  -v "$(pwd)/benchmark:/scripts:ro" -v "$(pwd)/benchmark/results:/results" \
  grafana/k6 run --env MODE=baseline --env BASE_URL=http://service-a:8000 /scripts/k6-load-test.js

# Comparar
python benchmark/analyze_overhead.py

# Volver al modo instrumentado
docker compose up -d --force-recreate service-a service-b
```

Cada corrida dura ~5.5 minutos (60 VUs constantes, 5 min + 20s de warm-up).
Los resultados ya ejecutados están en `benchmark/results/` y la tabla
comparativa completa en `docs/reporte-tecnico.md` sección 6.2.

> Nota Windows/Git Bash: si `docker run` falla con un path tipo
> `C:/Program Files/Git/scripts/...`, es MSYS reescribiendo el argumento;
> anteponer `MSYS_NO_PATHCONV=1` al comando.

## Despliegue en la nube

Para la **Actividad 2.2** (solo `service-a`/`service-b`), el IaC de
`iac/terraform/gcp/` (GKE) e `iac/terraform/aws/` (ECS Fargate), más
`iac/helm/otel-collector/`, se dejó **deliberadamente no desplegado** —
el stack local documentado arriba fue toda la evidencia de esa entrega.

Para el **laboratorio integrador (Módulos A-E)**, ambos módulos Terraform
se extendieron con el tercer servicio, bases de datos gestionadas,
service mesh, AIOps, Flow Logs y dashboards de seguridad -- pero el
despliegue real solo se ejecuta en **GCP** (ver la decisión de alcance
arriba); AWS se queda en el mismo estado "escrito y validado, no
desplegado" que ya describía la Actividad 2.2. Los pasos exactos están en
`docs/runbooks/00-validacion-local-y-preflight.md` en adelante, no en los
README de cada módulo de Terraform (que documentan la versión base de
Actividad 2.2 y quedan como referencia de esa infraestructura mínima).

## Generar el reporte técnico (Word / PDF)

El reporte fuente es `docs/reporte-tecnico.md`. Ya está generado como Word en
`docs/reporte-tecnico.docx` (encabezados, tablas, bloques de código y las 3
capturas de pantalla insertadas donde corresponden) — ábrelo y usa
Archivo → Guardar como → PDF para el entregable final.

Para regenerarlo después de editar el `.md` (por ejemplo si cambian los
resultados del benchmark):

```bash
python scripts/generate-report-docx.py   # requiere: pip install python-docx
```

Alternativas si prefieres ir directo a PDF sin pasar por Word:

```bash
# pandoc (si está instalado)
pandoc docs/reporte-tecnico.md -o docs/reporte-tecnico.pdf --pdf-engine=xelatex -V geometry:margin=2.5cm

# o abrir el .md en VS Code (extensión "Markdown PDF") y exportar
```

## Capturas de pantalla

Capturadas contra el stack local corriendo de verdad (no mockups), en
`docs/screenshots/`:

- [`01-jaeger-trace-service-a-service-b.png`](docs/screenshots/01-jaeger-trace-service-a-service-b.png) —
  flame graph de una traza de `/orders/{id}`: 10 spans, `service-a` y
  `service-b` bajo el mismo `trace_id` (propagación W3C confirmada).
- [`02-grafana-dashboard-6-paneles.png`](docs/screenshots/02-grafana-dashboard-6-paneles.png) —
  dashboard "OTel Lab" con los 6 paneles con datos reales.
- [`03-grafana-explore-logs-trazas-correlacion.png`](docs/screenshots/03-grafana-explore-logs-trazas-correlacion.png) —
  Grafana Explore (Loki) mostrando el log `inventory_checked` con su
  `trace_id` y el botón "Ver traza en Jaeger" (derived field) para saltar
  directo al flame graph.

Para regenerarlas o tomar más, con el stack corriendo:

```bash
# Generar tráfico para poblar el dashboard antes de capturar
for i in $(seq 1 50); do
  curl -s -o /dev/null "http://localhost:8000/orders/ord-100$((RANDOM % 5 + 1))"
done
```

## Estructura del repositorio

```
services/service-a/, service-b/, data-service/   Código OTel SDK (FastAPI) -- data-service es del laboratorio integrador
otel-collector/                             Config del Collector: local (docker-compose) + gcp + aws
observability/                              Prometheus (+ alert_rules.yml), Tempo, Loki, Grafana
scripts/init-db.sql                         Esquema y datos de prueba de PostgreSQL (incluye customers)
scripts/{aws,gcp}_preflight_check.sh        Preflight de permisos de solo lectura (laboratorio integrador)
benchmark/                                  k6-load-test.js, analyze_overhead.py, results/ (Actividad 2.2)
chaos/                                       Scripts de chaos engineering + medición de MTTD (Módulo D)
iac/terraform/{gcp,aws}/                    Terraform: GKE/Cloud SQL/Istio/AIOps/Flow Logs (gcp, desplegado)
                                             y ECS Fargate/RDS/App Mesh/AIOps/Flow Logs (aws, diseño no desplegado)
iac/istio/                                  Manifiestos de Istio (mTLS, destination rules) para GKE
iac/helm/otel-collector/                    Helm chart del Collector para GKE
docs/reporte-tecnico.md                     Reporte técnico de Actividad 2.2 (fuente del PDF)
docs/reporte-ejecutivo-final.md             Reporte ejecutivo del laboratorio integrador (Módulos A-E)
docs/madurez-observabilidad.md              Framework de madurez de 8 dominios + roadmap (Módulo E)
docs/video-demo-script.md                   Guion/checklist para el video de demostración
docs/runbooks/00-05                         Paso a paso: validación local, despliegue GCP, chaos, cierre
docker-compose.yaml                         Stack local completo (incluye data-service)
docker-compose.baseline.yml                 Overlay: desactiva el SDK de OTel para el benchmark
```

## Checklist de entregables

**Actividad 2.2 (base):**
- [x] Instrumentación OTel SDK: auto + custom, 3 pilares emitidos y verificados
- [x] OTel Collector: configurado y corriendo (local); config gcp/aws lista sin desplegar
- [x] Correlación cross-signal: trace_id verificado entre trazas, logs y (vía Resource) métricas
- [x] Benchmark de overhead: baseline real vs. OTel SDK, tabla en el reporte
- [x] IaC: Terraform GCP + AWS, Helm chart, repositorio organizado
- [x] Capturas de pantalla (`docs/screenshots/`)
- [x] Reporte técnico generado en Word (`docs/reporte-tecnico.docx`)

**Laboratorio integrador, Módulos A-E:** ver el checklist de estado real
(código listo vs. evidencia pendiente de ejecución) en
`docs/reporte-ejecutivo-final.md` y `docs/madurez-observabilidad.md` --
no se duplica aquí para no tener dos fuentes de verdad desincronizadas.
