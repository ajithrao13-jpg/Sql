-- =============================================================
-- 03_sample_data.sql
-- Representative sample data for every table in the test schema.
--
-- Purpose
-- -------
-- This script seeds the database with realistic baseline data so
-- that each unit test starts from a well-understood state.  It is
-- executed automatically by DatabaseSetup after the DDL scripts;
-- BaseTest.cleanAndReseed() re-runs it before every test method
-- so every test gets a clean, predictable dataset.
--
-- Tables populated (in FK-safe order)
-- ------------------------------------
--   dbo.STAGING            – 2 parent batches (IDs 1 and 2)
--   dbo.STAGING_FOLDERS    – 6 rows covering common scenarios
--   dbo.TARGET_FOLDERS     – 2 already-processed records
--   dbo.HASH_REGISTRY      – 2 hashes mirroring the TARGET rows
--   dbo.SYS_DELTA_LOG      – 1 prior-run audit entry
-- =============================================================

-- ---------------------------------------------------------------
-- 0. Clear existing rows (FK-safe order) before reseeding
-- ---------------------------------------------------------------
DELETE FROM dbo.STAGING_FOLDERS;
DELETE FROM dbo.TARGET_FOLDERS;
DELETE FROM dbo.HASH_REGISTRY;
DELETE FROM dbo.SYS_DELTA_LOG;
DELETE FROM dbo.STAGING;
GO

-- ---------------------------------------------------------------
-- 1. dbo.STAGING  –  parent batch records
-- ---------------------------------------------------------------
-- Batch 1: already fully processed in a prior run
INSERT INTO dbo.STAGING DEFAULT VALUES;   -- ID = 1 (first IDENTITY value after reset)

-- Batch 2: unprocessed rows waiting for the SP
INSERT INTO dbo.STAGING DEFAULT VALUES;   -- ID = 2
GO

-- ---------------------------------------------------------------
-- 2. dbo.STAGING_FOLDERS  –  incoming folder records
-- ---------------------------------------------------------------
-- Row 1 – Batch 1, already processed: SP must ignore it
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId,
     staging_id, Is_Processed)
VALUES
    (NULL, 'SAMPLE-F001', 'ACTIVE', 'TYPE-A',
     'Finance Reports Folder', 'ENTITY-001', 1, 'Y');

-- Row 2 – Batch 1, already processed: SP must ignore it
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId,
     staging_id, Is_Processed)
VALUES
    (NULL, 'SAMPLE-F002', 'ACTIVE', 'TYPE-B',
     'HR Documents Folder', 'ENTITY-002', 1, 'Y');

-- Row 3 – Batch 2, new folder (not in HASH_REGISTRY → will be upserted)
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId,
     staging_id, Is_Processed)
VALUES
    (NULL, 'SAMPLE-F003', 'ACTIVE', 'TYPE-A',
     'Legal Archive Folder', 'ENTITY-003', 2, 'N');

-- Row 4 – Batch 2, unchanged folder (hash will be pre-inserted into HASH_REGISTRY)
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId,
     staging_id, Is_Processed)
VALUES
    (NULL, 'SAMPLE-F004', 'ACTIVE', 'TYPE-B',
     'Compliance Folder', 'ENTITY-004', 2, 'N');

-- Row 5 – Batch 2, duplicate of Row 3 (same folderFolderID + values) → will be deduped
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId,
     staging_id, Is_Processed)
VALUES
    (NULL, 'SAMPLE-F003', 'ACTIVE', 'TYPE-A',
     'Legal Archive Folder', 'ENTITY-003', 2, 'N');

-- Row 6 – Batch 2, inactive/retired folder
INSERT INTO dbo.STAGING_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId,
     staging_id, Is_Processed)
VALUES
    (NULL, 'SAMPLE-F005', 'INACTIVE', 'TYPE-C',
     'Archived Project Folder', 'ENTITY-005', 2, 'N');
GO

-- ---------------------------------------------------------------
-- 3. dbo.TARGET_FOLDERS  –  records already in the target store
--    (mirrors the two 'Y'-processed rows above from batch 1)
-- ---------------------------------------------------------------
INSERT INTO dbo.TARGET_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id)
VALUES
    (NULL, 'SAMPLE-F001', 'ACTIVE', 'TYPE-A',
     'Finance Reports Folder', 'ENTITY-001', 1);

INSERT INTO dbo.TARGET_FOLDERS
    (folderIfUnmodifiedSince, folderFolderID, folderStateCode,
     folderTypeCode, folderDescription, folderOwnerEntityId, staging_id)
VALUES
    (NULL, 'SAMPLE-F002', 'ACTIVE', 'TYPE-B',
     'HR Documents Folder', 'ENTITY-002', 1);
GO

-- ---------------------------------------------------------------
-- 4. dbo.HASH_REGISTRY  –  hashes for the TARGET rows above
--    (also pre-seeds the hash for SAMPLE-F004 so it will be seen
--     as "unchanged" when the SP processes batch 2)
-- ---------------------------------------------------------------
-- Hash for SAMPLE-F001 (already in TARGET)
INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
SELECT
    'FOLDERS',
    HASHBYTES('SHA2_256', CONVERT(VARBINARY(8000),
        CONCAT_WS('|', ISNULL('', ''), 'SAMPLE-F001', 'ACTIVE', 'TYPE-A',
                       'Finance Reports Folder', 'ENTITY-001'))),
    DATEADD(MINUTE, -30, SYSUTCDATETIME()),
    DATEADD(MINUTE, -30, SYSUTCDATETIME());

-- Hash for SAMPLE-F002 (already in TARGET)
INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
SELECT
    'FOLDERS',
    HASHBYTES('SHA2_256', CONVERT(VARBINARY(8000),
        CONCAT_WS('|', ISNULL('', ''), 'SAMPLE-F002', 'ACTIVE', 'TYPE-B',
                       'HR Documents Folder', 'ENTITY-002'))),
    DATEADD(MINUTE, -30, SYSUTCDATETIME()),
    DATEADD(MINUTE, -30, SYSUTCDATETIME());

-- Hash for SAMPLE-F004 (unchanged – will not produce a new TARGET row when SP runs)
INSERT INTO dbo.HASH_REGISTRY (entity_name, row_hash, system_datetime, updated_datetime)
SELECT
    'FOLDERS',
    HASHBYTES('SHA2_256', CONVERT(VARBINARY(8000),
        CONCAT_WS('|', ISNULL('', ''), 'SAMPLE-F004', 'ACTIVE', 'TYPE-B',
                       'Compliance Folder', 'ENTITY-004'))),
    DATEADD(MINUTE, -15, SYSUTCDATETIME()),
    DATEADD(MINUTE, -15, SYSUTCDATETIME());
GO

-- ---------------------------------------------------------------
-- 5. dbo.SYS_DELTA_LOG  –  one representative prior-run audit row
-- ---------------------------------------------------------------
INSERT INTO dbo.SYS_DELTA_LOG
    (entity_name, started_at, input_row_count, rows_unchanged,
     rows_upserted, rows_deduped, rows_retired, status, error_message, duration_seconds)
VALUES
    ('FOLDERS',
     DATEADD(MINUTE, -60, SYSUTCDATETIME()),
     2,    -- input_row_count
     0,    -- rows_unchanged
     2,    -- rows_upserted (SAMPLE-F001 and SAMPLE-F002 were new that run)
     0,    -- rows_deduped
     0,    -- rows_retired
     'SUCCESS',
     NULL,
     1);   -- 1-second run
GO
