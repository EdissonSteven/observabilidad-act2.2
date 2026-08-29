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

| Componente | Rol | Dependencia crítica |
|---|---|---|
| `data-service` (FastAPI, :8002) | Perfil de cliente del pedido | Cloud SQL / RDS PostgreSQL (sin timeout ni retry -- mismo patrón de riesgo ya documentado para service-a/service-b en el informe técnico de la Actividad 2.2) |
| Cloud SQL / RDS (`customersdb`) | Persistencia de `customers`, dedicada a data-service | Peering privado (GCP) / Secrets Manager (AWS) -- ver `iac/terraform/{gcp,cloudsql.tf; aws,rds.tf}` |
| Service mesh (Istio sobre GKE / AWS App Mesh) | Observabilidad L7 + mTLS entre los 3 microservicios | Envoy sidecar por pod/task |
| VPC Flow Logs (ambas nubes) | Visibilidad de red N-S/E-W | Sin IAM nuevo en AWS (destino S3); nativo por subred en GCP |
| CloudWatch Anomaly Detection / Cloud Monitoring MQL | Correlación error_rate + latencia (Módulo B) | Métricas OTel vía el exporter `googlecloud`/`awsemf`-equivalente ya presente en el Collector |

Decisión de alcance explícita: `orders`/`inventory` permanecen en el
Postgres ya usado por service-a/service-b (Fargate en AWS, el Postgres del
clúster en GCP) -- Cloud SQL/RDS son la base de datos PROPIA y nueva de
`data-service`. Ver la justificación completa en
`iac/terraform/aws/rds.tf` y `iac/terraform/gcp/cloudsql.tf`.

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
| D1 | `tc netem delay 200ms` en `service-b` (docker-compose/GKE) o `INJECT_LATENCY_MS=200` (ECS Fargate, ver justificación de por qué Fargate no admite `NET_ADMIN`) | Solo el tráfico service-a → service-b; PostgreSQL/Cloud SQL/RDS fuera del radio | 60s, ventana corta y cronometrada | `tc qdisc del` automático / redeploy con `INJECT_LATENCY_MS=0` |
| D2 | `FAULT_INJECT_ERROR_RATE=0.10` en `data-service` (idéntico en los 3 entornos -- variable de aplicación, no depende de capabilities de red) | Solo data-service; service-a/service-b siguen respondiendo, degradados | 60s | Redeploy con `FAULT_INJECT_ERROR_RATE=0` |

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

[EVIDENCIA PENDIENTE: qué nube(s) se usaron realmente, con qué
configuración exacta (`deploy_rds`, `enable_app_mesh`, región/zona),
siguiendo `docs/runbooks/01-modulo-a-arquitectura.md` y
`04-modulo-d-chaos.md`.]

### 6.2 Resultados reales obtenidos

[EVIDENCIA PENDIENTE: tabla de percentiles baseline vs. durante-el-fallo
vs. post-rollback para D1 y D2, igual formato que la Tabla de
`GameDay_Plan.pdf` ya validada -- generada a partir de los CSV de
`chaos/load_gen.py`.]

### 6.3 MTTD medido

[EVIDENCIA PENDIENTE: salida de `chaos/measure_mttd.py` para D1 y D2, en
cada nube ejecutada -- ¿estuvo por debajo de 2 minutos?]

### 6.4 Comparación esperado vs. obtenido

[EVIDENCIA PENDIENTE: ¿se confirmaron las hipótesis D1/D2 tal cual, o
hubo un hallazgo no anticipado -- como el de connection pooling
descubierto en el Game Day anterior? Ese tipo de hallazgo (hipótesis
parcialmente refutada con causa raíz identificada) es el resultado más
valioso, no una debilidad del reporte.]

### 6.5 ¿Se degradó el SLO? ¿Se consumió el error budget?

[EVIDENCIA PENDIENTE: cálculo siguiendo el paso 3 de
`docs/runbooks/04-modulo-d-chaos.md`, con el supuesto de tráfico mensual
usado explícito.]

### 6.6 Reducción de alertas ruidosas (Módulo B)

[EVIDENCIA PENDIENTE: conteo real, alerta ingenua vs. correlacionada,
misma ventana de tráfico -- `docs/runbooks/02-modulo-b-aiops.md` paso 3.]

## 7. Network & Security Observability (Módulo C)

[EVIDENCIA PENDIENTE: resultado de la consulta Athena (AWS) y del
log-based metric (GCP) sobre tráfico rechazado; capturas de los
dashboards "Golden Signals de Seguridad" de ambas nubes;
disponibilidad real de Security Hub/SCC según los preflights.]

Brecha documentada de antemano (no depende de la ejecución): ninguno de
los 3 microservicios implementa autenticación de usuario final, así que
"intentos de autenticación fallidos" no es una señal real de este
sistema -- ver `docs/madurez-observabilidad.md`, dominio 5, para el
razonamiento completo y la remediación propuesta.

## 8. Debilidad sistémica revelada y remediación

[EVIDENCIA PENDIENTE: síntesis de 6.4 -- ¿qué reveló realmente el
experimento sobre el sistema? Seguir el mismo estándar de
`GameDay_Plan.pdf` sección 6: una debilidad concreta y accionable, no una
lista genérica de buenas prácticas.]

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
