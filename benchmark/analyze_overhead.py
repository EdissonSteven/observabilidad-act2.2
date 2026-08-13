#!/usr/bin/env python3
"""Fase 4 -- compara benchmark/results/results_baseline.json vs results_otel.json
(generados por k6-load-test.js) y escribe benchmark/results/overhead-comparison.md.

Uso:
    python3 benchmark/analyze_overhead.py
"""
import json
from pathlib import Path

RESULTS_DIR = Path(__file__).parent / "results"

METRICS = [
    ("Latencia promedio", "latency_avg_ms", "ms"),
    ("Latencia p95", "latency_p95_ms", "ms"),
    ("Latencia p99", "latency_p99_ms", "ms"),
    ("Error rate", "error_rate_pct", "%"),
    ("Throughput", "throughput_rps", "req/s"),
]


def load(name: str) -> dict:
    path = RESULTS_DIR / f"results_{name}.json"
    return json.loads(path.read_text(encoding="utf-8"))["metrics"]


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

    out = "\n".join(lines)
    print(out)
    (RESULTS_DIR / "overhead-comparison.md").write_text(out + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
