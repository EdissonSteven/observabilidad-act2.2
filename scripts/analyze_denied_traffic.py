#!/usr/bin/env python3
"""Golden signals de seguridad: analisis del trafico rechazado por firewall (Modulo C).

Consume los logs de Firewall Rules Logging generados por la regla
`deny_all_logged` de iac/terraform/gcp/network_security.tf (prioridad 65534,
source_ranges 0.0.0.0/0, INGRESS) y produce el resumen que alimenta el
dashboard "Golden Signals de Seguridad" y la seccion de Modulo C del reporte.

POR QUE HACE FALTA ESTE ANALISIS: la alerta `anomalous_denied_traffic` solo
dice "hubo un pico de conexiones rechazadas". Eso confirma que el mecanismo
de deteccion funciona, pero NO distingue un escaneo dirigido del ruido de
fondo de internet. La regla es un deny-all de prioridad minima, asi que
captura todo lo que ninguna regla mas especifica permitio -- health checks,
escaneo indiscriminado contra IPs publicas, y trafico legitimo mal dirigido,
todo junto. Separar señal de ruido requiere mirar la distribucion por IP
origen, puerto destino y geografia, que es lo que hace este script.

CLASIFICACION DE PUERTOS: se marcan los puertos que son objetivos conocidos
de escaneo automatizado. El rango 30000-32767 es especialmente relevante en
GKE: es el rango por defecto de NodePort de Kubernetes
(https://kubernetes.io/docs/concepts/services-networking/service/#type-nodeport),
asi que trafico dirigido ahi es un intento de encontrar Services expuestos,
no ruido generico.

Uso:
  # lee directamente de Cloud Logging (requiere gcloud autenticado)
  python3 scripts/analyze_denied_traffic.py --project observabilidad-lab-507021 --freshness 6h

  # o analiza un volcado ya guardado (recomendado: el volcado es evidencia)
  gcloud logging read 'resource.type="gce_subnetwork" jsonPayload.disposition="DENIED"' \\
    --project=observabilidad-lab-507021 --freshness=6h --format=json > denied.json
  python3 scripts/analyze_denied_traffic.py --input denied.json
"""

import argparse
import json
import subprocess
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

# Numeros de protocolo IP (IANA). Solo los que aparecen en logs de firewall.
PROTOCOLS = {1: "ICMP", 6: "TCP", 17: "UDP", 47: "GRE", 50: "ESP", 58: "ICMPv6"}

# Puertos que son objetivo habitual de escaneo automatizado. La etiqueta es
# descriptiva del servicio que suele escucharse ahi, no una afirmacion de que
# este sistema lo exponga.
WELL_KNOWN = {
    21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS",
    80: "HTTP", 110: "POP3", 135: "MSRPC", 139: "NetBIOS", 143: "IMAP",
    443: "HTTPS", 445: "SMB", 1433: "MSSQL", 1521: "Oracle",
    3306: "MySQL", 3389: "RDP", 5432: "PostgreSQL", 5900: "VNC",
    6379: "Redis", 8080: "HTTP-alt", 8443: "HTTPS-alt", 9200: "Elasticsearch",
    11211: "Memcached", 27017: "MongoDB",
}

NODEPORT_LO, NODEPORT_HI = 30000, 32767


def classify_port(port):
    if port in WELL_KNOWN:
        return WELL_KNOWN[port]
    if NODEPORT_LO <= port <= NODEPORT_HI:
        return "rango NodePort de K8s"
    return ""


def fetch(project, freshness):
    cmd = [
        "gcloud", "logging", "read",
        'resource.type="gce_subnetwork" jsonPayload.disposition="DENIED"',
        f"--project={project}", f"--freshness={freshness}", "--format=json",
    ]
    print(f"Consultando Cloud Logging ({freshness})...", file=sys.stderr)
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"gcloud fallo: {res.stderr.strip()}")
    return json.loads(res.stdout or "[]")


def table(counter, total, title, width=42, top=15, annotate=None):
    print(f"\n{title}")
    print("-" * 70)
    if not counter:
        print("  (sin datos)")
        return
    for key, n in counter.most_common(top):
        pct = 100.0 * n / total if total else 0.0
        note = ""
        if annotate:
            label = annotate(key)
            note = f"  [{label}]" if label else ""
        print(f"  {str(key):<{width}} {n:>7}  {pct:>5.1f} %{note}")
    if len(counter) > top:
        rest = sum(n for _, n in counter.most_common()[top:])
        print(f"  {'... otros ' + str(len(counter) - top) + ' valores':<{width}} {rest:>7}  "
              f"{100.0 * rest / total if total else 0:>5.1f} %")



def _pct(vals, p):
    if not vals:
        return 0.0
    s = sorted(vals)
    if len(s) == 1:
        return float(s[0])
    k = (len(s) - 1) * (p / 100.0)
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return float(s[lo]) if lo == hi else s[lo] + (s[hi] - s[lo]) * (k - lo)


def burst_analysis(entries, threshold, n_src_ips=0):
    """Distribucion de la tasa por minuto -- para elegir el umbral de la alerta con datos.

    La alert policy `anomalous_denied_traffic` usa ALIGN_RATE con
    alignment_period de 60s, o sea que compara CONEXIONES POR SEGUNDO
    promediadas por minuto. Elegir ese umbral a ojo produce una alerta que
    dispara con el ruido de fondo de internet (que es permanente y no
    accionable). Esta funcion mide la distribucion real para poder fijarlo.
    """
    per_min = Counter()
    for e in entries:
        ts = e.get("timestamp") or e.get("receiveTimestamp")
        if not ts:
            continue
        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except ValueError:
            continue
        per_min[dt.astimezone(timezone.utc).replace(second=0, microsecond=0)] += 1

    if not per_min:
        print("\n(sin timestamps utilizables para el analisis de rafagas)")
        return

    # Minutos sin ninguna conexion no aparecen en el Counter, pero SI cuentan
    # como 0 para la distribucion: se rellenan entre el primer y ultimo minuto.
    lo, hi = min(per_min), max(per_min)
    total_min = int((hi - lo).total_seconds() // 60) + 1
    counts = [per_min.get(lo + timedelta(minutes=i), 0) for i in range(total_min)]
    rates = [c / 60.0 for c in counts]  # conexiones/segundo, igual que ALIGN_RATE

    over = sum(1 for r in rates if r > threshold)
    print("\n" + "=" * 70)
    print(" DISTRIBUCION DE LA TASA POR MINUTO (para calibrar el umbral)")
    print("=" * 70)
    print(f"  Minutos analizados     : {total_min}")
    print(f"  Tasa media             : {sum(rates) / len(rates):.2f} conexiones/s")
    print(f"  p50 / p95 / p99        : {_pct(rates, 50):.2f} / {_pct(rates, 95):.2f} / {_pct(rates, 99):.2f} conexiones/s")
    print(f"  Maximo observado       : {max(rates):.2f} conexiones/s")
    print()
    print(f"  Umbral actual de la alerta: {threshold} conexiones/s")
    print(f"  Minutos que lo superan    : {over} de {total_min} ({100.0 * over / total_min:.1f} %)")
    if over:
        print()
        print(f"  -> La alerta dispararia {over} vez/veces en esta ventana SIN que haya")
        print("     ocurrido ningun incidente real: es ruido de fondo de internet.")
    else:
        print("  -> El umbral no se supera en esta ventana: no genera falsos positivos aqui.")

    # Tabla de calibracion: no existe un umbral "correcto" objetivo -- existe
    # el umbral que corresponde a la tasa de falsos positivos que se acepte.
    # Se muestra la equivalencia para que la decision sea informada y quede
    # documentada en el reporte, en vez de elegir un numero a ojo.
    print()
    print("  Calibracion -- cuantas veces dispararia cada umbral en esta ventana:")
    print(f"    {'umbral (conex/s)':<20} {'minutos que disparan':>22} {'% ventana':>12}")
    candidates = sorted({round(_pct(rates, q), 2) for q in (50, 90, 95, 99, 99.9)}
                        | {round(max(rates), 2), round(max(rates) * 1.5, 2), float(threshold)})
    for c in candidates:
        n = sum(1 for r in rates if r > c)
        tag = "  <- actual" if abs(c - threshold) < 1e-9 else ""
        print(f"    {c:<20.2f} {n:>22} {100.0 * n / total_min:>11.1f} %{tag}")
    print()
    print(f"  Para NO disparar con el ruido observado hace falta un umbral por")
    print(f"  encima de {max(rates):.2f} conexiones/s (el maximo de esta ventana).")
    print("  Advertencia: si en esta ventana hubo un escaneo dirigido real, ese")
    print("  maximo lo incluye -- calibrar sobre una ventana que se sepa limpia.")
    print()
    print("  LIMITACION DE FONDO: ningun umbral de VOLUMEN puede distinguir un")
    print("  escaneo dirigido de una rafaga de ruido, porque ambos se ven igual")
    print("  en esta metrica. Distinguirlos exige mirar la CONCENTRACION por IP")
    print(f"  origen -- y esa NO puede ser un label de la metrica ({n_src_ips:,} valores")
    print("  distintos en esta ventana, contra el limite practico que documenta")
    print("  https://docs.cloud.google.com/logging/docs/logs-based-metrics/labels:")
    print("  ~30.000 series activas por metrica, con recomendacion explicita de")
    print("  usar solo conjuntos pequeños de valores discretos).")
    print("  Por eso ese analisis vive en este script y no en la alerta.")
    print("=" * 70)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--project", help="Proyecto de GCP (lee de Cloud Logging)")
    src.add_argument("--input", help="Archivo JSON ya volcado con gcloud logging read")
    p.add_argument("--freshness", default="6h", help="Ventana de tiempo (default 6h)")
    p.add_argument("--alert-threshold", type=float, default=5.0,
                   help="Umbral actual de la alerta en conexiones/s (default 5, = var.denied_traffic_alert_threshold)")
    args = p.parse_args()

    entries = (json.load(open(args.input)) if args.input
               else fetch(args.project, args.freshness))

    if not entries:
        print("Sin entradas de trafico rechazado en la ventana consultada.")
        print("Eso tambien es un resultado valido: significa que no hubo trafico")
        print("anomalo detectado. Documentarlo como tal, no como fallo del setup.")
        return

    src_ips, dst_ports, countries, protos, dst_ips, rules = (
        Counter(), Counter(), Counter(), Counter(), Counter(), Counter())

    for e in entries:
        jp = e.get("jsonPayload", {})
        conn = jp.get("connection", {})
        loc = jp.get("remote_location", {})
        rd = jp.get("rule_details", {})
        if conn.get("src_ip"):
            src_ips[conn["src_ip"]] += 1
        if conn.get("dest_port") is not None:
            dst_ports[conn["dest_port"]] += 1
        if conn.get("dest_ip"):
            dst_ips[conn["dest_ip"]] += 1
        protos[conn.get("protocol")] += 1
        countries[(loc.get("country") or "desconocido").upper()] += 1
        if rd.get("reference"):
            rules[rd["reference"].split("firewall:")[-1]] += 1

    total = len(entries)
    nodeport_hits = sum(n for port, n in dst_ports.items()
                        if isinstance(port, int) and NODEPORT_LO <= port <= NODEPORT_HI)
    wellknown_hits = sum(n for port, n in dst_ports.items() if port in WELL_KNOWN)

    print("=" * 70)
    print(" Golden signals de seguridad -- trafico rechazado por firewall")
    print("=" * 70)
    print(f" Conexiones rechazadas   : {total:,}")
    print(f" IPs origen distintas    : {len(src_ips):,}")
    print(f" Puertos destino distintos: {len(dst_ports):,}")
    print(f" Paises origen distintos : {len(countries):,}")

    table(src_ips, total, "IPs ORIGEN mas frecuentes")
    table(dst_ports, total, "PUERTOS DESTINO mas atacados", width=42,
          annotate=lambda port: classify_port(port) if isinstance(port, int) else "")
    table(countries, total, "PAISES de origen (codigo ISO-3 de GCP)")
    table(protos, total, "PROTOCOLOS",
          annotate=lambda x: PROTOCOLS.get(x, f"protocolo IP {x}"))
    table(dst_ips, total, "IPs DESTINO alcanzadas (nodos del cluster)")
    table(rules, total, "REGLAS de firewall que rechazaron")

    print("\n" + "=" * 70)
    print(" INTERPRETACION")
    print("=" * 70)
    print(f"  Trafico al rango NodePort de K8s (30000-32767): {nodeport_hits:,} "
          f"({100.0 * nodeport_hits / total:.1f} %)")
    print(f"  Trafico a puertos de servicios conocidos      : {wellknown_hits:,} "
          f"({100.0 * wellknown_hits / total:.1f} %)")
    print()
    if src_ips:
        top_ip, top_n = src_ips.most_common(1)[0]
        conc = 100.0 * top_n / total
        print(f"  Concentracion: la IP mas activa ({top_ip}) genera el {conc:.1f} %")
        print(f"  del trafico rechazado.")
        if conc > 50:
            print("  -> Alta concentracion: sugiere un origen dirigido, no ruido difuso.")
        elif len(src_ips) > total / 10:
            print("  -> Muy disperso (muchas IPs, pocas conexiones cada una): patron")
            print("     tipico de escaneo de fondo de internet, no de un ataque dirigido.")
    print()
    print("  NOTA: la regla deny_all_logged tiene prioridad 65534 y source_ranges")
    print("  0.0.0.0/0, asi que captura TODO lo que ninguna regla mas especifica")
    print("  permitio. Un volumen alto NO implica por si solo un ataque -- implica")
    print("  que el mecanismo de deteccion funciona. La distribucion de arriba es")
    print("  lo que permite distinguir escaneo dirigido de ruido de fondo.")
    print("=" * 70)

    burst_analysis(entries, args.alert_threshold, len(src_ips))


if __name__ == "__main__":
    main()
