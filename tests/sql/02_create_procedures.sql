-- =============================================================
-- 02_create_procedures.sql
-- Creates the stored procedures under test.
-- =============================================================

-- USP_DELTA_FOLDERS
IF OBJECT_ID('dbo.USP_DELTA_FOLDERS', 'P') IS NOT NULL
    DROP PROCEDURE dbo.USP_DELTA_FOLDERS;
GO

CREATE PROCEDURE [dbo].[USP_DELTA_FOLDERS]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entity_name        VARCHAR(100)  = 'FOLDERS';
    DECLARE @current_timestamp  DATETIME2(7)  = SYSUTCDATETIME();
    DECLARE @start_time         DATETIME2(7)  = SYSUTCDATETIME();

    DECLARE @log_id             BIGINT = 0;
    DECLARE @input_row_count    INT    = 0;
    DECLARE @rows_unchanged     INT    = 0;
    DECLARE @rows_upserted      INT    = 0;
    DECLARE @rows_deduped       INT    = 0;
    DECLARE @rows_retired       INT    = 0;
    DECLARE @duration_seconds   INT    = 0;

    INSERT INTO dbo.SYS_DELTA_LOG (entity_name, status)
    VALUES (@entity_name, 'RUNNING');

    SET @log_id = SCOPE_IDENTITY();

BEGIN TRY
    BEGIN TRANSACTION;

        DECLARE @lock_result INT;

        EXEC @lock_result = sp_getapplock
            @Resource    = 'USP_DELTA_FOLDERS',
            @LockMode    = 'Exclusive',
            @LockOwner   = 'Transaction',
            @LockTimeout = 30000;

        IF @lock_result < 0
        BEGIN
            RAISERROR('Could not acquire lock. SP may already be running.', 16, 1);
            RETURN;
        END

        IF OBJECT_ID('tempdb..#staging_hash') IS NOT NULL
            DROP TABLE #staging_hash;

        SELECT
            x.*,
            ROW_NUMBER() OVER (PARTITION BY x.row_hash ORDER BY x.staging_row_id) AS rn
        INTO #staging_hash
        FROM
        (
            SELECT
                s.ID AS staging_row_id,
                s.folderIfUnmodifiedSince,
                s.folderFolderID,
                s.folderStateCode,
                s.folderTypeCode,
                s.folderDescription,
                s.folderOwnerEntityId,
                s.staging_id,
                HASHBYTES(
                    'SHA2_256',
                    CONVERT(
                        VARBINARY(8000),
                        CONCAT_WS('|',
                            ISNULL(s.folderIfUnmodifiedSince, ''),
                            ISNULL(s.folderFolderID, ''),
                            ISNULL(s.folderStateCode, ''),
                            ISNULL(s.folderTypeCode, ''),
                            ISNULL(s.folderDescription, ''),
                            ISNULL(s.folderOwnerEntityId, '')
                        )
                    )
                ) AS row_hash
            FROM dbo.STAGING_FOLDERS s
            WHERE s.Is_Processed = 'N'
        ) x;

        SELECT
            @input_row_count = COUNT(*),
            @rows_deduped    = SUM(CASE WHEN rn > 1 THEN 1 ELSE 0 END)
        FROM #staging_hash;

        IF @input_row_count = 0
        BEGIN
            COMMIT TRANSACTION;

            UPDATE dbo.SYS_DELTA_LOG
            SET
                input_row_count  = 0,
                rows_unchanged   = 0,
                rows_upserted    = 0,
                rows_deduped     = 0,
                rows_retired     = 0,
                duration_seconds = DATEDIFF(SECOND, @start_time, SYSUTCDATETIME()),
                status           = 'SUCCESS'
            WHERE log_id = @log_id;

            RETURN;
        END

        CREATE NONCLUSTERED INDEX IX_staging_hash
            ON #staging_hash (row_hash);

        -- Mark unchanged rows (hash already in registry)
        UPDATE hr
        SET hr.updated_datetime = @current_timestamp
        FROM dbo.HASH_REGISTRY hr
        INNER JOIN #staging_hash sh
            ON hr.entity_name = @entity_name
            AND hr.row_hash   = sh.row_hash
        WHERE sh.rn = 1;

        SET @rows_unchanged = @@ROWCOUNT;

        -- Insert new hashes
        INSERT INTO dbo.HASH_REGISTRY
        (
            entity_name,
            row_hash,
            system_datetime,
            updated_datetime
        )
        SELECT
            @entity_name,
            sh.row_hash,
            @current_timestamp,
            @current_timestamp
        FROM #staging_hash sh
        LEFT JOIN dbo.HASH_REGISTRY hr
            ON hr.entity_name = @entity_name
            AND hr.row_hash   = sh.row_hash
        WHERE hr.row_hash IS NULL
          AND sh.rn = 1;

        -- Insert new rows into target (only truly new hashes)
        INSERT INTO dbo.TARGET_FOLDERS
        (
            folderIfUnmodifiedSince,
            folderFolderID,
            folderStateCode,
            folderTypeCode,
            folderDescription,
            folderOwnerEntityId,
            staging_id
        )
        SELECT
            sh.folderIfUnmodifiedSince,
            sh.folderFolderID,
            sh.folderStateCode,
            sh.folderTypeCode,
            sh.folderDescription,
            sh.folderOwnerEntityId,
            sh.staging_id
        FROM #staging_hash sh
        LEFT JOIN dbo.HASH_REGISTRY hr
            ON hr.entity_name      = @entity_name
            AND hr.row_hash        = sh.row_hash
            AND hr.system_datetime < @current_timestamp
        WHERE hr.row_hash IS NULL
          AND sh.rn = 1;

        SET @rows_upserted = @@ROWCOUNT;

        -- Retire hashes not seen in this batch
        DELETE FROM dbo.HASH_REGISTRY
        WHERE entity_name     = @entity_name
          AND updated_datetime < @current_timestamp;

        SET @rows_retired = @@ROWCOUNT;

        -- Mark staging rows as processed
        UPDATE s
        SET s.Is_Processed = 'Y'
        FROM dbo.STAGING_FOLDERS s
        INNER JOIN #staging_hash sh
            ON s.ID = sh.staging_row_id;

        SET @duration_seconds = DATEDIFF(SECOND, @start_time, SYSUTCDATETIME());

        COMMIT TRANSACTION;

        UPDATE dbo.SYS_DELTA_LOG
        SET
            input_row_count  = @input_row_count,
            rows_unchanged   = @rows_unchanged,
            rows_upserted    = @rows_upserted,
            rows_deduped     = @rows_deduped,
            rows_retired     = @rows_retired,
            duration_seconds = @duration_seconds,
            status           = 'SUCCESS'
        WHERE log_id = @log_id;

END TRY
BEGIN CATCH

    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    UPDATE dbo.SYS_DELTA_LOG
    SET
        input_row_count  = @input_row_count,
        rows_unchanged   = @rows_unchanged,
        rows_upserted    = @rows_upserted,
        rows_deduped     = @rows_deduped,
        rows_retired     = @rows_retired,
        duration_seconds = DATEDIFF(SECOND, @start_time, SYSUTCDATETIME()),
        status           = 'FAILED',
        error_message    = ERROR_MESSAGE()
    WHERE log_id = @log_id;

    DECLARE @err_msg   NVARCHAR(4000) = ERROR_MESSAGE();
    DECLARE @err_sev   INT            = ERROR_SEVERITY();
    DECLARE @err_state INT            = ERROR_STATE();

    RAISERROR(@err_msg, @err_sev, @err_state);

END CATCH

END;
GO

-- =============================================================
-- USP_DELTA_MASTER
-- Orchestrates all delta procedures. Each sub-call is wrapped
-- in TRY/CATCH so individual failures do not stop the batch.
-- =============================================================
IF OBJECT_ID('dbo.USP_DELTA_MASTER', 'P') IS NOT NULL
    DROP PROCEDURE dbo.USP_DELTA_MASTER;
GO

CREATE PROCEDURE [dbo].[USP_DELTA_MASTER]
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY EXEC dbo.USP_DELTA_ACCESSCONTROLGRANTS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ADDRESSES; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ADDRESS_ADMINISTRATIVEAREAS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ADDRESSES_LOCALITIES; END TRY BEGIN CATCH END CATCH;

    BEGIN TRY EXEC dbo.USP_DELTA_ASSET_REPORTINGCODE; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSET_ALERTTHRESHOOLDPERCENTAGEOVERRIDES; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSET_CUSTOMDATA; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSET_HAIRCUTPERCENTAGEOVERRIDE; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSET_RECHARACTERISTICS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSETT_RECUSTOMPANEL; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSET_REDETAILS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSET_REFS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSET_USERDEFINEDFIELDS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSETCASH; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSETLIFEINSURANCES; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSETMISCELLANEOUS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_ASSETREALESTATES; END TRY BEGIN CATCH END CATCH;

    BEGIN TRY EXEC dbo.USP_DELTA_LEGALENFORCEABLEDOCUMENTGUARANT; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_LEGALENFORCEABLEDOCUMENTSECURITYINTERESTS; END TRY BEGIN CATCH END CATCH;

    BEGIN TRY EXEC dbo.USP_DELTA_LEGALENTITIES_CUSTOMDATA; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_LEGALENTITIESJURISTIC; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_LEGALENTITIESNATURAL; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_LEGALENTITIESSERVICEPROVIDERS; END TRY BEGIN CATCH END CATCH;

    BEGIN TRY EXEC dbo.USP_DELTA_LINKCOLLECTIONASSET; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_LINKSCOLLECTIONEXPOSURE; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_LINKSCOLLECTIONLEGALENTITY; END TRY BEGIN CATCH END CATCH;

    BEGIN TRY EXEC dbo.USP_DELTA_LINKSLEGALENFORCEABLEDOCUMENTASSET; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_LINKSLEGALENFORCEABLEDOCUMENTCOLLECTION; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_LINKSLEGALENFORCEABLEDOCUMENTEXPOSURE; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_LINKSLEGALENFORCEABLEDOCUMENTLEGALENTITY; END TRY BEGIN CATCH END CATCH;

    BEGIN TRY EXEC dbo.USP_DELTA_LINKSLEGALENTITYASSET; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_LINKSLEGALENTITYDOCUMENT; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_LINKSLEGALENTITYEXPOSURE; END TRY BEGIN CATCH END CATCH;

    BEGIN TRY EXEC dbo.USP_DELTA_NOTES; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_TASKS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_TELEPHONENUMBERS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_VALUATIONS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_CONDITIONS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_COLLATERALS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_CONTACTDETAILS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_DOCUMENTS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_CURRENTPHYSICALLOCATION; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_CUSTOMDATA; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_FACILITIES; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_FOLDERS; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_GENERALINSURANCES; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC dbo.USP_DELTA_PREMISES; END TRY BEGIN CATCH END CATCH;

END;
GO
