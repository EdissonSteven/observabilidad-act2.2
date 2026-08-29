#!/usr/bin/env python3
"""Generador de carga real contra GET /orders/{order_id} (flujo de 3 saltos:
service-a -> service-b -> data-service), parametrizable para apuntar a
local, AWS (ALB) o GCP (IP del Service/Ingress).

Mismo patrón que el load_gen.py usado en el Game Day de la Actividad 2.2
(peticiones secuenciales, mide latencia real por request, sin librerías de
carga externas) -- aquí generalizado con argparse en vez de argumentos
posicionales fijos, para poder apuntarlo a cualquiera de los 3 entornos sin
editar el script.

Uso:
    python3 chaos/load_gen.py --url http://localhost:8000/orders/ord-1002 \
        --duration 40 --out during_fault.csv
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--url",
        default="http://localhost:8000/orders/ord-1002",
        help="URL completa del endpoint a golpear (ALB DNS name para AWS, IP externa/Ingress para GCP).",
    )
    parser.add_argument("--duration", type=float, default=30, help="Duración de la corrida, en segundos.")
    parser.add_argument("--out", default="results.csv", help="Archivo CSV de salida.")
    parser.add_argument("--timeout", type=float, default=10, help="Timeout por request, en segundos.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    rows: list[tuple[float, object, float, str]] = []
    start = time.time()

    while time.time() - start < args.duration:
        t0 = time.time()
        try:
            with urllib.request.urlopen(args.url, timeout=args.timeout) as resp:
                body = resp.read()
                status = resp.status
                data = json.loads(body)
                # chaos.injected de data-service (Módulo D, experimento 2) o de
                # service-b (experimento 1) se refleja en el campo "error" de
                # customer/inventory dentro de la respuesta combinada de
                # service-a -- ver services/service-a/app/main.py.
                inv_error = (data.get("inventory") or {}).get("error")
                cust_error = (data.get("customer") or {}).get("error")
                note = inv_error or cust_error or ""
        except Exception as exc:  # noqa: BLE001 -- se registra la excepción como fila, no se detiene la corrida
            status = "ERR"
            note = str(exc)
        elapsed_ms = (time.time() - t0) * 1000
        rows.append((round(time.time() - start, 3), status, round(elapsed_ms, 2), note))

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("t_s,status,latency_ms,note\n")
        for r in rows:
            f.write(f"{r[0]},{r[1]},{r[2]},{r[3]}\n")

    latencies = sorted(r[2] for r in rows)
    errors = sum(1 for r in rows if r[1] != 200)

    def pct(p: float) -> float:
        if not latencies:
            return 0
        idx = min(int(len(latencies) * p), len(latencies) - 1)
        return latencies[idx]

    if not latencies:
        print("Sin datos -- revisa --url", file=sys.stderr)
        sys.exit(1)

    print(
        f"requests={len(rows)} errors_or_degraded={errors} "
        f"avg_ms={sum(latencies)/len(latencies):.1f} p50_ms={pct(0.5):.1f} "
        f"p95_ms={pct(0.95):.1f} p99_ms={pct(0.99):.1f} max_ms={max(latencies):.1f}"
    )


if __name__ == "__main__":
    main()
