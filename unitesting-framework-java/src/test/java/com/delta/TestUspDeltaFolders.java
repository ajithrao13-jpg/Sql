package com.delta;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * TestUspDeltaFolders
 * ===================
 * Unit tests for the {@code [dbo].[USP_DELTA_FOLDERS]} stored procedure.
 *
 * Each test exercises one distinct behaviour path of the SP. The
 * {@code cleanTables()} method in {@link BaseTest} ensures a clean state
 * before every test.
 *
 * Test catalogue
 * --------------
 * TC01  Empty staging table             → early-exit with SUCCESS, input_row_count=0
 * TC02  Single new row                  → inserted into TARGET_FOLDERS & HASH_REGISTRY
 * TC03  Staging row marked processed    → Is_Processed flipped to 'Y'
 * TC04  Duplicate rows deduplication    → only first occurrence processed; rows_deduped counted
 * TC05  Unchanged row (hash pre-exists) → rows_unchanged=1, no new TARGET insert
 * TC06  Old hashes retired              → rows not in current batch deleted from HASH_REGISTRY
 * TC07  Metrics captured in log         → all counters correct for a mixed batch
 * TC08  Already-processed rows ignored  → Is_Processed='Y' rows not re-counted
 * TC09  Mixed batch (new + unchanged)   → correct per-category counts
 * TC10  Log entry entity name           → SYS_DELTA_LOG always records entity_name='FOLDERS'
 */
@DisplayName("USP_DELTA_FOLDERS Tests")
class TestUspDeltaFolders extends BaseTest {

    // -------------------------------------------------------------------------
    // TC01 – Empty staging table
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC01: Empty staging table logs SUCCESS with zero counts")
    void testEmptyStagingLogsSuccess() throws Exception {
        DbUtils.execUspDeltaFolders(conn);

        Map<String, Object> log = DbUtils.getLatestLog(conn);
        assertNotNull(log, "Expected a log entry to be created");
        assertEquals("SUCCESS", log.get("status"));
        assertEquals(0, log.get("input_row_count"));
        assertEquals(0, log.get("rows_upserted"));
        assertEquals(0, log.get("rows_unchanged"));
        assertEquals(0, log.get("rows_deduped"));
        assertEquals(0, log.get("rows_retired"));
    }

    // -------------------------------------------------------------------------
    // TC02 – Single new row inserted into TARGET_FOLDERS
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC02: Single new row is inserted into TARGET_FOLDERS and HASH_REGISTRY")
    void testSingleNewRowInsertedToTarget() throws Exception {
        long stagingId = DbUtils.insertStagingParent(conn);
        DbUtils.insertStagingFolder(conn, stagingId);

        DbUtils.execUspDeltaFolders(conn);

        assertEquals(1, DbUtils.getTargetFoldersCount(conn));
        assertEquals(1, DbUtils.getHashRegistryCount(conn));

        Map<String, Object> log = DbUtils.getLatestLog(conn);
        assertEquals("SUCCESS", log.get("status"));
        assertEquals(1, log.get("input_row_count"));
        assertEquals(1, log.get("rows_upserted"));
        assertEquals(0, log.get("rows_unchanged"));
    }

    // -------------------------------------------------------------------------
    // TC03 – Staging row Is_Processed flag is set to 'Y'
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC03: All staging rows are marked Is_Processed='Y' after a successful run")
    void testStagingRowMarkedAsProcessed() throws Exception {
        long stagingId = DbUtils.insertStagingParent(conn);
        DbUtils.insertStagingFolder(conn, stagingId, "F001");
        DbUtils.insertStagingFolder(conn, stagingId, "F002");

        assertEquals(2, DbUtils.getUnprocessedStagingCount(conn));

        DbUtils.execUspDeltaFolders(conn);

        assertEquals(2, DbUtils.getProcessedStagingCount(conn));
        assertEquals(0, DbUtils.getUnprocessedStagingCount(conn));
    }

    // -------------------------------------------------------------------------
    // TC04 – Duplicate rows in staging are deduplicated
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC04: Three identical staging rows → one TARGET insert, rows_deduped=2")
    void testDuplicateStagingRowsDeduped() throws Exception {
        long stagingId = DbUtils.insertStagingParent(conn);
        for (int i = 0; i < 3; i++) {
            DbUtils.insertStagingFolder(
                conn, stagingId,
                null, "DUP-001", "ACTIVE", "TYPE-A", "Duplicate", "ENTITY-001", "N");
        }

        DbUtils.execUspDeltaFolders(conn);

        assertEquals(1, DbUtils.getTargetFoldersCount(conn));
        assertEquals(1, DbUtils.getHashRegistryCount(conn));

        Map<String, Object> log = DbUtils.getLatestLog(conn);
        assertEquals(3, log.get("input_row_count"));
        assertEquals(2, log.get("rows_deduped"));
        assertEquals(1, log.get("rows_upserted"));
    }

    // -------------------------------------------------------------------------
    // TC05 – Unchanged row (hash already in HASH_REGISTRY)
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC05: Row whose hash already exists → rows_unchanged=1, no new TARGET row")
    void testUnchangedRowNotReinserted() throws Exception {
        String folderFolderId = "KNOWN-001";
        long stagingId = DbUtils.insertStagingParent(conn);
        DbUtils.insertStagingFolder(conn, stagingId, folderFolderId);

        // Pre-insert the matching hash to simulate a previous run
        byte[] rowHash = DbUtils.computeFolderHash(
            conn, null, folderFolderId, "ACTIVE", "TYPE-A", "Test Folder", "ENTITY-001");
        DbUtils.insertHashRegistry(conn, "FOLDERS", rowHash, 60);

        DbUtils.execUspDeltaFolders(conn);

        assertEquals(0, DbUtils.getTargetFoldersCount(conn),
            "Hash already known – no new TARGET row");
        assertEquals(1, DbUtils.getHashRegistryCount(conn),
            "Hash registry count must remain 1");

        Map<String, Object> log = DbUtils.getLatestLog(conn);
        assertEquals(1, log.get("rows_unchanged"));
        assertEquals(0, log.get("rows_upserted"));
    }

    // -------------------------------------------------------------------------
    // TC06 – Old hashes are retired
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC06: Hash from a prior run absent in this batch is deleted (retired)")
    void testOldHashesRetired() throws Exception {
        byte[] staleHash = new byte[32]; // all-zero 32-byte value
        DbUtils.insertHashRegistry(conn, "FOLDERS", staleHash, 120);

        long stagingId = DbUtils.insertStagingParent(conn);
        DbUtils.insertStagingFolder(conn, stagingId, "NEW-AFTER-RETIRE");

        DbUtils.execUspDeltaFolders(conn);

        // After the run there should be exactly 1 hash (the new one)
        assertEquals(1, DbUtils.getHashRegistryCount(conn));

        Map<String, Object> log = DbUtils.getLatestLog(conn);
        assertEquals(1, log.get("rows_retired"), "Stale hash must be counted as retired");
    }

    // -------------------------------------------------------------------------
    // TC07 – All metrics captured correctly in a multi-row batch
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC07: input_row_count, rows_upserted, rows_unchanged, rows_deduped, rows_retired "
               + "are all captured correctly")
    void testLogCapturesAllMetrics() throws Exception {
        long stagingId = DbUtils.insertStagingParent(conn);

        // One row whose hash pre-exists (→ unchanged)
        String existingFolderId = "EXIST-001";
        byte[] existingHash = DbUtils.computeFolderHash(
            conn, null, existingFolderId, "ACTIVE", "TYPE-A", "Test Folder", "ENTITY-001");
        DbUtils.insertHashRegistry(conn, "FOLDERS", existingHash, 60);
        DbUtils.insertStagingFolder(conn, stagingId, existingFolderId);

        // Two new distinct rows (→ upserted=2)
        DbUtils.insertStagingFolder(conn, stagingId, "NEW-001");
        DbUtils.insertStagingFolder(conn, stagingId, "NEW-002");

        // One duplicate of NEW-001 (→ deduped=1)
        DbUtils.insertStagingFolder(conn, stagingId, "NEW-001");

        DbUtils.execUspDeltaFolders(conn);

        Map<String, Object> log = DbUtils.getLatestLog(conn);
        assertEquals("SUCCESS", log.get("status"));
        assertEquals(4, log.get("input_row_count"));  // 1 existing + 2 new + 1 dup
        assertEquals(1, log.get("rows_unchanged"));
        assertEquals(2, log.get("rows_upserted"));
        assertEquals(1, log.get("rows_deduped"));
        assertEquals(0, log.get("rows_retired"));      // existing hash was updated, not retired
    }

    // -------------------------------------------------------------------------
    // TC08 – Already-processed rows are ignored
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC08: Rows with Is_Processed='Y' are not counted by the SP")
    void testAlreadyProcessedRowsIgnored() throws Exception {
        long stagingId = DbUtils.insertStagingParent(conn);
        DbUtils.insertStagingFolder(
            conn, stagingId, null, "OLD-Y", "ACTIVE", "TYPE-A", "Test Folder", "ENTITY-001", "Y");
        DbUtils.insertStagingFolder(
            conn, stagingId, null, "OLD-Y2", "ACTIVE", "TYPE-A", "Test Folder", "ENTITY-001", "Y");

        DbUtils.execUspDeltaFolders(conn);

        Map<String, Object> log = DbUtils.getLatestLog(conn);
        assertEquals("SUCCESS", log.get("status"));
        assertEquals(0, log.get("input_row_count"));   // SP sees nothing unprocessed
        assertEquals(0, DbUtils.getTargetFoldersCount(conn));
    }

    // -------------------------------------------------------------------------
    // TC09 – Mixed batch: new rows + unchanged rows
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC09: 2 new rows + 1 pre-existing hash → upserted=2, unchanged=1")
    void testMixedNewAndUnchangedRows() throws Exception {
        long stagingId = DbUtils.insertStagingParent(conn);

        // Pre-existing hash
        String knownId = "MIX-KNOWN";
        byte[] knownHash = DbUtils.computeFolderHash(
            conn, null, knownId, "ACTIVE", "TYPE-A", "Test Folder", "ENTITY-001");
        DbUtils.insertHashRegistry(conn, "FOLDERS", knownHash, 60);
        DbUtils.insertStagingFolder(conn, stagingId, knownId);

        // Two genuinely new rows
        DbUtils.insertStagingFolder(conn, stagingId, "MIX-NEW-1");
        DbUtils.insertStagingFolder(conn, stagingId, "MIX-NEW-2");

        DbUtils.execUspDeltaFolders(conn);

        assertEquals(2, DbUtils.getTargetFoldersCount(conn));

        Map<String, Object> log = DbUtils.getLatestLog(conn);
        assertEquals(2, log.get("rows_upserted"));
        assertEquals(1, log.get("rows_unchanged"));
        assertEquals(3, log.get("input_row_count"));
    }

    // -------------------------------------------------------------------------
    // TC10 – Log entry always records the correct entity name
    // -------------------------------------------------------------------------
    @Test
    @DisplayName("TC10: SYS_DELTA_LOG always records entity_name='FOLDERS'")
    void testLogEntryRecordsEntityName() throws Exception {
        DbUtils.execUspDeltaFolders(conn);

        Map<String, Object> log = DbUtils.getLatestLog(conn);
        assertNotNull(log);
        assertEquals("FOLDERS", log.get("entity_name"));
        assertTrue(DbUtils.getLogCount(conn) >= 1);
    }
}
