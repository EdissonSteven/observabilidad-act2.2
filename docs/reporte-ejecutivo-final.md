# Reporte ejecutivo final -- Laboratorio integrador de observabilidad
## Arquitectura completa, AIOps, Network & Security, Chaos Engineering y madurez

> **Estado: BORRADOR / ESQUELETO.** Este documento fija la estructura y
> el contenido que YA es verdadero (arquitectura, diseño de hipótesis y
> experimentos, decisiones de IaC) antes de ejecutar el despliegue real.
> Cada sección con `[EVIDENCIA PENDIENTE]` se completa después de correr
> los runbooks en `docs/runbooks/` -- **no rellenar esos bloques con
> números inventados**; si un experimento no se llega a ejecutar en una
> nube, la sección correspondiente debe decir explícitamente "no
> ejecutado, IaC listo" (mismo estándar de honestidad que
> `docs/reporte-tecnico.md` de la Actividad 2.2). Al convertir esto a PDF
> (skill `pdf`), apuntar a 10 páginas recortando el detalle de este
> esqueleto, no añadiendo relleno.
>
> **Decisión de alcance (2026-08-29):** el despliegue real de esta entrega
> se ejecuta únicamente en **GCP** (cuenta con $300 de crédito de prueba).
> **AWS no se toca** -- ni `terraform apply` ni ningún paso manual --
> decisión explícita para no arriesgar el presupuesto ajustado del Learner
> Lab ($19). El Terraform de AWS (RDS, App Mesh, VPC Flow Logs, CloudWatch
> AIOps, dashboard de seguridad) queda como **diseño completo y validado
> sintácticamente** (ver `docs/runbooks/00-validacion-local-y-preflight.md`,
> Paso 0) pero **no desplegado** -- mismo estándar de honestidad que el
> README/`docs/reporte-tecnico.md` de la Actividad 2.2 ya aplicó al IaC de
> nube no desplegado en esa entrega. Toda mención más abajo a "ambas
> nubes" se lee como: GCP con evidencia real, AWS con el `.tf` como
> evidencia de diseño.

**Autores:** [completar -- mismo equipo de `GameDay_Plan.pdf`]
**Repositorio:** https://github.com/EdissonSteven/observabilidad-act2.2
(tag `v1.0` al momento de la entrega)
**Fecha:** [fecha de la ventana de despliegue real]

---

## 1. Resumen ejecutivo

[EVIDENCIA PENDIENTE: 1 párrafo resumiendo qué se desplegó de verdad, en
qué nube(s), qué confirmaron y qué refutaron los 2 experimentos de caos,
y el hallazgo más importante de la autoevaluación de madurez -- mismo
formato que la sección 1 de `GameDay_Plan.pdf`, ya validada.]

## 2. Arquitectura objetivo (Módulo A)

Extiende el pipeline de la Actividad 2.2 (`service-a` orquestador de
pedidos, `service-b` inventario, PostgreSQL, OTel Collector,
Jaeger/Tempo/Prometheus/Loki/Grafana) con un tercer microservicio:

| Componente | Rol | Dependencia crítica | Alcance de ejecución |
|---|---|---|---|
| `data-service` (FastAPI, :8002) | Perfil de cliente del pedido | Cloud SQL / RDS PostgreSQL (sin timeout ni retry -- mismo patrón de riesgo ya documentado para service-a/service-b en el informe técnico de la Actividad 2.2) | **GCP: desplegado.** AWS: código idéntico, IaC listo, no desplegado |
| Cloud SQL / RDS (`customersdb`) | Persistencia de `customers`, dedicada a data-service | Peering privado (GCP) / Secrets Manager (AWS) -- ver `iac/terraform/{gcp,cloudsql.tf; aws,rds.tf}` | **Cloud SQL: desplegado.** RDS: `.tf` validado, no desplegado |
| Service mesh (Istio sobre GKE / AWS App Mesh) | Observabilidad L7 + mTLS entre los 3 microservicios | Envoy sidecar por pod/task | **Istio (GKE): desplegado.** App Mesh: `.tf` validado, no desplegado |
| VPC Flow Logs (GCP; AWS diseñado) | Visibilidad de red N-S/E-W | Sin IAM nuevo en AWS (destino S3); nativo por subred en GCP | **GCP: desplegado.** AWS: `.tf` validado, no desplegado |
| Cloud Monitoring MQL (GCP; CloudWatch Anomaly Detection diseñado en AWS) | Correlación error_rate + latencia (Módulo B) | Métricas OTel vía el exporter `googlecloud`/`awsemf`-equivalente ya presente en el Collector | **GCP: desplegado y validado en consola.** AWS: `.tf` validado, no desplegado |

Decisión de alcance explícita (blast radius): `orders`/`inventory`
permanecen en el Postgres ya usado por service-a/service-b (el Postgres
del clúster en GCP; el equivalente en Fargate solo existe como diseño en
AWS) -- Cloud SQL/RDS son la base de datos PROPIA y nueva de
`data-service`. Ver la justificación completa en
`iac/terraform/aws/rds.tf` y `iac/terraform/gcp/cloudsql.tf`.

Segunda decisión de alcance, esta de negocio/presupuesto (ver nota al
inicio del documento): el despliegue real de todo lo anterior se hace
**solo en GCP**. El Terraform de AWS es código funcionalmente equivalente
(mismo `data-service`, mismas convenciones semánticas, misma lógica de
alertas) pero no se ejecuta contra el Learner Lab -- se cita como
evidencia de diseño, no de ejecución.

[EVIDENCIA PENDIENTE: diagrama de arquitectura actualizado con el 3er
servicio y la base de datos gestionada -- reutilizar/extender
`docs/charts/04_diagrama_arquitectura.png` de la Actividad 2.2.]

## 3. Hipótesis de fallo (Módulo D, formato Principios del Caos)

| # | Hipótesis | Tipo de fallo |
|---|---|---|
| D1 | En estado estable, cuando inyectamos 200ms de latencia de red en el enlace service-a → service-b, esperamos que GET /orders/{id} siga respondiendo 200 OK y que la traza muestre el salto de red como el componente dominante de la latencia, sin que aumente la tasa de error del sistema. | Latencia de red |
| D2 | En estado estable, cuando data-service devuelve error 500 en el 10% de las peticiones, esperamos que la alerta correlacionada del Módulo B (error_rate fuera de baseline ± 2σ Y latency_p99 > SLO) dispare en menos de 2 minutos, y que el trace_id de una petición fallida quede identificable en la notificación. | Error rate (aplicación) |

## 4. Experimentos de caos diseñados

| # | Fallo inyectado | Blast radius | Duración | Rollback |
|---|---|---|---|---|
| D1 | `tc netem delay 200ms` en `service-b`, ejecutado en GKE (el modo `INJECT_LATENCY_MS=200` para ECS Fargate queda documentado en el código pero no se ejecuta -- alcance GCP-only de esta entrega) | Solo el tráfico service-a → service-b; PostgreSQL/Cloud SQL fuera del radio | 60s, ventana corta y cronometrada | `tc qdisc del` automático |
| D2 | `FAULT_INJECT_ERROR_RATE=0.10` en `data-service`, ejecutado en GKE | Solo data-service; service-a/service-b siguen respondiendo, degradados | 60s | Redeploy con `FAULT_INJECT_ERROR_RATE=0` |

Procedimiento completo, comandos exactos y herramientas:
`docs/runbooks/04-modulo-d-chaos.md`, `chaos/h4_latency_service_b.sh`,
`chaos/h5_error_rate_data_service.sh`.

## 5. Métricas de observabilidad para verificar cada hipótesis (Módulo B)

| Hipótesis | SLI principal | Evidencia de logs/trazas |
|---|---|---|
| D1 | Latencia p95/p99 de `GET /orders/{id}` y tasa de error | Span `order.check_inventory` con duración elevada; contador `service_b_calls_total{outcome="success"}` sigue incrementando (no pasa a "unreachable") |
| D2 | `error_rate` (Cloud Monitoring/CloudWatch) y disponibilidad de `data-service` | Span `customer.fault_injected` con `chaos.injected=true`; log `customer_fault_injected`; contador `chaos_injected_total` |

Regla de correlación implementada (idéntica en Prometheus local,
CloudWatch y Cloud Monitoring -- ver
`observability/prometheus/alert_rules.yml`,
`iac/terraform/aws/cloudwatch_aiops.tf`,
`iac/terraform/gcp/monitoring_aiops.tf`):

```
error_rate > baseline_mean_30m + 2 * baseline_stddev_30m
AND
latency_p99 > SLO_threshold (300ms)
```

## 6. Ejecución real y resultados (Módulo D)

### 6.1 Procedimiento y herramientas

Nube de ejecución: **GCP únicamente** (ver decisión de alcance al inicio
del documento). AWS no se aplicó -- el Terraform correspondiente se cita
como diseño, no como ejecución.

[EVIDENCIA PENDIENTE: configuración exacta usada en GCP (región/zona,
project ID, si `enable_app_mesh`/`deploy_rds` aplican o son N/A por ser
variables de AWS), siguiendo `docs/runbooks/01-modulo-a-arquitectura.md` y
`04-modulo-d-chaos.md` (sección GCP de cada uno).]

**Nota metodológica:** antes de ejecutar contra GCP, los dos experimentos
de caos (D1 y D2) se ensayaron completos en local (docker-compose),
siguiendo el mismo estándar de "validar en seco antes de gastar
presupuesto de nube" del Runbook 0. Ese ensayo encontró y corrigió dos
problemas reales -- uno de arquitectura (D2) y un hallazgo no anticipado
de rendimiento (D1) -- antes de que llegaran a costar tiempo o crédito de
GCP. El detalle completo, con evidencia, está en las secciones 6.4 y 8;
`docs/runbooks/04-modulo-d-chaos.md` (Paso 0) documenta cómo repetir el
mismo ensayo, y `chaos/run_experimento_d2.sh` es el script resultante. La
ejecución real en GCP (secciones 6.2, 6.3, 6.5, 6.6 y 9 de aquí en
adelante) parte ya del código e IaC corregidos por este ensayo.

### 6.2 Resultados reales obtenidos

[EVIDENCIA PENDIENTE: tabla de percentiles baseline vs. durante-el-fallo
vs. post-rollback para D1 y D2, igual formato que la Tabla de
`GameDay_Plan.pdf` ya validada -- generada a partir de los CSV de
`chaos/load_gen.py`.]

### 6.3 MTTD medido

[EVIDENCIA PENDIENTE: salida de `chaos/measure_mttd.py` para D1 y D2 en
GCP (`--backend gcp`) -- ¿estuvo por debajo de 2 minutos?]

### 6.4 Comparación esperado vs. obtenido

**Evidencia de esta sección: ensayo local (docker-compose), 2026-08-29,
previo al despliegue en GCP** (ver nota metodológica en 6.1). Se
documenta aquí porque es el resultado real más temprano disponible sobre
el comportamiento de las hipótesis D1/D2; la sección 6.2 recoge la
confirmación (o divergencia) de estos mismos hallazgos una vez ejecutados
en GCP.

**D1 -- parcialmente confirmada, con hallazgo no anticipado.** La parte
"sin que aumente la tasa de error" se confirmó: con 200ms de latencia
inyectada (`tc netem`) en el enlace service-a → service-b, `GET
/orders/{id}` siguió respondiendo 200 en el 100% de las peticiones
(1680 requests, `errors_or_degraded=0`). Pero la magnitud de la latencia
observada NO coincidió con la esperada: p99=471.4ms y max=843.3ms, es
decir 2-4x el retraso de 200ms realmente inyectado -- no un margen de
medición, una duplicación sistemática. Causa raíz identificada en el
código, no inferida: `_check_inventory()` en
`services/service-a/app/main.py` crea un `httpx.AsyncClient(timeout=5.0)`
nuevo en CADA llamada a service-b (`async with httpx.AsyncClient(...) as
client:` dentro de la función), sin *connection pooling* ni *keep-alive*
entre peticiones. Bajo latencia de red inyectada, el establecimiento de
la conexión TCP y el envío/recepción de la petición HTTP atraviesan
ambos el enlace retrasado, pagando el costo de red dos veces por
petición lógica en vez de una. Mismo patrón (`_fetch_customer()` hacia
data-service) existe también para el tercer salto, aunque D1 solo inyectó
el fallo en el segundo. **Se documenta como hallazgo, sin modificar
código** (decisión explícita: el objetivo del experimento era validar la
hipótesis y medir, no optimizar el pool de conexiones de httpx en este
ciclo) -- queda como mejora identificada en
`docs/madurez-observabilidad.md` (dominio de instrumentación/rendimiento).

**D2 -- refutada en su forma original, confirmada tras corregir dos
problemas reales.** La hipótesis esperaba que
`CorrelatedDegradation` dispare en <2 min ante 10% de error rate
inyectado en data-service. En el primer intento, con tráfico real
sostenido y error rate 100% durante más de 60s seguidos, **la alerta
nunca pasó de `inactive`.** Dos causas raíz distintas, verificadas
empíricamente antes de tocar ningún archivo (nunca se asumió la causa sin
evidencia, por la naturaleza de este informe):

1. **Degradación silenciosa (bug de arquitectura, ya visto en el Game
   Day de la Actividad 2.2, ahora recurrente en el salto
   service-a→data-service):** `get_order()` solo marca `status_label`
   distinto de "200" si una `HTTPException` sale de la función, pero
   `_fetch_customer()` atrapa internamente TODOS sus fallos (tanto
   `httpx.HTTPStatusError` como `httpx.RequestError`) y responde con un
   diccionario de error, sin propagar excepción -- `get_order()` sigue
   devolviendo 200 igual. Consecuencia: `http_requests_total` (la única
   señal de la que dependía la regla original) nunca ve un 5xx para este
   caso, sin importar qué tan mal calibrado esté el umbral. Confirmado
   con `curl http://localhost:9090/metrics | grep -i data_service_calls`,
   que sí mostraba el fallo real vía `data_service_calls_total{outcome="unreachable"}`
   mientras `http_requests_total` se mantenía en 200 -- la señal correcta
   ya existía, solo no estaba conectada a la alerta. **Fix:** se añadió
   `service_a:data_service_error_rate:ratio_rate2m` (mismo patrón
   baseline±2σ, sobre `data_service_calls_total{outcome!="success"}`) y
   se combinó con `or` en `CorrelatedDegradation`
   (`observability/prometheus/alert_rules.yml`), y su equivalente en
   `iac/terraform/gcp/monitoring_aiops.tf`
   (`correlated_degradation_data_service`, como policy independiente
   porque el combiner de una alert policy de GCP no admite `(A or B) and
   C` dentro de una sola policy) e
   `iac/terraform/aws/cloudwatch_aiops.tf` (rama `OR` en el
   `alarm_rule` de la alarma compuesta, diseño no ejecutado).

2. **Baseline auto-envenenado (hallazgo metodológico, no de código):**
   tras el fix anterior, una segunda corrida SIGUIÓ sin disparar la
   alerta -- pero esta vez con datos reales que lo explican, no con
   `NaN`. Se observó `error_rate` subiendo de 40% a 61.7% mientras
   `umbral` (baseline_mean_30m + 2·stddev_30m) subía en paralelo, siempre
   ~1.4-1.5x por encima (40→60, 53.85→76.94, 61.70→86.40): con el
   volumen de Prometheus recién reseteado, la "historia de 30 minutos"
   usada por `avg_over_time`/`stddev_over_time` era en realidad el propio
   experimento en curso, así que el baseline no representaba
   comportamiento normal -- se movía junto con la anomalía en vez de
   servir de referencia fija. Relacionado: antes de eso, `umbral` había
   quedado en `NaN` de forma persistente por divisiones `0/0` (sin
   tráfico en ventanas de prueba previas), y en punto flotante IEEE 754
   `valor > NaN` siempre es `false` -- un solo `NaN` dentro de la ventana
   de 30 minutos deja la alerta ciega ese tiempo completo. **Fix:**
   `clamp_min(denominador, 1e-9)` en ambas fórmulas de ratio (evita el
   `NaN` por falta de tráfico) y, como práctica operativa, dejar correr
   tráfico limpio (≥5 min en local, ventana de baseline de GCP es 1h así
   que se recomienda más) ANTES de inyectar el fallo -- documentado en
   `docs/runbooks/04-modulo-d-chaos.md` (Paso 0) y encapsulado en
   `chaos/run_experimento_d2.sh` para que sea repetible igual cada vez.

   **Confirmación empírica final** (capturas en
   `docs/evidencia/d2_correlateddegradation_*.png`): con el baseline ya
   asentado en 0/0 durante 5 minutos de warm-up limpio, al inyectar el
   fallo `CorrelatedDegradation` pasó de `inactive` a **`PENDING`**
   (`Active Since: 2026-08-29T04:43:33.325497069Z`, `Value:
   17.41`) y, sostenido más de 60s (el `for: 1m` de la regla), a
   **`FIRING`** (mismo `Active Since`, `Value: 100`) --
   `docs/evidencia/d2_correlateddegradation_pending_detalle.png` y
   `d2_correlateddegradation_firing_detalle.png`.

### 6.5 ¿Se degradó el SLO? ¿Se consumió el error budget?

[EVIDENCIA PENDIENTE: cálculo siguiendo el paso 3 de
`docs/runbooks/04-modulo-d-chaos.md`, con el supuesto de tráfico mensual
usado explícito.]

### 6.6 Reducción de alertas ruidosas (Módulo B)

[EVIDENCIA PENDIENTE: conteo real, alerta ingenua vs. correlacionada,
misma ventana de tráfico -- `docs/runbooks/02-modulo-b-aiops.md` paso 3.]

## 7. Network & Security Observability (Módulo C)

Ejecutado solo en GCP (ver decisión de alcance). La consulta Athena sobre
VPC Flow Logs en S3 (`docs/runbooks/03-modulo-c-network-security.md`,
sección AWS) no se ejecuta -- se documenta como diseño equivalente, ya
que la lógica (contar tráfico `REJECT` por origen/puerto) es la misma que
el log-based metric de GCP, solo cambia el motor de consulta.

[EVIDENCIA PENDIENTE: resultado del log-based metric de GCP sobre
tráfico rechazado; captura del dashboard "Golden Signals de Seguridad"
de GCP; disponibilidad real de Security Command Center según el
preflight (`scripts/gcp_preflight_check.sh`).]

Brecha documentada de antemano (no depende de la ejecución): ninguno de
los 3 microservicios implementa autenticación de usuario final, así que
"intentos de autenticación fallidos" no es una señal real de este
sistema -- ver `docs/madurez-observabilidad.md`, dominio 5, para el
razonamiento completo y la remediación propuesta.

## 8. Debilidad sistémica revelada y remediación

**Debilidad:** el sistema tiene un patrón recurrente de **degradación
silenciosa invisible a las métricas basadas en status HTTP**. No es un
bug aislado de `data-service` -- es la MISMA clase de fallo que ya se
había encontrado en el Game Day de la Actividad 2.2 (service-a →
service-b), y en este laboratorio integrador volvió a aparecer de forma
idéntica un salto más adelante (service-a → data-service), pese a que
`data-service` es un servicio nuevo escrito después de conocer el
problema. Eso indica que la causa no es "un desarrollador se olvidó de
algo" sino un patrón estructural: **cualquier código que atrape una
excepción de una llamada saliente y siga respondiendo 200 al llamador
esconde ese fallo de toda métrica que dependa del status code de la
respuesta final**, sin importar cuántas veces se repita el ejercicio de
chaos engineering si la métrica de instrumentación no cambia.

**Por qué importa más allá de este caso puntual:** un operador que solo
mira dashboards de `http_requests_total`/tasa de 5xx durante un incidente
real vería el sistema "sano" (200 en todos lados) mientras una
dependencia interna falla activamente -- exactamente el escenario que un
sistema de AIOps con correlación baseline±2σ está pensado para prevenir,
y que en la primera implementación de este laboratorio NO prevenía,
porque la señal correcta (`data_service_calls_total` con el outcome real)
ya existía en el código pero nunca se conectó a la alerta.

**Remediación aplicada (no solo propuesta -- ya implementada y validada
empíricamente en local, ver sección 6.4):**

1. Wiring de la señal correcta a la alerta de correlación en las 3
   implementaciones (Prometheus local, GCP MQL, AWS metric math/alarma
   compuesta), en vez de solo documentar el hallazgo.
2. Endurecimiento de la fórmula del baseline (`clamp_min`) contra `NaN`
   por falta de tráfico -- un problema que, sin el ensayo local previo,
   muy probablemente se hubiera descubierto recién durante la ejecución
   real en GCP, con presupuesto y tiempo de Learner Lab/crédito ya
   gastados.
3. Procedimiento operativo documentado (warm-up antes de inyectar
   fallos) para que el mismo error de metodología no se repita al
   ejecutar en GCP ni en una futura ejecución de este mismo laboratorio.

**Remediación propuesta, no aplicada en este ciclo** (queda en
`docs/madurez-observabilidad.md` como mejora priorizada): una convención
de instrumentación explícita para el equipo -- toda función que capture
una excepción de una dependencia saliente y decida "degradar
controladamente" (responder con datos parciales en vez de propagar el
error) debe emitir una métrica de negocio dedicada al outcome real de esa
llamada (como ya hace `data_service_calls_total`), y esa métrica debe
declararse obligatoria en la checklist de code review para cualquier
integración nueva -- no depender de que cada nuevo servicio repita el
mismo hallazgo por separado.

## 9. Reporte de madurez de observabilidad (Módulo E)

Ver `docs/madurez-observabilidad.md` para el framework completo de 8
dominios (con fuentes citadas), la autoevaluación 1-5 por dominio, y el
roadmap a 3 meses. Resumen de niveles:

[Copiar aquí la tabla final de `docs/madurez-observabilidad.md` una vez
los niveles 🔶 (provisionales) se confirmen o ajusten con la evidencia de
las secciones 6-7 de este reporte.]

## 10. Referencias

1. Netflix. *Chaos Monkey.* <https://netflix.github.io/chaosmonkey/>
2. LitmusChaos. *Cloud Native Chaos Engineering.* <https://litmuschaos.io/>
3. GCP. *Cloud Observability Documentation.* <https://cloud.google.com/stackdriver/docs>
4. AWS. *AWS Observability Best Practices* (incluye el Observability
   Maturity Model usado en la sección 9). <https://aws-observability.github.io/observability-best-practices/>
5. Sigelman, B., et al. (2021). *Towards Observability Data Management at
   Scale.* ACM SIGOPS.
6. Tigera. *eBPF and Network Observability.* <https://www.tigera.io/learn/guides/ebpf/>
7. GCP. *Security Command Center Overview.* <https://cloud.google.com/security-command-center/docs/concepts-security-command-center-overview>
8. OpenTelemetry. *Semantic conventions for database client spans.*
   <https://opentelemetry.io/docs/specs/semconv/db/database-spans/>
9. `GameDay_Plan.pdf` (Actividad anterior, este mismo equipo) -- precedente
   metodológico para las secciones 3-8.
