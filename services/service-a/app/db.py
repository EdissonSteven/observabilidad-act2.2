import os

import psycopg2
import psycopg2.extras

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://app:secret@localhost:5432/appdb")


def get_connection():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)
