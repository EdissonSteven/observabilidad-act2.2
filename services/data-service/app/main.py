"""data-service: microservicio de datos de cliente (Módulo A del laboratorio
integrador).

Servicio hoja de la cadena `service-a -> service-b -> data-service`: recibe
la llamada HTTP desde service-a (con `traceparent` W3C ya inyectado por su
instrumentación de cliente, igual que service-b) y resuelve el perfil del
cliente dueño del pedido consultando Cloud SQL / RDS PostgreSQL.

Fault injection controlada (Módulo D, experimento 2 -- "error rate 10% en
data-service"): con `FAULT_INJECT_ERROR_RATE` (float 0-1, default 0 =
desactivado) cada request tiene esa probabilidad de fallar con 500 antes de
tocar la base de datos. Mismo espíritu que el interruptor
`OTEL_SDK_DISABLED` ya usado en el repo para el benchmark de la Fase 4 de
la Actividad 2.2: una variable de entorno explícita, documentada, que solo
se activa durante la ventana cronometrada del Game Day -- nunca en el
tráfico normal. El fallo queda marcado con `chaos.injected=true` en el
span y en el log, para poder diferenciarlo de un fallo real de
infraestructura al analizar Jaeger/Grafana después del experimento.
"""
from __future__ import annotations

import os
import random
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Response
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.trace import Status, StatusCode
from prometheus_client import start_http_server

from app import telemetry
from app.db import DB_SEMCONV_ATTRS, get_connection
from app.telemetry import logger, meter, tracer

PROMETHEUS_PORT = int(os.getenv("PROMETHEUS_PORT", "9093"))
APP_VERSION = telemetry.VERSION

customer_requests_total = meter.create_counter(
    "customer_requests_total",
    description="Consultas de perfil de cliente procesadas, por resultado",
)
customer_query_duration = meter.create_histogram(
    "customer_query_duration_seconds",
    unit="s",
    description="Latencia de la consulta de cliente a Cloud SQL/RDS",
)
chaos_injected_total = meter.create_counter(
    "chaos_injected_total",
    description="Fallos inyectados a propósito por FAULT_INJECT_ERROR_RATE (Módulo D, experimento 2)",
)


def _fault_injection_rate() -> float:
    # Leída en cada request (no cacheada al importar el módulo) para que el
    # runbook de caos pueda subirla/bajarla en caliente vía variable de
    # entorno del contenedor/task sin reiniciar el proceso más de una vez.
    try:
        return max(0.0, min(1.0, float(os.getenv("FAULT_INJECT_ERROR_RATE", "0"))))
    except ValueError:
        return 0.0


@asynccontextmanager
async def lifespan(app: FastAPI):
    start_http_server(PROMETHEUS_PORT)
    logger.info("prometheus_metrics_server_started", extra={"port": PROMETHEUS_PORT})
    yield
    trace.get_tracer_provider().shutdown()


app = FastAPI(title="data-service · customers", version=APP_VERSION, lifespan=lifespan)
if not telemetry.OTEL_SDK_DISABLED:
    FastAPIInstrumentor.instrument_app(app, excluded_urls="/health", tracer_provider=trace.get_tracer_provider())


@app.get("/health")
async def health():
    return {"status": "ok", "service": "data-service"}


@app.get("/customers/{customer_id}")
async def get_customer(customer_id: str, response: Response):
    endpoint = "/customers/{customer_id}"
    start = time.time()

    fault_rate = _fault_injection_rate()
    if fault_rate > 0 and random.random() < fault_rate:
        with tracer.start_as_current_span(
            "customer.fault_injected",
            attributes={"customer.id": customer_id, "chaos.injected": True, "chaos.fault_rate": fault_rate},
        ) as span:
            span.set_status(Status(StatusCode.ERROR, "chaos: fallo inyectado (Módulo D, experimento 2)"))
            chaos_injected_total.add(1, {"endpoint": endpoint})
            customer_requests_total.add(1, {"outcome": "chaos_injected"})
            logger.error(
                "customer_fault_injected",
                extra={"customer_id": customer_id, "fault_rate": fault_rate, "chaos_injected": True},
            )
        response.status_code = 500
        raise HTTPException(status_code=500, detail="error simulado (chaos experiment Módulo D)")

    with tracer.start_as_current_span(
        "customer.fetch_from_db",
        kind=trace.SpanKind.CLIENT,
        attributes={
            **DB_SEMCONV_ATTRS,
            "db.operation.name": "SELECT",
            "db.collection.name": "customers",
            "db.query.summary": "SELECT ... FROM customers WHERE id = ?",
            "customer.id": customer_id,
        },
    ) as span:
        try:
            conn = get_connection()
            with conn, conn.cursor() as cur:
                cur.execute(
                    "SELECT id, full_name, tier, country FROM customers WHERE id = %s",
                    (customer_id,),
                )
                row = cur.fetchone()
            conn.close()

            duration = time.time() - start
            customer_query_duration.record(duration, {"outcome": "found" if row else "not_found"})

            if row is None:
                span.set_status(Status(StatusCode.ERROR, "customer not found"))
                customer_requests_total.add(1, {"outcome": "not_found"})
                logger.warning("customer_not_found", extra={"customer_id": customer_id})
                raise HTTPException(status_code=404, detail=f"cliente '{customer_id}' no existe")

            span.set_attribute("customer.tier", row["tier"])
            span.set_status(Status(StatusCode.OK))
            customer_requests_total.add(1, {"outcome": "db_hit"})
            logger.info(
                "customer_fetched",
                extra={"customer_id": customer_id, "tier": row["tier"], "duration_s": round(duration, 4)},
            )
            return dict(row)

        except HTTPException:
            raise
        except Exception as exc:  # noqa: BLE001
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            customer_requests_total.add(1, {"outcome": "error"})
            logger.error("customer_fetch_failed", extra={"customer_id": customer_id, "error": str(exc)})
            raise HTTPException(status_code=500, detail="error consultando el cliente") from exc
