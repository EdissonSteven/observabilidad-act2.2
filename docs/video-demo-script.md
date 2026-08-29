# Guion / checklist -- video de demostración en vivo

> Este guion asume que ya se ejecutaron (o se están ejecutando en vivo,
> según lo que decidan grabar) los runbooks de `docs/runbooks/`. No es un
> script para leer palabra por palabra -- es una checklist de qué mostrar
> en pantalla y en qué orden, para que ningún criterio de la rúbrica quede
> sin evidencia visual. Cada bloque indica qué pantalla/comando mostrar y
> qué runbook lo respalda. Si un módulo no se llegó a ejecutar en una nube
> real, dilo explícitamente en el video ("esto quedó como IaC listo, no
> desplegado, por costo/tiempo") -- es preferible eso a simular algo que no
> pasó.

**Duración objetivo:** 12-15 min. **Grabación recomendada:** pantalla
completa + narración en vivo (no doblaje posterior), para que quede claro
que los resultados no fueron editados.

---

## 0. Apertura (30 seg)

- Nombre del equipo, nombre de la actividad, y una frase de una línea: qué
  se extendió respecto a la Actividad 2.2 (mostrar brevemente el
  `README.md` del repo y la sección "Arquitectura objetivo" de
  `docs/reporte-ejecutivo-final.md`).
- Mostrar el repo en GitHub, con el tag `v1.0` visible en la página de
  releases/tags.

## 1. Arquitectura (Módulo A) -- 2 min

- [ ] Mostrar el diagrama de arquitectura (extensión de
  `docs/charts/04_diagrama_arquitectura.png` con el 3er servicio).
- [ ] `docker compose config` o `docker compose ps` con los 3 servicios
  (`service-a`, `service-b`, `data-service`) corriendo localmente, más
  Postgres, Collector, Jaeger, Prometheus, Grafana.
- [ ] Hacer una petición real: `curl http://localhost:8000/orders/ord-1001`
  (o el endpoint equivalente) y abrir Jaeger para mostrar la traza
  completa de **3 saltos** (`service-a` → `service-b` → `data-service`),
  con los atributos `db.system.name`, `db.namespace`,
  `server.address`/`server.port` visibles en el span de `data-service`
  (semantic conventions de DB, Módulo A).
- [ ] Si se desplegó en GCP/AWS real: mostrar el mismo trace pero apuntando
  al endpoint de nube, y el estado de Istio/App Mesh (`istioctl proxy-status`
  o la consola de App Mesh) confirmando el sidecar activo. Si no se
  desplegó, decirlo aquí y mostrar el `.tf` como evidencia de diseño.

## 2. AIOps y correlación (Módulo B) -- 2 min

- [ ] Mostrar `observability/prometheus/alert_rules.yml` (o la consola de
  CloudWatch/Cloud Monitoring si se aplicó) con las dos alertas: la
  correlacionada (`error_rate > baseline + 2σ AND latency_p99 > SLO`) y la
  ingenua estática.
- [ ] Mostrar el conteo real de disparos de cada una sobre la misma
  ventana (Runbook 2, paso 3) -- captura de `describe-alarm-history` o del
  panel de Alerting de Cloud Monitoring.
- [ ] Si se validó el MQL en la consola de GCP (Runbook 2, paso 1), mostrar
  esa captura como evidencia de que la consulta no se dejó "a ciegas".

## 3. Network & Security (Módulo C) -- 1.5 min

- [ ] Mostrar el dashboard "Golden Signals de Seguridad" (Grafana/Cloud
  Monitoring/CloudWatch, según dónde se construyó).
- [ ] Mostrar el resultado real de la consulta de tráfico rechazado
  (Athena en AWS o el log-based metric en GCP), aunque el resultado sea 0
  filas -- explicar en voz que eso también es un resultado válido.
- [ ] Mostrar la salida real de `scripts/aws_preflight_check.sh` y/o
  `scripts/gcp_preflight_check.sh` para lo que salió bloqueado (ej. Security
  Hub/SCC) -- es evidencia de que se intentó, no una carencia oculta.

## 4. Chaos Engineering (Módulo D) -- 4-5 min (el bloque más importante)

### Experimento 1 -- latencia 200ms en service-b

- [ ] Mostrar el archivo de hipótesis (`docs/reporte-ejecutivo-final.md`,
  sección 3, D1) antes de correr nada.
- [ ] Terminal 1: `python3 chaos/load_gen.py --url ... --duration 180 --out during_h4.csv` corriendo en vivo.
- [ ] Terminal 2: ejecutar `chaos/h4_latency_service_b.sh` en vivo, mostrar
  el timestamp `FAULT_START` impreso.
- [ ] Terminal 3: `chaos/measure_mttd.py` corriendo y mostrando el `MTTD=...s`
  calculado al final -- decir en voz si quedó por debajo de 120s.
- [ ] Mostrar el gráfico de latencia por request (matplotlib, mismo estilo
  que `GameDay_Plan.pdf`) generado a partir de `during_h4.csv`.

### Experimento 2 -- error rate 10% en data-service

- [ ] Repetir la misma secuencia con `chaos/h5_error_rate_data_service.sh`.
- [ ] Mostrar el span `customer.fault_injected` en Jaeger con
  `chaos.injected=true` durante la ventana del experimento.
- [ ] Mostrar la captura real de la notificación de alerta recibida
  (email/SNS/notification channel) con el `trace_id` -- este es el
  criterio "alerta accionable" del Módulo D.

### Cierre del bloque de caos

- [ ] Decir en voz: ¿se confirmaron D1/D2 tal cual, o hubo un hallazgo no
  anticipado? (Ver `docs/reporte-ejecutivo-final.md`, sección 6.4).
- [ ] Mostrar el cálculo de consumo de error budget (sección 6.5).

## 5. Madurez de observabilidad (Módulo E) -- 1.5 min

- [ ] Mostrar la tabla final de `docs/madurez-observabilidad.md` (los 8
  dominios, puntaje 1-5, con al menos una fuente citada visible en
  pantalla).
- [ ] Mencionar 1-2 acciones concretas del roadmap a 3 meses.

## 6. Cierre y limpieza (30 seg)

- [ ] Mostrar `terraform destroy` corriendo (o ya corrido) y la consola de
  la nube confirmando $0 en recursos activos (Runbook 5) -- importante
  para demostrar responsabilidad de costos frente al Learner Lab/crédito
  GCP.
- [ ] Cierre: una frase sobre la debilidad sistémica más importante
  revelada (sección 8 del reporte) y qué se haría distinto con más tiempo.

---

## Checklist de evidencia a tener ABIERTA/lista antes de empezar a grabar

- [ ] Repo en GitHub, tag `v1.0` ya creado.
- [ ] Stack local (`docker compose`) arriba y saludable, o el endpoint de
  nube real si se desplegó.
- [ ] Jaeger/Tempo, Grafana, y la consola de la nube (si aplica) ya
  autenticadas en pestañas separadas -- no perder tiempo de grabación
  iniciando sesión en vivo.
- [ ] Los CSV de `load_gen.py` de una corrida de baseline YA generados de
  antemano (no hace falta grabar el baseline, solo los 2 experimentos).
- [ ] `docs/reporte-ejecutivo-final.md` y `docs/madurez-observabilidad.md`
  abiertos en el editor para mostrar las tablas rápidamente.

## Regla de honestidad para la grabación

Si algo no se llega a desplegar en una nube real antes de grabar (por
tiempo o presupuesto), no se simula ni se corta para aparentar que sí
corrió. Se muestra el IaC listo (`terraform plan` si alcanzó a correrse) y
se dice en voz alta que quedó pendiente -- exactamente el mismo estándar
aplicado en `docs/reporte-ejecutivo-final.md` y ya validado en
`GameDay_Plan.pdf` de la actividad anterior.
