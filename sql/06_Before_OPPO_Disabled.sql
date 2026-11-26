/*
    06_Before_OPPO_Disabled.sql

    BEFORE — ONE REUSABLE PLAN

    Compatibility level stays 170. OPPO stays ON at the database scope.
    This procedure disables OPPO for its statement with the supported hint:

        OPTION (USE HINT('DISABLE_OPTIONAL_PARAMETER_OPTIMIZATION'))

    A single reusable plan must remain valid when @CustomerId is NULL and when
    it is not NULL. That can make a selective execution read more pages than
    an index seek would. It does not mean every optional predicate scans.

    Database-scoped alternative, not used here because it would also disable
    the AFTER procedure in this database:

        ALTER DATABASE SCOPED CONFIGURATION SET OPTIONAL_PARAMETER_OPTIMIZATION = OFF;

    NULL executions are consumed with INSERT...EXEC so a scripted run does not
    print every order. The procedure statement itself is unchanged.
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

CREATE OR ALTER PROCEDURE dbo.SearchOrders_Before
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
       OR @CustomerId IS NULL
    OPTION (USE HINT('DISABLE_OPTIONAL_PARAMETER_OPTIMIZATION'));
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
EXEC dbo.SearchOrders_Before @CustomerId = NULL;

SET @NullRows = ROWCOUNT_BIG();
TRUNCATE TABLE #Sink;

INSERT #Sink (OrderId, CustomerId, OrderDate, TotalAmount)
EXEC dbo.SearchOrders_Before @CustomerId = @SelectiveCustomerId;

SET @SelectiveRows = ROWCOUNT_BIG();

PRINT CONCAT(N'BEFORE NULL parameter rows: ', @NullRows);
PRINT CONCAT(N'BEFORE customer ', @SelectiveCustomerId, N' rows: ', @SelectiveRows);

SELECT TOP (10)
    OrderId,
    CustomerId,
    OrderDate,
    TotalAmount
FROM #Sink
ORDER BY OrderId;

DROP TABLE #Sink;
GO
