"""
test_usp_delta_master.py
========================
Unit tests for the [dbo].[USP_DELTA_MASTER] stored procedure.

USP_DELTA_MASTER is an orchestrator that calls every entity-level delta SP
in sequence.  Each sub-call is wrapped in BEGIN TRY … END CATCH so that
individual failures are swallowed and execution continues.

Test catalogue
--------------
TC01  Procedure executes without raising an exception.
TC02  Sub-procedure failures (non-existent SPs) do NOT stop execution –
      the master completes and USP_DELTA_FOLDERS is still invoked.
TC03  When STAGING_FOLDERS has data, running USP_DELTA_MASTER causes
      USP_DELTA_FOLDERS to process it (end-to-end integration check).
"""

from __future__ import annotations

import pytest

from tests.helpers.db_utils import (
    exec_usp_delta_master,
    get_latest_log,
    get_target_folders_count,
    insert_staging_folder,
    insert_staging_parent,
)


class TestUSPDeltaMaster:
    """Integration tests for USP_DELTA_MASTER."""

    # ------------------------------------------------------------------
    # TC01 – Master procedure executes without error
    # ------------------------------------------------------------------
    def test_master_executes_without_error(self, db_conn):
        """TC01: USP_DELTA_MASTER completes successfully (no unhandled exception)."""
        cursor = db_conn.cursor()

        # Should not raise
        exec_usp_delta_master(cursor)

        cursor.close()

    # ------------------------------------------------------------------
    # TC02 – Sub-procedure failures do not stop the master
    # ------------------------------------------------------------------
    def test_master_continues_after_missing_sub_procedures(self, db_conn):
        """
        TC02: Most sub-procedures do not exist in the test database.
        USP_DELTA_MASTER wraps every call in TRY/CATCH, so 'object not found'
        errors are silently ignored and the master still completes.
        """
        cursor = db_conn.cursor()

        # Run with an empty staging table (USP_DELTA_FOLDERS will finish cleanly)
        exec_usp_delta_master(cursor)

        # USP_DELTA_FOLDERS is the only real sub-proc; verify it logged SUCCESS
        log = get_latest_log(cursor, entity_name="FOLDERS")
        assert log is not None, "USP_DELTA_FOLDERS should have logged an entry"
        assert log["status"] == "SUCCESS"

        cursor.close()

    # ------------------------------------------------------------------
    # TC03 – Master delegates to USP_DELTA_FOLDERS end-to-end
    # ------------------------------------------------------------------
    def test_master_triggers_folders_processing(self, db_conn):
        """
        TC03: When STAGING_FOLDERS has unprocessed data, calling USP_DELTA_MASTER
        causes USP_DELTA_FOLDERS to run and insert records into TARGET_FOLDERS.
        """
        cursor = db_conn.cursor()

        # Set up staging data
        staging_id = insert_staging_parent(cursor)
        insert_staging_folder(cursor, staging_id=staging_id, folder_folder_id="MASTER-F001")
        insert_staging_folder(cursor, staging_id=staging_id, folder_folder_id="MASTER-F002")

        exec_usp_delta_master(cursor)

        # Both rows should have been processed via USP_DELTA_FOLDERS
        assert get_target_folders_count(cursor) == 2

        log = get_latest_log(cursor, entity_name="FOLDERS")
        assert log["status"] == "SUCCESS"
        assert log["rows_upserted"] == 2

        cursor.close()
