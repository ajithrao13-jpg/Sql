-- =============================================================
-- 03_tsqlt_tests_folders.sql
-- tSQLt unit tests for [dbo].[USP_DELTA_FOLDERS].
--
-- Test catalogue
-- --------------
-- TC01  Empty staging table            → early-exit with SUCCESS, input_row_count=0
-- TC02  Single new row                 → inserted into TARGET_FOLDERS & HASH_REGISTRY
-- TC03  Staging row marked processed   → Is_Processed flipped to 'Y'
-- TC04  Duplicate rows deduplication   → only first occurrence processed; rows_deduped counted
-- TC05  Unchanged row (hash pre-exists)→ rows_unchanged=1, no new TARGET insert
-- TC06  Old hashes retired             → rows not in current batch deleted from HASH_REGISTRY
-- TC07  Metrics captured in log        → all counters correct for a mixed batch
-- TC08  Already-processed rows ignored → Is_Processed='Y' rows not re-counted
-- TC09  Mixed batch (new + unchanged)  → correct per-category counts
-- TC10  Log entry entity name          → SYS_DELTA_LOG always records entity_name='FOLDERS'
-- =============================================================

EXEC tSQLt.NewTestClass 'TestUSPDeltaFolders';
GO

-- -------------------------------------------------------------
-- SetUp – runs before every test in this class; clears all
-- tables in FK-safe order so each test starts clean.
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE TestUSPDeltaFolders.[SetUp]
AS
BEGIN
    DELETE FROM dbo.STAGING_FOLDERS;
    DELETE FROM dbo.STAGING;
    DELETE FROM dbo.TARGET_FOLDERS;
    DELETE FROM dbo.HASH_REGISTRY;
    DELETE FROM dbo.SYS_DELTA_LOG;
END;
GO

-- =============================================================
-- Helper: insert a parent row into dbo.STAGING and return its ID
-- =============================================================
CREATE OR ALTER FUNCTION TestUSPDeltaFolders.fn_InsertStagingParent()
RETURNS BIGINT
AS
BEGIN
    -- Cannot INSERT from a function; caller must use the procedure below.
    RETURN NULL;
END;
GO

-- -------------------------------------------------------------
-- TC01 – Empty staging table → early-exit with SUCCESS
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaFolders].[test TC01 - empty staging logs success]
AS
BEGIN
    -- Arrange: tables are empty (SetUp ran)

    -- Act
    EXEC dbo.USP_DELTA_FOLDERS;

    -- Assert
    DECLARE @status          VARCHAR(10);
    DECLARE @input_row_count INT;
    DECLARE @rows_upserted   INT;
    DECLARE @rows_unchanged  INT;
    DECLARE @rows_deduped    INT;
    DECLARE @rows_retired    INT;

    SELECT TOP 1
        @status          = status,
        @input_row_count = input_row_count,
        @rows_upserted   = rows_upserted,
        @rows_unchanged  = rows_unchanged,
        @rows_deduped    = rows_deduped,
        @rows_retired    = rows_retired
    FROM dbo.SYS_DELTA_LOG
    ORDER BY log_id DESC;

    EXEC tSQLt.AssertEquals 'SUCCESS', @status,          'status must be SUCCESS';
    EXEC tSQLt.AssertEquals 0,         @input_row_count, 'input_row_count must be 0';
    EXEC tSQLt.AssertEquals 0,         @rows_upserted,   'rows_upserted must be 0';
    EXEC tSQLt.AssertEquals 0,         @rows_unchanged,  'rows_unchanged must be 0';
    EXEC tSQLt.AssertEquals 0,         @rows_deduped,    'rows_deduped must be 0';
    EXEC tSQLt.AssertEquals 0,         @rows_retired,    'rows_retired must be 0';
END;
GO

-- -------------------------------------------------------------
-- TC02 – Single new row inserted to TARGET_FOLDERS
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaFolders].[test TC02 - single new row inserted to target]
AS
BEGIN
    -- Arrange
    INSERT INTO dbo.STAGING DEFAULT VALUES;
    DECLARE @staging_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO dbo.STAGING_FOLDERS
        (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
         folderTypeCode, folderDescription, folderOwnerEntityId,
         staging_id, Is_Processed)
    VALUES (NULL, 'FOLDER-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001',
            @staging_id, 'N');

    -- Act
    EXEC dbo.USP_DELTA_FOLDERS;

    -- Assert
    DECLARE @target_count INT;
    DECLARE @hash_count   INT;
    DECLARE @status       VARCHAR(10);
    DECLARE @upserted     INT;
    DECLARE @unchanged    INT;
    DECLARE @input_count  INT;

    SELECT @target_count = COUNT(*) FROM dbo.TARGET_FOLDERS;
    SELECT @hash_count   = COUNT(*) FROM dbo.HASH_REGISTRY WHERE entity_name = 'FOLDERS';

    SELECT TOP 1
        @status      = status,
        @input_count = input_row_count,
        @upserted    = rows_upserted,
        @unchanged   = rows_unchanged
    FROM dbo.SYS_DELTA_LOG ORDER BY log_id DESC;

    EXEC tSQLt.AssertEquals 1,         @target_count, 'TARGET_FOLDERS must have 1 row';
    EXEC tSQLt.AssertEquals 1,         @hash_count,   'HASH_REGISTRY must have 1 row';
    EXEC tSQLt.AssertEquals 'SUCCESS', @status,       'status must be SUCCESS';
    EXEC tSQLt.AssertEquals 1,         @input_count,  'input_row_count must be 1';
    EXEC tSQLt.AssertEquals 1,         @upserted,     'rows_upserted must be 1';
    EXEC tSQLt.AssertEquals 0,         @unchanged,    'rows_unchanged must be 0';
END;
GO

-- -------------------------------------------------------------
-- TC03 – Staging row Is_Processed flag is set to 'Y'
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaFolders].[test TC03 - staging row marked as processed]
AS
BEGIN
    -- Arrange: two unprocessed rows
    INSERT INTO dbo.STAGING DEFAULT VALUES;
    DECLARE @staging_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('F001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('F002', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    -- Act
    EXEC dbo.USP_DELTA_FOLDERS;

    -- Assert
    DECLARE @processed_count   INT;
    DECLARE @unprocessed_count INT;

    SELECT @processed_count   = COUNT(*) FROM dbo.STAGING_FOLDERS WHERE Is_Processed = 'Y';
    SELECT @unprocessed_count = COUNT(*) FROM dbo.STAGING_FOLDERS WHERE Is_Processed = 'N';

    EXEC tSQLt.AssertEquals 2, @processed_count,   'All rows must be marked as processed';
    EXEC tSQLt.AssertEquals 0, @unprocessed_count, 'No unprocessed rows should remain';
END;
GO

-- -------------------------------------------------------------
-- TC04 – Duplicate rows in staging are deduplicated
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaFolders].[test TC04 - duplicate staging rows deduped]
AS
BEGIN
    -- Arrange: three identical rows
    INSERT INTO dbo.STAGING DEFAULT VALUES;
    DECLARE @staging_id BIGINT = SCOPE_IDENTITY();

    DECLARE @i INT = 1;
    WHILE @i <= 3
    BEGIN
        INSERT INTO dbo.STAGING_FOLDERS
            (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
             folderOwnerEntityId, staging_id, Is_Processed)
        VALUES ('DUP-001', 'ACTIVE', 'TYPE-A', 'Duplicate', 'ENTITY-001', @staging_id, 'N');
        SET @i += 1;
    END;

    -- Act
    EXEC dbo.USP_DELTA_FOLDERS;

    -- Assert
    DECLARE @target_count INT;
    DECLARE @hash_count   INT;
    DECLARE @input_count  INT;
    DECLARE @deduped      INT;
    DECLARE @upserted     INT;

    SELECT @target_count = COUNT(*) FROM dbo.TARGET_FOLDERS;
    SELECT @hash_count   = COUNT(*) FROM dbo.HASH_REGISTRY WHERE entity_name = 'FOLDERS';

    SELECT TOP 1
        @input_count = input_row_count,
        @deduped     = rows_deduped,
        @upserted    = rows_upserted
    FROM dbo.SYS_DELTA_LOG ORDER BY log_id DESC;

    EXEC tSQLt.AssertEquals 1, @target_count, 'Only 1 row should be inserted into TARGET_FOLDERS';
    EXEC tSQLt.AssertEquals 1, @hash_count,   'Only 1 hash should exist in HASH_REGISTRY';
    EXEC tSQLt.AssertEquals 3, @input_count,  'input_row_count must be 3';
    EXEC tSQLt.AssertEquals 2, @deduped,      'rows_deduped must be 2';
    EXEC tSQLt.AssertEquals 1, @upserted,     'rows_upserted must be 1';
END;
GO

-- -------------------------------------------------------------
-- TC05 – Unchanged row (hash already in HASH_REGISTRY)
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaFolders].[test TC05 - unchanged row not reinserted]
AS
BEGIN
    -- Arrange: staging row whose hash is pre-seeded in the registry
    INSERT INTO dbo.STAGING DEFAULT VALUES;
    DECLARE @staging_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('KNOWN-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    -- Pre-insert matching hash with a backdated timestamp
    DECLARE @row_hash VARBINARY(32);
    SELECT @row_hash = HASHBYTES(
        'SHA2_256',
        CONVERT(VARBINARY(8000),
            CONCAT_WS('|', '', 'KNOWN-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001'))
    );

    INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
    VALUES (
        'FOLDERS',
        @row_hash,
        DATEADD(SECOND, -60, SYSUTCDATETIME()),
        DATEADD(SECOND, -60, SYSUTCDATETIME())
    );

    -- Act
    EXEC dbo.USP_DELTA_FOLDERS;

    -- Assert
    DECLARE @target_count INT;
    DECLARE @hash_count   INT;
    DECLARE @unchanged    INT;
    DECLARE @upserted     INT;

    SELECT @target_count = COUNT(*) FROM dbo.TARGET_FOLDERS;
    SELECT @hash_count   = COUNT(*) FROM dbo.HASH_REGISTRY WHERE entity_name = 'FOLDERS';

    SELECT TOP 1
        @unchanged = rows_unchanged,
        @upserted  = rows_upserted
    FROM dbo.SYS_DELTA_LOG ORDER BY log_id DESC;

    EXEC tSQLt.AssertEquals 0, @target_count, 'Hash already known – no new TARGET row';
    EXEC tSQLt.AssertEquals 1, @hash_count,   'Hash registry count must remain 1';
    EXEC tSQLt.AssertEquals 1, @unchanged,    'rows_unchanged must be 1';
    EXEC tSQLt.AssertEquals 0, @upserted,     'rows_upserted must be 0';
END;
GO

-- -------------------------------------------------------------
-- TC06 – Old hashes are retired
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaFolders].[test TC06 - old hashes retired]
AS
BEGIN
    -- Arrange: stale hash in registry that is NOT in the current batch
    DECLARE @stale_hash VARBINARY(32) = CAST(REPLICATE(CHAR(0), 32) AS VARBINARY(32));
    INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
    VALUES (
        'FOLDERS',
        @stale_hash,
        DATEADD(SECOND, -120, SYSUTCDATETIME()),
        DATEADD(SECOND, -120, SYSUTCDATETIME())
    );

    -- New, different staging row
    INSERT INTO dbo.STAGING DEFAULT VALUES;
    DECLARE @staging_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('NEW-AFTER-RETIRE', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    -- Act
    EXEC dbo.USP_DELTA_FOLDERS;

    -- Assert: only the new hash should remain (stale was deleted)
    DECLARE @hash_count INT;
    DECLARE @retired    INT;

    SELECT @hash_count = COUNT(*) FROM dbo.HASH_REGISTRY WHERE entity_name = 'FOLDERS';

    SELECT TOP 1 @retired = rows_retired
    FROM dbo.SYS_DELTA_LOG ORDER BY log_id DESC;

    EXEC tSQLt.AssertEquals 1, @hash_count, 'Only the new hash should remain in HASH_REGISTRY';
    EXEC tSQLt.AssertEquals 1, @retired,    'rows_retired must be 1';
END;
GO

-- -------------------------------------------------------------
-- TC07 – All metrics captured correctly in a multi-row batch
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaFolders].[test TC07 - log captures all metrics]
AS
BEGIN
    -- Arrange
    INSERT INTO dbo.STAGING DEFAULT VALUES;
    DECLARE @staging_id BIGINT = SCOPE_IDENTITY();

    -- One row whose hash pre-exists (→ unchanged)
    DECLARE @existing_hash VARBINARY(32);
    SELECT @existing_hash = HASHBYTES(
        'SHA2_256',
        CONVERT(VARBINARY(8000),
            CONCAT_WS('|', '', 'EXIST-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001'))
    );
    INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
    VALUES (
        'FOLDERS', @existing_hash,
        DATEADD(SECOND, -60, SYSUTCDATETIME()),
        DATEADD(SECOND, -60, SYSUTCDATETIME())
    );
    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('EXIST-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    -- Two new distinct rows (→ upserted=2)
    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('NEW-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('NEW-002', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    -- One duplicate of NEW-001 (→ deduped=1)
    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('NEW-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    -- Act
    EXEC dbo.USP_DELTA_FOLDERS;

    -- Assert
    DECLARE @status      VARCHAR(10);
    DECLARE @input_count INT;
    DECLARE @unchanged   INT;
    DECLARE @upserted    INT;
    DECLARE @deduped     INT;
    DECLARE @retired     INT;

    SELECT TOP 1
        @status      = status,
        @input_count = input_row_count,
        @unchanged   = rows_unchanged,
        @upserted    = rows_upserted,
        @deduped     = rows_deduped,
        @retired     = rows_retired
    FROM dbo.SYS_DELTA_LOG ORDER BY log_id DESC;

    EXEC tSQLt.AssertEquals 'SUCCESS', @status,      'status must be SUCCESS';
    EXEC tSQLt.AssertEquals 4,         @input_count, 'input_row_count must be 4';
    EXEC tSQLt.AssertEquals 1,         @unchanged,   'rows_unchanged must be 1';
    EXEC tSQLt.AssertEquals 2,         @upserted,    'rows_upserted must be 2';
    EXEC tSQLt.AssertEquals 1,         @deduped,     'rows_deduped must be 1';
    EXEC tSQLt.AssertEquals 0,         @retired,     'rows_retired must be 0 (existing hash updated, not retired)';
END;
GO

-- -------------------------------------------------------------
-- TC08 – Already-processed rows are ignored
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaFolders].[test TC08 - already processed rows ignored]
AS
BEGIN
    -- Arrange: rows already marked Is_Processed='Y'
    INSERT INTO dbo.STAGING DEFAULT VALUES;
    DECLARE @staging_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('OLD-Y', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'Y');

    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('OLD-Y2', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'Y');

    -- Act
    EXEC dbo.USP_DELTA_FOLDERS;

    -- Assert
    DECLARE @status       VARCHAR(10);
    DECLARE @input_count  INT;
    DECLARE @target_count INT;

    SELECT TOP 1
        @status      = status,
        @input_count = input_row_count
    FROM dbo.SYS_DELTA_LOG ORDER BY log_id DESC;

    SELECT @target_count = COUNT(*) FROM dbo.TARGET_FOLDERS;

    EXEC tSQLt.AssertEquals 'SUCCESS', @status,       'status must be SUCCESS';
    EXEC tSQLt.AssertEquals 0,         @input_count,  'SP sees nothing unprocessed';
    EXEC tSQLt.AssertEquals 0,         @target_count, 'TARGET_FOLDERS must be empty';
END;
GO

-- -------------------------------------------------------------
-- TC09 – Mixed batch: new rows + unchanged rows
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaFolders].[test TC09 - mixed new and unchanged rows]
AS
BEGIN
    -- Arrange
    INSERT INTO dbo.STAGING DEFAULT VALUES;
    DECLARE @staging_id BIGINT = SCOPE_IDENTITY();

    -- Pre-existing hash
    DECLARE @known_hash VARBINARY(32);
    SELECT @known_hash = HASHBYTES(
        'SHA2_256',
        CONVERT(VARBINARY(8000),
            CONCAT_WS('|', '', 'MIX-KNOWN', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001'))
    );
    INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
    VALUES (
        'FOLDERS', @known_hash,
        DATEADD(SECOND, -60, SYSUTCDATETIME()),
        DATEADD(SECOND, -60, SYSUTCDATETIME())
    );
    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('MIX-KNOWN', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    -- Two genuinely new rows
    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('MIX-NEW-1', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    INSERT INTO dbo.STAGING_FOLDERS
        (folderFolderID, folderStateCode, folderTypeCode, folderDescription,
         folderOwnerEntityId, staging_id, Is_Processed)
    VALUES ('MIX-NEW-2', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

    -- Act
    EXEC dbo.USP_DELTA_FOLDERS;

    -- Assert
    DECLARE @target_count INT;
    DECLARE @upserted     INT;
    DECLARE @unchanged    INT;
    DECLARE @input_count  INT;

    SELECT @target_count = COUNT(*) FROM dbo.TARGET_FOLDERS;

    SELECT TOP 1
        @upserted    = rows_upserted,
        @unchanged   = rows_unchanged,
        @input_count = input_row_count
    FROM dbo.SYS_DELTA_LOG ORDER BY log_id DESC;

    EXEC tSQLt.AssertEquals 2, @target_count, 'TARGET_FOLDERS must have 2 rows';
    EXEC tSQLt.AssertEquals 2, @upserted,     'rows_upserted must be 2';
    EXEC tSQLt.AssertEquals 1, @unchanged,    'rows_unchanged must be 1';
    EXEC tSQLt.AssertEquals 3, @input_count,  'input_row_count must be 3';
END;
GO

-- -------------------------------------------------------------
-- TC10 – Log entry always records the correct entity name
-- -------------------------------------------------------------
CREATE OR ALTER PROCEDURE [TestUSPDeltaFolders].[test TC10 - log entry records entity name]
AS
BEGIN
    -- Arrange: tables are empty (SetUp ran)

    -- Act
    EXEC dbo.USP_DELTA_FOLDERS;

    -- Assert
    DECLARE @entity_name VARCHAR(100);
    DECLARE @log_count   INT;

    SELECT TOP 1 @entity_name = entity_name
    FROM dbo.SYS_DELTA_LOG ORDER BY log_id DESC;

    SELECT @log_count = COUNT(*) FROM dbo.SYS_DELTA_LOG;

    EXEC tSQLt.AssertEquals 'FOLDERS', @entity_name, 'entity_name must be FOLDERS';

    IF @log_count < 1
        EXEC tSQLt.Fail 'Expected at least 1 row in SYS_DELTA_LOG';
END;
GO
