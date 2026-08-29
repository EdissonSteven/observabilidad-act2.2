"""Acceso a datos de data-service (Cloud SQL / RDS PostgreSQL en despliegue
real; Postgres local en docker-compose para desarrollo/validación).

Además de la conexión, expone `DB_SEMCONV_ATTRS`: los atributos de span
recomendados/condicionalmente-requeridos por las OTel Database Semantic
Conventions vigentes
(https://opentelemetry.io/docs/specs/semconv/db/database-spans/) que
`Psycopg2Instrumentor` NO añade automáticamente en esta versión del paquete
(0.46b0 solo cubre `db.system`/`db.statement`, todavía con el nombre
pre-1.23 de la convención). Se calculan una sola vez a partir de
`DATABASE_URL` y se adjuntan a mano en cada span de negocio en main.py.
"""
from __future__ import annotations

import os
from urllib.parse import urlparse

import psycopg2
import psycopg2.extras

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://app:secret@localhost:5432/appdb")

_parsed = urlparse(DATABASE_URL)

# Atributos estables de las OTel DB Semantic Conventions (db/database-spans.md):
#   db.system.name   -- identificador del motor (valor fijo: "postgresql")
#   db.namespace     -- nombre de la base de datos, calificado con host:puerto
#   server.address   -- host del servidor de base de datos
#   server.port      -- puerto, solo si no es el default (5432 sí lo es, pero
#                        se incluye igual por trazabilidad explícita en un
#                        entorno multi-nube donde el puerto puede cambiar)
DB_SEMCONV_ATTRS = {
    "db.system.name": "postgresql",
    "db.namespace": (_parsed.path or "/appdb").lstrip("/"),
    "server.address": _parsed.hostname or "localhost",
    "server.port": _parsed.port or 5432,
}


def get_connection():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)
