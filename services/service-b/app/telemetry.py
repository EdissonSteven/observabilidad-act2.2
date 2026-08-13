"""Bootstrap de OpenTelemetry para service-b.

Se importa antes que cualquier otra cosa en main.py: las auto-instrumentaciones
(FastAPI, psycopg2) deben registrarse antes de que esos módulos construyan sus
objetos, o quedan sin instrumentar.
"""
from __future__ import annotations

import logging
import os

from opentelemetry import metrics, trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.prometheus import PrometheusMetricReader
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.metrics.view import ExplicitBucketHistogramAggregation, View
from opentelemetry.sdk.resources import SERVICE_NAME, SERVICE_VERSION, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from pythonjsonlogger import jsonlogger

SERVICE = "service-b"
VERSION = os.getenv("APP_VERSION", "1.0.0")
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")

# Ver el comentario extenso en service-a/app/telemetry.py: con esta variable
# en true, trace.get_tracer()/metrics.get_meter() devuelven las
# implementaciones no-op de la API (sin provider registrado) -- es el
# baseline real usado en el benchmark de la Fase 4.
OTEL_SDK_DISABLED = os.getenv("OTEL_SDK_DISABLED", "false").lower() == "true"

# Ver el comentario extenso en service-a/app/telemetry.py: sin esto, todos los
# histogramas *_seconds caen en el primer bucket por defecto (le=5.0, pensado
# para milisegundos) y el p95/p99 sale inflado a varios segundos.
_SECONDS_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10)
_SECONDS_HISTOGRAM_VIEWS = [
    View(
        instrument_type=metrics.Histogram,
        instrument_name="*_seconds",
        aggregation=ExplicitBucketHistogramAggregation(_SECONDS_BUCKETS),
    )
]


class TraceContextFilter(logging.Filter):
    """Inyecta trace_id/span_id del span activo en cada registro de log.

    Este es el pivote de correlación: el mismo trace_id que aparece en el
    flame graph de Jaeger/Tempo queda impreso en la línea de log JSON, así
    Grafana Explorer puede saltar de logs -> traza y viceversa.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        span_ctx = trace.get_current_span().get_span_context()
        if span_ctx.is_valid:
            record.trace_id = format(span_ctx.trace_id, "032x")
            record.span_id = format(span_ctx.span_id, "016x")
        else:
            record.trace_id = "0" * 32
            record.span_id = "0" * 16
        return True


def _build_resource() -> Resource:
    return Resource.create(
        {
            SERVICE_NAME: SERVICE,
            SERVICE_VERSION: VERSION,
            "deployment.environment": ENVIRONMENT,
            "cloud.provider": os.getenv("CLOUD_PROVIDER", "local"),
        }
    )


def configure_logging(resource: Resource) -> logging.Logger:
    # Handler 1: stdout JSON con trace_id/span_id -- para `docker compose logs`
    # y para grep manual durante troubleshooting (ver README).
    stdout_handler = logging.StreamHandler()
    fmt = jsonlogger.JsonFormatter(
        "%(asctime)s %(levelname)s %(name)s %(message)s %(trace_id)s %(span_id)s",
        rename_fields={"asctime": "timestamp", "levelname": "level"},
    )
    stdout_handler.setFormatter(fmt)
    stdout_handler.addFilter(TraceContextFilter())

    handlers: list[logging.Handler] = [stdout_handler]
    if not OTEL_SDK_DISABLED:
        # Handler 2: OTLP hacia el Collector -> Loki. El LoggingHandler del
        # SDK adjunta trace_id/span_id al LogRecord automáticamente a partir
        # del span activo, sin necesidad del filtro manual de arriba.
        logger_provider = LoggerProvider(resource=resource)
        logger_provider.add_log_record_processor(
            BatchLogRecordProcessor(OTLPLogExporter(endpoint=OTLP_ENDPOINT, insecure=True))
        )
        set_logger_provider(logger_provider)
        handlers.append(LoggingHandler(level=logging.INFO, logger_provider=logger_provider))

    logger = logging.getLogger(SERVICE)
    logger.setLevel(logging.INFO)
    logger.handlers = handlers
    logger.propagate = False
    return logger


def configure_tracing(resource: Resource) -> trace.Tracer:
    if OTEL_SDK_DISABLED:
        return trace.get_tracer(SERVICE, VERSION)

    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True)
    # Batch: agrupa spans en memoria (hasta 512, cada 5s) antes de enviarlos
    # al Collector -> evita 1 request de red por span bajo carga.
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    return trace.get_tracer(SERVICE, VERSION)


def configure_metrics(resource: Resource) -> metrics.Meter:
    if OTEL_SDK_DISABLED:
        return metrics.get_meter(SERVICE, VERSION)

    # Dos readers simultáneos: uno expone /metrics para scraping directo de
    # Prometheus, el otro empuja al Collector cada 15s (ruta usada en cloud
    # real hacia Cloud Monitoring / CloudWatch Metrics vía OTLP).
    prometheus_reader = PrometheusMetricReader()
    otlp_reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=OTLP_ENDPOINT, insecure=True),
        export_interval_millis=15000,
    )
    provider = MeterProvider(
        resource=resource,
        metric_readers=[prometheus_reader, otlp_reader],
        views=_SECONDS_HISTOGRAM_VIEWS,
    )
    metrics.set_meter_provider(provider)
    return metrics.get_meter(SERVICE, VERSION)


def instrument_libraries(tracer_provider: trace.TracerProvider) -> None:
    if OTEL_SDK_DISABLED:
        return
    # FastAPI se instrumenta explícitamente en main.py con `instrument_app`
    # justo después de crear `app` -- ver el comentario en service-a para el
    # porqué (instrument() global sin app resultó poco fiable).
    Psycopg2Instrumentor().instrument(tracer_provider=tracer_provider)


resource = _build_resource()
logger = configure_logging(resource)
tracer = configure_tracing(resource)
meter = configure_metrics(resource)
instrument_libraries(trace.get_tracer_provider())
