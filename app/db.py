"""Database connection management."""

from __future__ import annotations

from contextlib import contextmanager
import os
from typing import Iterator

import psycopg2
import psycopg2.extras


def database_dsn() -> str:
    dsn = os.environ.get("ANALYTICS_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if dsn:
        return dsn

    host = os.environ.get("DB_HOST")
    password = os.environ.get("DB_PASS")
    if not host or not password:
        raise RuntimeError("Set ANALYTICS_DATABASE_URL, DATABASE_URL, or DB_HOST/DB_PASS for analytics-api.")

    user = os.environ.get("DB_USER", "fpds_analytics_api_readonly")
    port = os.environ.get("DB_PORT", "5432")
    name = os.environ.get("DB_NAME", "postgres")
    return f"host={host} port={port} dbname={name} user={user} password={password} connect_timeout=10"


@contextmanager
def db_cursor(read_only: bool = True) -> Iterator[psycopg2.extensions.cursor]:
    """Open a database cursor.

    Args:
        read_only: If True (default), sets the transaction to read-only.
            Set to False for operations that need writes, such as
            api_admin.validate_api_key() which updates rate-limit counters.
    """
    conn = psycopg2.connect(database_dsn(), cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        with conn:
            with conn.cursor() as cur:
                statement_timeout = os.environ.get("FPDS_ANALYTICS_STATEMENT_TIMEOUT", "45s")
                cur.execute("set local statement_timeout = %s", (statement_timeout,))
                if read_only:
                    cur.execute("set local default_transaction_read_only = on")
                yield cur
    finally:
        conn.close()
