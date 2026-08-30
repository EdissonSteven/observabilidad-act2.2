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

**Evidencia:** ✅ **Istio desplegado y verificado en GKE real.** mTLS
STRICT activo entre los 3 microservicios, todos los pods `2/2 Running` con
sidecar `istio-proxy` inyectado, `istioctl proxy-status` reportando
`Clusters/Listeners/Routes Match`, y tráfico real atravesando el mesh
(trace de 3 saltos `862025050a4b863f91cecd8faa78758b`). AWS App Mesh
(`iac/terraform/aws/appmesh.tf`) queda como diseño equivalente no
desplegado -- decisión de alcance.

**Hallazgo no anticipado, con costo real:** el mTLS STRICT del namespace
bloqueó por completo el scraping de Google Managed Prometheus sobre el
`otel-collector` -- un scraper EXTERNO al mesh, sin certificados de istiod.
Efecto: **TODAS las métricas de aplicación dejaron de llegar a Cloud
Monitoring**, sin ningún error visible en los logs del collector, porque el
rechazo ocurre en el sidecar Envoy y no en el proceso. Confirmado contra la
documentación oficial de Istio y resuelto con un `PeerAuthentication` de
excepción por puerto (`portLevelMtls: {8889: PERMISSIVE}`), verificado con
un pod SIN inyección de sidecar. Es la ilustración concreta de que el mesh
no es gratis: añade una superficie de fallo que es invisible desde la
aplicación.

**Nivel actual: 3** ✅ (criterio pre-registrado cumplido: mesh desplegado y
verificado, con métricas de Envoy por request). No se reclama 4/5 porque
eBPF nativo (Cilium/Tigera Calico Enterprise) no está en alcance -- queda
en el roadmap.

---

## Dominio 4 -- AIOps / detección de anomalías

**Fuente:** AWS Observability Maturity Model (stage 3–4); enunciado
Módulo B.

**Qué mide:** si la detección de degradación usa una banda de
comportamiento esperado (baseline ± σ) en vez de solo un umbral fijo, y si
correlaciona más de una señal.

**Evidencia:** ✅ **La alerta correlacionada disparó contra un incidente
real** (Experimento 3, `docs/modulo-d-resultados.md`), y las dos policies
**discriminaron correctamente**: `correlated-degradation` (basada en 5xx
HTTP) NO disparó -- correcto, no hubo ningún 5xx --, mientras
`correlated-degradation-data-service` SÍ lo hizo, detectando la degradación
silenciosa. Esa discriminación es evidencia directa de que la correlación
distingue casos, no solo suma señales.

**Límites documentados, medidos y no aparentes en el diseño:**

1. *Un fallo de un solo síntoma no puede activar una regla de dos
   síntomas.* Los Experimentos 1 y 2 no dispararon, y no por
   configuración: la inyección de error en `data-service` es un *fast-fail*
   que responde antes de tocar la BD, así que **baja** la latencia en vez
   de subirla. Comprobado midiendo, no deduciendo: p50 216.6→218.1 ms
   durante el fallo. Hizo falta un experimento combinado.
2. *La correlación cambia ruido por ceguera.* El mismo mecanismo que evita
   falsos positivos deja pasar fallos que producen errores SIN degradar
   latencia -- una caída total de la base de datos, por ejemplo. No es un
   defecto corregible con parámetros: es el trade-off inherente de la
   conjunción.
3. *El umbral es ESTÁTICO, no un baseline dinámico.* El diseño original
   (media + 2σ) se abandonó al no poder confirmar la sintaxis de ventana
   deslizante en MQL. Un umbral fijo no es "detección de anomalías" en
   sentido estricto -- es lo que impide reclamar 5 en este dominio.
4. *La migración a PromQL degradó el mensaje de alerta.* Ver dominio 2.

**Nivel actual: 4** ✅ (criterio pre-registrado cumplido: la alerta
compuesta disparó correctamente contra un incidente real y discriminó
frente a la policy que no debía disparar). La comparación formal de conteo
de disparos frente a `naive_static_threshold` requiere
`chaos/h6_blip_postgres.sh` -- el único fallo que produce 5xx reales en
este sistema, ver dominio 6. Para 5 haría falta un baseline dinámico real.

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

**Evidencia:** ✅ **MTTD medido contra un incidente real: 282 s** (243 s
si se cuenta desde la activación efectiva del fallo, descontando el
rollout). Consumo de error budget calculado: **2.31 %** del presupuesto
mensual en ~7 minutos. Ambos con `chaos/measure_mttd.py` y
`chaos/analyze_error_budget.py`, reproducibles desde los CSV en
`docs/evidencia/modulo-d/`.

**El criterio pre-registrado era MTTD < 2 min. NO se cumple** -- 282 s
frente a 120 s. Y la descomposición explica por qué, con números:

| Tramo | Duración | Causa |
|---|---|---|
| Rollout de `kubectl set env` | ~47 s | El fallo no está vivo hasta que los pods se reemplazan |
| Ramp de la ventana `rate[2m]` | ~60 s | El error rate tarda en cruzar el umbral |
| `duration` de la condition | 60 s | La condición debe sostenerse |
| **Latencia del pipeline de métricas** | **~117 s** | Scrape (30 s) + ingesta de GMP + cadencia de evaluación |

**El hallazgo que importa: el piso del MTTD lo pone el pipeline de
métricas, no la configuración de la alerta.** Durante la depuración se bajó
el `duration` de 180 s a 60 s y el MTTD siguió en 282 s. Seguir bajándolo
no ayuda -- el cuello de botella está aguas arriba, en el intervalo de
scraping. Es un límite estructural que ninguna cantidad de ajuste fino de
umbrales resuelve.

**Segundo hallazgo, sobre el SLI y no sobre el tiempo:** el mismo incidente
consumió **2.31 % del error budget medido por violación de latencia y
0.00 % medido por códigos HTTP**. Con el 30 % de las llamadas a
`data-service` fallando y el 88 % de las peticiones violando el SLO, un SLO
de disponibilidad basado en 5xx habría reportado 100 % de éxito. El reporte
mensual habría salido impecable.

**Tercer hallazgo:** el sistema **ya violaba su propio SLO en reposo** --
15.71 % de las peticiones por encima de 250 ms con tráfico limpio, p99
basal de 564 ms (más del doble del SLO). No se había detectado antes porque
nadie había mirado la distribución, solo el promedio.

**Nivel actual: 3.** El criterio pre-registrado (MTTD < 2 min) no se
cumplió, así que no sube a 4 -- se respeta el criterio tal como se fijó
antes de medir. Hay SLO explícito, MTTD medido y error budget calculado,
que es lo que sostiene el 3; falta que el tiempo de detección sea
aceptable y que el error budget sea una métrica viva y no un cálculo
post-hoc.

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

**Actualización tras la ejecución real:** los experimentos ya no están
"diseñados" sino **ejecutados contra GKE real**, y produjeron un hallazgo
que no estaba en la hipótesis: dos de los tres no dispararon la alerta, y
la causa resultó ser estructural (un fallo de un solo síntoma no puede
activar una regla de correlación de dos síntomas). Eso obligó a diseñar un
tercer experimento combinado, y a un cuarto (`chaos/h6_blip_postgres.sh`)
al descubrir que `service-a` nunca devuelve 5xx por fallos de dependencias
-- lo que hace inejecutable a la alerta ingenua con los experimentos
previos. Un Game Day que solo confirma lo que ya se esperaba aporta poco;
este refutó dos hipótesis y forzó rediseñar el instrumento de medición.

**Nivel actual: 4** ✅ (precedente real + 3 experimentos ejecutados con
rollback explícito y ventana cronometrada, más 1 diseñado). Para 5: estos
experimentos deberían programarse como Game Day recurrente (ver dominio 8),
no ejecutarse solo para la entrega.

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

**Hallazgo de gobierno surgido de la ejecución real:** `terraform plan`
**no basta** para juzgar el riesgo de un cambio sobre recursos de
observabilidad. El plan dice qué intentará Terraform, no qué permitirá la
nube ni qué datos se pierden en el camino. Dos evidencias concretas:

1. Omitir un `-var` (Terraform no los recuerda entre corridas) planificó
   destruir el notification channel de todas las alertas. Solo lo impidió
   una restricción de integridad referencial de la API de GCP.
2. Un `must be replaced` sobre un log-based metric es, en la práctica, una
   **pérdida de historial irreversible** -- las métricas basadas en logs no
   se recalculan retroactivamente. Eso no aparece por ninguna parte en la
   salida del plan. La API volvió a ser la última línea de defensa.

La lección operativa es concreta: revisar planes de Terraform sobre
recursos de observabilidad exige entender la semántica de datos del
recurso, no solo leer las líneas de `+`/`-`/`~`. Está documentada inline en
`iac/terraform/gcp/network_security.tf` y en el roadmap.

**Segundo hallazgo:** el propio `scripts/gcp_preflight_check.sh` daba un
`[OK]` infundado sobre Security Command Center, porque comprobaba "¿ve el
usuario alguna organización?" en lugar de "¿de qué organización cuelga el
proyecto?". Un preflight que da luz verde a una comprobación mal planteada
es peor que no tenerlo. Corregido, con la evidencia del error en el propio
script.

**Nivel actual: 4** ✅. Para 5: este Game Day necesitaría repetirse con
una cadencia fija (trimestral, por ejemplo) con el mismo runbook, no como
evento único de una entrega -- ver roadmap.

---

## Resumen de niveles

Los niveles marcados como "provisional, X→Y tras Fase 3" en la primera
redacción de este documento **ya están resueltos con datos reales**. Se
respetan los criterios tal como se fijaron ANTES de medir, en ambas
direcciones: donde el criterio se cumplió el dominio sube, y donde no se
cumplió se queda -- aunque el resto de la evidencia sea buena.

| Dominio | Nivel actual | Meta a 3 meses | Criterio pre-registrado |
|---|---|---|---|
| 1. Instrumentación 3 pilares | 4 | 5 | — |
| 2. Correlación cross-signal | 3 | 4 | — |
| 3. Red / service mesh L7 | **3** ⬆ | 4 | Mesh desplegado y verificado → **cumplido** |
| 4. AIOps / anomalías | **4** ⬆ | 5 | La alerta compuesta dispara correctamente → **cumplido** |
| 5. Seguridad y cumplimiento | 2 | 3 | — |
| 6. Alertas / MTTD-MTTR/error budget | **3** ⏸ | 4 | MTTD < 2 min → **NO cumplido** (282 s) |
| 7. Chaos Engineering | 4 | 5 | — |
| 8. Cultura y gobierno | 4 | 5 | — |

El dominio 6 es el caso que más vale la pena mirar: hay SLO explícito, MTTD
medido con precisión de segundos y error budget calculado -- más evidencia
que en varios dominios que puntúan igual o más alto. Pero el criterio que
se fijó antes de medir era un umbral de tiempo, y no se alcanzó. Subirlo a
4 ahora sería mover la portería después del tiro.

## Roadmap de mejora (3 meses)

Priorizado por lo que la ejecución real demostró que falta, no por lo que
parecía faltar en el diseño. Cada ítem cita la medición que lo justifica.

### Mes 1 -- lo que la medición señaló como cuello de botella

**1. Bajar el `interval` del `PodMonitoring` de 30 s a 10 s.**
*Por qué:* la descomposición del MTTD (dominio 6) atribuye ~117 s de los
282 s a la latencia del pipeline de métricas. Es el tramo más grande y el
único que no se puede reducir tocando la alerta -- se comprobó bajando el
`duration` de 180 s a 60 s sin efecto apreciable en el total. Es un cambio
de una línea en `iac/gmp/podmonitoring-otel-collector.yaml`, con costo en
volumen de muestras que hay que medir.
*Cómo se verifica:* repetir `chaos/run_experimento_d3_combinado.sh` y
comparar el MTTD contra los 282 s de referencia.

**2. Añadir un SLI de throughput.**
*Por qué:* el incidente del Experimento 3 redujo el throughput un **69 %**
(4.14 → 1.27 req/s) y **ningún SLI del sistema lo capturó** -- ni el de
latencia ni el de errores. Una pérdida de dos tercios de la capacidad de
servicio fue invisible para el sistema de alertas.

**3. Revisar el SLO de latencia de 250 ms.**
*Por qué:* el sistema lo viola el **15.71 % del tiempo en reposo**, con un
p99 basal de 564 ms. O el objetivo es irreal para una arquitectura de 3
saltos con Cloud SQL, o hay latencia base que optimizar. Un SLO que se
incumple sin incidentes no es un SLO: es ruido de fondo con nombre. Decidir
cuál de las dos cosas es, con datos, antes de seguir construyendo alertas
encima.

**4. Arreglar el mensaje de las alertas PromQL.**
*Por qué:* llegan con `metric: __missing__` y un número desnudo ("A PromQL
query was observed at 21.056..."), frente a las de `condition_threshold`
que dicen "is above threshold of 5 with a value of 12.783". La causa está
identificada: `sum(...)` sin `by` descarta todas las labels. Fix concreto:
`by (namespace)` en las agregaciones, campo `labels` del
`condition_prometheus_query_language` para contexto estático, y `severity`
(hoy todas llegan como `No severity`).

### Mes 2 -- seguridad (dominio 5, el más débil)

**5. Sustituir la detección de tráfico anómalo por volumen por detección
por concentración.**
*Por qué:* la alerta actual es **a la vez demasiado sensible y demasiado
insensible**, y está cuantificado. Disparó dos veces con ruido de fondo
inaccionable (se recuperó sola en 1 min 51 s), mientras la única fuente con
firma de reconocimiento real -- 982 conexiones, todas al puerto 443, desde
una VM de GCP en Londres -- genera 0.045 conex/s, cien veces por debajo del
umbral. **Ningún valor del umbral arregla ambos problemas**, porque el
volumen no es la dimensión que separa las poblaciones.
*Diseño propuesto:* una consulta analítica periódica sobre los logs que
alerte cuando una sola IP supere N intentos contra el mismo puerto en una
ventana. No puede vivir en una métrica: IP origen y puerto destino tienen
3 789 y 4 802 valores distintos, muy por encima del límite de cardinalidad.

**6. Cloud Armor delante del Ingress.** Aunque no haya autenticación de
usuario final, sí hay superficie HTTP pública -- el análisis de tráfico
rechazado muestra escaneo constante de puertos conocidos (Telnet 3.8 %,
SSH 1.4 %).

**7. Security Command Center queda descartado**, y la justificación cambió
respecto a la primera redacción: no es que falte una organización, es que
**el proyecto no cuelga de ninguna** (verificado con
`gcloud projects describe --format='value(parent.type,parent.id)'`, que
devuelve vacío, mientras `gcloud organizations list` sí devuelve una). Y
aunque colgara de la organización institucional, activarlo afectaría a
todos los proyectos de la Universidad -- fuera de alcance por criterio, no
solo por permisos.

### Mes 3 -- gobierno (dominio 8) y consolidación

**8. Política de revisión de planes de Terraform sobre recursos de
observabilidad.**
*Por qué:* dos veces en una sola sesión, un `terraform plan` de aspecto
inofensivo habría destruido infraestructura de observabilidad, y en ambos
casos lo impidió la API de GCP, no la revisión humana. Un `must be
replaced` sobre un log-based metric es pérdida de historial irreversible y
eso no aparece en el plan. La política concreta: para recursos de
observabilidad, exigir que la revisión indique explícitamente qué datos
históricos se pierden con cada `replace`.

**9. Programar el Game Day como tarea recurrente trimestral**, reutilizando
`chaos/run_experimento_d3_combinado.sh` con hipótesis nuevas. Es lo único
que separa al dominio 7 del nivel 5.

**10. Unificar `orders`/`inventory` (hoy en el Postgres del clúster, sin
PVC) bajo Cloud SQL**, como ya está `customers`. Hoy el sistema tiene dos
motores de datos con niveles de gestión distintos, y solo uno está
respaldado.

**11. eBPF nativo (Cilium) para el dominio 3**, si el mesh demuestra valor
sostenido. Es lo que separaría al dominio 3 del nivel 4-5, pero exige
justificar el costo operativo de otra capa.
