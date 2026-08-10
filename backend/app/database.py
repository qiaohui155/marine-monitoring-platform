from __future__ import annotations

from contextlib import contextmanager

import psycopg
from psycopg.rows import dict_row

from .config import DB_CONFIG, database_ready


@contextmanager
def get_connection():
    if not database_ready():
        raise RuntimeError("Database password is not configured. Run configure_database.ps1 first.")

    connection = psycopg.connect(**DB_CONFIG, row_factory=dict_row)
    try:
        yield connection
    finally:
        connection.close()
