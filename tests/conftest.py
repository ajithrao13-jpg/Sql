"""
conftest.py – pytest fixtures shared across all test modules.

Provides:
  db_conn – session-scoped pyodbc connection (autocommit=True).

Table cleanup is handled by tSQLt: each test procedure runs inside a
savepoint that is rolled back after the test, so no Python-level cleanup
is needed between tests.
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

    autocommit=True so that tSQLt's internal transaction management
    (savepoints and rollbacks) works correctly without nesting inside
    an outer Python-controlled transaction.
    """
    conn = pyodbc.connect(CONNECTION_STRING, autocommit=True)
    yield conn
    conn.close()
