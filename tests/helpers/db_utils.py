"""
db_utils.py – Reusable helper functions for database interactions in tests.

All functions accept a pyodbc connection or cursor and operate on the
test database.

tSQLt runner helpers
--------------------
run_tsqlt_class  – Execute a tSQLt test class and store results.
get_tsqlt_results – Return all results for a tSQLt class from the last run.
"""

from __future__ import annotations
from typing import Any


# ---------------------------------------------------------------------------
# tSQLt runner helpers
# ---------------------------------------------------------------------------

def run_tsqlt_class(conn, class_name: str) -> None:
    """
    Execute all tests in a tSQLt class.

    Results are stored in ``tSQLt.TestResult`` and can be retrieved with
    :func:`get_tsqlt_results`.  Individual test failures do NOT raise a
    Python exception; use :func:`get_tsqlt_results` to inspect outcomes.
    """
    cursor = conn.cursor()
    try:
        cursor.execute(f"EXEC tSQLt.Run '{class_name}'")
        # Consume any remaining result sets so the connection is left clean
        while cursor.nextset():
            pass
    finally:
        cursor.close()


def get_tsqlt_results(conn, class_name: str) -> list[dict[str, Any]]:
    """
    Return all rows from ``tSQLt.TestResult`` for *class_name* as a list
    of dicts with keys ``Name``, ``Result``, and ``Msg``.
    """
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            SELECT Name, Result, Msg
            FROM   tSQLt.TestResult
            WHERE  Class = ?
            """,
            class_name,
        )
        columns = [desc[0] for desc in cursor.description]
        return [dict(zip(columns, row)) for row in cursor.fetchall()]
    finally:
        cursor.close()


# ---------------------------------------------------------------------------
# Insert helpers
# ---------------------------------------------------------------------------

def insert_staging_parent(cursor) -> int:
    """Insert a row into dbo.STAGING and return its generated ID."""
    cursor.execute("INSERT INTO dbo.STAGING DEFAULT VALUES")
    cursor.execute("SELECT SCOPE_IDENTITY()")
    return int(cursor.fetchone()[0])


def insert_staging_folder(
    cursor,
    staging_id: int,
    folder_if_unmodified_since: str | None = None,
    folder_folder_id: str = "FOLDER-001",
    folder_state_code: str = "ACTIVE",
    folder_type_code: str = "TYPE-A",
    folder_description: str = "Test Folder",
    folder_owner_entity_id: str = "ENTITY-001",
    is_processed: str = "N",
) -> None:
    """Insert a row into dbo.STAGING_FOLDERS."""
    cursor.execute(
        """
        INSERT INTO dbo.STAGING_FOLDERS
            (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
             folderTypeCode, folderDescription, folderOwnerEntityId,
             staging_id, Is_Processed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        folder_if_unmodified_since,
        folder_folder_id,
        folder_state_code,
        folder_type_code,
        folder_description,
        folder_owner_entity_id,
        staging_id,
        is_processed,
    )


def insert_hash_registry(
    cursor,
    entity_name: str,
    row_hash: bytes,
    age_seconds: int = 60,
) -> None:
    """
    Insert a hash into dbo.HASH_REGISTRY with timestamps backdated by
    *age_seconds* so it appears older than the current SP run timestamp.
    """
    cursor.execute(
        """
        INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
        VALUES (
            ?,
            ?,
            DATEADD(SECOND, ?, SYSUTCDATETIME()),
            DATEADD(SECOND, ?, SYSUTCDATETIME())
        )
        """,
        entity_name,
        row_hash,
        -age_seconds,
        -age_seconds,
    )


# ---------------------------------------------------------------------------
# Execute stored procedures
# ---------------------------------------------------------------------------

def exec_usp_delta_folders(cursor) -> None:
    """Execute dbo.USP_DELTA_FOLDERS."""
    cursor.execute("EXEC dbo.USP_DELTA_FOLDERS")


def exec_usp_delta_master(cursor) -> None:
    """Execute dbo.USP_DELTA_MASTER."""
    cursor.execute("EXEC dbo.USP_DELTA_MASTER")


# ---------------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------------

def get_latest_log(cursor, entity_name: str = "FOLDERS") -> dict[str, Any] | None:
    """Return the most recent SYS_DELTA_LOG row for *entity_name* as a dict."""
    cursor.execute(
        """
        SELECT TOP 1 *
        FROM dbo.SYS_DELTA_LOG
        WHERE entity_name = ?
        ORDER BY log_id DESC
        """,
        entity_name,
    )
    row = cursor.fetchone()
    if row is None:
        return None
    columns = [desc[0] for desc in cursor.description]
    return dict(zip(columns, row))


def get_target_folders_count(cursor) -> int:
    """Return the number of rows in dbo.TARGET_FOLDERS."""
    cursor.execute("SELECT COUNT(*) FROM dbo.TARGET_FOLDERS")
    return cursor.fetchone()[0]


def get_hash_registry_count(cursor, entity_name: str = "FOLDERS") -> int:
    """Return the number of hash rows in dbo.HASH_REGISTRY for *entity_name*."""
    cursor.execute(
        "SELECT COUNT(*) FROM dbo.HASH_REGISTRY WHERE entity_name = ?",
        entity_name,
    )
    return cursor.fetchone()[0]


def get_processed_staging_count(cursor) -> int:
    """Return the number of STAGING_FOLDERS rows where Is_Processed = 'Y'."""
    cursor.execute("SELECT COUNT(*) FROM dbo.STAGING_FOLDERS WHERE Is_Processed = 'Y'")
    return cursor.fetchone()[0]


def get_unprocessed_staging_count(cursor) -> int:
    """Return the number of STAGING_FOLDERS rows where Is_Processed = 'N'."""
    cursor.execute("SELECT COUNT(*) FROM dbo.STAGING_FOLDERS WHERE Is_Processed = 'N'")
    return cursor.fetchone()[0]


def compute_folder_hash(
    cursor,
    folder_if_unmodified_since: str | None,
    folder_folder_id: str | None,
    folder_state_code: str | None,
    folder_type_code: str | None,
    folder_description: str | None,
    folder_owner_entity_id: str | None,
) -> bytes:
    """
    Compute the SHA2-256 hash exactly as USP_DELTA_FOLDERS does, so test
    setup can pre-insert matching hashes into HASH_REGISTRY.
    """
    cursor.execute(
        """
        SELECT HASHBYTES(
            'SHA2_256',
            CONVERT(
                VARBINARY(8000),
                CONCAT_WS('|',
                    ISNULL(?, ''),
                    ISNULL(?, ''),
                    ISNULL(?, ''),
                    ISNULL(?, ''),
                    ISNULL(?, ''),
                    ISNULL(?, '')
                )
            )
        )
        """,
        folder_if_unmodified_since,
        folder_folder_id,
        folder_state_code,
        folder_type_code,
        folder_description,
        folder_owner_entity_id,
    )
    return cursor.fetchone()[0]


def get_log_count(cursor) -> int:
    """Return total number of rows in dbo.SYS_DELTA_LOG."""
    cursor.execute("SELECT COUNT(*) FROM dbo.SYS_DELTA_LOG")
    return cursor.fetchone()[0]
