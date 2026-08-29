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
            iac/terraform/gcp/monitoring_aiops.tf). Requiere
            `google-cloud-monitoring` y credenciales (`gcloud auth
            application-default login`).

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
    print("(Ctrl+C para detener si el experimento ya terminó sin disparar -- eso también es un resultado válido para el reporte.)")

    import time

    while True:
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
    # La API de Cloud Monitoring para incidentes abiertos es
    # `AlertPolicyServiceClient` + `NotificationChannelServiceClient` no
    # exponen directamente el historial de incidentes por policy de forma
    # simple vía el SDK -- el camino más confiable es Cloud Logging (todo
    # alert policy que dispara escribe una entrada de log en
    # `logName="projects/<project>/logs/cloudmonitoring.googleapis.com%2Falerts"`).
    # Se consulta eso aquí en vez del SDK de Monitoring directamente.
    from google.cloud import logging as gcp_logging

    if not args.project_id:
        sys.exit("--project-id es requerido para backend=gcp")
    if not args.alarm_name:
        sys.exit("--alarm-name es requerido para backend=gcp (display_name de la alert policy)")

    client = gcp_logging.Client(project=args.project_id)
    filter_str = (
        'logName="projects/%s/logs/cloudmonitoring.googleapis.com%%2Falerts" '
        'AND jsonPayload.policyUserLabels.display_name="%s" '
        'AND jsonPayload.incident.state="open"' % (args.project_id, args.alarm_name)
    )
    print(f"Consultando Cloud Logging con filtro:\n{filter_str}\n")

    entries = list(client.list_entries(filter_=filter_str, order_by=gcp_logging.ASCENDING, max_results=20))
    for entry in entries:
        started_at = entry.timestamp
        if started_at.tzinfo is None:
            started_at = started_at.replace(tzinfo=timezone.utc)
        if started_at >= fault_start:
            mttd = (started_at - fault_start).total_seconds()
            print(f"INCIDENTE ABIERTO: {entry.payload}")
            print(f"fault_start={fault_start.isoformat()} fired_at={started_at.isoformat()} MTTD={mttd:.1f}s")
            return

    print("No se encontró un incidente abierto para esa alert policy en el filtro consultado -- revisa el nombre exacto (display_name) o si la alerta nunca disparó.")


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
