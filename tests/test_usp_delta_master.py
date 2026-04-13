"""
test_usp_delta_master.py
========================
Runs the tSQLt test class [TestUSPDeltaMaster] via pyodbc and surfaces
each individual tSQLt test result as a pytest test case.

The actual test logic lives in T-SQL inside
``tests/sql/04_tsqlt_tests_master.sql``.

Test catalogue (defined in the SQL file)
-----------------------------------------
TC01  Procedure executes without raising an exception.
TC02  Sub-procedure failures (non-existent SPs) do NOT stop execution –
      the master completes and USP_DELTA_FOLDERS is still invoked.
TC03  When STAGING_FOLDERS has data, running USP_DELTA_MASTER causes
      USP_DELTA_FOLDERS to process it (end-to-end integration check).
"""

from __future__ import annotations

import pytest

from tests.helpers.db_utils import run_tsqlt_class, get_tsqlt_results

TSQLT_CLASS = "TestUSPDeltaMaster"


class TestUSPDeltaMaster:
    """Runs the tSQLt test class TestUSPDeltaMaster and reports each result."""

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

    def test_TC01_master_executes_without_error(self, db_conn):
        self._assert_test(db_conn, "TC01")

    def test_TC02_master_continues_after_missing_sub_procedures(self, db_conn):
        self._assert_test(db_conn, "TC02")

    def test_TC03_master_triggers_folders_processing(self, db_conn):
        self._assert_test(db_conn, "TC03")
