"""Bootstrap de OpenTelemetry para service-a.

Mismo patrón que service-b (ver ese módulo para el detalle de cada
decisión), con dos diferencias: el nombre de servicio/puerto, y que aquí
también se instrumenta el cliente HTTP saliente (httpx) hacia service-b.
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
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
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

SERVICE = "service-a"
VERSION = os.getenv("APP_VERSION", "1.0.0")
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")

# Los histogramas *_seconds miden en segundos, pero los bucket boundaries por
# defecto del SDK (0, 5, 10, 25... 10000) están pensados para milisegundos:
# casi toda la telemetría real (decenas/cientos de ms) cae en el primer
# bucket no-cero (le=5.0) y deja a histogram_quantile interpolando sobre un
# único escalón -- da un p95/p99 fantasma de varios segundos aunque el
# request real haya tardado 40ms. Boundaries explícitos en segundos (los
# clásicos de Prometheus) resuelven la precisión real del histograma.
_SECONDS_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10)
_SECONDS_HISTOGRAM_VIEWS = [
    View(
        instrument_type=metrics.Histogram,
        instrument_name="*_seconds",
        aggregation=ExplicitBucketHistogramAggregation(_SECONDS_BUCKETS),
    )
]

# Interruptor para el benchmark de la Fase 4 (análisis de overhead): con
# OTEL_SDK_DISABLED=true no se registra ningún TracerProvider/MeterProvider
# ni se instrumenta ninguna librería -- trace.get_tracer()/metrics.get_meter()
# devuelven entonces las implementaciones no-op de la propia API de OTel, así
# que el código de negocio (los `with tracer.start_as_current_span(...)` de
# main.py) sigue ejecutándose sin cambios, pero sin crear spans, sin exportar
# nada y sin auto-instrumentación. Este es el baseline real contra el que se
# compara "con OTel SDK" -- no solo apagar el Collector, que dejaría intacto
# todo el costo de creación/serialización de spans en el proceso.
OTEL_SDK_DISABLED = os.getenv("OTEL_SDK_DISABLED", "false").lower() == "true"


class TraceContextFilter(logging.Filter):
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
    stdout_handler = logging.StreamHandler()
    fmt = jsonlogger.JsonFormatter(
        "%(asctime)s %(levelname)s %(name)s %(message)s %(trace_id)s %(span_id)s",
        rename_fields={"asctime": "timestamp", "levelname": "level"},
    )
    stdout_handler.setFormatter(fmt)
    stdout_handler.addFilter(TraceContextFilter())

    handlers: list[logging.Handler] = [stdout_handler]
    if not OTEL_SDK_DISABLED:
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
        return trace.get_tracer(SERVICE, VERSION)  # no provider registrado -> no-op tracer

    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    return trace.get_tracer(SERVICE, VERSION)


def configure_metrics(resource: Resource) -> metrics.Meter:
    if OTEL_SDK_DISABLED:
        return metrics.get_meter(SERVICE, VERSION)  # no-op meter

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

    # FastAPI NO se instrumenta aquí: `FastAPIInstrumentor().instrument()`
    # (global, sin app) depende de parchear `FastAPI.__init__` antes de que
    # se cree la instancia, y en la práctica resultó poco fiable -- cada
    # span de negocio terminaba como *root* de su propio trace en vez de
    # colgar del span del servidor. `instrument_app(app)` (llamado desde
    # main.py justo después de crear `app`) es el patrón explícito y es el
    # que efectivamente propaga un único trace_id para todo el request.
    #
    # HTTPXClientInstrumentor inyecta el header W3C `traceparent` en cada
    # llamada saliente -- es lo único necesario para que service-b continúe
    # el mismo trace_id, sin tocar el código de negocio.
    HTTPXClientInstrumentor().instrument(tracer_provider=tracer_provider)
    Psycopg2Instrumentor().instrument(tracer_provider=tracer_provider)


resource = _build_resource()
logger = configure_logging(resource)
tracer = configure_tracing(resource)
meter = configure_metrics(resource)
instrument_libraries(trace.get_tracer_provider())
