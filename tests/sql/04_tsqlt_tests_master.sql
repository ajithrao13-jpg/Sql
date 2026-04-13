-- =============================================================
-- 04_tsqlt_tests_master.sql
-- tSQLt unit tests for [dbo].[USP_DELTA_MASTER].
--
-- USP_DELTA_MASTER is an orchestrator that calls every entity-level
-- delta SP in sequence.  Each sub-call is wrapped in BEGIN TRY … END
-- CATCH so individual failures are swallowed.
--
-- Test catalogue
-- --------------
-- TC01  Procedure executes without raising an exception.
-- TC02  Sub-procedure failures (non-existent SPs) do NOT stop execution –
--       the master completes and USP_DELTA_FOLDERS is still invoked.
-- TC03  When STAGING_FOLDERS has data, running USP_DELTA_MASTER causes
--       USP_DELTA_FOLDERS to process it (end-to-end integration check).
-- =============================================================

EXEC tSQLt.NewTestClass 'TestUSPDeltaMaster';
GO

-- -------------------------------------------------------------
-- SetUp – clears all test tables before every test
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE TestUSPDeltaMaster.[SetUp]
AS
BEGIN
    DELETE FROM dbo.STAGING_FOLDERS;
    DELETE FROM dbo.STAGING;
    DELETE FROM dbo.TARGET_FOLDERS;
    DELETE FROM dbo.HASH_REGISTRY;
    DELETE FROM dbo.SYS_DELTA_LOG;
END;
GO

-- -------------------------------------------------------------
-- TC01 – Master procedure executes without error
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaMaster].[test TC01 - master executes without error]
AS
BEGIN
    -- Arrange: tables are empty (SetUp ran)

    -- Act: should not raise an unhandled exception
    EXEC dbo.USP_DELTA_MASTER;

    -- If we reach here the procedure completed successfully.
    -- A failure (unhandled exception) would cause tSQLt to mark this test as failed.
END;
GO

-- -------------------------------------------------------------
-- TC02 – Sub-procedure failures do not stop the master
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaMaster].[test TC02 - master continues after missing sub procedures]
AS
BEGIN
    -- Arrange: staging is empty; most sub-procedures do not exist in the test
    --          database.  USP_DELTA_MASTER wraps every call in TRY/CATCH,
    --          so "object not found" errors are silently swallowed.

    -- Act
    EXEC dbo.USP_DELTA_MASTER;

    -- Assert: USP_DELTA_FOLDERS is the only real sub-proc; it should have
    --         logged a SUCCESS entry.
    DECLARE @status VARCHAR(10);

    SELECT TOP 1 @status = status
    FROM dbo.SYS_DELTA_LOG
    WHERE entity_name = 'FOLDERS'
    ORDER BY log_id DESC;

    IF @status IS NULL
        EXEC tSQLt.Fail 'USP_DELTA_FOLDERS should have logged an entry';

    EXEC tSQLt.AssertEquals 'SUCCESS', @status,
        'USP_DELTA_FOLDERS log entry must have status SUCCESS';
END;
GO

-- -------------------------------------------------------------
-- TC03 – Master delegates to USP_DELTA_FOLDERS end-to-end
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaMaster].[test TC03 - master triggers folders processing]
AS
BEGIN
    -- Arrange: two unprocessed staging rows
    INSERT INTO dbo.STAGING DEFAULT VALUES;
    DECLARE @staging_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('MASTER-F001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('MASTER-F002', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    -- Act
    EXEC dbo.USP_DELTA_MASTER;

    -- Assert: both rows should have been processed via USP_DELTA_FOLDERS
    DECLARE @target_count INT;
    DECLARE @status       VARCHAR(10);
    DECLARE @upserted     INT;

    SELECT @target_count = COUNT(*) FROM dbo.TARGET_FOLDERS;

    SELECT TOP 1
        @status   = status,
        @upserted = rows_upserted
    FROM dbo.SYS_DELTA_LOG
    WHERE entity_name = 'FOLDERS'
    ORDER BY log_id DESC;

    EXEC tSQLt.AssertEquals 2,         @target_count, 'TARGET_FOLDERS must have 2 rows';
    EXEC tSQLt.AssertEquals 'SUCCESS', @status,       'USP_DELTA_FOLDERS log must be SUCCESS';
    EXEC tSQLt.AssertEquals 2,         @upserted,     'rows_upserted must be 2';
END;
GO
