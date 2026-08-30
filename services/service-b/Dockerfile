FROM python:3.12-slim

WORKDIR /srv

# iproute2 (paquete que trae el binario `tc`) -- necesario para el modo "tc"
# (real, vía tc netem) de chaos/h4_latency_service_b.sh, Módulo D
# Experimento 1. Hallazgo real (2026-08-30): sin este paquete, `kubectl exec
# ... -- tc qdisc add ...` falla con "tc: command not found" en el pod real
# de GKE -- el modo "tc" nunca había sido viable con esta imagen hasta este
# fix (el comentario original de h4_latency_service_b.sh que decía que ya
# se había probado se refería a una imagen anterior, no a esta). El modo
# "env" (INJECT_LATENCY_MS) sigue siendo el fallback que no depende de este
# paquete -- ver el propio script para el porqué de los dos modos.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8001 9091

HEALTHCHECK --interval=10s --timeout=5s --retries=5 \
    CMD curl -f http://localhost:8001/health || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001"]
