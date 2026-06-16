-- ========================================================================
-- PART E: TRIGGERS, LOGGING & EMAIL ALERTS
-- ========================================================================

USE AdventureWorks2022;
GO

-- ------------------------------------------------------------------------
-- TASK 1: CREATE AUDIT TABLE
-- ------------------------------------------------------------------------

IF OBJECT_ID('dbo.AuditTable', 'U') IS NOT NULL
    DROP TABLE dbo.AuditTable;
GO

CREATE TABLE dbo.AuditTable (
    AuditID       INT IDENTITY(1,1) PRIMARY KEY,
    TableName     NVARCHAR(128) NOT NULL,
    ActionType    NVARCHAR(10) NOT NULL
                  CHECK (ActionType IN ('INSERT','UPDATE','DELETE')),
    AuditUser     NVARCHAR(128) NOT NULL DEFAULT SYSTEM_USER,
    AuditDateTime DATETIME NOT NULL DEFAULT GETDATE(),
    Description   NVARCHAR(MAX) NOT NULL
);
GO
-- Verify table exists
SELECT * FROM dbo.AuditTable;

-- ------------------------------------------------------------------------
-- TASK 2: CREATE CUSTOMER AND PRODUCT TRIGGERS
-- ------------------------------------------------------------------------

-- Customer INSERT trigger
CREATE TRIGGER trg_Customer_Insert
ON Sales.Customer
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.AuditTable
        (TableName, ActionType, AuditUser, AuditDateTime, Description)
    SELECT
        'Sales.Customer',
        'INSERT',
        SYSTEM_USER,
        GETDATE(),
        'A new record was inserted by ' + SYSTEM_USER
        + ' for customer with CustomerID: '
        + CAST(i.CustomerID AS NVARCHAR(20))
    FROM inserted i;
END;
GO

-- Customer UPDATE trigger
CREATE OR ALTER TRIGGER trg_Customer_Update
ON Sales.Customer
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.AuditTable
        (TableName, ActionType, AuditUser, AuditDateTime, Description)
    SELECT
        'Sales.Customer',
        'UPDATE',
        SYSTEM_USER,
        GETDATE(),
        'The record updated by ' + SYSTEM_USER
        + ' belongs to customer with CustomerID: '
        + CAST(i.CustomerID AS NVARCHAR(20))
    FROM inserted i;
END;
GO

-----*****
-- Customer DELETE trigger
CREATE OR ALTER TRIGGER trg_Customer_Delete
ON Sales.Customer
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.AuditTable
        (TableName, ActionType, AuditUser, AuditDateTime, Description)
    SELECT
        'Sales.Customer',
        'DELETE',
        SYSTEM_USER,
        GETDATE(),
        'The record that was deleted by ' + SYSTEM_USER
        + ' belongs to customer with CustomerID: '
        + CAST(d.CustomerID AS NVARCHAR(20))
    FROM deleted d;
END;
GO

SELECT name, is_disabled, create_date
FROM sys.triggers
WHERE name LIKE 'trg_Customer%';


-- Product INSERT trigger
CREATE TRIGGER trg_Product_Insert
ON Production.Product
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.AuditTable
        (TableName, ActionType, AuditUser, AuditDateTime, Description)
    SELECT
        'Production.Product',
        'INSERT',
        SYSTEM_USER,
        GETDATE(),
        'A new record was inserted by ' + SYSTEM_USER
        + ' for product with ProductID: '
        + CAST(i.ProductID AS NVARCHAR(20))
    FROM inserted i;
END;
GO

-- Product UPDATE trigger
CREATE TRIGGER trg_Product_Update
ON Production.Product
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.AuditTable
        (TableName, ActionType, AuditUser, AuditDateTime, Description)
    SELECT
        'Production.Product',
        'UPDATE',
        SYSTEM_USER,
        GETDATE(),
        'The record updated by ' + SYSTEM_USER
        + ' belongs to product with ProductID: '
        + CAST(i.ProductID AS NVARCHAR(20))
    FROM inserted i;
END;
GO

-- Product DELETE trigger
CREATE TRIGGER trg_Product_Delete
ON Production.Product
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.AuditTable
        (TableName, ActionType, AuditUser, AuditDateTime, Description)
    SELECT
        'Production.Product',
        'DELETE',
        SYSTEM_USER,
        GETDATE(),
        'The record that was deleted by ' + SYSTEM_USER
        + ' belongs to product with ProductID: '
        + CAST(i.ProductID AS NVARCHAR(20))
    FROM deleted d;
END;
GO

SELECT name, is_disabled, create_date
FROM sys.triggers
WHERE name LIKE 'trg_Product%';

-- ---------------------------------------------------------------------
-- TASK 3: LOGGING
-- ---------------------------------------------------------------------

-- Verification: Query AuditTable to Confirm Logging Works
SELECT 
    t.name          AS TriggerName,
    OBJECT_NAME(t.parent_id) AS TableName,
    t.is_disabled,
    t.create_date,
    t.modify_date
FROM sys.triggers t
WHERE t.name IN (
    'trg_Customer_Insert',
    'trg_Customer_Update', 
    'trg_Customer_Delete',
    'trg_Product_Insert',
    'trg_Product_Update',
    'trg_Product_Delete'
)
ORDER BY t.name;



-- --------------------------------------------------------------------
-- TASK 4: EMAIL ALERTS
-- --------------------------------------------------------------------

-- Enable Database Mail
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
GO

EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;
GO

-- Create a Mail Account
EXEC msdb.dbo.sysmail_add_account_sp
    @account_name    = 'DBMailAccount',
    @description     = 'Database Mail Account for Alerts',
    @email_address   = 'siligakhwathi@gmail.com',
    @display_name    = 'SQL Server DB Alerts',
    @mailserver_name = 'smtp.yourdomain.com',
    @port            = 587,
    @enable_ssl      = 1,
    @username        = 'siligakhwathi@gmail.com',
    @password        = 'xatt txcy psxs rjad';
GO

-- Create a Mail Profile
EXEC msdb.dbo.sysmail_add_profile_sp
    @profile_name = 'DBMailProfile',
    @description  = 'Profile for automated DB alert emails';
GO

-- Link Account to Profile
EXEC msdb.dbo.sysmail_add_profileaccount_sp
    @profile_name    = 'DBMailProfile',
    @account_name    = 'DBMailAccount',
    @sequence_number = 1;
GO

-- Grant Public Access to Profile
EXEC msdb.dbo.sysmail_add_principalprofile_sp
    @profile_name   = 'DBMailProfile',
    @principal_name = 'public',
    @is_default     = 1;
GO

-- Test the Mail Configuration
EXEC msdb.dbo.sp_send_dbmail
    @profile_name = 'DBMailProfile',
    @recipients   = 'siligakhwathi@gmail.com',
    @subject      = 'Database Mail Test',
    @body         = 'Database Mail is configured and working correctly.';
GO

-- Alert 1: Email When a Product Price Changes
CREATE OR ALTER TRIGGER trg_Product_PriceChange_Alert
ON Production.Product
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(ListPrice)
    BEGIN
        DECLARE @ProductID  NVARCHAR(20);
        DECLARE @OldPrice   DECIMAL(18,2);
        DECLARE @NewPrice   DECIMAL(18,2);
        DECLARE @Body1      NVARCHAR(MAX);

        SELECT TOP 1
            @ProductID = CAST(i.ProductID AS NVARCHAR(20)),
            @OldPrice  = d.ListPrice,
            @NewPrice  = i.ListPrice
        FROM inserted i
        INNER JOIN deleted d ON i.ProductID = d.ProductID;

        SET @Body1 = 'Product price was changed by ' + SYSTEM_USER
                   + ' | ProductID: ' + @ProductID
                   + ' | Old Price: ' + CAST(@OldPrice AS NVARCHAR(20))
                   + ' | New Price: ' + CAST(@NewPrice AS NVARCHAR(20));

        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = 'DBMailProfile',
            @recipients   = 'siligakhwathi@gmail.com',
            @subject      = 'ALERT: Product Price Changed',
            @body         = @Body1;
    END;
END;
GO

-- Alert 2: Email When a Record is Deleted (Customer)
CREATE OR ALTER TRIGGER trg_Customer_Delete_Alert
ON Sales.Customer
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CustomerID NVARCHAR(20);
    DECLARE @Body2      NVARCHAR(MAX);

    SELECT TOP 1
        @CustomerID = CAST(CustomerID AS NVARCHAR(20))
    FROM deleted;

    SET @Body2 = 'A customer record was DELETED by ' + SYSTEM_USER
               + ' | CustomerID: ' + @CustomerID;
               EXEC msdb.dbo.sp_send_dbmail
        @profile_name = 'DBMailProfile',
        @recipients   = 'siligakhwathi@gmail.com',
        @subject      = 'ALERT: Customer Record Deleted',
        @body         = @Body2;
END;
GO


-- Alert 3: Email When a Record is Deleted (Product)
DROP TRIGGER IF EXISTS Production.trg_Product_Delete_Alert;
GO
CREATE OR ALTER TRIGGER trg_Product_Delete_Alert
ON Production.Product
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ProductID NVARCHAR(20);
    DECLARE @Body3     NVARCHAR(MAX);

    SELECT TOP 1
        @ProductID = CAST(ProductID AS NVARCHAR(20))
    FROM deleted;

    SET @Body3 = 'A product record was DELETED by ' + SYSTEM_USER
               + ' | ProductID: ' + @ProductID;

               EXEC msdb.dbo.sp_send_dbmail
        @profile_name = 'DBMailProfile',
        @recipients   = 'siligakhwathi@gmail.com',
        @subject      = 'ALERT: Product Record Deleted',
        @body         = @Body3;
END;
GO

-- Alert 4: Email When a Critical Update Occurs (Customer)
CREATE OR ALTER TRIGGER trg_Customer_CriticalUpdate_Alert
ON Sales.Customer
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(TerritoryID)
    BEGIN
        DECLARE @CustID NVARCHAR(20);
        DECLARE @Body4  NVARCHAR(MAX);

        SELECT TOP 1
            @CustID = CAST(CustomerID AS NVARCHAR(20))
        FROM inserted;

        SET @Body4 = 'Critical customer data was modified by ' + SYSTEM_USER
                   + ' | CustomerID: ' + @CustID
                   + ' | Fields changed: TerritoryID';

        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = 'DBMailProfile',
            @recipients   = 'siligakhwathi@gmail.com',
            @subject      = 'ALERT: Critical Customer Data Updated',
            @body         = @Body4;
    END;
END;
GO


-- Verification: Check All Alert Triggers Exist and Are Active
SELECT
    name          AS TriggerName,
    OBJECT_NAME(parent_id) AS TableName,
    is_disabled,
    create_date
FROM sys.triggers
WHERE name IN (
    'trg_Product_PriceChange_Alert',
    'trg_Customer_Delete_Alert',
    'trg_Product_Delete_Alert',
    'trg_Customer_CriticalUpdate_Alert'
)
ORDER BY name;
GO

-- --------------------------------------------------------------------
-- TASK 5: CONDITIONAL ALERTS (ADVANCED)
-- --------------------------------------------------------------------

-- Conditional Alert 1: Price Change > 10%
CREATE OR ALTER TRIGGER trg_Product_ConditionalPriceAlert
ON Production.Product
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(ListPrice)
    BEGIN
        DECLARE @ProductID  NVARCHAR(20);
        DECLARE @OldPrice   DECIMAL(18,2);
        DECLARE @NewPrice   DECIMAL(18,2);
        DECLARE @PctChange  DECIMAL(10,4);
        DECLARE @Body1      NVARCHAR(MAX);

        SELECT TOP 1
            @ProductID = CAST(i.ProductID AS NVARCHAR(20)),
            @OldPrice  = d.ListPrice,
            @NewPrice  = i.ListPrice,
            @PctChange = ABS((i.ListPrice - d.ListPrice) 
                         / NULLIF(d.ListPrice, 0)) * 100
        FROM inserted i
        INNER JOIN deleted d ON i.ProductID = d.ProductID;

        -- Only send alert if price change is greater than 10%
        IF @PctChange > 10
        BEGIN
            SET @Body1 = 'PRICE CHANGE ALERT'
                       + ' | ProductID: '   + @ProductID
                       + ' | Old Price: '   + CAST(@OldPrice AS NVARCHAR(20))
                       + ' | New Price: '   + CAST(@NewPrice AS NVARCHAR(20))
                       + ' | Change %: '    + CAST(ROUND(@PctChange, 2) AS NVARCHAR(20)) + '%'
                       + ' | Changed by: '  + SYSTEM_USER;

            EXEC msdb.dbo.sp_send_dbmail
                @profile_name = 'DBMailProfile',
                @recipients   = 'siligakhwathi@gmail.com',
                @subject      = 'ALERT: Product Price Changed By More Than 10%',
                @body         = @Body1;
        END;
    END;
END;
GO


-- Conditional Alert 2: Sensitive Data Modified (Customer)
CREATE OR ALTER TRIGGER trg_Customer_SensitiveDataAlert
ON Sales.Customer
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Only fire when TerritoryID (sensitive field) is modified
    IF UPDATE(TerritoryID)
    BEGIN
        DECLARE @CustID NVARCHAR(20);
        DECLARE @OldTerr NVARCHAR(20);
        DECLARE @NewTerr NVARCHAR(20);
        DECLARE @Body2   NVARCHAR(MAX);

        SELECT TOP 1
            @CustID   = CAST(i.CustomerID  AS NVARCHAR(20)),
            @OldTerr  = CAST(d.TerritoryID AS NVARCHAR(20)),
            @NewTerr  = CAST(i.TerritoryID AS NVARCHAR(20))
        FROM inserted i
        INNER JOIN deleted d ON i.CustomerID = d.CustomerID;

        -- Only send alert if TerritoryID actually changed to a different value
        IF @OldTerr <> @NewTerr
        BEGIN
            SET @Body2 = 'SENSITIVE DATA ALERT'
                       + ' | CustomerID: '      + @CustID
                       + ' | Modified by: '     + SYSTEM_USER
                       + ' | Old TerritoryID: ' + @OldTerr
                       + ' | New TerritoryID: ' + @NewTerr;

            EXEC msdb.dbo.sp_send_dbmail
                @profile_name = 'DBMailProfile',
                @recipients   = 'siligakhwathi@gmail.com',
                @subject      = 'ALERT: Sensitive Customer Data Modified',
                @body         = @Body2;
        END;
    END;
END;
GO

-- Verification: Check Conditional Triggers Exist and Are Active
SELECT
    name                   AS TriggerName,
    OBJECT_NAME(parent_id) AS TableName,
    is_disabled,
    create_date
FROM sys.triggers
WHERE name IN (
    'trg_Product_ConditionalPriceAlert',
    'trg_Customer_SensitiveDataAlert'
)
ORDER BY name;
GO

SELECT * FROM Production.Product
-- Example: increase price by 20% (change 1 to your chosen ProductID)
UPDATE Production.Product
SET ListPrice = ListPrice * 1.20
WHERE ProductID = 1;
GO


DROP TRIGGER IF EXISTS Production.trg_Product_Audit;
GO
UPDATE Production.Product
SET ListPrice = ListPrice * 1.20
WHERE ProductID = 1;
GO

-- Example
UPDATE Production.Product
SET ListPrice = ListPrice * 1.20
WHERE ProductID = 1;
GO