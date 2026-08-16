#!/usr/bin/env python3
"""Fase 4 -- compara benchmark/results/results_baseline.json vs results_otel.json
(generados por k6-load-test.js) y escribe benchmark/results/overhead-comparison.md.

Si además existen benchmark/results/cpu_baseline.csv y cpu_otel.csv (muestreo de
`docker stats --no-stream` cada ~1-2s durante toda la ventana de carga, ver
benchmark/results/README para el método), agrega una tabla de CPU promedio por
contenedor. Esas dos corridas de CPU se ejecutan por separado de la corrida de
latencia "oficial" (los timestamps de los JSON de latencia no cambian) porque el
propio muestreo de `docker stats` compite por CPU con los contenedores bajo
prueba y distorsiona la latencia si se mide en la misma corrida -- ver sección
6.2 del reporte técnico.

Uso:
    python3 benchmark/analyze_overhead.py
"""
import csv
import json
from collections import defaultdict
from pathlib import Path

RESULTS_DIR = Path(__file__).parent / "results"

METRICS = [
    ("Latencia promedio", "latency_avg_ms", "ms"),
    ("Latencia p95", "latency_p95_ms", "ms"),
    ("Latencia p99", "latency_p99_ms", "ms"),
    ("Error rate", "error_rate_pct", "%"),
    ("Throughput", "throughput_rps", "req/s"),
]

CPU_CONTAINERS = [
    ("service-a", "observabilidad-act22-service-a-1"),
    ("service-b", "observabilidad-act22-service-b-1"),
    ("otel-collector", "observabilidad-act22-otel-collector-1"),
]


def load(name: str) -> dict:
    path = RESULTS_DIR / f"results_{name}.json"
    return json.loads(path.read_text(encoding="utf-8"))["metrics"]


def load_cpu_avg(name: str) -> dict[str, float] | None:
    path = RESULTS_DIR / f"cpu_{name}.csv"
    if not path.exists():
        return None
    sums: dict[str, float] = defaultdict(float)
    counts: dict[str, int] = defaultdict(int)
    with path.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            pct = float(row["cpu_perc"].strip("%"))
            sums[row["name"]] += pct
            counts[row["name"]] += 1
    return {name: sums[name] / counts[name] for name in sums if counts[name]}


def pct_diff(baseline: float, otel: float) -> float:
    return ((otel - baseline) / baseline) * 100 if baseline else 0.0


def main() -> None:
    baseline = load("baseline")
    otel = load("otel")

    lines = ["| Métrica | Sin OTel (baseline) | Con OTel SDK | Overhead |",
             "|---|---|---|---|"]
    for label, key, unit in METRICS:
        b, o = baseline[key], otel[key]
        diff = pct_diff(b, o)
        sign = "+" if diff >= 0 else ""
        lines.append(f"| {label} | {b:.2f} {unit} | {o:.2f} {unit} | {sign}{diff:.1f}% |")

    p99_overhead_ms = otel["latency_p99_ms"] - baseline["latency_p99_ms"]
    lines += [
        "",
        f"Latencia adicional p99: **{p99_overhead_ms:+.2f} ms** "
        f"({pct_diff(baseline['latency_p99_ms'], otel['latency_p99_ms']):+.1f}%)",
    ]

    cpu_baseline = load_cpu_avg("baseline")
    cpu_otel = load_cpu_avg("otel")
    if cpu_baseline and cpu_otel:
        lines += [
            "",
            "### CPU promedio por contenedor",
            "",
            "Muestreado con `docker stats --no-stream` cada ~1-2s durante toda la "
            "ventana de carga (60 VUs, 5 min), promediado sobre todas las muestras "
            "-- no un snapshot puntual.",
            "",
            "| Contenedor | Sin OTel (baseline) | Con OTel SDK | Overhead |",
            "|---|---|---|---|",
        ]
        for label, container in CPU_CONTAINERS:
            b = cpu_baseline.get(container)
            o = cpu_otel.get(container)
            if b is None or o is None:
                continue
            diff_pp = o - b
            diff_pct = pct_diff(b, o)
            sign = "+" if diff_pct >= 0 else ""
            lines.append(
                f"| `{label}` | {b:.2f}% | {o:.2f}% | {diff_pp:+.2f} pp ({sign}{diff_pct:.1f}%) |"
            )

    out = "\n".join(lines)
    print(out)
    (RESULTS_DIR / "overhead-comparison.md").write_text(out + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
