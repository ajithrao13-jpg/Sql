package com.delta;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

/**
 * TestUspDeltaMaster
 * ==================
 * Unit tests for the {@code [dbo].[USP_DELTA_MASTER]} stored procedure.
 *
 * {@code USP_DELTA_MASTER} is an orchestrator that calls every entity-level
 * delta SP in sequence. Each sub-call is wrapped in {@code BEGIN TRY … END
 * CATCH} so that individual failures are swallowed and execution continues.
 *
 * Test catalogue
 * --------------
 * TC01  Procedure executes without raising an exception.
 * TC02  Sub-procedure failures (non-existent SPs) do NOT stop execution –
 *       the master completes and USP_DELTA_FOLDERS is still invoked.
 * TC03  When STAGING_FOLDERS has data, running USP_DELTA_MASTER causes
 *       USP_DELTA_FOLDERS to process it (end-to-end integration check).
 */
@DisplayName("USP_DELTA_MASTER Tests")
class TestUspDeltaMaster extends BaseTest {

    // -------------------------------------------------------------------------
    // TC01 – Master procedure executes without error
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC01: USP_DELTA_MASTER completes successfully (no unhandled exception)")
    void testMasterExecutesWithoutError() {
        assertDoesNotThrow(() -> DbUtils.execUspDeltaMaster(conn));
    }

    // -------------------------------------------------------------------------
    // TC02 – Sub-procedure failures do not stop the master
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC02: USP_DELTA_MASTER continues after missing sub-procedures")
    void testMasterContinuesAfterMissingSubProcedures() throws Exception {
        // Run with an empty staging table (USP_DELTA_FOLDERS will finish cleanly)
        DbUtils.execUspDeltaMaster(conn);

        // USP_DELTA_FOLDERS is the only real sub-proc; verify it logged SUCCESS
        Map<String, Object> log = DbUtils.getLatestLog(conn, "FOLDERS");
        assertNotNull(log, "USP_DELTA_FOLDERS should have logged an entry");
        assertEquals("SUCCESS", log.get("status"));
    }

    // -------------------------------------------------------------------------
    // TC03 – Master delegates to USP_DELTA_FOLDERS end-to-end
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC03: USP_DELTA_MASTER triggers USP_DELTA_FOLDERS processing end-to-end")
    void testMasterTriggersFoldersProcessing() throws Exception {
        long stagingId = DbUtils.insertStagingParent(conn);
        DbUtils.insertStagingFolder(conn, stagingId, "MASTER-F001");
        DbUtils.insertStagingFolder(conn, stagingId, "MASTER-F002");

        DbUtils.execUspDeltaMaster(conn);

        // Both rows should have been processed via USP_DELTA_FOLDERS
        assertEquals(2, DbUtils.getTargetFoldersCount(conn));

        Map<String, Object> log = DbUtils.getLatestLog(conn, "FOLDERS");
        assertEquals("SUCCESS", log.get("status"));
        assertEquals(2, log.get("rows_upserted"));
    }
}
