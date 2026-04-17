"""
setup_db.py – Bootstrap script executed once before the test suite.

Responsibilities:
  1. Wait for SQL Server to become available.
  2. Create the test database if it does not already exist.
  3. Execute DDL scripts (tables → stored procedures) inside the test DB.

Usage:
    python tests/setup_db.py
"""

from __future__ import annotations

import os
import re
import sys
import time

import pyodbc

# ---------------------------------------------------------------------------
# Configuration (all values overridable via environment variables)
# ---------------------------------------------------------------------------
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "1433")
DB_NAME = os.environ.get("DB_NAME", "TestDB")
DB_USER = os.environ.get("DB_USER", "sa")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "Str0ngPass!2024")

MASTER_CONN_STR = (
    f"DRIVER={{ODBC Driver 18 for SQL Server}};"
    f"SERVER={DB_HOST},{DB_PORT};"
    "DATABASE=master;"
    f"UID={DB_USER};"
    f"PWD={DB_PASSWORD};"
    "TrustServerCertificate=yes;"
)

TEST_CONN_STR = (
    f"DRIVER={{ODBC Driver 18 for SQL Server}};"
    f"SERVER={DB_HOST},{DB_PORT};"
    f"DATABASE={DB_NAME};"
    f"UID={DB_USER};"
    f"PWD={DB_PASSWORD};"
    "TrustServerCertificate=yes;"
)

SQL_DIR = os.path.join(os.path.dirname(__file__), "sql")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def split_go_batches(sql: str) -> list[str]:
    """Split a T-SQL script on GO batch separators."""
    batches = re.split(r"^\s*GO\s*$", sql, flags=re.MULTILINE | re.IGNORECASE)
    return [b.strip() for b in batches if b.strip()]


def execute_sql_file(cursor, filepath: str) -> None:
    """Read *filepath*, split on GO, and execute each batch."""
    with open(filepath, encoding="utf-8") as fh:
        sql = fh.read()
    for batch in split_go_batches(sql):
        cursor.execute(batch)


def wait_for_sql_server(retries: int = 30, delay: int = 5) -> bool:
    """Poll SQL Server until it accepts a connection or retries are exhausted."""
    print(f"Waiting for SQL Server at {DB_HOST}:{DB_PORT} ...")
    for attempt in range(1, retries + 1):
        try:
            conn = pyodbc.connect(MASTER_CONN_STR, timeout=5, autocommit=True)
            conn.close()
            print(f"  SQL Server is ready (attempt {attempt}).")
            return True
        except Exception as exc:
            print(f"  Attempt {attempt}/{retries} failed: {exc}")
            time.sleep(delay)
    return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def setup() -> None:
    if not wait_for_sql_server():
        print("ERROR: SQL Server did not become available in time.", file=sys.stderr)
        sys.exit(1)

    # Create the test database
    conn = pyodbc.connect(MASTER_CONN_STR, autocommit=True)
    cursor = conn.cursor()
    cursor.execute(
        f"IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'{DB_NAME}')"
        f"    CREATE DATABASE [{DB_NAME}];"
    )
    conn.close()
    print(f"Database '{DB_NAME}' is ready.")

    # Execute DDL scripts in sorted filename order (01_… before 02_…)
    conn = pyodbc.connect(TEST_CONN_STR, autocommit=True)
    cursor = conn.cursor()
    for filename in sorted(os.listdir(SQL_DIR)):
        if filename.lower().endswith(".sql"):
            filepath = os.path.join(SQL_DIR, filename)
            print(f"Executing {filepath} ...")
            execute_sql_file(cursor, filepath)
    conn.close()

    print("Database setup complete.")


if __name__ == "__main__":
    setup()
