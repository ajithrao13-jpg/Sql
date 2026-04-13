"""
conftest.py – pytest fixtures shared across all test modules.

Provides:
  db_conn  – session-scoped pyodbc connection (autocommit=True).
  clean_tables – autouse fixture that truncates test tables before every test.
"""

from __future__ import annotations

import os

import pyodbc
import pytest

# ---------------------------------------------------------------------------
# Connection settings (overridden by environment variables in CI)
# ---------------------------------------------------------------------------
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "1433")
DB_NAME = os.environ.get("DB_NAME", "TestDB")
DB_USER = os.environ.get("DB_USER", "sa")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "Str0ngPass!2024")

CONNECTION_STRING = (
    f"DRIVER={{ODBC Driver 18 for SQL Server}};"
    f"SERVER={DB_HOST},{DB_PORT};"
    f"DATABASE={DB_NAME};"
    f"UID={DB_USER};"
    f"PWD={DB_PASSWORD};"
    "TrustServerCertificate=yes;"
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def db_conn():
    """
    Open a single pyodbc connection for the entire test session.

    autocommit=True is used so that:
    - test setup INSERT statements are immediately visible to the SP.
    - the SP's own explicit BEGIN/COMMIT TRANSACTION executes without
      nesting inside an outer test transaction.
    """
    conn = pyodbc.connect(CONNECTION_STRING, autocommit=True)
    yield conn
    conn.close()


@pytest.fixture(autouse=True)
def clean_tables(db_conn):
    """
    Delete all rows from every test table before each test.

    Tables are deleted in child-first order to satisfy FK constraints.
    """
    cursor = db_conn.cursor()
    cursor.execute("DELETE FROM dbo.STAGING_FOLDERS")
    cursor.execute("DELETE FROM dbo.STAGING")
    cursor.execute("DELETE FROM dbo.TARGET_FOLDERS")
    cursor.execute("DELETE FROM dbo.HASH_REGISTRY")
    cursor.execute("DELETE FROM dbo.SYS_DELTA_LOG")
    cursor.close()
    yield
