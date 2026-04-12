-- =============================================================
-- 01_create_tables.sql
-- Creates all tables needed by the stored procedures under test.
-- =============================================================

-- Drop in FK-safe order (children before parents)
IF OBJECT_ID('dbo.STAGING_FOLDERS',  'U') IS NOT NULL DROP TABLE dbo.STAGING_FOLDERS;
GO
IF OBJECT_ID('dbo.TARGET_FOLDERS',   'U') IS NOT NULL DROP TABLE dbo.TARGET_FOLDERS;
GO
IF OBJECT_ID('dbo.HASH_REGISTRY',    'U') IS NOT NULL DROP TABLE dbo.HASH_REGISTRY;
GO
IF OBJECT_ID('dbo.SYS_DELTA_LOG',    'U') IS NOT NULL DROP TABLE dbo.SYS_DELTA_LOG;
GO
IF OBJECT_ID('dbo.STAGING',          'U') IS NOT NULL DROP TABLE dbo.STAGING;
GO

-- Parent table required by STAGING_FOLDERS FK
CREATE TABLE dbo.STAGING (
    ID BIGINT IDENTITY(1,1) NOT NULL,
    CONSTRAINT PK_STAGING PRIMARY KEY CLUSTERED (ID ASC)
);
GO

-- Source staging table for folder records
CREATE TABLE dbo.STAGING_FOLDERS (
    ID                      BIGINT IDENTITY(1,1) NOT NULL,
    folderIfUnmodifiedSince NVARCHAR(MAX) NULL,
    folderFolderID          NVARCHAR(MAX) NULL,
    folderStateCode         NVARCHAR(MAX) NULL,
    folderTypeCode          NVARCHAR(MAX) NULL,
    folderDescription       NVARCHAR(MAX) NULL,
    folderOwnerEntityId     NVARCHAR(MAX) NULL,
    staging_id              BIGINT NOT NULL,
    Is_Processed            CHAR(1) NOT NULL CONSTRAINT DF_STAGING_FOLDERS_IS_PROCESSED DEFAULT ('N'),
    CONSTRAINT PK_STAGING_FOLDERS PRIMARY KEY CLUSTERED (ID ASC),
    CONSTRAINT FK_STAGING_FOLDERS_STAGING FOREIGN KEY (staging_id)
        REFERENCES dbo.STAGING (ID)
);
GO

-- Destination table for processed folder records
CREATE TABLE dbo.TARGET_FOLDERS (
    ID                      BIGINT IDENTITY(1,1) NOT NULL,
    folderIfUnmodifiedSince NVARCHAR(MAX) NULL,
    folderFolderID          NVARCHAR(MAX) NULL,
    folderStateCode         NVARCHAR(MAX) NULL,
    folderTypeCode          NVARCHAR(MAX) NULL,
    folderDescription       NVARCHAR(MAX) NULL,
    folderOwnerEntityId     NVARCHAR(MAX) NULL,
    staging_id              BIGINT NOT NULL,
    CONSTRAINT PK_TARGET_FOLDERS PRIMARY KEY CLUSTERED (ID ASC)
);
GO

-- Change-detection hash store
CREATE TABLE dbo.HASH_REGISTRY (
    entity_name      VARCHAR(100) NOT NULL,
    row_hash         VARBINARY(32) NOT NULL,
    system_datetime  DATETIME2(7) NOT NULL
        CONSTRAINT DF_hash_registry_system_datetime DEFAULT (SYSUTCDATETIME()),
    updated_datetime DATETIME2(7) NOT NULL
        CONSTRAINT DF_hash_registry_updated_datetime DEFAULT (SYSUTCDATETIME())
);
GO

-- Execution audit log
CREATE TABLE dbo.SYS_DELTA_LOG (
    log_id           BIGINT IDENTITY(1,1) NOT NULL,
    entity_name      VARCHAR(100) NOT NULL,
    started_at       DATETIME2(7) NOT NULL
        CONSTRAINT DF_SYS_DELTA_LOG_started_at DEFAULT (SYSUTCDATETIME()),
    input_row_count  INT NULL,
    rows_unchanged   INT NULL,
    rows_upserted    INT NULL,
    rows_deduped     INT NULL,
    rows_retired     INT NULL,
    status           VARCHAR(10) NOT NULL,
    error_message    NVARCHAR(4000) NULL,
    duration_seconds INT NULL,
    CONSTRAINT PK_SYS_DELTA_LOG PRIMARY KEY CLUSTERED (log_id ASC)
);
GO
