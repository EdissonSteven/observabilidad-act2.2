#!/usr/bin/env python3
"""Analisis de degradacion de SLO y consumo de error budget (Modulo D, preguntas 2 y 3).

Responde con datos REALES del CSV de chaos/load_gen.py las preguntas 2 y 3 de
docs/runbooks/04-modulo-d-chaos.md:

  2. Se degrado el SLO?  -> compara p50/p95/p99 y tasa de violacion del umbral
     de latencia entre la ventana LIMPIA (warm-up) y la ventana de FALLO del
     mismo CSV. Usar el mismo CSV para ambas ventanas elimina la variabilidad
     entre corridas (misma red, mismos pods, mismo generador de carga).

  3. Se consumio el error budget?  -> aplica la formula del runbook:
         (peticiones_degradadas / peticiones_totales_del_mes) / (1 - SLO)

DEFINICION DE "PETICION DEGRADADA" (importante para interpretar el resultado):
se cuentan por separado dos criterios, porque en este sistema NO coinciden:

  a) Fallo HTTP visible: status != 200. En el Experimento 3 real esto dio CERO
     -- service-a atrapa el fallo de data-service en _fetch_customer() y
     responde 200 igual (degradacion silenciosa, ver services/service-a/app/main.py).
     Un SLO de disponibilidad basado solo en codigos HTTP habria reportado
     100 % de exito durante un incidente real. Ese es justamente el falso
     negativo que motivo la metrica data_service_calls_total.

  b) Violacion del SLO de latencia: latency_ms > umbral. Este SI captura el
     incidente. Es el criterio que se usa para el error budget por defecto.

El umbral por defecto (250 ms) coincide con var.latency_p99_slo_ms de
iac/terraform/gcp/variables.tf y con la frontera de bucket le="0.25" que
evaluan las alert policies -- ver el hallazgo 5 de monitoring_aiops.tf.

SUPUESTO DE TRAFICO MENSUAL: no hay trafico de produccion real que medir, asi
que se extrapola el ritmo observado en la propia corrida (peticiones/segundo)
a un mes de 30 dias. Es un supuesto auto-consistente y se imprime explicito en
la salida para que quede documentado en el reporte. Se puede sobrescribir con
--monthly-requests si se prefiere otro supuesto.

Uso:
  python3 chaos/analyze_error_budget.py --csv d3_combinado_20260830_054521.csv \\
      --fault-start-s 110 --fault-end-s 496

  # o dando las marcas de tiempo absolutas que imprimieron los scripts:
  python3 chaos/analyze_error_budget.py --csv d3_combinado_20260830_054521.csv \\
      --loadgen-start 2026-08-30T05:45:22Z \\
      --fault-start   2026-08-30T05:47:04Z \\
      --fault-end     2026-08-30T05:53:38Z
"""

import argparse
import csv
import sys
from datetime import datetime, timezone


def _parse_ts(value: str) -> datetime:
    v = value.strip().replace("Z", "+00:00")
    dt = datetime.fromisoformat(v)
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def percentile(sorted_values, pct):
    """Percentil por interpolacion lineal (mismo metodo que numpy.percentile)."""
    if not sorted_values:
        return float("nan")
    if len(sorted_values) == 1:
        return sorted_values[0]
    k = (len(sorted_values) - 1) * (pct / 100.0)
    lo, hi = int(k), min(int(k) + 1, len(sorted_values) - 1)
    if lo == hi:
        return sorted_values[lo]
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (k - lo)


def describe(rows, threshold_ms, label):
    if not rows:
        print(f"  {label}: (sin peticiones en esta ventana)")
        return None
    lat = sorted(r["latency_ms"] for r in rows)
    http_fail = sum(1 for r in rows if r["status"] != 200)
    slow = sum(1 for r in rows if r["latency_ms"] > threshold_ms)
    stats = {
        "n": len(rows),
        "p50": percentile(lat, 50),
        "p95": percentile(lat, 95),
        "p99": percentile(lat, 99),
        "max": lat[-1],
        "http_fail": http_fail,
        "slow": slow,
        "slow_pct": 100.0 * slow / len(rows),
    }
    print(f"  {label}")
    print(f"    peticiones                 : {stats['n']}")
    print(f"    p50 / p95 / p99            : {stats['p50']:.1f} / {stats['p95']:.1f} / {stats['p99']:.1f} ms")
    print(f"    maximo                     : {stats['max']:.1f} ms")
    print(f"    fallos HTTP (status != 200): {stats['http_fail']}")
    print(f"    sobre umbral de {threshold_ms:.0f} ms      : {stats['slow']} ({stats['slow_pct']:.2f} %)")
    return stats


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--csv", required=True, help="CSV de chaos/load_gen.py")
    p.add_argument("--fault-start-s", type=float, help="Inicio del fallo, en segundos desde el arranque de load_gen")
    p.add_argument("--fault-end-s", type=float, help="Fin del fallo, en segundos desde el arranque de load_gen")
    p.add_argument("--loadgen-start", help="Marca de tiempo ISO del arranque de load_gen (alternativa a --fault-start-s)")
    p.add_argument("--fault-start", help="Marca de tiempo ISO del inicio del fallo")
    p.add_argument("--fault-end", help="Marca de tiempo ISO del fin del fallo")
    p.add_argument("--latency-slo-ms", type=float, default=250.0,
                   help="Umbral de latencia del SLO en ms (default 250, = var.latency_p99_slo_ms)")
    p.add_argument("--availability-slo", type=float, default=99.5,
                   help="Objetivo de disponibilidad mensual en %% (default 99.5)")
    p.add_argument("--monthly-requests", type=float, default=None,
                   help="Supuesto de peticiones/mes. Si se omite, se extrapola el ritmo observado a 30 dias.")
    args = p.parse_args()

    # Resolver la ventana de fallo a offsets en segundos.
    if args.fault_start_s is None or args.fault_end_s is None:
        if not (args.loadgen_start and args.fault_start and args.fault_end):
            sys.exit("Da --fault-start-s/--fault-end-s, o las tres marcas ISO "
                     "(--loadgen-start, --fault-start, --fault-end)")
        t0 = _parse_ts(args.loadgen_start)
        fault_start_s = (_parse_ts(args.fault_start) - t0).total_seconds()
        fault_end_s = (_parse_ts(args.fault_end) - t0).total_seconds()
    else:
        fault_start_s, fault_end_s = args.fault_start_s, args.fault_end_s

    rows = []
    with open(args.csv, newline="") as fh:
        for r in csv.DictReader(fh):
            try:
                rows.append({
                    "t_s": float(r["t_s"]),
                    "status": int(r["status"]),
                    "latency_ms": float(r["latency_ms"]),
                    "note": r.get("note", ""),
                })
            except (ValueError, KeyError, TypeError):
                continue  # fila malformada o incompleta: se ignora

    if not rows:
        sys.exit(f"No se pudo leer ninguna fila valida de {args.csv}")

    clean = [r for r in rows if r["t_s"] < fault_start_s]
    fault = [r for r in rows if fault_start_s <= r["t_s"] <= fault_end_s]
    after = [r for r in rows if r["t_s"] > fault_end_s]

    thr = args.latency_slo_ms
    print("=" * 70)
    print(" Analisis de SLO y error budget -- Modulo D")
    print("=" * 70)
    print(f" CSV                : {args.csv}")
    print(f" Ventana de fallo   : t={fault_start_s:.0f}s .. t={fault_end_s:.0f}s ({fault_end_s - fault_start_s:.0f}s)")
    print(f" Umbral de latencia : {thr:.0f} ms  (= var.latency_p99_slo_ms)")
    print(f" SLO objetivo       : {args.availability_slo} % mensual")
    print()
    print(" PREGUNTA 2 -- Se degrado el SLO?")
    print()
    base = describe(clean, thr, "ANTES del fallo (warm-up, trafico limpio)")
    print()
    bad = describe(fault, thr, "DURANTE el fallo")
    if after:
        print()
        describe(after, thr, "DESPUES del fallo (recuperacion)")

    if base and bad:
        print()
        print("  Comparacion antes -> durante:")
        for k, name in (("p50", "p50"), ("p95", "p95"), ("p99", "p99")):
            b, d = base[k], bad[k]
            factor = d / b if b else float("inf")
            print(f"    {name:3}: {b:7.1f} ms -> {d:7.1f} ms   ({factor:.1f}x)")
        print(f"    tasa de violacion del SLO: {base['slow_pct']:.2f} % -> {bad['slow_pct']:.2f} %")

    print()
    print(" PREGUNTA 3 -- Se consumio el error budget?")
    print()
    if not bad:
        print("  (sin datos en la ventana de fallo)")
        return

    duration_s = rows[-1]["t_s"] - rows[0]["t_s"]
    rate_rps = len(rows) / duration_s if duration_s > 0 else 0.0
    seconds_per_month = 30 * 24 * 3600

    if args.monthly_requests is not None:
        monthly = args.monthly_requests
        origin = "dado con --monthly-requests"
    else:
        monthly = rate_rps * seconds_per_month
        origin = (f"extrapolado del ritmo observado ({rate_rps:.2f} req/s "
                  f"sobre {duration_s:.0f}s) a 30 dias")

    budget_frac = 1.0 - (args.availability_slo / 100.0)
    budget_requests = monthly * budget_frac

    degraded_latency = bad["slow"]
    degraded_http = bad["http_fail"]

    print(f"  SUPUESTO de trafico mensual: {monthly:,.0f} peticiones")
    print(f"    ({origin})")
    print(f"  Error budget mensual ({budget_frac * 100:.2f} %): {budget_requests:,.0f} peticiones")
    print()

    for label, degraded in (("violacion de latencia (> %.0f ms)" % thr, degraded_latency),
                            ("fallo HTTP (status != 200)", degraded_http)):
        consumed = 100.0 * degraded / budget_requests if budget_requests else float("inf")
        print(f"  Criterio: {label}")
        print(f"    peticiones degradadas en el experimento: {degraded}")
        print(f"    consumo del error budget mensual       : {consumed:.2f} %")
        if degraded == 0:
            print("    ^ CERO por este criterio pese a un incidente real -- ver la nota")
            print("      sobre degradacion silenciosa en el encabezado de este script.")
        print()

    print("=" * 70)


if __name__ == "__main__":
    main()
