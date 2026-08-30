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


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--project", help="Proyecto de GCP (lee de Cloud Logging)")
    src.add_argument("--input", help="Archivo JSON ya volcado con gcloud logging read")
    p.add_argument("--freshness", default="6h", help="Ventana de tiempo (default 6h)")
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


if __name__ == "__main__":
    main()
