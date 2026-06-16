-- ============================================================
-- PART D: BACKUP & RECOVERY
-- Database: AdventureWorks2022
-- Purpose:  Demonstrates Full, Differential, and Transaction Log
--           backups, integrity verification, and a full restore
--           sequence for the AdventureWorks2022 database.
-- ============================================================

-- WHY BACKUPS MATTER:
-- Backups are the last line of defence against data loss caused by
-- hardware failure, accidental deletion, corruption, or ransomware.
-- SQL Server supports three backup types that work together:
--   1. FULL       – a complete snapshot of the entire database.
--   2. DIFFERENTIAL – only the pages that changed since the last Full.
--   3. TRANSACTION LOG (T-Log) – every committed transaction since
--      the last log backup, enabling point-in-time recovery.
-- Together they let you minimise both data loss (RPO) and downtime (RTO).

DECLARE @BackupPath NVARCHAR(256) = N'C:\SQLBackups\AdventureWorks2022\';


-- Switch to the master database so we can issue database-level commands
-- (BACKUP DATABASE, RESTORE) without being blocked by an active user connection.
USE master;
GO


-- ============================================================
-- SECTION 1: FULL BACKUP
-- ============================================================
-- 

DECLARE @FullBackupFile NVARCHAR(512) =
   
    N'C:\SQLBackups\AdventureWorks2022\AdventureWorks2022_FULL_'
    + REPLACE(REPLACE(CONVERT(NVARCHAR, GETDATE(), 120), ':', '-'), ' ', '_')
    + N'.bak';

BACKUP DATABASE AdventureWorks2022
TO DISK = @FullBackupFile
WITH
    
    NAME           = N'AdventureWorks2022 - Full Database Backup',
    DESCRIPTION    = N'Full backup taken by SCOA031 DBA Project',

    -- COMPRESSION reduces the backup file size (often 60-80% smaller)
    -- and speeds up the write — a win for both storage and time.
    COMPRESSION,

    -- STATS = 10 prints a progress message every 10% so you can
    -- monitor long-running backups in SSMS or the SQL Agent job log.
    STATS          = 10,

    -- CHECKSUM computes a checksum over every backup page.
    -- If the file is corrupted on disk, RESTORE VERIFYONLY will
    -- catch it before you need the backup in an emergency.
    CHECKSUM;
GO

PRINT 'Full backup completed.';
GO


-- ============================================================
-- SECTION 2: DIFFERENTIAL BACKUP
-- ============================================================

DECLARE @DiffBackupFile NVARCHAR(512) =
    N'C:\SQLBackups\AdventureWorks2022\AdventureWorks2022_DIFF_'
    + REPLACE(REPLACE(CONVERT(NVARCHAR, GETDATE(), 120), ':', '-'), ' ', '_')
    + N'.bak';

BACKUP DATABASE AdventureWorks2022
TO DISK = @DiffBackupFile
WITH
    DIFFERENTIAL,   -- Key option: only changed pages since last Full
    NAME           = N'AdventureWorks2022 - Differential Backup',
    DESCRIPTION    = N'Differential backup taken by SCOA031 DBA Project',
    COMPRESSION,
    STATS          = 10,
    CHECKSUM;
GO

PRINT 'Differential backup completed.';
GO


-- ============================================================
-- SECTION 3: TRANSACTION LOG BACKUP
--
-- ============================================================

-- Ensure the database is in FULL recovery model.
-- FULL recovery: every transaction is fully logged, enabling
-- point-in-time restore to any second within the log chain.
ALTER DATABASE AdventureWorks2022 SET RECOVERY FULL;
GO

DECLARE @LogBackupFile NVARCHAR(512) =
    -- T-Log files use the .trn extension by convention,
    -- making them easy to distinguish from .bak files.
    N'C:\SQLBackups\AdventureWorks2022\AdventureWorks2022_LOG_'
    + REPLACE(REPLACE(CONVERT(NVARCHAR, GETDATE(), 120), ':', '-'), ' ', '_')
    + N'.trn';

-- BACKUP LOG (not BACKUP DATABASE) captures only log records.
BACKUP LOG AdventureWorks2022
TO DISK = @LogBackupFile
WITH
    NAME        = N'AdventureWorks2022 - Transaction Log Backup',
    DESCRIPTION = N'T-log backup taken by SCOA031 DBA Project',
    COMPRESSION,
    STATS       = 10,
    CHECKSUM;
GO

PRINT 'Transaction log backup completed.';
GO


-- ============================================================
-- SECTION 4: VERIFY BACKUP INTEGRITY
-- ============================================================


-- Verify the most recent full backup
-- (Replace <timestamp> with the actual value from Section 1)
RESTORE VERIFYONLY
FROM DISK = N'C:\SQLBackups\AdventureWorks2022\AdventureWorks2022_FULL_<timestamp>.bak'
WITH CHECKSUM;  -- Re-validates the checksums written during the backup
GO

-- ---- Backup History Report ----

SELECT
    bs.database_name,
    bs.backup_start_date,
    bs.backup_finish_date,

    -- Raw type code (D / I / L)
    bs.type AS BackupType,

 
    CASE bs.type
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Transaction Log'
    END AS BackupTypeName,

    bmf.physical_device_name AS BackupFile,

    -- Convert bytes → MB for readability
    bs.backup_size / 1024 / 1024            AS BackupSizeMB,
    bs.compressed_backup_size / 1024 / 1024AS CompressedSizeMB

FROM msdb.dbo.backupset         bs
JOIN msdb.dbo.backupmediafamily bmf
    ON bs.media_set_id = bmf.media_set_id

-- Filter to only our target database
WHERE  bs.database_name = 'AdventureWorks2022'

-- Most recent first so the latest backup appears at the top
ORDER BY bs.backup_start_date DESC;
GO


-- ============================================================
-- SECTION 5: RESTORE DEMONSTRATION
-- ============================================================

-- PHASE 1: Restore the Full backup

RESTORE DATABASE AdventureWorks2022_Restored
FROM DISK = N'C:\SQLBackups\AdventureWorks2022\AdventureWorks2022_FULL_<timestamp>.bak'
WITH
    MOVE N'AdventureWorks2022'
        TO N'C:\SQLData\AdventureWorks2022_Restored.mdf',     -- Redirect MDF
    MOVE N'AdventureWorks2022_log'
        TO N'C:\SQLData\AdventureWorks2022_Restored_log.ldf', -- Redirect LDF
    NORECOVERY,   -- Keep in restoring state; Differential still to come
    STATS = 10;
GO

-- PHASE 2: Apply the Differential backup

RESTORE DATABASE AdventureWorks2022_Restored
FROM DISK = N'C:\SQLBackups\AdventureWorks2022\AdventureWorks2022_DIFF_<timestamp>.bak'
WITH
    NORECOVERY,   -- Keep in restoring state; T-Log(s) still to come
    STATS = 10;
GO

-- PHASE 3: Apply the Transaction Log backup

RESTORE LOG AdventureWorks2022_Restored
FROM DISK = N'C:\SQLBackups\AdventureWorks2022\AdventureWorks2022_LOG_<timestamp>.trn'
WITH
    RECOVERY,     -- Final restore: bring database online now
    STATS = 10;
GO

PRINT 'Database restored successfully as AdventureWorks2022_Restored';
GO