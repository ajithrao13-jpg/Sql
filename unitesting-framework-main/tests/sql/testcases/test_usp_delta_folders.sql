-- =============================================================================
-- test_usp_delta_folders.sql
-- SQL-driven unit tests for dbo.USP_DELTA_FOLDERS
--
-- HOW TO ADD A NEW TEST CASE
-- --------------------------
-- 1. Copy the block template below (@@TEST ... @@END_TEST).
-- 2. Give it a unique name after @@TEST:.
-- 3. Write your setup SQL (INSERT statements, DECLARE variables, etc.).
-- 4. Call the stored procedure with EXEC dbo.USP_DELTA_FOLDERS.
-- 5. Add @@ASSERT blocks; each SELECT must return 1 (PASS) or 0 (FAIL).
-- 6. Save the file and run pytest – no Python changes needed.
--
-- ASSERTION CONTRACT
-- ------------------
-- Every SELECT after @@ASSERT: must return exactly ONE row, ONE column.
--   1  => assertion passes
--   0  => assertion fails  (framework reports the description + actual value)
--
-- AVAILABLE TABLES (all wiped before each test by the clean_tables fixture)
--   dbo.STAGING             – parent of STAGING_FOLDERS (auto-ID)
--   dbo.STAGING_FOLDERS     – source rows fed to the SP
--   dbo.TARGET_FOLDERS      – rows inserted by the SP
--   dbo.HASH_REGISTRY       – change-detection hashes maintained by the SP
--   dbo.SYS_DELTA_LOG       – execution audit log written by the SP
-- =============================================================================


-- @@TEST: TC01 - Empty staging table logs success
-- @@DESCRIPTION: With no unprocessed rows the SP exits early with SUCCESS and all counters = 0

EXEC dbo.USP_DELTA_FOLDERS;

-- @@ASSERT: A log entry is created
SELECT CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG;

-- @@ASSERT: status is SUCCESS
SELECT CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: input_row_count is 0
SELECT CASE WHEN input_row_count = 0 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_upserted is 0
SELECT CASE WHEN rows_upserted = 0 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_unchanged is 0
SELECT CASE WHEN rows_unchanged = 0 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_deduped is 0
SELECT CASE WHEN rows_deduped = 0 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_retired is 0
SELECT CASE WHEN rows_retired = 0 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@END_TEST


-- @@TEST: TC02 - Single new row inserted to target
-- @@DESCRIPTION: One new staging row is inserted into TARGET_FOLDERS and HASH_REGISTRY

DECLARE @staging_id BIGINT;
INSERT INTO dbo.STAGING DEFAULT VALUES;
SET @staging_id = SCOPE_IDENTITY();

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'FOLDER-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

EXEC dbo.USP_DELTA_FOLDERS;

-- @@ASSERT: TARGET_FOLDERS has 1 row
SELECT CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END
FROM dbo.TARGET_FOLDERS;

-- @@ASSERT: HASH_REGISTRY has 1 row
SELECT CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END
FROM dbo.HASH_REGISTRY;

-- @@ASSERT: status is SUCCESS
SELECT CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: input_row_count is 1
SELECT CASE WHEN input_row_count = 1 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_upserted is 1
SELECT CASE WHEN rows_upserted = 1 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_unchanged is 0
SELECT CASE WHEN rows_unchanged = 0 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@END_TEST


-- @@TEST: TC03 - Staging row marked as processed after SP run
-- @@DESCRIPTION: After a successful run all staging rows have Is_Processed flipped to Y

DECLARE @staging_id BIGINT;
INSERT INTO dbo.STAGING DEFAULT VALUES;
SET @staging_id = SCOPE_IDENTITY();

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'F001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'F002', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

EXEC dbo.USP_DELTA_FOLDERS;

-- @@ASSERT: Both staging rows are now marked Is_Processed = Y
SELECT CASE WHEN COUNT(*) = 2 THEN 1 ELSE 0 END
FROM dbo.STAGING_FOLDERS
WHERE Is_Processed = 'Y';

-- @@ASSERT: No unprocessed staging rows remain
SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
FROM dbo.STAGING_FOLDERS
WHERE Is_Processed = 'N';

-- @@END_TEST


-- @@TEST: TC04 - Duplicate staging rows are deduplicated
-- @@DESCRIPTION: Three identical rows produce one TARGET insert and rows_deduped = 2

DECLARE @staging_id BIGINT;
INSERT INTO dbo.STAGING DEFAULT VALUES;
SET @staging_id = SCOPE_IDENTITY();

-- Insert 3 identical rows
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'DUP-001', 'ACTIVE', 'TYPE-A', 'Duplicate', 'ENTITY-001', @staging_id, 'N');

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'DUP-001', 'ACTIVE', 'TYPE-A', 'Duplicate', 'ENTITY-001', @staging_id, 'N');

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'DUP-001', 'ACTIVE', 'TYPE-A', 'Duplicate', 'ENTITY-001', @staging_id, 'N');

EXEC dbo.USP_DELTA_FOLDERS;

-- @@ASSERT: Only 1 row inserted into TARGET_FOLDERS (duplicates removed)
SELECT CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END
FROM dbo.TARGET_FOLDERS;

-- @@ASSERT: HASH_REGISTRY has exactly 1 row
SELECT CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END
FROM dbo.HASH_REGISTRY;

-- @@ASSERT: input_row_count is 3
SELECT CASE WHEN input_row_count = 3 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_deduped is 2
SELECT CASE WHEN rows_deduped = 2 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_upserted is 1
SELECT CASE WHEN rows_upserted = 1 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@END_TEST


-- @@TEST: TC05 - Unchanged row with pre-existing hash is not reinserted
-- @@DESCRIPTION: A row whose hash already exists in HASH_REGISTRY produces rows_unchanged=1 and no new TARGET row

DECLARE @staging_id BIGINT;
INSERT INTO dbo.STAGING DEFAULT VALUES;
SET @staging_id = SCOPE_IDENTITY();

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'KNOWN-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

-- Pre-insert the matching hash to simulate a previous SP run
-- The hash must match exactly what USP_DELTA_FOLDERS computes (CONCAT_WS with | separator)
INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
VALUES (
    'FOLDERS',
    HASHBYTES(
        'SHA2_256',
        CONVERT(VARBINARY(8000),
            CONCAT_WS('|', '', 'KNOWN-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001')
        )
    ),
    DATEADD(SECOND, -60, SYSUTCDATETIME()),
    DATEADD(SECOND, -60, SYSUTCDATETIME())
);

EXEC dbo.USP_DELTA_FOLDERS;

-- @@ASSERT: TARGET_FOLDERS is empty (hash already known – no new row)
SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
FROM dbo.TARGET_FOLDERS;

-- @@ASSERT: HASH_REGISTRY still has exactly 1 row
SELECT CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END
FROM dbo.HASH_REGISTRY;

-- @@ASSERT: rows_unchanged is 1
SELECT CASE WHEN rows_unchanged = 1 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_upserted is 0
SELECT CASE WHEN rows_upserted = 0 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@END_TEST


-- @@TEST: TC06 - Old hashes not in current batch are retired
-- @@DESCRIPTION: A hash from a prior run that is absent from this batch is deleted and rows_retired=1

-- Insert a stale hash (arbitrary 32-byte value – not matching the new staging row)
INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
VALUES (
    'FOLDERS',
    0x0000000000000000000000000000000000000000000000000000000000000000,
    DATEADD(SECOND, -120, SYSUTCDATETIME()),
    DATEADD(SECOND, -120, SYSUTCDATETIME())
);

-- New staging row with a different hash
DECLARE @staging_id BIGINT;
INSERT INTO dbo.STAGING DEFAULT VALUES;
SET @staging_id = SCOPE_IDENTITY();

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'NEW-AFTER-RETIRE', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

EXEC dbo.USP_DELTA_FOLDERS;

-- @@ASSERT: HASH_REGISTRY has exactly 1 row (stale hash deleted, new hash added)
SELECT CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END
FROM dbo.HASH_REGISTRY;

-- @@ASSERT: rows_retired is 1
SELECT CASE WHEN rows_retired = 1 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@END_TEST


-- @@TEST: TC07 - All metrics captured correctly in a mixed multi-row batch
-- @@DESCRIPTION: input_row_count, rows_upserted, rows_unchanged, rows_deduped, rows_retired all correct

DECLARE @staging_id BIGINT;
INSERT INTO dbo.STAGING DEFAULT VALUES;
SET @staging_id = SCOPE_IDENTITY();

-- Pre-insert a known hash (row EXIST-001 will be unchanged)
INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
VALUES (
    'FOLDERS',
    HASHBYTES(
        'SHA2_256',
        CONVERT(VARBINARY(8000),
            CONCAT_WS('|', '', 'EXIST-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001')
        )
    ),
    DATEADD(SECOND, -60, SYSUTCDATETIME()),
    DATEADD(SECOND, -60, SYSUTCDATETIME())
);

-- Row 1: unchanged (hash pre-exists)
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'EXIST-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

-- Rows 2 and 3: genuinely new (will be upserted)
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'NEW-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'NEW-002', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

-- Row 4: duplicate of NEW-001 (will be deduped)
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'NEW-001', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

EXEC dbo.USP_DELTA_FOLDERS;

-- @@ASSERT: status is SUCCESS
SELECT CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: input_row_count is 4 (1 existing + 2 new + 1 duplicate)
SELECT CASE WHEN input_row_count = 4 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_unchanged is 1
SELECT CASE WHEN rows_unchanged = 1 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_upserted is 2
SELECT CASE WHEN rows_upserted = 2 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_deduped is 1
SELECT CASE WHEN rows_deduped = 1 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_retired is 0 (existing hash was refreshed, not retired)
SELECT CASE WHEN rows_retired = 0 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@END_TEST


-- @@TEST: TC08 - Already-processed rows are ignored by the SP
-- @@DESCRIPTION: Rows with Is_Processed=Y are not counted; SP should log input_row_count=0

DECLARE @staging_id BIGINT;
INSERT INTO dbo.STAGING DEFAULT VALUES;
SET @staging_id = SCOPE_IDENTITY();

-- Insert rows that are already marked as processed
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'OLD-Y', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'Y');

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'OLD-Y2', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'Y');

EXEC dbo.USP_DELTA_FOLDERS;

-- @@ASSERT: status is SUCCESS
SELECT CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: input_row_count is 0 (SP sees nothing unprocessed)
SELECT CASE WHEN input_row_count = 0 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: TARGET_FOLDERS remains empty
SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
FROM dbo.TARGET_FOLDERS;

-- @@END_TEST


-- @@TEST: TC09 - Mixed batch with new and unchanged rows
-- @@DESCRIPTION: 2 new rows + 1 pre-existing hash => rows_upserted=2, rows_unchanged=1

DECLARE @staging_id BIGINT;
INSERT INTO dbo.STAGING DEFAULT VALUES;
SET @staging_id = SCOPE_IDENTITY();

-- Pre-insert hash for the known row
INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
VALUES (
    'FOLDERS',
    HASHBYTES(
        'SHA2_256',
        CONVERT(VARBINARY(8000),
            CONCAT_WS('|', '', 'MIX-KNOWN', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001')
        )
    ),
    DATEADD(SECOND, -60, SYSUTCDATETIME()),
    DATEADD(SECOND, -60, SYSUTCDATETIME())
);

-- Known row (unchanged)
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'MIX-KNOWN', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

-- Two genuinely new rows
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'MIX-NEW-1', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id, Is_Processed)
VALUES (NULL, 'MIX-NEW-2', 'ACTIVE', 'TYPE-A', 'Test Folder', 'ENTITY-001', @staging_id, 'N');

EXEC dbo.USP_DELTA_FOLDERS;

-- @@ASSERT: TARGET_FOLDERS has 2 rows (only the new ones)
SELECT CASE WHEN COUNT(*) = 2 THEN 1 ELSE 0 END
FROM dbo.TARGET_FOLDERS;

-- @@ASSERT: rows_upserted is 2
SELECT CASE WHEN rows_upserted = 2 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: rows_unchanged is 1
SELECT CASE WHEN rows_unchanged = 1 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: input_row_count is 3
SELECT CASE WHEN input_row_count = 3 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@END_TEST


-- @@TEST: TC10 - Log entry always records the correct entity name
-- @@DESCRIPTION: SYS_DELTA_LOG rows must carry entity_name=FOLDERS

EXEC dbo.USP_DELTA_FOLDERS;

-- @@ASSERT: entity_name in the latest log entry is FOLDERS
SELECT CASE WHEN entity_name = 'FOLDERS' THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG
ORDER BY log_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROW ONLY;

-- @@ASSERT: At least one log entry exists
SELECT CASE WHEN COUNT(*) >= 1 THEN 1 ELSE 0 END
FROM dbo.SYS_DELTA_LOG;

-- @@END_TEST
