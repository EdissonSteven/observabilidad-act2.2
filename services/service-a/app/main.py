"""service-a: microservicio orquestador de pedidos.

Flujo del endpoint principal (GET /orders/{order_id}):
  1. Lee el pedido en PostgreSQL (span custom `order.fetch_from_db`).
  2. Llama a service-b para conocer el stock del producto (span custom
     `order.check_inventory`, que envuelve la llamada HTTP -- httpx ya
     viene auto-instrumentado, así que el header `traceparent` W3C se
     propaga sin código adicional).
  3. Devuelve la respuesta combinada, incluyendo el trace_id para que el
     benchmark k6 y la demo puedan pegarlo directo en Jaeger/Grafana.
"""
from __future__ import annotations

import os
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.trace import Status, StatusCode
from prometheus_client import start_http_server

from app import telemetry
from app.db import get_connection
from app.telemetry import logger, meter, tracer

PROMETHEUS_PORT = int(os.getenv("PROMETHEUS_PORT", "9090"))
SERVICE_B_URL = os.getenv("SERVICE_B_URL", "http://localhost:8001")
APP_VERSION = telemetry.VERSION

http_requests_total = meter.create_counter(
    "http_requests_total",
    description="Total de requests HTTP recibidos, por endpoint y status",
)
http_request_duration = meter.create_histogram(
    "http_request_duration_seconds",
    unit="s",
    description="Latencia end-to-end del request (usada para p50/p95/p99)",
)
http_requests_in_flight = meter.create_up_down_counter(
    "http_requests_in_flight",
    description="Requests en vuelo ahora mismo (señal de saturación)",
)
service_b_calls_total = meter.create_counter(
    "service_b_calls_total",
    description="Llamadas salientes a service-b, por resultado",
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    start_http_server(PROMETHEUS_PORT)
    logger.info("prometheus_metrics_server_started", extra={"port": PROMETHEUS_PORT})
    yield
    trace.get_tracer_provider().shutdown()


app = FastAPI(title="service-a · orders", version=APP_VERSION, lifespan=lifespan)
if not telemetry.OTEL_SDK_DISABLED:
    # excluded_urls evita que el ASGI middleware cree CUALQUIER span
    # (incluidos los internos de "http send"/"receive") para /health --
    # filtrar solo en el Collector no alcanza porque esos spans internos no
    # llevan http.target.
    FastAPIInstrumentor.instrument_app(app, excluded_urls="/health", tracer_provider=trace.get_tracer_provider())


@app.get("/health")
async def health():
    return {"status": "ok", "service": "service-a"}


@app.get("/orders/{order_id}")
async def get_order(order_id: str):
    endpoint = "/orders/{order_id}"
    start = time.time()
    http_requests_in_flight.add(1, {"endpoint": endpoint})
    status_label = "500"

    try:
        order = _fetch_order(order_id)
        inventory = await _check_inventory(order["sku"])

        status_label = "200"
        return {
            "order": order,
            "inventory": inventory,
            "trace_id": format(trace.get_current_span().get_span_context().trace_id, "032x"),
        }
    except HTTPException as exc:
        status_label = str(exc.status_code)
        raise
    finally:
        http_requests_in_flight.add(-1, {"endpoint": endpoint})
        duration = time.time() - start
        http_request_duration.record(duration, {"endpoint": endpoint})
        http_requests_total.add(1, {"endpoint": endpoint, "status": status_label})


def _fetch_order(order_id: str) -> dict:
    with tracer.start_as_current_span(
        "order.fetch_from_db",
        kind=trace.SpanKind.CLIENT,
        attributes={"db.system": "postgresql", "db.operation": "SELECT", "order.id": order_id},
    ) as span:
        try:
            conn = get_connection()
            with conn, conn.cursor() as cur:
                cur.execute(
                    "SELECT id, sku, quantity, status FROM orders WHERE id = %s",
                    (order_id,),
                )
                row = cur.fetchone()
            conn.close()

            if row is None:
                span.set_status(Status(StatusCode.ERROR, "order not found"))
                logger.warning("order_not_found", extra={"order_id": order_id})
                raise HTTPException(status_code=404, detail=f"pedido '{order_id}' no existe")

            span.set_attribute("order.status", row["status"])
            span.set_attribute("order.sku", row["sku"])
            span.set_status(Status(StatusCode.OK))
            logger.info("order_fetched", extra={"order_id": order_id, "status": row["status"]})
            return dict(row)

        except HTTPException:
            raise
        except Exception as exc:  # noqa: BLE001
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            logger.error("order_fetch_failed", extra={"order_id": order_id, "error": str(exc)})
            raise HTTPException(status_code=500, detail="error consultando el pedido") from exc


async def _check_inventory(sku: str) -> dict:
    with tracer.start_as_current_span(
        "order.check_inventory",
        kind=trace.SpanKind.CLIENT,
        attributes={"peer.service": "service-b", "order.sku": sku},
    ) as span:
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.get(f"{SERVICE_B_URL}/inventory/{sku}")
                resp.raise_for_status()
                inventory = resp.json()

            span.set_attribute("http.status_code", resp.status_code)
            span.set_attribute("inventory.available_units", inventory.get("available_units", -1))
            service_b_calls_total.add(1, {"outcome": "success"})
            logger.info("inventory_checked", extra={"sku": sku, "available_units": inventory.get("available_units")})
            return inventory

        except httpx.HTTPStatusError as exc:
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            service_b_calls_total.add(1, {"outcome": "http_error"})
            logger.error("inventory_check_failed", extra={"sku": sku, "error": str(exc)})
            return {"available_units": None, "error": "service-b respondió con error"}

        except httpx.RequestError as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, "service-b unreachable"))
            service_b_calls_total.add(1, {"outcome": "unreachable"})
            logger.error("inventory_check_unreachable", extra={"sku": sku, "error": str(exc)})
            return {"available_units": None, "error": "service-b no disponible"}
