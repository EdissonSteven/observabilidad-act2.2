# Módulo C -- Resultados de Network & Security Observability (GCP real)

Ejecutado el 2026-08-30 contra el proyecto `observabilidad-lab-507021`.
Todos los números salen de artefactos reales en `docs/evidencia/modulo-c/`.

## Qué se construyó

| Componente | Recurso | Estado |
|---|---|---|
| VPC Flow Logs | `log_config` en la subred (`main.tf`) | Activo |
| Firewall Rule Logging | `google_compute_firewall.deny_all_logged` (prioridad 65534) | Activo |
| Métrica derivada | `google_logging_metric.denied_traffic` | Activa |
| Alerta | `google_monitoring_alert_policy.anomalous_denied_traffic` | Activa, **disparó 2 veces** |
| Dashboard | `google_monitoring_dashboard.security_golden_signals` | Activo |
| Security Command Center | No desplegado | Brecha documentada (requiere Organización de GCP) |

Nota sobre por qué hacen falta DOS mecanismos: VPC Flow Logs captura el
tráfico **permitido**; para ver intentos **rechazados** hace falta Firewall
Rules Logging, que en GCP se habilita por regla de firewall, no por subred.
De ahí la regla `deny_all_logged`: un deny-all de prioridad mínima que no
bloquea nada que ya estuviera permitido, solo genera la señal.

## El pipeline funciona de punta a punta (evidencia)

La alerta llegó por correo dos veces, de forma espontánea:

```
07:58 UTC  Alert firing    -- above threshold of 5 with a value of 12.783
08:00 UTC  Alert recovered -- below threshold of 5 with a value of 0.617
           duration: 1 min 51 secs
```

Esto confirma la cadena completa: Firewall Rules Logging → Cloud Logging →
log-based metric → alert policy → canal de notificación. Ningún paso es
teórico.

## Análisis del tráfico rechazado

Ventana de 6 horas, **10 338 conexiones rechazadas**, analizadas con
`scripts/analyze_denied_traffic.py`:

| Dimensión | Valores distintos | Concentración |
|---|---|---|
| IPs origen | 3 789 | La más activa: 9.5 % |
| Puertos destino | 4 802 | El más atacado (443): 10.8 % |
| Países | 69 | USA 47 %, GBR 22 %, NLD 11 % |
| Protocolos | 2 | TCP 95.1 %, UDP 4.9 % |
| IPs destino | 3 | Los 2 nodos del clúster |

Puertos más golpeados: HTTPS (10.8 %), **Telnet (3.8 %)**, SSH (1.4 %), HTTP
(0.9 %). Solo el 1.7 % del tráfico fue al rango NodePort de Kubernetes
(30000-32767).

### El tráfico se separa en dos poblaciones distintas

**Población 1 -- ruido de fondo de internet (90.5 %).** Extremadamente
difusa: 3 788 IPs para ~9 300 conexiones, es decir ~2.5 conexiones por IP,
repartidas en 69 países y casi 5 000 puertos. Telnet en segundo lugar es la
firma clásica de botnets tipo Mirai buscando dispositivos IoT con
credenciales por defecto. Este tráfico golpea a cualquier IP pública del
mundo y no tiene relación con este sistema en particular.

**Población 2 -- una fuente concentrada (9.5 %).** La IP `34.153.177.134`
generó 982 conexiones, **todas al puerto 443, ninguna a otro puerto**,
sostenidas durante las 6 horas (~2.7 por minuto). Verificada contra los
rangos publicados de Google Cloud
(https://www.gstatic.com/ipranges/cloud.json): pertenece a
`34.153.128.0/18`, scope `europe-west2` -- una VM de GCP en Londres, ajena a
este proyecto (el clúster está en us-central1). El perfil monopuerto,
persistente y de alto volumen es el de un servicio de escaneo o censo
gestionado, no el de un barrido oportunista.

## Hallazgo principal: la alerta es a la vez demasiado sensible y demasiado insensible

Este es el resultado que importa del módulo, y está cuantificado.

**Demasiado sensible.** El ruido de fondo tiene una media de 0.48
conexiones/s (10 338 / 6 h), pero produce ráfagas naturales que cruzan el
umbral de 5. Se observaron dos disparos reales: uno a 7.43 y otro a 12.78
conexiones/s. El segundo se recuperó **1 min 51 s después**, con un valor de
0.617 -- que corrobora de forma independiente la media calculada. Ninguno de
los dos disparos correspondió a un incidente ni admitía acción alguna.

**Demasiado insensible.** La única fuente con firma reconocible de
reconocimiento dirigido -- la IP de Londres sondeando 443 sin parar --
genera 982 conexiones en 6 h, es decir **0.045 conexiones/s**. Está *dos
órdenes de magnitud por debajo* del umbral. La alerta nunca la va a ver.

**Ningún valor del umbral arregla ambos problemas**, porque el volumen total
no es la dimensión que separa las dos poblaciones. Lo que las separa es la
**concentración**: una IP contra un puerto, de forma sostenida. Subir el
umbral a 15 o 20 elimina los falsos positivos y deja la ceguera intacta.

Es exactamente el mismo defecto que `naive_static_threshold` en el Módulo B:
un umbral absoluto sobre una señal con ruido estructural, sin correlación
con nada. Los dos módulos llegan a la misma conclusión desde ángulos
distintos.

### Por qué la corrección no cabe en la alerta

Detectar concentración exige agrupar por IP origen y puerto destino. Ninguna
de las dos puede ser label de la métrica: tienen 3 789 y 4 802 valores
distintos, y Cloud Logging documenta un máximo de 10 labels y ~30 000 series
temporales activas por métrica, con recomendación explícita de usar solo
"conjuntos pequeños de valores discretos"
(https://docs.cloud.google.com/logging/docs/logs-based-metrics/labels).

Sí se añadieron las dimensiones de baja cardinalidad que caben:
`country` (69), `protocol` (2) y `dest_ip` (3) -- 414 series como máximo. El
análisis por IP y puerto vive en `scripts/analyze_denied_traffic.py`, que
consulta Cloud Logging directamente. Esa separación es una decisión de
diseño, no una carencia: la detección de concentración pertenece a una
consulta analítica, no a una métrica de series temporales.

## Comparación de calidad del mensaje entre tipos de condición

Observación no planeada, con valor para el Módulo B. El mismo proyecto tiene
alertas de dos tipos, y sus mensajes difieren mucho:

| | `condition_threshold` (Módulo C) | `condition_prometheus_query_language` (Módulo D) |
|---|---|---|
| Resumen | "is above threshold of **5** with a value of **12.783**" | "A PromQL query was observed at 21.056510536161806" |
| Métrica | Nombrada completa | `metric: __missing__` |
| Contexto | subnetwork, location, log source | ninguno |
| Acciones | VIEW INCIDENT + **VIEW LOGS** | VIEW INCIDENT |

La causa está identificada: las consultas PromQL usan `sum(...)` sin `by`,
lo que descarta todas las labels y deja a Cloud Monitoring sin nada con qué
nombrar la serie. Es un trade-off real de la migración a PromQL, que se
adoptó por verificabilidad (ver `docs/modulo-d-resultados.md`).

## Security Command Center

No se despliega. SCC se activa a nivel de **organización** de GCP, y esta
cuenta individual no tiene un recurso de organización al que engancharse --
`google_scc_*` fallaría con "no organization found". Está documentado como
brecha explícita en `docs/madurez-observabilidad.md` (dominio 5), con el
log-based metric de arriba como sustituto funcional dentro del alcance del
laboratorio. Verificable con `scripts/gcp_preflight_check.sh`, que corre
`gcloud organizations list`.

## Recomendaciones para el roadmap (Módulo E)

1. **Sustituir la detección por volumen por detección por concentración**:
   una consulta analítica periódica sobre los logs que alerte cuando una
   sola IP supere N intentos contra el mismo puerto en una ventana. Detecta
   la población 2 e ignora la 1.
2. **Si se conserva el umbral de volumen**, calibrarlo con la distribución
   medida (`scripts/analyze_denied_traffic.py --alert-threshold`) y aceptar
   explícitamente la tasa de falsos positivos elegida, en vez de fijar un
   número a ojo.
3. **Añadir severidad** a las alert policies (ambas llegan como
   `No severity`).
4. **Restringir el alcance de la regla `deny_all_logged`** o filtrar el
   log-based metric a los rangos que importen, para reducir el volumen de
   logs facturados por ruido que no se va a accionar.

## Evidencia

En `docs/evidencia/modulo-c/`:

- `denied_traffic_6h.json` -- volcado crudo de las 10 338 entradas.
- `denied_traffic_analisis.txt` -- salida completa del script de análisis.
- Capturas de los correos de alerta: el par **disparo (12.783) + recuperación
  (0.617, duración 1 min 51 s)**, que documenta el falso positivo completo.
- Captura del dashboard "Golden Signals de Seguridad".

Reproducible con:

```bash
gcloud logging read 'resource.type="gce_subnetwork" jsonPayload.disposition="DENIED"' \
  --project=<PROJECT_ID> --freshness=6h --format=json > denied.json
python3 scripts/analyze_denied_traffic.py --input denied.json --alert-threshold 5
```
