-- PART A - SECTION 1: DATA MANAGEMENT PROCEDURES
-- =====================================================

-- -------------------------------------------
-- Procedure 1: Add a new customer
-- Inserts into Sales.Customer with validation,
-- transaction control and error handling
-- -------------------------------------------
CREATE PROCEDURE usp_AddNewCustomer
    @PersonID    INT,
    @TerritoryID INT
AS
BEGIN
    SET NOCOUNT ON;

    -- basic input validation before we even touch the DB
    IF @PersonID IS NULL OR @TerritoryID IS NULL
    BEGIN
        PRINT 'Error: PersonID and TerritoryID cannot be NULL';
        RETURN;
    END

    -- check that the PersonID actually exists in Person.Person
    IF NOT EXISTS (SELECT 1 FROM Person.Person WHERE BusinessEntityID = @PersonID)
    BEGIN
        PRINT 'Error: PersonID ' + CAST(@PersonID AS VARCHAR) + ' does not exist in Person.Person';
        RETURN;
    END

    -- check the territory is valid
    IF NOT EXISTS (SELECT 1 FROM Sales.SalesTerritory WHERE TerritoryID = @TerritoryID)
    BEGIN
        PRINT 'Error: TerritoryID ' + CAST(@TerritoryID AS VARCHAR) + ' does not exist';
        RETURN;
    END

    -- check if this person already has a customer record
    IF EXISTS (SELECT 1 FROM Sales.Customer WHERE PersonID = @PersonID)
    BEGIN
        PRINT 'Error: A customer record for PersonID ' + CAST(@PersonID AS VARCHAR) + ' already exists';
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

            INSERT INTO Sales.Customer (PersonID, TerritoryID)
            VALUES (@PersonID, @TerritoryID);

        COMMIT TRANSACTION;
        PRINT 'Customer added successfully. CustomerID = ' + CAST(SCOPE_IDENTITY() AS VARCHAR);

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        PRINT 'Failed to add customer. Error: ' + ERROR_MESSAGE();
    END CATCH
END;
GO
--It gives error of procedure already exist , so we alter it so we can re use it
ALTER PROCEDURE usp_AddNewCustomer


---TESTING

SELECT * FROM Sales.Customer
WHERE PersonID =234;
EXEC usp_AddNewCustomer '234', '3';


-- -------------------------------------------
-- Procedure 2: Update a product price
-- Updates ListPrice for a given product
-- Also validates that the new price is positive
-- -------------------------------------------
CREATE PROCEDURE usp_UpdateProductPrice
    @ProductID INT,
    @NewPrice  MONEY
AS
BEGIN
    SET NOCOUNT ON;

    -- input validation
    IF @ProductID IS NULL OR @NewPrice IS NULL
    BEGIN
        PRINT 'Error: ProductID and NewPrice are required';
        RETURN;
    END

    IF @NewPrice <= 0
    BEGIN
        PRINT 'Error: Price must be greater than zero';
        RETURN;
    END

    -- check the product exists
    IF NOT EXISTS (SELECT 1 FROM Production.Product WHERE ProductID = @ProductID)
    BEGIN
        PRINT 'Error: ProductID ' + CAST(@ProductID AS VARCHAR) + ' not found';
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

            UPDATE Production.Product
            SET ListPrice = @NewPrice,
                ModifiedDate = GETDATE()
            WHERE ProductID = @ProductID;

        COMMIT TRANSACTION;
        PRINT 'Product price updated successfully for ProductID: ' + CAST(@ProductID AS VARCHAR);

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        PRINT 'Failed to update price. Error: ' + ERROR_MESSAGE();
    END CATCH
END;
GO
--It gives error of procedure already exist , so we alter it so we can re use it
ALTER PROCEDURE usp_UpdateProductPrice

--Testing
EXEC usp_UpdateProductPrice '1' , 'O';


SELECT * FROM Production.Product;


-- -------------------------------------------
-- Procedure 3: Archive inactive customers
-- Moves customers with no orders in the last
-- X years into ArchivedCustomers table then
-- removes them from Sales.Customer
-- -------------------------------------------




CREATE PROCEDURE usp_ArchiveInactiveCustomers
    @YearsInactive INT = 5   -- default: customers with no orders in 5+ years
AS
BEGIN
    SET NOCOUNT ON;

    IF @YearsInactive <= 0
    BEGIN
        PRINT 'Error: YearsInactive must be a positive number';
        RETURN;
    END

    DECLARE @CutoffDate DATETIME = DATEADD(YEAR, -@YearsInactive, GETDATE());

    BEGIN TRY
        BEGIN TRANSACTION;

            -- archive the inactive customers first
            INSERT INTO ArchivedCustomers (CustomerID, PersonID, TerritoryID, ArchivedBy)
            SELECT c.CustomerID, c.PersonID, c.TerritoryID, SYSTEM_USER
            FROM Sales.Customer c
           WHERE NOT EXISTS (
          SELECT 1
          FROM Sales.SalesOrderHeader soh
          WHERE soh.CustomerID = c.CustomerID
          );
            

            DECLARE @ArchivedCount INT = @@ROWCOUNT;

            -- now delete them from the main table
            DELETE FROM Sales.Customer
            WHERE CustomerID IN (
                SELECT CustomerID FROM  ArchivedCustomers
                WHERE ArchivedBy = SYSTEM_USER
                AND   ArchivedOn >= CAST(GETDATE() AS DATE)
            );

        COMMIT TRANSACTION;
        PRINT CAST(@ArchivedCount AS VARCHAR) + ' inactive customer(s) archived successfully';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        PRINT 'Archive failed. Error: ' + ERROR_MESSAGE();
    END CATCH
END;
GO

--It gives error of procedure already exist , so we alter it so we can re use it
ALTER PROCEDURE usp_ArchiveInactiveCustomers

--execution of the code
EXEC usp_ArchiveInactiveCustomers;

SELECT * FROM ArchivedCustomers;

-- =====================================================
-- PART A - SECTION 2: REPORTING PROCEDURES
-- =====================================================

-- -------------------------------------------
-- Report 1: Monthly Sales Report
-- Returns total sales per month between two dates
-- -------------------------------------------
CREATE PROCEDURE usp_MonthlySalesReport
    @StartDate DATETIME,
    @EndDate   DATETIME
AS
BEGIN
    SET NOCOUNT ON;

    IF @StartDate IS NULL OR @EndDate IS NULL
    BEGIN
        PRINT 'Error: Both StartDate and EndDate are required';
        RETURN;
    END

    IF @StartDate > @EndDate
    BEGIN
        PRINT 'Error: StartDate cannot be after EndDate';
        RETURN;
    END

    SELECT
        YEAR(h.OrderDate)                        AS SalesYear,
        MONTH(h.OrderDate)                       AS SalesMonth,
        DATENAME(MONTH, h.OrderDate)             AS MonthName,
        COUNT(DISTINCT h.SalesOrderID)           AS TotalOrders,
        SUM(h.TotalDue)                          AS TotalRevenue,
        AVG(h.TotalDue)                          AS AverageOrderValue,
        COUNT(DISTINCT h.CustomerID)             AS UniqueCustomers
    FROM Sales.SalesOrderHeader h
    WHERE h.OrderDate BETWEEN @StartDate AND @EndDate
    GROUP BY
        YEAR(h.OrderDate),
        MONTH(h.OrderDate),
        DATENAME(MONTH, h.OrderDate)
    ORDER BY
        SalesYear,
        SalesMonth;
END;
GO
--It gives error of procedure already exist , so we alter it so we can re use it
ALTER PROCEDURE usp_MonthlySalesReport


--execution of the code
EXEC usp_MonthlySalesReport '2013-02-01' , '2013-09-12';



-- -------------------------------------------
-- Report 2: Top 10 Best-Selling Products
-- Returns top 10 by quantity sold in date range
-- -------------------------------------------
CREATE PROCEDURE usp_GetTop10Products
    @StartDate DATETIME,
    @EndDate   DATETIME
AS
BEGIN
    SET NOCOUNT ON;

    IF @StartDate IS NULL OR @EndDate IS NULL
    BEGIN
        PRINT 'Error: Please provide a valid date range';
        RETURN;
    END

    SELECT TOP 10
        p.ProductID,
        p.Name                      AS ProductName,
        p.ProductNumber,
        SUM(d.OrderQty)             AS TotalQuantitySold,
        SUM(d.LineTotal)            AS TotalRevenue,
        COUNT(DISTINCT d.SalesOrderID) AS NumberOfOrders
    FROM Sales.SalesOrderDetail d
    JOIN Production.Product p
        ON d.ProductID = p.ProductID
    JOIN Sales.SalesOrderHeader h
        ON d.SalesOrderID = h.SalesOrderID
    WHERE h.OrderDate BETWEEN @StartDate AND @EndDate
    GROUP BY
        p.ProductID,
        p.Name,
        p.ProductNumber
    ORDER BY TotalQuantitySold DESC;
END;
GO


--execution
EXEC usp_GetTop10Products '2013-02-01' , '2013-09-12';


-- -------------------------------------------
-- Report 3: Employee Performance Summary
-- Shows sales totals per employee in a date range
-- -------------------------------------------
CREATE PROCEDURE usp_EmployeePerformance
    @StartDate DATETIME,
    @EndDate   DATETIME
AS
BEGIN
    SET NOCOUNT ON;

    IF @StartDate IS NULL OR @EndDate IS NULL
    BEGIN
        PRINT 'Error: Please provide a valid date range';
        RETURN;
    END

    SELECT
        e.BusinessEntityID                                      AS EmployeeID,
        p.FirstName + ' ' + p.LastName                         AS FullName,
        e.JobTitle,
        COUNT(DISTINCT h.SalesOrderID)                          AS TotalOrdersHandled,
        SUM(h.TotalDue)                                         AS TotalSalesValue,
        AVG(h.TotalDue)                                         AS AverageOrderValue,
        MAX(h.OrderDate)                                        AS LastSaleDate
    FROM HumanResources.Employee e
    JOIN Person.Person p
        ON e.BusinessEntityID = p.BusinessEntityID
    JOIN Sales.SalesPerson sp
        ON e.BusinessEntityID = sp.BusinessEntityID
    JOIN Sales.SalesOrderHeader h
        ON sp.BusinessEntityID = h.SalesPersonID
    WHERE h.OrderDate BETWEEN @StartDate AND @EndDate
    GROUP BY
        e.BusinessEntityID,
        p.FirstName,
        p.LastName,
        e.JobTitle
    ORDER BY TotalSalesValue DESC;
END;
GO
--It gives error of procedure already exist , so we alter it so we can re use it
ALTER PROCEDURE usp_EmployeePerformance


--EXECUTION OF PROCEDURE
EXEC usp_EmployeePerformance '2013-02-01' , '2013-09-12';