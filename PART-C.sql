/*
PART C: PERFORMANCE OPTIMIZATION

Step 1: Identify slow queries (examples)
These are the kinds of queries that would
run slowly without proper indexes

SLOW QUERY EXAMPLE 1 (no index on OrderDate)
SELECT * FROM Sales.SalesOrderHeader WHERE OrderDate BETWEEN '2013-01-01' AND '2013-12-31'

SLOW QUERY EXAMPLE 2 (no index on ProductID in SalesOrderDetail)
SELECT ProductID, SUM(OrderQty) FROM Sales.SalesOrderDetail GROUP BY ProductID

Step 2: Create indexes to fix the slow queries
*/


-- PERFORMANCE TEST
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- BEFORE INDEX (slow)
SELECT *
FROM Sales.SalesOrderHeader
WHERE OrderDate BETWEEN '2013-01-01' AND '2013-12-31';

-- Index on OrderDate - speeds up date range queries for sales reports
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_SalesOrderHeader_OrderDate'
    AND object_id = OBJECT_ID('Sales.SalesOrderHeader')
)
CREATE NONCLUSTERED INDEX IX_SalesOrderHeader_OrderDate
ON Sales.SalesOrderHeader (OrderDate)
INCLUDE (CustomerID, TotalDue, SalesPersonID);

GO

-- AFTER INDEX (optimized)
SELECT SalesOrderID, CustomerID, OrderDate, TotalDue
FROM Sales.SalesOrderHeader
WHERE OrderDate BETWEEN '2013-01-01' AND '2013-12-31';


-- Index on SalesOrderDetail.ProductID - speeds up product sales totals



--before index
SELECT ProductID, SUM(OrderQty)
FROM Sales.SalesOrderDetail
GROUP BY ProductID;


IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_SalesOrderDetail_ProductID3'
    AND object_id = OBJECT_ID('Sales.SalesOrderDetail')
)

CREATE NONCLUSTERED INDEX IX_SalesOrderDetail_ProductID3
ON Sales.SalesOrderDetail (ProductID)
INCLUDE (OrderQty, LineTotal, SalesOrderID);
GO

-- AFTER INDEX
SELECT ProductID, SUM(OrderQty)
FROM Sales.SalesOrderDetail
GROUP BY ProductID;



-- BEFORE INDEX (slow)
SELECT CustomerID, PersonID, TerritoryID
FROM Sales.Customer
WHERE PersonID = 10000;   

-- Index on Customer.PersonID - speeds up customer lookups by person
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Customer_PersonID'
    AND object_id = OBJECT_ID('Sales.Customer')
)
CREATE NONCLUSTERED INDEX IX_Customer_PersonID
ON Sales.Customer (PersonID)
INCLUDE (TerritoryID);
GO


-- AFTER INDEX (optimized)
SELECT CustomerID, PersonID, TerritoryID
FROM Sales.Customer
WHERE PersonID = 10000;


-- BEFORE INDEX
SELECT BusinessEntityID, JobTitle, HireDate
FROM HumanResources.Employee
WHERE JobTitle = 'Sales Representative';

-- Index on Employee for HR queries
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Employee_JobTitle'
    AND object_id = OBJECT_ID('HumanResources.Employee')
)
CREATE NONCLUSTERED INDEX IX_Employee_JobTitle
ON HumanResources.Employee (JobTitle)
INCLUDE (BusinessEntityID, HireDate);
GO

-- AFTER INDEX
SELECT BusinessEntityID, JobTitle, HireDate
FROM HumanResources.Employee
WHERE JobTitle = 'Sales Representative';

/*
Step 3: Optimized queries (vs the slow ones above)

OPTIMIZED QUERY 1: uses the new index on OrderDate
SELECT SalesOrderID, CustomerID, OrderDate, TotalDue
FROM Sales.SalesOrderHeader WITH (INDEX(IX_SalesOrderHeader_OrderDate))
WHERE OrderDate BETWEEN '2013-01-01' AND '2013-12-31'

OPTIMIZED QUERY 2: uses the new index on ProductID
SELECT ProductID, SUM(OrderQty) AS TotalQty
FROM Sales.SalesOrderDetail WITH (INDEX(IX_SalesOrderDetail_ProductID))
GROUP BY ProductID
ORDER BY TotalQty DESC


Step 4: Monitoring stored procedures (Part C)
*/

-- Procedure: Detect long-running queries
CREATE PROCEDURE usp_DetectLongRunningQueries
    @ThresholdSeconds INT = 30   -- default: flag anything running > 30 seconds
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        r.session_id,
        r.status,
        r.start_time,
        DATEDIFF(SECOND, r.start_time, GETDATE())   AS RunningForSeconds,
        r.command,
        DB_NAME(r.database_id)                       AS DatabaseName,
        r.cpu_time,
        r.total_elapsed_time / 1000                  AS ElapsedTimeSeconds,
        r.reads,
        r.writes,
        SUBSTRING(t.text, 1, 500)                    AS QueryText
    FROM sys.dm_exec_requests r
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
    WHERE r.session_id <> @@SPID   -- exclude this query itself
    AND   DATEDIFF(SECOND, r.start_time, GETDATE()) > @ThresholdSeconds
    ORDER BY RunningForSeconds DESC;
END;
GO


-- Procedure: Check database size
CREATE PROCEDURE usp_CheckDatabaseSize
AS
BEGIN
    SET NOCOUNT ON;

    -- overall database file sizes
    SELECT
        name                                             AS FileName,
        type_desc                                        AS FileType,
        CAST(size * 8.0 / 1024 AS DECIMAL(10,2))       AS SizeMB,
        CAST(max_size * 8.0 / 1024 AS DECIMAL(10,2))   AS MaxSizeMB,
        physical_name                                    AS FilePath
    FROM sys.database_files;

    -- top 10 largest tables by row count
    SELECT TOP 10
        SCHEMA_NAME(t.schema_id) + '.' + t.name         AS TableName,
        p.rows                                           AS [RowCount],
        CAST(SUM(a.total_pages) * 8.0 / 1024 AS DECIMAL(10,2)) AS TotalSizeMB
    FROM sys.tables t
    JOIN sys.indexes i      ON t.object_id = i.object_id
    JOIN sys.partitions p   ON i.object_id = p.object_id AND i.index_id = p.index_id
    JOIN sys.allocation_units a ON p.partition_id = a.container_id
    WHERE i.index_id IN (0, 1)
    GROUP BY t.schema_id, t.name, p.rows
    ORDER BY TotalSizeMB DESC;
END;
GO


-- Procedure: Monitor index fragmentation
CREATE PROCEDURE usp_MonitorIndexFragmentation
    @FragmentationThreshold FLOAT = 10.0   -- flag indexes with >10% fragmentation
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        SCHEMA_NAME(t.schema_id) + '.' + t.name         AS TableName,
        i.name                                           AS IndexName,
        i.type_desc                                      AS IndexType,
        CAST(s.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS FragmentationPercent,
        s.page_count                                     AS PageCount,
        CASE
            WHEN s.avg_fragmentation_in_percent > 30 THEN 'REBUILD recommended'
            WHEN s.avg_fragmentation_in_percent > 10 THEN 'REORGANIZE recommended'
            ELSE 'OK'
        END AS Recommendation
    FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') s
    JOIN sys.indexes i
        ON s.object_id = i.object_id AND s.index_id = i.index_id
    JOIN sys.tables t
        ON i.object_id = t.object_id
    WHERE s.avg_fragmentation_in_percent >= @FragmentationThreshold
    AND   s.page_count > 100   -- ignore tiny indexes
    ORDER BY s.avg_fragmentation_in_percent DESC;
END;
GO





SELECT * 
FROM Sales.SalesOrderHeader
WHERE OrderDate BETWEEN '2013-01-01' AND '2013-12-31';