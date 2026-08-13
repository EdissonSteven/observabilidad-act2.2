"""service-b: microservicio de inventario.

Recibe llamadas HTTP desde service-a con el header W3C `traceparent` ya
inyectado por su instrumentación de cliente. FastAPIInstrumentor extrae ese
header automáticamente y continúa el mismo trace_id -- no hay código manual
de propagación en este servicio, es puramente automático.
"""
from __future__ import annotations

import os
import random
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.trace import Status, StatusCode
from prometheus_client import start_http_server

from app import telemetry
from app.db import get_connection
from app.telemetry import logger, meter, tracer

PROMETHEUS_PORT = int(os.getenv("PROMETHEUS_PORT", "9091"))
APP_VERSION = telemetry.VERSION

inventory_requests_total = meter.create_counter(
    "inventory_requests_total",
    description="Consultas de inventario procesadas, por resultado",
)
inventory_query_duration = meter.create_histogram(
    "inventory_query_duration_seconds",
    unit="s",
    description="Latencia de la consulta de stock a PostgreSQL",
)
reservations_total = meter.create_counter(
    "inventory_reservations_total",
    description="Reservas de stock procesadas, por resultado",
)
reservations_in_flight = meter.create_up_down_counter(
    "inventory_reservations_in_flight",
    description="Reservas de stock siendo procesadas ahora mismo (saturación)",
)

# Simula un cache L1 en memoria del proceso: permite mostrar un span de
# negocio que NO toca la base de datos, además de reducir p50 en la demo.
_stock_cache: dict[str, dict] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    start_http_server(PROMETHEUS_PORT)
    logger.info("prometheus_metrics_server_started", extra={"port": PROMETHEUS_PORT})
    yield
    trace.get_tracer_provider().shutdown()


app = FastAPI(title="service-b · inventory", version=APP_VERSION, lifespan=lifespan)
if not telemetry.OTEL_SDK_DISABLED:
    FastAPIInstrumentor.instrument_app(app, excluded_urls="/health", tracer_provider=trace.get_tracer_provider())


@app.get("/health")
async def health():
    return {"status": "ok", "service": "service-b"}


@app.get("/inventory/{sku}")
async def get_stock(sku: str):
    if sku in _stock_cache:
        with tracer.start_as_current_span(
            "inventory.cache_lookup", attributes={"sku": sku, "cache.hit": True}
        ):
            logger.info("stock_cache_hit", extra={"sku": sku})
            inventory_requests_total.add(1, {"outcome": "cache_hit"})
            return _stock_cache[sku]

    start = time.time()
    with tracer.start_as_current_span(
        "inventory.fetch_stock",
        kind=trace.SpanKind.CLIENT,
        attributes={"db.system": "postgresql", "db.operation": "SELECT", "sku": sku},
    ) as span:
        try:
            # Latencia de DB variable para que el flame graph y el p99 del
            # benchmark reflejen un caso realista (no todos los queries
            # cuestan lo mismo).
            time.sleep(random.uniform(0.008, 0.12))

            conn = get_connection()
            with conn, conn.cursor() as cur:
                cur.execute(
                    "SELECT sku, available_units, warehouse FROM inventory WHERE sku = %s",
                    (sku,),
                )
                row = cur.fetchone()
            conn.close()

            duration = time.time() - start
            inventory_query_duration.record(duration, {"outcome": "found" if row else "not_found"})

            if row is None:
                span.set_status(Status(StatusCode.ERROR, "sku not found"))
                inventory_requests_total.add(1, {"outcome": "not_found"})
                raise HTTPException(status_code=404, detail=f"sku '{sku}' no existe en inventario")

            result = {
                "sku": row["sku"],
                "available_units": row["available_units"],
                "warehouse": row["warehouse"],
            }
            span.set_attribute("inventory.available_units", result["available_units"])
            span.set_status(Status(StatusCode.OK))
            _stock_cache[sku] = result

            inventory_requests_total.add(1, {"outcome": "db_hit"})
            logger.info(
                "stock_fetched",
                extra={"sku": sku, "available_units": result["available_units"], "duration_s": round(duration, 4)},
            )
            return result

        except HTTPException:
            raise
        except Exception as exc:  # noqa: BLE001 - se registra y se traduce a 500
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            inventory_requests_total.add(1, {"outcome": "error"})
            logger.error("stock_fetch_failed", extra={"sku": sku, "error": str(exc)})
            raise HTTPException(status_code=500, detail="error consultando inventario") from exc


@app.post("/inventory/{sku}/reserve")
async def reserve_stock(sku: str, units: int = 1):
    """Reserva unidades de stock. Span custom anidado: valida antes de comprometer."""
    reservations_in_flight.add(1)
    with tracer.start_as_current_span(
        "inventory.reserve", attributes={"sku": sku, "reservation.units": units}
    ) as span:
        try:
            with tracer.start_as_current_span("inventory.validate_availability") as val_span:
                time.sleep(random.uniform(0.004, 0.02))
                cached = _stock_cache.get(sku)
                available = cached["available_units"] if cached else random.randint(0, 40)
                val_span.set_attribute("inventory.available_units", available)

                if available < units:
                    val_span.set_status(Status(StatusCode.ERROR, "insufficient stock"))
                    span.set_status(Status(StatusCode.ERROR, "reservation rejected"))
                    reservations_total.add(1, {"outcome": "rejected"})
                    logger.warning("reservation_rejected", extra={"sku": sku, "units": units, "available": available})
                    raise HTTPException(status_code=409, detail="stock insuficiente para reservar")

            _stock_cache.pop(sku, None)  # invalida cache: el stock cambió
            span.set_status(Status(StatusCode.OK))
            reservations_total.add(1, {"outcome": "confirmed"})
            logger.info("reservation_confirmed", extra={"sku": sku, "units": units})
            return {"sku": sku, "units": units, "status": "confirmed"}
        finally:
            reservations_in_flight.add(-1)
