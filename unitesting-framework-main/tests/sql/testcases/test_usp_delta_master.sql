-- =============================================================================
-- test_usp_delta_master.sql
-- SQL-driven unit tests for dbo.USP_DELTA_MASTER
--
-- USP_DELTA_MASTER is an orchestrator that calls every entity-level delta SP
-- in sequence.  Each sub-call is wrapped in BEGIN TRY … END CATCH so that
-- individual failures are swallowed and execution continues.
--
-- To add a new test case follow the same @@TEST / @@ASSERT / @@END_TEST
-- pattern used in test_usp_delta_folders.sql.
-- =============================================================================


-- @@TEST: TC01 - Master procedure executes without error
-- @@DESCRIPTION: USP_DELTA_MASTER completes successfully with no unhandled exception

EXEC dbo.USP_DELTA_MASTER;

-- @@ASSERT: USP_DELTA_FOLDERS logged at least one entry (the master called it)
SELECT CASE WHEN COUNT(*) >= 1 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
WHERE entity_name = 'FOLDERS';

-- @@END_TEST


-- @@TEST: TC02 - Sub-procedure failures do not stop the master
-- @@DESCRIPTION: Non-existent sub-procedures are silently ignored via TRY/CATCH; USP_DELTA_FOLDERS still runs

-- Run with an empty staging table; only USP_DELTA_FOLDERS exists in the test DB
EXEC dbo.USP_DELTA_MASTER;

-- @@ASSERT: USP_DELTA_FOLDERS logged a SUCCESS entry (master did not abort)
SELECT CASE WHEN COUNT(*) >= 1 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
WHERE entity_name = 'FOLDERS'
  AND status = 'SUCCESS';

-- @@END_TEST


-- @@TEST: TC03 - Master delegates to USP_DELTA_FOLDERS end-to-end
-- @@DESCRIPTION: When STAGING_FOLDERS has data, calling USP_DELTA_MASTER processes it via USP_DELTA_FOLDERS

DECLARE @staging_id BIGINT;
INSERT INTO dbo.STAGING DEFAULT VALUES;
SET @staging_id = SCOPE_IDENTITY();

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'MASTER-F001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'MASTER-F002', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

EXEC dbo.USP_DELTA_MASTER;

-- @@ASSERT: Both staging rows were processed into TARGET_FOLDERS
SELECT CASE WHEN COUNT(*) = 2 THEN 1 ELSE 0 END
FROM dbo.TARGET_FOLDERS;

-- @@ASSERT: USP_DELTA_FOLDERS logged SUCCESS
SELECT CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
WHERE entity_name = 'FOLDERS'
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_upserted is 2
SELECT CASE WHEN rows_upserted = 2 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
WHERE entity_name = 'FOLDERS'
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@END_TEST
