#!/usr/bin/env python3
"""Mide el MTTD real (Módulo D: "verificar que el sistema de observabilidad
detecta y alerta en < 2 minutos") comparando el timestamp de inyección del
fallo (impreso por chaos/h4_*.sh o chaos/h5_*.sh como FAULT_START) contra el
momento en que la alerta correspondiente pasó a estado de alarma.

Tres backends, uno por entorno -- usa el que corresponda a dónde se corrió
el experimento:

  local  -- Prometheus local, endpoint /api/v1/alerts (expone las alertas
            actualmente en estado firing directamente, sin necesitar
            Alertmanager). Requiere que
            observability/prometheus/prometheus.yaml tenga cargada la regla
            de alerta correspondiente -- ver
            observability/prometheus/alert_rules.yml y
            docs/runbooks/02-modulo-b-aiops.md.

  aws    -- CloudWatch, alarma compuesta
            (`<project_name>-correlated-degradation`, ver
            iac/terraform/aws/cloudwatch_aiops.tf). Requiere `boto3` y
            credenciales de AWS ya configuradas (mismas del Learner Lab).

  gcp    -- Cloud Monitoring, alert policy
            (`<cluster_name>-correlated-degradation`, ver
            iac/terraform/gcp/monitoring_aiops.tf). Usa el comando oficial
            `gcloud alpha monitoring alerts list` (requiere `gcloud` ya
            autenticado -- el mismo login que usas para `terraform
            apply`/`kubectl`, no hace falta configurar nada aparte).

            Hallazgo real (2026-08-30): la versión anterior de esta función
            intentaba leer el incidente desde Cloud Logging
            (`jsonPayload.policyUserLabels.display_name` en
            `cloudmonitoring.googleapis.com%2Falerts`) -- un esquema de
            campos que NO se pudo confirmar contra documentación oficial
            (regla del proyecto: nada sin referenciar). Se reemplazó por
            `gcloud alpha monitoring alerts list`, cuyo formato de salida
            SÍ está documentado con ejemplo completo, incluyendo el campo
            `open_time` que este script necesita
            (https://docs.cloud.google.com/monitoring/alerts/incidents-events)
            y el filtro `policy.display_name="..."`
            (https://docs.cloud.google.com/sdk/gcloud/reference/alpha/monitoring/alerts/list).
            Es un comando `alpha` (puede cambiar sin aviso, según la propia
            documentación de gcloud) pero es la única vía con esquema de
            campos verificable para este laboratorio.

Uso:
    python3 chaos/measure_mttd.py --backend aws \
        --fault-start 2026-08-29T14:03:10Z \
        --alarm-name observability-lab-correlated-degradation \
        --region us-east-1
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--backend", required=True, choices=["local", "aws", "gcp"])
    parser.add_argument("--fault-start", required=True, help="Timestamp UTC ISO8601 (ej. 2026-08-29T14:03:10Z), impreso por los scripts h4_/h5_.")
    parser.add_argument("--alarm-name", help="Nombre de la alarma/alert policy (aws/gcp).")
    parser.add_argument("--region", default="us-east-1", help="Región AWS (solo backend=aws).")
    parser.add_argument("--project-id", help="Project ID de GCP (solo backend=gcp).")
    parser.add_argument("--prometheus-url", default="http://localhost:9091", help="Base URL de Prometheus (solo backend=local).")
    parser.add_argument("--alert-name", default="CorrelatedDegradation", help="Nombre de la alerta en las reglas de Prometheus (solo backend=local).")
    parser.add_argument("--timeout-s", type=int, default=900, help="Máximo tiempo de sondeo antes de rendirse (local/gcp, default 900s=15min) -- evita dejar el script colgado si la alerta nunca dispara.")
    return parser.parse_args()


def _parse_ts(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def measure_local(args: argparse.Namespace, fault_start: datetime) -> None:
    import urllib.request
    import json

    # /api/v1/alerts expone el estado ACTUAL, no el historial -- para MTTD
    # real hay que sondear en un loop mientras el experimento corre (ver el
    # runbook: correr este script EN PARALELO al chaos/h5_*.sh, no después).
    url = f"{args.prometheus_url}/api/v1/alerts"
    print(f"Sondeando {url} cada 2s buscando la alerta '{args.alert_name}' en estado firing...")
    print(f"(máximo {args.timeout_s}s, luego se rinde solo -- Ctrl+C también sirve si quieres cortar antes.)")

    import time

    deadline = time.monotonic() + args.timeout_s
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                data = json.loads(resp.read())
        except Exception as exc:  # noqa: BLE001
            print(f"error consultando Prometheus: {exc}", file=sys.stderr)
            time.sleep(2)
            continue

        for alert in data.get("data", {}).get("alerts", []):
            if alert.get("labels", {}).get("alertname") == args.alert_name and alert.get("state") == "firing":
                fired_at = _parse_ts(alert["activeAt"])
                mttd = (fired_at - fault_start).total_seconds()
                print(f"ALERTA DISPARADA: {alert['labels']}")
                print(f"fault_start={fault_start.isoformat()} fired_at={fired_at.isoformat()} MTTD={mttd:.1f}s")
                return
        time.sleep(2)

    print(f"Se agotaron los {args.timeout_s}s de sondeo sin ver la alerta en firing -- resultado igualmente válido para el reporte (la alerta no disparó a tiempo, o nunca disparó).")


def measure_aws(args: argparse.Namespace, fault_start: datetime) -> None:
    import boto3

    if not args.alarm_name:
        sys.exit("--alarm-name es requerido para backend=aws")

    client = boto3.client("cloudwatch", region_name=args.region)
    print(f"Consultando historial de {args.alarm_name} en CloudWatch (región {args.region})...")

    resp = client.describe_alarm_history(
        AlarmName=args.alarm_name,
        HistoryItemType="StateUpdate",
        StartDate=fault_start,
        MaxRecords=20,
        ScanBy="TimestampAscending",
    )

    for item in resp.get("AlarmHistoryItems", []):
        if '"stateValue":"ALARM"' in item.get("HistorySummary", "") or "ALARM" in item.get("HistorySummary", ""):
            fired_at = item["Timestamp"]
            if fired_at.tzinfo is None:
                fired_at = fired_at.replace(tzinfo=timezone.utc)
            mttd = (fired_at - fault_start).total_seconds()
            print(f"ALARMA: {item['HistorySummary']}")
            print(f"fault_start={fault_start.isoformat()} fired_at={fired_at.isoformat()} MTTD={mttd:.1f}s")
            return

    print("No se encontró transición a ALARM en el historial consultado -- revisa el rango de tiempo o si la alarma nunca disparó (resultado igualmente válido para el reporte).")


def measure_gcp(args: argparse.Namespace, fault_start: datetime) -> None:
    # `gcloud alpha monitoring alerts list` -- comando oficial documentado
    # (ver el docstring del módulo para las 2 fuentes citadas) que expone
    # `open_time` por incidente, ya filtrable por `policy.display_name`.
    # Se invoca vía subprocess (no hay SDK de Python separado para este
    # comando alpha) usando las credenciales de `gcloud` ya autenticadas en
    # esta sesión (las mismas de `terraform apply`/`kubectl`).
    import json
    import subprocess
    import time

    if not args.project_id:
        sys.exit("--project-id es requerido para backend=gcp")
    if not args.alarm_name:
        sys.exit("--alarm-name es requerido para backend=gcp (display_name de la alert policy)")

    filter_expr = f'policy.display_name="{args.alarm_name}" AND state=OPEN'
    cmd = [
        "gcloud",
        "alpha",
        "monitoring",
        "alerts",
        "list",
        f"--project={args.project_id}",
        f"--filter={filter_expr}",
        "--sort-by=open_time",
        "--format=json",
    ]

    print(f"Sondeando incidentes OPEN de '{args.alarm_name}' cada 5s (máximo {args.timeout_s}s)...")
    print(f"Comando: {' '.join(cmd)}\n")

    deadline = time.monotonic() + args.timeout_s
    while time.monotonic() < deadline:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"error consultando gcloud: {result.stderr.strip()}", file=sys.stderr)
            time.sleep(5)
            continue

        try:
            incidents = json.loads(result.stdout or "[]")
        except json.JSONDecodeError:
            incidents = []

        for incident in incidents:
            open_time_str = incident.get("open_time") or incident.get("openTime")
            if not open_time_str:
                continue
            opened_at = _parse_ts(open_time_str)
            if opened_at >= fault_start:
                mttd = (opened_at - fault_start).total_seconds()
                print(f"INCIDENTE ABIERTO: {incident.get('name')} -- {incident.get('summaryText', '')}")
                print(f"fault_start={fault_start.isoformat()} fired_at={opened_at.isoformat()} MTTD={mttd:.1f}s")
                return

        time.sleep(5)

    print(f"Se agotaron los {args.timeout_s}s de sondeo sin ver un incidente OPEN posterior a fault_start -- resultado igualmente válido para el reporte (la alerta no disparó a tiempo, o nunca disparó). Verifica también en Cloud Console -> Monitoring -> Alerting por si acaso.")


def main() -> None:
    args = parse_args()
    fault_start = _parse_ts(args.fault_start)

    if args.backend == "local":
        measure_local(args, fault_start)
    elif args.backend == "aws":
        measure_aws(args, fault_start)
    elif args.backend == "gcp":
        measure_gcp(args, fault_start)


if __name__ == "__main__":
    main()
