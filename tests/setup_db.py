"""
setup_db.py – Bootstrap script executed once before the test suite.

Responsibilities:
  1. Wait for SQL Server to become available.
  2. Create the test database if it does not already exist.
  3. Enable CLR and mark the database as trustworthy (required by tSQLt).
  4. Download and install tSQLt if it is not already present.
  5. Execute DDL scripts (tables → stored procedures → tSQLt tests) inside
     the test DB.

Usage:
    python tests/setup_db.py
"""

from __future__ import annotations

import io
import os
import re
import sys
import time
import urllib.request
import zipfile

import pyodbc

# ---------------------------------------------------------------------------
# Configuration (all values overridable via environment variables)
# ---------------------------------------------------------------------------
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "1433")
DB_NAME = os.environ.get("DB_NAME", "TestDB")
DB_USER = os.environ.get("DB_USER", "sa")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "Str0ngPass!2024")

# tSQLt release to install (set TSQLT_DOWNLOAD_URL to override)
TSQLT_DOWNLOAD_URL = os.environ.get(
    "TSQLT_DOWNLOAD_URL",
    "https://github.com/tSQLt-org/tSQLt/releases/download/v1.0.8317.15834/tSQLt.zip",
)

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

# SQL files that define schema/procedures (run before tSQLt tests)
SCHEMA_SQL_PATTERN = re.compile(r"^0[12]_.*\.sql$", re.IGNORECASE)
# SQL files that define tSQLt test classes (run after tSQLt is installed)
TEST_SQL_PATTERN = re.compile(r"^0[3-9]_.*\.sql$|^\d{2,}_.*\.sql$", re.IGNORECASE)


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


def execute_sql_text(cursor, sql: str) -> None:
    """Split *sql* on GO and execute each batch."""
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


def tsqlt_is_installed(cursor) -> bool:
    """Return True if the tSQLt schema already exists in the current database."""
    cursor.execute(
        "SELECT 1 FROM sys.schemas WHERE name = 'tSQLt'"
    )
    return cursor.fetchone() is not None


def install_tsqlt(cursor) -> None:
    """Download tSQLt and execute its install script against the current DB."""
    print(f"  Downloading tSQLt from {TSQLT_DOWNLOAD_URL} ...")
    with urllib.request.urlopen(TSQLT_DOWNLOAD_URL, timeout=120) as response:
        zip_data = response.read()

    with zipfile.ZipFile(io.BytesIO(zip_data)) as zf:
        # The install script is always named tSQLt.class.sql inside the zip
        install_name = next(
            name for name in zf.namelist()
            if name.lower().endswith("tsqlt.class.sql")
        )
        install_sql = zf.read(install_name).decode("utf-8")

    print("  Installing tSQLt ...")
    execute_sql_text(cursor, install_sql)
    print("  tSQLt installed successfully.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def setup() -> None:
    if not wait_for_sql_server():
        print("ERROR: SQL Server did not become available in time.", file=sys.stderr)
        sys.exit(1)

    # ── Create test database ────────────────────────────────────────────────
    conn = pyodbc.connect(MASTER_CONN_STR, autocommit=True)
    cursor = conn.cursor()
    cursor.execute(
        f"IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'{DB_NAME}')"
        f"    CREATE DATABASE [{DB_NAME}];"
    )
    # tSQLt requires CLR enabled at the server level and TRUSTWORTHY on the DB
    cursor.execute("EXEC sp_configure 'show advanced options', 1; RECONFIGURE;")
    cursor.execute("EXEC sp_configure 'clr enabled', 1; RECONFIGURE;")
    cursor.execute("EXEC sp_configure 'clr strict security', 0; RECONFIGURE;")
    cursor.execute(f"ALTER DATABASE [{DB_NAME}] SET TRUSTWORTHY ON;")
    conn.close()
    print(f"Database '{DB_NAME}' is ready.")

    # ── Execute schema DDL scripts (01_create_tables, 02_create_procedures) ─
    conn = pyodbc.connect(TEST_CONN_STR, autocommit=True)
    cursor = conn.cursor()
    for filename in sorted(os.listdir(SQL_DIR)):
        if filename.lower().endswith(".sql") and SCHEMA_SQL_PATTERN.match(filename):
            filepath = os.path.join(SQL_DIR, filename)
            print(f"Executing schema script: {filepath} ...")
            execute_sql_file(cursor, filepath)
    conn.close()

    # ── Install tSQLt ───────────────────────────────────────────────────────
    conn = pyodbc.connect(TEST_CONN_STR, autocommit=True)
    cursor = conn.cursor()
    if tsqlt_is_installed(cursor):
        print("tSQLt is already installed, skipping.")
    else:
        install_tsqlt(cursor)
    conn.close()

    # ── Execute tSQLt test-class SQL files (03_… and above) ─────────────────
    conn = pyodbc.connect(TEST_CONN_STR, autocommit=True)
    cursor = conn.cursor()
    for filename in sorted(os.listdir(SQL_DIR)):
        if filename.lower().endswith(".sql") and TEST_SQL_PATTERN.match(filename):
            filepath = os.path.join(SQL_DIR, filename)
            print(f"Executing tSQLt test script: {filepath} ...")
            execute_sql_file(cursor, filepath)
    conn.close()

    print("Database setup complete.")


if __name__ == "__main__":
    setup()
