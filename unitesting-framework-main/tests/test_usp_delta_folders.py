"""
test_usp_delta_folders.py
=========================
Unit tests for the [dbo].[USP_DELTA_FOLDERS] stored procedure.

Each test exercises one distinct behaviour path of the SP.  The
``clean_tables`` autouse fixture (conftest.py) ensures a clean state
before every test.

Test catalogue
--------------
TC01  Empty staging table            → early-exit with SUCCESS, input_row_count=0
TC02  Single new row                 → inserted into TARGET_FOLDERS & HASH_REGISTRY
TC03  Staging row marked processed   → Is_Processed flipped to 'Y'
TC04  Duplicate rows deduplication   → only first occurrence processed; rows_deduped counted
TC05  Unchanged row (hash pre-exists)→ rows_unchanged=1, no new TARGET insert
TC06  Old hashes retired             → rows not in current batch deleted from HASH_REGISTRY
TC07  Metrics captured in log        → all counters correct for a mixed batch
TC08  Already-processed rows ignored → Is_Processed='Y' rows not re-counted
TC09  Mixed batch (new + unchanged)  → correct per-category counts
TC10  Log entry entity name          → SYS_DELTA_LOG always records entity_name='FOLDERS'
"""

from __future__ import annotations

import pytest

from tests.helpers.db_utils import (
    compute_folder_hash,
    exec_usp_delta_folders,
    get_hash_registry_count,
    get_latest_log,
    get_log_count,
    get_processed_staging_count,
    get_target_folders_count,
    get_unprocessed_staging_count,
    insert_hash_registry,
    insert_staging_folder,
    insert_staging_parent,
)


class TestUSPDeltaFolders:
    """Integration tests for USP_DELTA_FOLDERS."""

    # ------------------------------------------------------------------
    # TC01 – Empty staging table
    # ------------------------------------------------------------------
    def test_empty_staging_logs_success(self, db_conn):
        """TC01: With no unprocessed rows the SP exits early with SUCCESS."""
        cursor = db_conn.cursor()

        exec_usp_delta_folders(cursor)

        log = get_latest_log(cursor)
        assert log is not None, "Expected a log entry to be created"
        assert log["status"] == "SUCCESS"
        assert log["input_row_count"] == 0
        assert log["rows_upserted"] == 0
        assert log["rows_unchanged"] == 0
        assert log["rows_deduped"] == 0
        assert log["rows_retired"] == 0

        cursor.close()

    # ------------------------------------------------------------------
    # TC02 – Single new row inserted into TARGET_FOLDERS
    # ------------------------------------------------------------------
    def test_single_new_row_inserted_to_target(self, db_conn):
        """TC02: One new staging row → inserted into TARGET_FOLDERS and HASH_REGISTRY."""
        cursor = db_conn.cursor()

        staging_id = insert_staging_parent(cursor)
        insert_staging_folder(cursor, staging_id=staging_id)

        exec_usp_delta_folders(cursor)

        assert get_target_folders_count(cursor) == 1
        assert get_hash_registry_count(cursor) == 1

        log = get_latest_log(cursor)
        assert log["status"] == "SUCCESS"
        assert log["input_row_count"] == 1
        assert log["rows_upserted"] == 1
        assert log["rows_unchanged"] == 0

        cursor.close()

    # ------------------------------------------------------------------
    # TC03 – Staging row Is_Processed flag is set to 'Y'
    # ------------------------------------------------------------------
    def test_staging_row_marked_as_processed(self, db_conn):
        """TC03: After a successful run all staging rows are flipped to Is_Processed='Y'."""
        cursor = db_conn.cursor()

        staging_id = insert_staging_parent(cursor)
        insert_staging_folder(cursor, staging_id=staging_id, folder_folder_id="F001")
        insert_staging_folder(cursor, staging_id=staging_id, folder_folder_id="F002")

        assert get_unprocessed_staging_count(cursor) == 2

        exec_usp_delta_folders(cursor)

        assert get_processed_staging_count(cursor) == 2
        assert get_unprocessed_staging_count(cursor) == 0

        cursor.close()

    # ------------------------------------------------------------------
    # TC04 – Duplicate rows in staging are deduplicated
    # ------------------------------------------------------------------
    def test_duplicate_staging_rows_deduped(self, db_conn):
        """TC04: Three identical rows → one TARGET insert; rows_deduped=2."""
        cursor = db_conn.cursor()

        staging_id = insert_staging_parent(cursor)
        for _ in range(3):
            insert_staging_folder(
                cursor,
                staging_id=staging_id,
                folder_folder_id="DUP-001",
                folder_description="Duplicate",
            )

        exec_usp_delta_folders(cursor)

        assert get_target_folders_count(cursor) == 1
        assert get_hash_registry_count(cursor) == 1

        log = get_latest_log(cursor)
        assert log["input_row_count"] == 3
        assert log["rows_deduped"] == 2
        assert log["rows_upserted"] == 1

        cursor.close()

    # ------------------------------------------------------------------
    # TC05 – Unchanged row (hash already in HASH_REGISTRY)
    # ------------------------------------------------------------------
    def test_unchanged_row_not_reinserted(self, db_conn):
        """TC05: A row whose hash already exists → rows_unchanged=1, no new TARGET row."""
        cursor = db_conn.cursor()

        folder_folder_id = "KNOWN-001"
        staging_id = insert_staging_parent(cursor)
        insert_staging_folder(
            cursor,
            staging_id=staging_id,
            folder_folder_id=folder_folder_id,
        )

        # Pre-insert the matching hash to simulate a previous run
        row_hash = compute_folder_hash(
            cursor,
            None,            # folderIfUnmodifiedSince
            folder_folder_id,
            "ACTIVE",
            "TYPE-A",
            "Test Folder",
            "ENTITY-001",
        )
        insert_hash_registry(cursor, "FOLDERS", row_hash, age_seconds=60)

        exec_usp_delta_folders(cursor)

        assert get_target_folders_count(cursor) == 0, "Hash already known – no new TARGET row"
        assert get_hash_registry_count(cursor) == 1, "Hash registry count must remain 1"

        log = get_latest_log(cursor)
        assert log["rows_unchanged"] == 1
        assert log["rows_upserted"] == 0

        cursor.close()

    # ------------------------------------------------------------------
    # TC06 – Old hashes are retired
    # ------------------------------------------------------------------
    def test_old_hashes_retired(self, db_conn):
        """TC06: A hash from a prior run that is absent in this batch is deleted."""
        cursor = db_conn.cursor()

        # Insert a stale hash into the registry (not part of the current batch)
        stale_hash = b"\x00" * 32  # Arbitrary 32-byte value
        insert_hash_registry(cursor, "FOLDERS", stale_hash, age_seconds=120)

        # New, different staging row
        staging_id = insert_staging_parent(cursor)
        insert_staging_folder(
            cursor,
            staging_id=staging_id,
            folder_folder_id="NEW-AFTER-RETIRE",
        )

        exec_usp_delta_folders(cursor)

        # After the run there should be exactly 1 hash (the new one)
        assert get_hash_registry_count(cursor) == 1

        log = get_latest_log(cursor)
        assert log["rows_retired"] == 1, "Stale hash must be counted as retired"

        cursor.close()

    # ------------------------------------------------------------------
    # TC07 – All metrics captured correctly in a multi-row batch
    # ------------------------------------------------------------------
    def test_log_captures_all_metrics(self, db_conn):
        """TC07: input_row_count, rows_upserted, rows_unchanged, rows_deduped, rows_retired."""
        cursor = db_conn.cursor()

        staging_id = insert_staging_parent(cursor)

        # One row whose hash pre-exists (→ unchanged)
        existing_folder_id = "EXIST-001"
        existing_hash = compute_folder_hash(
            cursor, None, existing_folder_id, "ACTIVE", "TYPE-A", "Test Folder", "ENTITY-001"
        )
        insert_hash_registry(cursor, "FOLDERS", existing_hash, age_seconds=60)
        insert_staging_folder(cursor, staging_id=staging_id, folder_folder_id=existing_folder_id)

        # Two new distinct rows (→ upserted=2)
        insert_staging_folder(cursor, staging_id=staging_id, folder_folder_id="NEW-001")
        insert_staging_folder(cursor, staging_id=staging_id, folder_folder_id="NEW-002")

        # One duplicate of NEW-001 (→ deduped=1)
        insert_staging_folder(cursor, staging_id=staging_id, folder_folder_id="NEW-001")

        exec_usp_delta_folders(cursor)

        log = get_latest_log(cursor)
        assert log["status"] == "SUCCESS"
        assert log["input_row_count"] == 4   # 1 existing + 2 new + 1 dup
        assert log["rows_unchanged"] == 1
        assert log["rows_upserted"] == 2
        assert log["rows_deduped"] == 1
        assert log["rows_retired"] == 0      # existing hash was updated, not retired

        cursor.close()

    # ------------------------------------------------------------------
    # TC08 – Already-processed rows are ignored
    # ------------------------------------------------------------------
    def test_already_processed_rows_ignored(self, db_conn):
        """TC08: Rows with Is_Processed='Y' are not counted by the SP."""
        cursor = db_conn.cursor()

        staging_id = insert_staging_parent(cursor)
        # Insert rows that are already processed
        insert_staging_folder(
            cursor, staging_id=staging_id, folder_folder_id="OLD-Y", is_processed="Y"
        )
        insert_staging_folder(
            cursor, staging_id=staging_id, folder_folder_id="OLD-Y2", is_processed="Y"
        )

        exec_usp_delta_folders(cursor)

        log = get_latest_log(cursor)
        assert log["status"] == "SUCCESS"
        assert log["input_row_count"] == 0    # SP sees nothing unprocessed
        assert get_target_folders_count(cursor) == 0

        cursor.close()

    # ------------------------------------------------------------------
    # TC09 – Mixed batch: new rows + unchanged rows
    # ------------------------------------------------------------------
    def test_mixed_new_and_unchanged_rows(self, db_conn):
        """TC09: 2 new rows + 1 pre-existing hash → upserted=2, unchanged=1."""
        cursor = db_conn.cursor()

        staging_id = insert_staging_parent(cursor)

        # Pre-existing hash
        known_id = "MIX-KNOWN"
        known_hash = compute_folder_hash(
            cursor, None, known_id, "ACTIVE", "TYPE-A", "Test Folder", "ENTITY-001"
        )
        insert_hash_registry(cursor, "FOLDERS", known_hash, age_seconds=60)
        insert_staging_folder(cursor, staging_id=staging_id, folder_folder_id=known_id)

        # Two genuinely new rows
        insert_staging_folder(cursor, staging_id=staging_id, folder_folder_id="MIX-NEW-1")
        insert_staging_folder(cursor, staging_id=staging_id, folder_folder_id="MIX-NEW-2")

        exec_usp_delta_folders(cursor)

        assert get_target_folders_count(cursor) == 2

        log = get_latest_log(cursor)
        assert log["rows_upserted"] == 2
        assert log["rows_unchanged"] == 1
        assert log["input_row_count"] == 3

        cursor.close()

    # ------------------------------------------------------------------
    # TC10 – Log entry always records the correct entity name
    # ------------------------------------------------------------------
    def test_log_entry_records_entity_name(self, db_conn):
        """TC10: SYS_DELTA_LOG rows always carry entity_name='FOLDERS'."""
        cursor = db_conn.cursor()

        exec_usp_delta_folders(cursor)

        log = get_latest_log(cursor)
        assert log is not None
        assert log["entity_name"] == "FOLDERS"
        assert get_log_count(cursor) >= 1

        cursor.close()
