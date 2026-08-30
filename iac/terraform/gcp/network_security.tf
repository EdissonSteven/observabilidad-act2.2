# ---------------------------------------------------------------------------
# Network & Security Observability (Módulo C).
#
# VPC Flow Logs ya está habilitado en la subred (ver el bloque log_config
# en main.tf) -- eso captura TODO el tráfico permitido. Para ver tráfico
# RECHAZADO ("tráfico anómalo entre servicios") hace falta además Firewall
# Rule Logging, que es un mecanismo distinto en GCP: se habilita por regla
# de firewall, no por subred. Esta VPC (creada con auto_create_subnetworks
# = false en main.tf) no trae ninguna regla de firewall implícita más allá
# de las que GKE gestiona automáticamente para el propio clúster -- así que
# se añade aquí una regla explícita de deny-all de prioridad baja (65534,
# por debajo de cualquier regla más específica que GKE u otros módulos
# creen) con logging activado: no bloquea nada que ya estuviera permitido,
# solo genera la señal de "intento rechazado" para el dashboard de
# seguridad.
#
# Security Command Center: NO se incluye como recurso de Terraform aquí a
# propósito. SCC se activa a nivel de ORGANIZACIÓN de GCP, no de proyecto, y
# su alcance son los proyectos que cuelgan de esa organización.
#
# VERIFICADO CON EVIDENCIA REAL (2026-08-30), y el camino hasta la
# verificación es en sí un hallazgo:
#
#   $ gcloud organizations list          -> devuelve 1 organización
#   $ gcloud projects describe observabilidad-lab-507021 \
#       --format='value(parent.type,parent.id)'
#                                        -> VACÍO
#
# Las dos cosas son compatibles y la distinción es la que importa: la cuenta
# (@unisabana.edu.co, institucional) SÍ ve una organización, pero el proyecto
# de este laboratorio fue creado FUERA de ella -- es un proyecto huérfano,
# sin parent. `gcloud organizations list` responde "qué organizaciones ve el
# usuario", no "de qué organización cuelga el proyecto".
#
# Conclusión: SCC no es aplicable a este proyecto. No hay organización de la
# que cuelgue, así que no hay nada a lo que engancharlo.
#
# Y aunque el proyecto colgara de la organización institucional, activarlo
# seguiría estando FUERA DE ALCANCE: SCC afectaría a TODOS los proyectos de
# la Universidad, no solo a este, con implicaciones de costo y de política
# que no corresponden a un trabajo individual de maestría.
#
# El sustituto funcional dentro del alcance real del laboratorio es el
# Firewall Rule Logging + log-based metric de abajo. Documentado como brecha
# explícita en docs/madurez-observabilidad.md (dominio 5).
#
# NOTA sobre el preflight: scripts/gcp_preflight_check.sh comprobaba esto MAL
# (usaba `gcloud organizations list` y concluía "SCC podría habilitarse", un
# [OK] infundado). Ya está corregido para mirar el parent del proyecto. Un
# preflight que da un OK engañoso es peor que no tenerlo.
# ---------------------------------------------------------------------------

resource "google_compute_firewall" "deny_all_logged" {
  name      = "${var.network_name}-deny-all-logged"
  network   = google_compute_network.vpc.id
  priority  = 65534
  direction = "INGRESS"

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# La métrica ORIGINAL se deja EXACTAMENTE como estaba, sin labels, a
# propósito. Ver el comentario de google_logging_metric.denied_traffic_labeled
# más abajo para el hallazgo completo y por qué hay dos métricas.
resource "google_logging_metric" "denied_traffic" {
  project     = var.project_id
  name        = "${var.cluster_name}-denied-connections"
  description = "Conteo de conexiones rechazadas por firewall (Módulo C: golden signal de tráfico anómalo N-S/E-W). Sin labels: es la que consume la alert policy y la que conserva el historial -- ver denied_traffic_labeled para el desglose."
  filter      = "resource.type=\"gce_subnetwork\" jsonPayload.disposition=\"DENIED\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# ---------------------------------------------------------------------------
# HALLAZGO REAL (2026-08-30): por qué existen DOS métricas sobre los mismos logs
# ---------------------------------------------------------------------------
# Se intentó añadir labels (country/protocol/dest_ip) a la métrica original
# para poder desglosar el tráfico rechazado en el dashboard. Terraform lo
# planificó como REEMPLAZO (`must be replaced`, con `+ labels { # forces
# replacement }` en las tres), porque cambiar el metric_descriptor de una
# métrica basada en logs no es una operación in-place.
#
# El apply falló con un error real de la API:
#
#   Error 400: Cannot delete metric observability-lab-gke-denied-connections.
#   That metric is still used in an alerting policy.
#
# Es la MISMA protección de integridad referencial que ya había bloqueado la
# destrucción accidental del notification channel (ver el hallazgo 5 del
# Módulo D). GCP se niega a borrar recursos de observabilidad que estén
# referenciados, lo cual en ambos casos evitó una pérdida no intencionada.
#
# Había dos salidas posibles:
#   (a) Migrar en dos pasos: crear la métrica con labels, repuntar la alert
#       policy a ella, y en un segundo apply borrar la original. Termina con
#       UNA sola métrica, más limpio.
#   (b) Conservar la original para la alerta y añadir una segunda con labels
#       solo para el dashboard.
#
# Se eligió (b), y la razón NO es la comodidad: las métricas basadas en logs
# NO se recalculan retroactivamente -- una métrica nueva empieza a contar
# desde su creación. La opción (a) habría destruido el historial de la
# métrica que produjo la mejor evidencia del Módulo C (los dos disparos
# reales de la alerta: 7.43 y 12.78 conexiones/s, con su recuperación a los
# 1 min 51 s). Esa serie temporal es irreproducible: el tráfico de escaneo de
# esa ventana no vuelve.
#
# El costo de (b) es redundancia: dos métricas contando exactamente los
# mismos logs. Se asume a conciencia y queda documentado aquí. Si en algún
# momento el historial deja de importar, consolidar en una sola siguiendo (a).
resource "google_logging_metric" "denied_traffic_labeled" {
  project     = var.project_id
  name        = "${var.cluster_name}-denied-connections-labeled"
  description = "Igual que ${var.cluster_name}-denied-connections pero CON labels, para el desglose del dashboard. Existe por separado para no destruir el historial de la original -- ver el comentario del recurso."
  filter      = "resource.type=\"gce_subnetwork\" jsonPayload.disposition=\"DENIED\""

  # QUÉ SE PUEDE Y QUÉ NO SE PUEDE ETIQUETAR (decisión de cardinalidad):
  # Cloud Logging documenta máximo 10 labels y ~30.000 series activas por
  # métrica, recomendando solo "conjuntos pequeños de valores discretos"
  # (https://docs.cloud.google.com/logging/docs/logs-based-metrics/labels).
  # Medido sobre la ventana real de 6h (10.338 conexiones):
  #   - src_ip    : 3.789 valores distintos -> INVIABLE
  #   - dest_port : 4.802 valores distintos -> INVIABLE
  #   - country   :    69 valores           -> OK
  #   - protocol  :     2 valores           -> OK
  #   - dest_ip   :     3 valores (los nodos) -> OK
  # Máximo 69 x 2 x 3 = 414 series. El desglose por IP origen y puerto
  # destino -- que es justamente el que distingue un escaneo dirigido del
  # ruido de fondo -- NO cabe en una métrica y vive en
  # scripts/analyze_denied_traffic.py.
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "country"
      value_type  = "STRING"
      description = "País de origen (código ISO-3 de jsonPayload.remote_location.country)."
    }
    labels {
      key         = "protocol"
      value_type  = "STRING"
      description = "Número de protocolo IP (6=TCP, 17=UDP)."
    }
    labels {
      key         = "dest_ip"
      value_type  = "STRING"
      description = "IP del nodo del clúster que recibió el intento."
    }
  }

  label_extractors = {
    "country"  = "EXTRACT(jsonPayload.remote_location.country)"
    "protocol" = "EXTRACT(jsonPayload.connection.protocol)"
    "dest_ip"  = "EXTRACT(jsonPayload.connection.dest_ip)"
  }
}

# Hallazgo real del primer apply (2026-08-29): aunque google_logging_metric
# .denied_traffic se creó bien en el mismo apply ("Creation complete after
# 6s"), la policy de abajo falló con "Cannot find metric(s) that match
# type = logging.googleapis.com/user/... If a metric was created recently,
# it could take up to 10 minutes to become available" -- un log-based
# metric recién creado tarda en indexarse como métrica consultable por
# Cloud Monitoring, y Terraform no espera eso por defecto (no hay señal de
# "listo" que la API exponga). Se fuerza una espera explícita en vez de
# depender de que el usuario reintente el apply a mano.
resource "time_sleep" "wait_for_denied_traffic_metric" {
  depends_on      = [google_logging_metric.denied_traffic]
  create_duration = "150s"
}

resource "google_monitoring_alert_policy" "anomalous_denied_traffic" {
  project      = var.project_id
  display_name = "${var.cluster_name}-anomalous-denied-traffic"
  combiner     = "OR"

  conditions {
    display_name = "pico de conexiones rechazadas"
    condition_threshold {
      filter          = "resource.type=\"gce_subnetwork\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.denied_traffic.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.denied_traffic_alert_threshold
      duration        = "60s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = var.alert_notification_email != "" ? [google_monitoring_notification_channel.aiops_email[0].id] : []

  # 150s suele bastar, pero Google documenta hasta 10 minutos de
  # propagación -- si este recurso vuelve a fallar con el mismo error,
  # simplemente reintenta `terraform apply` unos minutos después: el
  # log-based metric y el resto del stack ya están creados (idempotente),
  # solo falta que esta única policy quede registrada.
  depends_on = [google_project_service.monitoring, time_sleep.wait_for_denied_traffic_metric]
}

# --- Dashboard "Golden Signals de Seguridad" -------------------------------
# Mismo alcance honesto que el lado AWS (ver
# iac/terraform/aws/security_dashboard.tf): ni service-a, ni service-b, ni
# data-service implementan autenticación de usuario final, así que
# "intentos de autenticación fallidos" no tiene una señal real en ESTE
# sistema. El dashboard adapta el concepto a lo que sí se observa.
#
# CORRECCIÓN (2026-08-30): este comentario decía antes que el dashboard
# incluía un panel de "saturación de CPU/memoria de los pods como proxy de
# escaneos/DoS de bajo volumen" -- ese panel NUNCA estuvo implementado en los
# tiles. El comentario prometía algo que el código no entregaba. Se sustituye
# por un panel que sí aporta señal de seguridad directa: el desglose del
# tráfico rechazado POR PAÍS DE ORIGEN, posible ahora que la métrica tiene
# labels (ver el comentario de google_logging_metric.denied_traffic arriba).
# La saturación de CPU como proxy de DoS era una señal indirecta y forzada;
# el desglose geográfico del tráfico rechazado responde directamente a la
# pregunta "¿esto es ruido difuso o una fuente concentrada?".
#
# LO QUE ESTE DASHBOARD NO PUEDE MOSTRAR, y por qué: el desglose por IP
# origen y por puerto destino es el que de verdad distingue un escaneo
# dirigido del ruido de fondo (hallazgo real: una sola IP de GCP generó el
# 9,5 % del tráfico rechazado en 6h, TODA ella contra el puerto 443 --
# perfil claramente distinto del resto, que es difuso). Pero esas dos
# dimensiones tienen 3.789 y 4.802 valores distintos respectivamente, muy
# por encima de lo que admite una métrica basada en logs. Ese análisis vive
# en scripts/analyze_denied_traffic.py, que consulta Cloud Logging directo.
resource "google_monitoring_dashboard" "security_golden_signals" {
  project        = var.project_id
  dashboard_json = jsonencode({
    displayName = "${var.cluster_name} - Golden Signals de Seguridad"
    mosaicLayout = {
      columns = 12
      tiles = [
        {
          width = 12, height = 2,
          widget = {
            text = {
              content = "Ni service-a, ni service-b, ni data-service implementan autenticación de usuario final -- ver docs/madurez-observabilidad.md (dominio 5) para la brecha documentada y su remediación. Paneles abajo: tráfico rechazado por firewall, conexiones activas a Cloud SQL, y saturación de cómputo como proxies de actividad anómala.",
              format  = "MARKDOWN"
            }
          }
        },
        {
          width = 6, height = 4, yPos = 2,
          widget = {
            title = "Conexiones rechazadas por firewall (deny-all-logged)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "resource.type=\"gce_subnetwork\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.denied_traffic.name}\""
                    aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE" }
                  }
                }
              }]
            }
          }
        },
        {
          width = 12, height = 4, yPos = 6,
          widget = {
            title = "Tráfico rechazado por país de origen (¿difuso o concentrado?)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "resource.type=\"gce_subnetwork\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.denied_traffic_labeled.name}\""
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = "ALIGN_RATE"
                      crossSeriesReducer = "REDUCE_SUM"
                      groupByFields      = ["metric.label.country"]
                    }
                  }
                }
              }]
            }
          }
        },
        {
          width = 6, height = 4, xPos = 6, yPos = 2,
          widget = {
            title = "Cloud SQL (customers) - conexiones activas"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter      = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.project_id}:${var.cluster_name}-customers\" AND metric.type=\"cloudsql.googleapis.com/database/postgresql/num_backends\""
                    aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
                  }
                }
              }]
            }
          }
        }
      ]
    }
  })
}
