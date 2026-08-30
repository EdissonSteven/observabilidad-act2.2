# Framework de madurez de observabilidad (8 dominios) y autoevaluación

> **Estado de este documento:** borrador escrito junto con el código/IaC de
> los Módulos A–E, antes de ejecutar el despliegue real (Fase 3 del plan de
> ejecución). Los niveles de madurez marcados con 🔶 son **provisionales**
> y asumen que la evidencia planeada se captura con éxito -- deben
> revisarse contra los resultados reales antes de entregar el PDF
> ejecutivo. Los marcados con ✅ ya están confirmados con evidencia real
> (código, IaC validado con `python-hcl2`, o docs/reporte-tecnico.md de la
> Actividad 2.2 heredado).
>
> Decisión de alcance: el despliegue real de esta entrega es solo en GCP
> (ver `docs/reporte-ejecutivo-final.md`). Donde este documento menciona
> piezas de AWS como "pendientes de aplicar", se leen como "diseñadas,
> validadas sintácticamente, no desplegadas por decisión de alcance" -- no
> es una limitación técnica del Learner Lab, es una decisión deliberada de
> presupuesto.

## Por qué 8 dominios propios, y no un "blueprint" oficial

El enunciado pide autoevaluar contra un "Observability Foundation
Blueprint (8 dominios)". Una búsqueda específica no encontró ningún marco
publicado con ese nombre exacto y esa estructura -- por lo que, para no citar
una fuente inexistente, este documento construye un framework propio de 8
dominios, cada uno explícitamente derivado de una fuente real y verificable:

1. **AWS Observability Maturity Model** -- 4 stages (Foundational →
   Intermediate → Advanced → Proactive) sobre las dimensiones Logs /
   Metrics / Traces / Dashboards-Alerting / Strategy.
   <https://aws-observability.github.io/observability-best-practices/guides/observability-maturity-model/>
   (material del curso).
2. **OpenTelemetry Semantic Conventions** (traces, database spans) --
   <https://opentelemetry.io/docs/specs/semconv/db/database-spans/>
3. **Tigera -- eBPF and Network Observability** --
   <https://www.tigera.io/learn/guides/ebpf/> (material del curso).
4. **GCP Security Command Center -- Overview** --
   <https://cloud.google.com/security-command-center/docs/concepts-security-command-center-overview>
   (material del curso).
5. Sigelman, B., et al. (2021). *Towards Observability Data Management at
   Scale.* ACM SIGOPS. (material del curso).
6. Metodología de Principios del Caos (Chaos Engineering), ya usada en la
   actividad anterior del curso y en `GameDay_Plan.pdf`.

La escala es 1–5 (CMMI-style, la convención más común en los modelos de
madurez citados arriba) aplicada a cada dominio de forma independiente,
sin promediar en un único número global -- un sistema puede ser maduro en
instrumentación y aún inmaduro en cultura, y esa distinción es justamente
el valor de un modelo de 8 dominios en vez de un solo score.

| Nivel | Significado general (adaptado de AWS Observability Maturity Model) |
|---|---|
| 1 | Ad-hoc / inexistente -- no hay señal, o existe pero no se usa. |
| 2 | Instrumentado -- la señal existe y se colecta, sin correlación ni alertas basadas en ella. |
| 3 | Correlacionado -- la señal se cruza con otras (traza↔log↔métrica) y alimenta dashboards/alertas. |
| 4 | Proactivo -- detección de anomalías / SLOs con error budget, no solo umbrales fijos. |
| 5 | Autónomo -- remediación asistida o automática, y el dominio es parte de la cultura de ingeniería (Game Day recurrente, revisiones periódicas). |

---

## Dominio 1 -- Instrumentación de los 3 pilares

**Fuente:** AWS Observability Maturity Model (stage 1–2), OTel Semantic
Conventions.

**Qué mide:** cobertura de trazas, métricas y logs en los 3 microservicios,
y adherencia a convenciones semánticas estándar (no solo "hay telemetría",
sino que es *interoperable*).

**Evidencia:** service-a/service-b (heredado, validado en
`docs/reporte-tecnico.md` de la Actividad 2.2) ✅. data-service añade
atributos de las OTel DB Semantic Conventions vigentes (`db.system.name`,
`db.namespace`, `db.operation.name`, `db.collection.name`,
`server.address`, `server.port` -- ver `services/data-service/app/db.py`)
que `Psycopg2Instrumentor` 0.46b0 todavía no cubre automáticamente.

**Nivel actual: 4** ✅ (3 pilares completos, semántica estándar, en los 3
servicios). Para llegar a 5: instrumentar también PostgreSQL/Cloud
SQL/RDS del lado servidor (slow query log correlacionado con trace_id),
no solo el lado cliente.

---

## Dominio 2 -- Correlación cross-signal

**Fuente:** AWS Observability Maturity Model (stage 3), Sigelman et al.
2021 (arquitectura de correlación a escala vía trace_id/span_id
propagados end-to-end).

**Qué mide:** si trazas, logs y métricas se pueden cruzar por trace_id sin
trabajo manual.

**Evidencia:** correlación logs↔trazas en Grafana Explore ya validada en
la Actividad 2.2 (`docs/screenshots/03-*`) ✅; se extiende automáticamente
a data-service porque usa el mismo `TraceContextFilter` (ver
`services/data-service/app/telemetry.py`) sin código adicional.

**Nivel actual: 3** ✅ heredado + extendido. Para llegar a 4: la alerta
correlacionada del Módulo B (`CorrelatedDegradation`) debe llevar el
trace_id de la petición fallida directo en la notificación (hoy es un
enlace a una consulta, no el ID incrustado) -- ver roadmap.

---

## Dominio 3 -- Observabilidad de red / service mesh L7

**Fuente:** Tigera -- eBPF and Network Observability; Módulo A del
enunciado.

**Qué mide:** visibilidad L7 del tráfico entre microservicios (más allá de
"llegó/no llegó" -- latencia por request, mTLS, tasa de éxito por ruta).

**Evidencia:** 🔶 Istio (GKE, `iac/istio/`) diseñado y listo, pendiente de
aplicar y confirmar `istioctl proxy-status` / métricas de Envoy reales en
esta ventana de ejecución (GCP). AWS App Mesh
(`iac/terraform/aws/appmesh.tf`, `enable_app_mesh`) queda como diseño
equivalente no desplegado -- decisión de alcance, no limitación técnica.

**Nivel actual (provisional): 2→3 tras Fase 3.** Sin mesh desplegado, la
observabilidad de red hoy es la que ya daba VPC Flow Logs (dominio 5) --
ad-hoc. Con Istio/App Mesh desplegado y verificado sube a 3 (correlacionado:
métricas de Envoy por request, visibles en Grafana/CloudWatch). No se
reclama 4/5 aquí porque eBPF nativo (Cilium/Tigera Calico Enterprise) no
está en alcance de este laboratorio -- queda en el roadmap.

---

## Dominio 4 -- AIOps / detección de anomalías

**Fuente:** AWS Observability Maturity Model (stage 3–4); enunciado
Módulo B.

**Qué mide:** si la detección de degradación usa una banda de
comportamiento esperado (baseline ± σ) en vez de solo un umbral fijo, y si
correlaciona más de una señal.

**Evidencia:** regla de correlación implementada 3 veces (Prometheus local
✅ diseño completo, `GCP Cloud Monitoring MQL` 🔶 pendiente de validar
sintaxis contra la consola real y de aplicar -- esta es la que se ejecuta
de verdad en esta entrega; `AWS CloudWatch Anomaly Detection` queda como
diseño equivalente no desplegado, decisión de alcance).
Comparación cuantitativa contra alarma de umbral estático diseñada
(`naive_static_threshold`/`NaiveStatic5xx`, en GCP) para medir reducción
real de falsos positivos.

**Nivel actual (provisional): 3→4 tras Fase 3**, condicionado a que la
alerta compuesta dispare correctamente y se cuente la reducción de ruido
con datos reales del mismo experimento.

---

## Dominio 5 -- Seguridad y cumplimiento

**Fuente:** GCP Security Command Center -- Overview; enunciado Módulo C.

**Qué mide:** visibilidad de postura de seguridad (findings, tráfico
rechazado, superficie de autenticación).

**Evidencia y brecha explícita:** VPC Flow Logs + Firewall Rule Logging
diseñados en ambas nubes (`iac/terraform/aws/vpc_flow_logs.tf`,
`iac/terraform/gcp/network_security.tf`), pero **desplegados y verificados
solo en GCP** en esta entrega (decisión de alcance; el `.tf` de AWS es
evidencia de diseño).

**Security Command Center no es aplicable a este proyecto**, verificado con
evidencia real (2026-08-30). SCC se activa a nivel de organización y su
alcance son los proyectos que cuelgan de ella. La comprobación decisiva no
es si la cuenta ve alguna organización, sino de cuál cuelga el proyecto:

```
$ gcloud organizations list          -> 1 organización
$ gcloud projects describe observabilidad-lab-507021 \
    --format='value(parent.type,parent.id)'
                                     -> (vacío)
```

Ambos resultados son compatibles: la cuenta institucional
(@unisabana.edu.co) sí pertenece a una organización, pero el proyecto de
este laboratorio se creó FUERA de ella -- es un proyecto huérfano, sin
parent. No hay organización a la que enganchar SCC.

Y aunque el proyecto colgara de la organización de la Universidad, activar
SCC seguiría estando fuera de alcance: afectaría a **todos** los proyectos
institucionales, no solo a este, con implicaciones de costo y de política
ajenas a un trabajo individual. La decisión de no activarlo sería la misma.

*Hallazgo metodológico asociado:* `scripts/gcp_preflight_check.sh`
comprobaba esto incorrectamente -- usaba `gcloud organizations list` y
concluía "SCC podría habilitarse", un `[OK]` infundado que contradecía la
realidad. Ya está corregido para mirar el `parent` del proyecto. Un
preflight que da un OK engañoso es peor que no tener preflight, porque
induce confianza donde no la hay; es el mismo tipo de defecto que este
laboratorio busca detectar en los sistemas que observa.

Tampoco hay autenticación de usuario final en ninguno de los 3
microservicios, así que "intentos de autenticación fallidos" no es una
señal real del sistema.

**Nivel actual: 2.** Hay señal de red (flow logs, tráfico rechazado) pero
sin la capa de postura de seguridad centralizada (SCC/Security Hub) ni
señal de autenticación. Es, honestamente, el dominio más débil del
sistema -- ver remediación en el roadmap.

---

## Dominio 6 -- Alertas y gestión de incidentes (MTTD/MTTR/error budget)

**Fuente:** AWS Observability Maturity Model (stage 3); Google SRE
(error budgets, práctica estándar de la industria referenciada
implícitamente por el enunciado del Módulo D).

**Qué mide:** si las alertas están atadas a SLOs con error budget, y si el
tiempo de detección es medible y aceptable (< 2 min, según el enunciado).

**Evidencia:** 🔶 `chaos/measure_mttd.py` diseñado para medir MTTD contra
Prometheus local, GCP (Cloud Monitoring) y AWS (CloudWatch) -- solo el
backend `gcp` se ejercita en esta entrega; SLO de latencia p99 explícito
(`latency_p99_slo_ms`, mismo valor definido en ambos módulos Terraform
para que la comparación sea justa si algún día se despliega también en
AWS). Pendiente: MTTD real de los 2 experimentos del Módulo D en GCP, y
cálculo de consumo de error budget durante cada ventana.

**Nivel actual (provisional): 3→4 tras Fase 3**, condicionado a MTTD
medido < 2 min en al menos un experimento.

---

## Dominio 7 -- Chaos Engineering proactivo

**Fuente:** metodología de Principios del Caos ya aplicada en la actividad
anterior (`GameDay_Plan.pdf`, validado); enunciado Módulo D.

**Qué mide:** si el equipo valida hipótesis de fallo de forma recurrente y
controlada, no solo reactivamente tras un incidente real.

**Evidencia:** ✅ Precedente real ya ejecutado (H1 del laboratorio
anterior, con blast radius/duración/rollback definidos y evidencia real de
Jaeger/Prometheus). Esta actividad añade 2 experimentos más
(`chaos/h4_*.sh`, `chaos/h5_*.sh`) con el mismo estándar de rigor
(rollback explícito, ventana cronometrada).

**Nivel actual: 4** ✅ (precedente real + nuevos experimentos diseñados
con el mismo rigor). Para 5: estos experimentos deberían programarse como
Game Day recurrente (ver dominio 8), no ejecutarse solo para la entrega.

---

## Dominio 8 -- Cultura y gobierno (IaC, Game Day recurrente, decisiones documentadas)

**Fuente:** AWS Observability Maturity Model (dimensión "Strategy");
práctica general de SRE.

**Qué mide:** si la infraestructura y las decisiones de observabilidad
están versionadas, documentadas y son repetibles por cualquier persona del
equipo -- no tribal knowledge.

**Evidencia:** ✅ 100% IaC (Terraform + Helm + manifiestos de Istio),
decisiones de arquitectura documentadas inline en el propio código (mismo
estilo que `docs/reporte-tecnico.md` de la Actividad 2.2), scripts de
preflight que fuerzan verificar permisos antes de gastar presupuesto.

**Nivel actual: 4** ✅. Para 5: este Game Day necesitaría repetirse on
una cadencia fija (trimestral, por ejemplo) con el mismo runbook, no como
evento único de una entrega -- ver roadmap.

---

## Resumen de niveles

| Dominio | Nivel actual | Meta a 3 meses |
|---|---|---|
| 1. Instrumentación 3 pilares | 4 | 5 |
| 2. Correlación cross-signal | 3 | 4 |
| 3. Red / service mesh L7 | 2 (🔶3 tras Fase 3) | 4 |
| 4. AIOps / anomalías | 3 (🔶4 tras Fase 3) | 4 |
| 5. Seguridad y cumplimiento | 2 | 3 |
| 6. Alertas / MTTD-MTTR/error budget | 3 (🔶4 tras Fase 3) | 4 |
| 7. Chaos Engineering | 4 | 5 |
| 8. Cultura y gobierno | 4 | 5 |

## Roadmap de mejora (3 meses)

**Mes 1 -- cerrar las brechas más baratas primero.**
- Dominio 2: incrustar el `trace_id` directamente en el payload de la
  notificación de la alerta compuesta (hoy es un enlace a una consulta) --
  requiere una función pequeña (Lambda/Cloud Function) que lea el último
  log ERROR del servicio y lo adjunte antes de publicar a SNS/notification
  channel. Se decidió no incluirla en esta entrega para no depender de una
  pieza más sin poder probarla contra presupuesto real de Learner Lab (ver
  `iac/terraform/aws/cloudwatch_aiops.tf`) -- primer candidato del roadmap.
- Dominio 6: instrumentar el cálculo de error budget como métrica propia
  (`slo_error_budget_remaining_ratio`), no solo como cálculo manual
  post-experimento.

**Mes 2 -- cerrar la brecha de seguridad (dominio 5, el más débil).**
- Si el proyecto GCP migra a una organización real (Cloud Identity), volver
  a intentar Security Command Center Standard.
- Mientras tanto: Cloud Armor / AWS WAF básico frente al ALB/Ingress
  (aunque no haya autenticación de usuario final, sí hay superficie HTTP
  pública que vale la pena proteger de escaneo/DoS de bajo volumen).
- Añadir GuardDuty (AWS) fuera del Learner Lab, en una cuenta de
  producción real, como sustituto de Security Hub.

**Mes 3 -- consolidar cultura (dominio 8) y mesh (dominio 3).**
- Programar este Game Day como scheduled task recurrente (trimestral),
  reutilizando `chaos/h4_*.sh`/`h5_*.sh` con nuevas hipótesis.
- Completar la migración de `orders`/`inventory` (hoy en Postgres-on-Fargate
  / el Postgres del clúster GKE) a la misma base gestionada que
  `customers` (RDS/Cloud SQL), unificando el dominio de datos completo bajo
  un solo motor gestionado -- ver la nota de alcance en
  `iac/terraform/aws/rds.tf` y `iac/terraform/gcp/cloudsql.tf`.
- Si el mesh (dominio 3) demostró valor real en la Fase 3, evaluar
  Anthos Service Mesh gestionado / AWS App Mesh en modo producción (con
  HA real, no la configuración de laboratorio de esta entrega).
