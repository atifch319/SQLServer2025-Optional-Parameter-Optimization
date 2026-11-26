/*
    07_After_OPPO_Enabled.sql

    AFTER — OPTIONAL PARAMETER PLAN OPTIMIZATION

    Same SELECT and WHERE text as dbo.SearchOrders_Before.
    The disabling hint is not present. Database compatibility is 170 and
    OPTIONAL_PARAMETER_OPTIMIZATION is ON.

    For an eligible query, SQL Server can build a dispatcher plan and
    query variants, then choose a variant from the parameter state
    (NULL or not NULL). An index seek is possible for a selective value.
    It is not guaranteed. The engine decides from statistics, indexes,
    and eligibility rules.

    Equivalent parameterized batch, not executed by this script:

        EXEC sys.sp_executesql
            N'SELECT OrderId, CustomerId, OrderDate, TotalAmount
              FROM dbo.Orders
              WHERE CustomerId = @CustomerId
                 OR @CustomerId IS NULL;',
            N'@CustomerId int',
            @CustomerId = NULL;
*/
USE SqlServerOPPODemo;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET ARITHABORT ON;
GO

CREATE OR ALTER PROCEDURE dbo.SearchOrders_After
    @CustomerId int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        OrderId,
        CustomerId,
        OrderDate,
        TotalAmount
    FROM dbo.Orders
    WHERE CustomerId = @CustomerId
       OR @CustomerId IS NULL;
END;
GO

SET NOCOUNT ON;

DECLARE @SelectiveCustomerId int;
DECLARE @NullRows bigint;
DECLARE @SelectiveRows bigint;

SELECT @SelectiveCustomerId = SelectiveCustomerId
FROM dbo.DemoSettings
WHERE SettingsId = 1;

IF OBJECT_ID(N'tempdb..#Sink') IS NOT NULL
    DROP TABLE #Sink;

CREATE TABLE #Sink
(
    OrderId int NOT NULL,
    CustomerId int NOT NULL,
    OrderDate datetime2(0) NOT NULL,
    TotalAmount decimal(18, 2) NOT NULL
);

INSERT #Sink (OrderId, CustomerId, OrderDate, TotalAmount)
EXEC dbo.SearchOrders_After @CustomerId = NULL;

SET @NullRows = ROWCOUNT_BIG();
TRUNCATE TABLE #Sink;

INSERT #Sink (OrderId, CustomerId, OrderDate, TotalAmount)
EXEC dbo.SearchOrders_After @CustomerId = @SelectiveCustomerId;

SET @SelectiveRows = ROWCOUNT_BIG();

PRINT CONCAT(N'AFTER NULL parameter rows: ', @NullRows);
PRINT CONCAT(N'AFTER customer ', @SelectiveCustomerId, N' rows: ', @SelectiveRows);

SELECT TOP (10)
    OrderId,
    CustomerId,
    OrderDate,
    TotalAmount
FROM #Sink
ORDER BY OrderId;

DROP TABLE #Sink;
GO
