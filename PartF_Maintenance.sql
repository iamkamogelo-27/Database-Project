-- ============================================================
-- PART F: MAINTENANCE & SERVER HEALTH
-- ============================================================

USE AdventureWorks2022;
GO

-- ============================================================
-- SECTION 1: INDEX REBUILD / REORGANIZE MAINTENANCE
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.usp_MaintainIndexes
    @RebuildThreshold     FLOAT = 30.0,   -- % fragmentation → REBUILD
    @ReorganizeThreshold  FLOAT = 10.0,   -- % fragmentation → REORGANIZE
    @MinPageCount         INT   = 100      -- Ignore tiny indexes
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SchemaName  NVARCHAR(128);
    DECLARE @TableName   NVARCHAR(128);
    DECLARE @IndexName   NVARCHAR(128);
    DECLARE @Frag        FLOAT;
    DECLARE @Action      NVARCHAR(20);
    DECLARE @SQL         NVARCHAR(MAX);

    DECLARE idx_cursor CURSOR FOR
        SELECT
            OBJECT_SCHEMA_NAME(ips.object_id)              AS SchemaName,
            OBJECT_NAME(ips.object_id)                     AS TableName,
            i.name                                         AS IndexName,
            ips.avg_fragmentation_in_percent               AS Fragmentation,
            CASE
                WHEN ips.avg_fragmentation_in_percent >= @RebuildThreshold    THEN 'REBUILD'
                WHEN ips.avg_fragmentation_in_percent >= @ReorganizeThreshold THEN 'REORGANIZE'
            END AS Action
        FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
        JOIN sys.indexes i
            ON ips.object_id = i.object_id AND ips.index_id = i.index_id
        WHERE i.name IS NOT NULL
          AND ips.page_count > @MinPageCount
          AND ips.avg_fragmentation_in_percent >= @ReorganizeThreshold;

    OPEN idx_cursor;
    FETCH NEXT FROM idx_cursor INTO @SchemaName, @TableName, @IndexName, @Frag, @Action;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Action = 'REBUILD'
        BEGIN
            SET @SQL = 'ALTER INDEX [' + @IndexName + '] ON ['
                + @SchemaName + '].[' + @TableName + '] REBUILD WITH (ONLINE = OFF, FILLFACTOR = 80);';
        END
        ELSE IF @Action = 'REORGANIZE'
        BEGIN
            SET @SQL = 'ALTER INDEX [' + @IndexName + '] ON ['
                + @SchemaName + '].[' + @TableName + '] REORGANIZE;';
        END

        PRINT @Action + ': [' + @SchemaName + '].[' + @TableName + '].[' + @IndexName
            + '] - ' + CAST(ROUND(@Frag, 2) AS NVARCHAR) + '% fragmented';

        EXEC sp_executesql @SQL;

        FETCH NEXT FROM idx_cursor INTO @SchemaName, @TableName, @IndexName, @Frag, @Action;
    END

    CLOSE idx_cursor;
    DEALLOCATE idx_cursor;

    PRINT 'Index maintenance completed at ' + CAST(GETDATE() AS NVARCHAR);
END;
GO

-- ============================================================
-- SECTION 2: DATABASE INTEGRITY CHECK (DBCC CHECKDB)
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.usp_DatabaseIntegrityCheck
    @RepairMode NVARCHAR(30) = 'NONE'  -- NONE | REPAIR_REBUILD | REPAIR_ALLOW_DATA_LOSS
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @StartTime DATETIME = GETDATE();

    PRINT '=== DBCC CHECKDB starting at ' + CAST(@StartTime AS NVARCHAR) + ' ===';

    -- Run integrity check
    IF @RepairMode = 'NONE'
    BEGIN
        DBCC CHECKDB ('AdventureWorks2022') WITH NO_INFOMSGS, ALL_ERRORMSGS;
    END
    ELSE IF @RepairMode = 'REPAIR_REBUILD'
    BEGIN
        -- Requires single-user mode
        ALTER DATABASE AdventureWorks2022 SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DBCC CHECKDB ('AdventureWorks2022', REPAIR_REBUILD) WITH NO_INFOMSGS;
        ALTER DATABASE AdventureWorks2022 SET MULTI_USER;
    END
    ELSE IF @RepairMode = 'REPAIR_ALLOW_DATA_LOSS'
    BEGIN
        ALTER DATABASE AdventureWorks2022 SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DBCC CHECKDB ('AdventureWorks2022', REPAIR_ALLOW_DATA_LOSS) WITH NO_INFOMSGS;
        ALTER DATABASE AdventureWorks2022 SET MULTI_USER;
    END

    -- Also run table-level checks
    DBCC CHECKCATALOG ('AdventureWorks2022') WITH NO_INFOMSGS;
    DBCC CHECKALLOC ('AdventureWorks2022')   WITH NO_INFOMSGS;

    PRINT '=== DBCC CHECKDB completed at ' + CAST(GETDATE() AS NVARCHAR) + ' ===';
    PRINT 'Duration: ' + CAST(DATEDIFF(SECOND, @StartTime, GETDATE()) AS NVARCHAR) + ' seconds';
END;
GO

-- ============================================================
-- SECTION 3: SQL SERVER AGENT JOBS (SCHEDULED AUTOMATION)
-- ============================================================

USE msdb;
GO

-- ------------------------------------------------------------
-- JOB 1: Weekly Full Backup (Sundays at 23:00)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'AdventureWorks_FullBackup_Weekly')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name = N'AdventureWorks_FullBackup_Weekly',
        @description = N'Weekly full backup of AdventureWorks2022 - SCOA031 Project';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name      = N'AdventureWorks_FullBackup_Weekly',
        @step_name     = N'Execute Full Backup',
        @subsystem     = N'TSQL',
        @command       = N'
DECLARE @BackupFile NVARCHAR(512) =
    N''C:\SQLBackups\AdventureWorks2022\AdventureWorks2022_FULL_''
    + REPLACE(REPLACE(CONVERT(NVARCHAR,GETDATE(),120),'':'',''-''),'' '',''_'')
    + N''.bak'';
BACKUP DATABASE AdventureWorks2022
TO DISK = @BackupFile
WITH COMPRESSION, CHECKSUM, STATS = 10;',
        @database_name = N'master';

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name     = N'Weekly_Sunday_2300',
        @freq_type         = 8,          -- Weekly
        @freq_interval     = 1,          -- Sunday
        @freq_recurrence_factor = 1,
        @active_start_time = 230000;     -- 23:00:00

    EXEC msdb.dbo.sp_attach_schedule
        @job_name      = N'AdventureWorks_FullBackup_Weekly',
        @schedule_name = N'Weekly_Sunday_2300';

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'AdventureWorks_FullBackup_Weekly';

    PRINT 'Full Backup job created.';
END
GO

-- ------------------------------------------------------------
-- JOB 2: Nightly Differential Backup (Mon-Sat at 23:00)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'AdventureWorks_DiffBackup_Nightly')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name    = N'AdventureWorks_DiffBackup_Nightly',
        @description = N'Nightly differential backup of AdventureWorks2022';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name      = N'AdventureWorks_DiffBackup_Nightly',
        @step_name     = N'Execute Differential Backup',
        @subsystem     = N'TSQL',
        @command       = N'
DECLARE @BackupFile NVARCHAR(512) =
    N''C:\SQLBackups\AdventureWorks2022\AdventureWorks2022_DIFF_''
    + REPLACE(REPLACE(CONVERT(NVARCHAR,GETDATE(),120),'':'',''-''),'' '',''_'')
    + N''.bak'';
BACKUP DATABASE AdventureWorks2022
TO DISK = @BackupFile
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, STATS = 10;',
        @database_name = N'master';

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name          = N'Nightly_MonSat_2300',
        @freq_type              = 8,
        @freq_interval          = 126,   -- Mon(2)+Tue(4)+Wed(8)+Thu(16)+Fri(32)+Sat(64) = 126
        @freq_recurrence_factor = 1,
        @active_start_time      = 230000;

    EXEC msdb.dbo.sp_attach_schedule
        @job_name      = N'AdventureWorks_DiffBackup_Nightly',
        @schedule_name = N'Nightly_MonSat_2300';

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'AdventureWorks_DiffBackup_Nightly';

    PRINT 'Differential Backup job created.';
END
GO

-- ------------------------------------------------------------
-- JOB 3: Hourly Transaction Log Backup
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'AdventureWorks_LogBackup_Hourly')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name    = N'AdventureWorks_LogBackup_Hourly',
        @description = N'Hourly transaction log backup of AdventureWorks2022';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name      = N'AdventureWorks_LogBackup_Hourly',
        @step_name     = N'Execute Log Backup',
        @subsystem     = N'TSQL',
        @command       = N'
DECLARE @BackupFile NVARCHAR(512) =
    N''C:\SQLBackups\AdventureWorks2022\AdventureWorks2022_LOG_''
    + REPLACE(REPLACE(CONVERT(NVARCHAR,GETDATE(),120),'':'',''-''),'' '',''_'')
    + N''.trn'';
BACKUP LOG AdventureWorks2022
TO DISK = @BackupFile
WITH COMPRESSION, CHECKSUM, STATS = 10;',
        @database_name = N'master';

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name          = N'Hourly_Every60Min',
        @freq_type              = 4,     -- Daily
        @freq_interval          = 1,
        @freq_subday_type       = 8,     -- Hours
        @freq_subday_interval   = 1;     -- Every 1 hour

    EXEC msdb.dbo.sp_attach_schedule
        @job_name      = N'AdventureWorks_LogBackup_Hourly',
        @schedule_name = N'Hourly_Every60Min';

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'AdventureWorks_LogBackup_Hourly';

    PRINT 'Log Backup job created.';
END
GO

-- ------------------------------------------------------------
-- JOB 4: Weekly Index Maintenance (Saturdays at 01:00)
-- ------------------------------------------------------------
USE msdb;
GO

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'AdventureWorks_IndexMaintenance_Weekly')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name    = N'AdventureWorks_IndexMaintenance_Weekly',
        @description = N'Weekly index rebuild/reorganize for AdventureWorks2022';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name      = N'AdventureWorks_IndexMaintenance_Weekly',
        @step_name     = N'Run Index Maintenance',
        @subsystem     = N'TSQL',
        @command       = N'USE AdventureWorks2022; EXEC dbo.usp_MaintainIndexes;',
        @database_name = N'AdventureWorks2022';

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name          = N'Weekly_Saturday_0100',
        @freq_type              = 8,
        @freq_interval          = 64,    -- Saturday
        @freq_recurrence_factor = 1,
        @active_start_time      = 010000;

    EXEC msdb.dbo.sp_attach_schedule
        @job_name      = N'AdventureWorks_IndexMaintenance_Weekly',
        @schedule_name = N'Weekly_Saturday_0100';

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'AdventureWorks_IndexMaintenance_Weekly';

    PRINT 'Index Maintenance job created.';
END
GO

-- ------------------------------------------------------------
-- JOB 5: Weekly DBCC CHECKDB (Sundays at 01:00)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'AdventureWorks_DBCC_Weekly')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name    = N'AdventureWorks_DBCC_Weekly',
        @description = N'Weekly database integrity check for AdventureWorks2022';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name      = N'AdventureWorks_DBCC_Weekly',
        @step_name     = N'Run DBCC CHECKDB',
        @subsystem     = N'TSQL',
        @command       = N'USE AdventureWorks2022; EXEC dbo.usp_DatabaseIntegrityCheck;',
        @database_name = N'AdventureWorks2022';

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name          = N'Weekly_Sunday_0100',
        @freq_type              = 8,
        @freq_interval          = 1,     -- Sunday
        @freq_recurrence_factor = 1,
        @active_start_time      = 010000;

    EXEC msdb.dbo.sp_attach_schedule
        @job_name      = N'AdventureWorks_DBCC_Weekly',
        @schedule_name = N'Weekly_Sunday_0100';

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'AdventureWorks_DBCC_Weekly';

    PRINT 'DBCC CHECKDB job created.';
END
GO

-- View all created jobs
SELECT
    j.name AS JobName,
    j.description,
    j.enabled,
    s.name AS ScheduleName,
    s.active_start_time
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
JOIN msdb.dbo.sysschedules s    ON js.schedule_id = s.schedule_id
WHERE j.name LIKE 'AdventureWorks%'
ORDER BY j.name;
GO
