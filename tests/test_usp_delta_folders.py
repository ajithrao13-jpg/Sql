"""
test_usp_delta_folders.py
=========================
Runs the tSQLt test class [TestUSPDeltaFolders] via pyodbc and surfaces
each individual tSQLt test result as a pytest test case.

The actual test logic lives in T-SQL inside
``tests/sql/03_tsqlt_tests_folders.sql``.  This file is the thin Python
runner that:

  1. Executes ``EXEC tSQLt.Run 'TestUSPDeltaFolders'`` against the live
     SQL Server test database.
  2. Queries ``tSQLt.TestResult`` for the outcome of each procedure.
  3. Fails the corresponding pytest test if tSQLt recorded a failure or
     error for it.

Test catalogue (defined in the SQL file)
-----------------------------------------
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

from tests.helpers.db_utils import run_tsqlt_class, get_tsqlt_results

TSQLT_CLASS = "TestUSPDeltaFolders"


class TestUSPDeltaFolders:
    """Runs the tSQLt test class TestUSPDeltaFolders and reports each result."""

    @pytest.fixture(autouse=True, scope="class")
    def _run_tsqlt(self, db_conn):
        """Execute the tSQLt class once for the whole pytest class."""
        run_tsqlt_class(db_conn, TSQLT_CLASS)

    def _assert_test(self, db_conn, test_name: str) -> None:
        results = get_tsqlt_results(db_conn, TSQLT_CLASS)
        match = next(
            (r for r in results if test_name.lower() in r["Name"].lower()),
            None,
        )
        if match is None:
            pytest.fail(f"tSQLt test '{test_name}' not found in results.")
        if match["Result"] != "Success":
            pytest.fail(
                f"tSQLt test '{match['Name']}' {match['Result']}: {match['Msg']}"
            )

    def test_TC01_empty_staging_logs_success(self, db_conn):
        self._assert_test(db_conn, "TC01")

    def test_TC02_single_new_row_inserted_to_target(self, db_conn):
        self._assert_test(db_conn, "TC02")

    def test_TC03_staging_row_marked_as_processed(self, db_conn):
        self._assert_test(db_conn, "TC03")

    def test_TC04_duplicate_staging_rows_deduped(self, db_conn):
        self._assert_test(db_conn, "TC04")

    def test_TC05_unchanged_row_not_reinserted(self, db_conn):
        self._assert_test(db_conn, "TC05")

    def test_TC06_old_hashes_retired(self, db_conn):
        self._assert_test(db_conn, "TC06")

    def test_TC07_log_captures_all_metrics(self, db_conn):
        self._assert_test(db_conn, "TC07")

    def test_TC08_already_processed_rows_ignored(self, db_conn):
        self._assert_test(db_conn, "TC08")

    def test_TC09_mixed_new_and_unchanged_rows(self, db_conn):
        self._assert_test(db_conn, "TC09")

    def test_TC10_log_entry_records_entity_name(self, db_conn):
        self._assert_test(db_conn, "TC10")
