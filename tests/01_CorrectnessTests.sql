/*
    01_CorrectnessTests.sql

    Correctness only. This script does not assert elapsed time or a speedup.
    It prints TEST_RESULT and TEST_TOTALS lines and throws if any test fails.
*/
USE SqlServerOPPODemo;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET ARITHABORT ON;

IF DB_NAME() <> N'SqlServerOPPODemo'
    THROW 50200, 'Correctness tests refused to run because the current database is not SqlServerOPPODemo.', 1;

DECLARE @Tests table
(
    TestId int IDENTITY(1, 1) NOT NULL,
    TestName nvarchar(80) NOT NULL,
    Status nvarchar(10) NOT NULL,
    Detail nvarchar(1000) NOT NULL
);

DECLARE @Major int = TRY_CONVERT(int, CONVERT(nvarchar(20), SERVERPROPERTY('ProductMajorVersion')));
DECLARE @Version nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion'));
DECLARE @Edition nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));
DECLARE @Compatibility int;
DECLARE @Oppo int;
DECLARE @CustomerCount int;
DECLARE @OrderCount int;
DECLARE @SelectiveCustomerId int;
DECLARE @SelectiveOrderCount int;
DECLARE @ActualCustomers bigint;
DECLARE @ActualOrders bigint;
DECLARE @SelectiveOrders bigint;
DECLARE @Customer125 bigint;

SELECT @Compatibility = compatibility_level
FROM sys.databases
WHERE name = N'SqlServerOPPODemo';

SELECT @Oppo = CONVERT(int, value)
FROM sys.database_scoped_configurations
WHERE name = N'OPTIONAL_PARAMETER_OPTIMIZATION';

SELECT
    @CustomerCount = CustomerCount,
    @OrderCount = OrderCount,
    @SelectiveCustomerId = SelectiveCustomerId,
    @SelectiveOrderCount = SelectiveOrderCount
FROM dbo.DemoSettings
WHERE SettingsId = 1;

SELECT @ActualCustomers = COUNT_BIG(*) FROM dbo.Customers;
SELECT @ActualOrders = COUNT_BIG(*) FROM dbo.Orders;
SELECT @SelectiveOrders = COUNT_BIG(*) FROM dbo.Orders WHERE CustomerId = @SelectiveCustomerId;
SELECT @Customer125 = COUNT_BIG(*) FROM dbo.Customers WHERE CustomerId = 125;

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'EngineMajorVersion17',
    CASE WHEN @Major = 17 THEN N'PASS' ELSE N'FAIL' END,
    CONCAT(N'version=', @Version, N'; edition=', @Edition, N'; major=', COALESCE(CONVERT(nvarchar(20), @Major), N'null'))
);

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'CompatibilityLevel170',
    CASE WHEN @Compatibility = 170 THEN N'PASS' ELSE N'FAIL' END,
    CONCAT(N'compatibility_level=', COALESCE(CONVERT(nvarchar(20), @Compatibility), N'null'))
);

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'OppoScopedConfigurationOn',
    CASE WHEN @Oppo = 1 THEN N'PASS' ELSE N'FAIL' END,
    CONCAT(N'OPTIONAL_PARAMETER_OPTIMIZATION=', COALESCE(CONVERT(nvarchar(20), @Oppo), N'null'))
);

DECLARE @BeforeDef nvarchar(max);
DECLARE @AfterDef nvarchar(max);
SELECT @BeforeDef = definition FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'dbo.SearchOrders_Before');
SELECT @AfterDef = definition FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'dbo.SearchOrders_After');

DECLARE @BeforeNorm nvarchar(max) = REPLACE(REPLACE(REPLACE(REPLACE(COALESCE(@BeforeDef, N''), N' ', N''), CHAR(9), N''), CHAR(10), N''), CHAR(13), N'');
DECLARE @AfterNorm nvarchar(max) = REPLACE(REPLACE(REPLACE(REPLACE(COALESCE(@AfterDef, N''), N' ', N''), CHAR(9), N''), CHAR(10), N''), CHAR(13), N'');
DECLARE @Fragment nvarchar(300) = N'SELECTOrderId,CustomerId,OrderDate,TotalAmountFROMdbo.OrdersWHERECustomerId=@CustomerIdOR@CustomerIdISNULL';

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'BeforeProcedureUsesDisableHint',
    CASE
        WHEN @BeforeDef LIKE N'%DISABLE_OPTIONAL_PARAMETER_OPTIMIZATION%' THEN N'PASS'
        ELSE N'FAIL'
    END,
    CASE WHEN @BeforeDef IS NULL THEN N'procedure missing' ELSE N'hint presence checked' END
);

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'AfterProcedureOmitsDisableHint',
    CASE
        WHEN @AfterDef IS NOT NULL
         AND @AfterDef NOT LIKE N'%DISABLE_OPTIONAL_PARAMETER_OPTIMIZATION%' THEN N'PASS'
        ELSE N'FAIL'
    END,
    CASE WHEN @AfterDef IS NULL THEN N'procedure missing' ELSE N'hint absence checked' END
);

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'DemoDataMatchesSettings',
    CASE
        WHEN @ActualCustomers = @CustomerCount AND @ActualOrders = @OrderCount THEN N'PASS'
        ELSE N'FAIL'
    END,
    CONCAT(N'customers=', @ActualCustomers, N'/', @CustomerCount, N'; orders=', @ActualOrders, N'/', @OrderCount)
);

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'Customer125Exists',
    CASE WHEN @Customer125 = 1 THEN N'PASS' ELSE N'FAIL' END,
    CONCAT(N'customer_125_rows=', @Customer125)
);

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'SelectiveCustomerOrderCount',
    CASE WHEN @SelectiveOrders = @SelectiveOrderCount THEN N'PASS' ELSE N'FAIL' END,
    CONCAT(N'customer=', @SelectiveCustomerId, N'; orders=', @SelectiveOrders, N'; expected=', @SelectiveOrderCount)
);

DECLARE @IndexKeys int;
DECLARE @IndexIncludes int;
SELECT @IndexKeys = COUNT(*)
FROM sys.indexes AS i
INNER JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id AND ic.index_id = i.index_id
INNER JOIN sys.columns AS c
    ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'dbo.Orders')
  AND i.name = N'IX_Orders_CustomerId'
  AND ic.is_included_column = 0
  AND ic.key_ordinal = 1
  AND c.name = N'CustomerId';

SELECT @IndexIncludes = COUNT(*)
FROM sys.indexes AS i
INNER JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id AND ic.index_id = i.index_id
INNER JOIN sys.columns AS c
    ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'dbo.Orders')
  AND i.name = N'IX_Orders_CustomerId'
  AND ic.is_included_column = 1
  AND c.name IN (N'OrderDate', N'TotalAmount');

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'CustomerIndexShape',
    CASE WHEN @IndexKeys = 1 AND @IndexIncludes = 2 THEN N'PASS' ELSE N'FAIL' END,
    CONCAT(N'customer_key=', @IndexKeys, N'; included_orderdate_totalamount=', @IndexIncludes)
);

IF OBJECT_ID(N'tempdb..#BeforeNull') IS NOT NULL DROP TABLE #BeforeNull;
IF OBJECT_ID(N'tempdb..#AfterNull') IS NOT NULL DROP TABLE #AfterNull;
IF OBJECT_ID(N'tempdb..#BeforeSelective') IS NOT NULL DROP TABLE #BeforeSelective;
IF OBJECT_ID(N'tempdb..#AfterSelective') IS NOT NULL DROP TABLE #AfterSelective;

CREATE TABLE #BeforeNull
(
    OrderId int NOT NULL PRIMARY KEY,
    CustomerId int NOT NULL,
    OrderDate datetime2(0) NOT NULL,
    TotalAmount decimal(18, 2) NOT NULL
);
CREATE TABLE #AfterNull
(
    OrderId int NOT NULL PRIMARY KEY,
    CustomerId int NOT NULL,
    OrderDate datetime2(0) NOT NULL,
    TotalAmount decimal(18, 2) NOT NULL
);
CREATE TABLE #BeforeSelective
(
    OrderId int NOT NULL PRIMARY KEY,
    CustomerId int NOT NULL,
    OrderDate datetime2(0) NOT NULL,
    TotalAmount decimal(18, 2) NOT NULL
);
CREATE TABLE #AfterSelective
(
    OrderId int NOT NULL PRIMARY KEY,
    CustomerId int NOT NULL,
    OrderDate datetime2(0) NOT NULL,
    TotalAmount decimal(18, 2) NOT NULL
);

INSERT #BeforeNull (OrderId, CustomerId, OrderDate, TotalAmount)
EXEC dbo.SearchOrders_Before @CustomerId = NULL;
INSERT #AfterNull (OrderId, CustomerId, OrderDate, TotalAmount)
EXEC dbo.SearchOrders_After @CustomerId = NULL;
INSERT #BeforeSelective (OrderId, CustomerId, OrderDate, TotalAmount)
EXEC dbo.SearchOrders_Before @CustomerId = @SelectiveCustomerId;
INSERT #AfterSelective (OrderId, CustomerId, OrderDate, TotalAmount)
EXEC dbo.SearchOrders_After @CustomerId = @SelectiveCustomerId;

DECLARE @NullMissing bigint;
DECLARE @NullExtra bigint;
SELECT @NullMissing = COUNT_BIG(*)
FROM
(
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM dbo.Orders
    EXCEPT
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM #AfterNull
) AS d;
SELECT @NullExtra = COUNT_BIG(*)
FROM
(
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM #AfterNull
    EXCEPT
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM dbo.Orders
) AS d;

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'NullFilterReturnsAllOrders',
    CASE WHEN @NullMissing = 0 AND @NullExtra = 0 THEN N'PASS' ELSE N'FAIL' END,
    CONCAT(N'missing_from_result=', @NullMissing, N'; extra_in_result=', @NullExtra)
);

DECLARE @SelectiveWrong bigint;
DECLARE @SelectiveReturned bigint;
SELECT @SelectiveWrong = COUNT_BIG(*) FROM #AfterSelective WHERE CustomerId <> @SelectiveCustomerId;
SELECT @SelectiveReturned = COUNT_BIG(*) FROM #AfterSelective;

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'SelectiveFilterReturnsOnlyThatCustomer',
    CASE
        WHEN @SelectiveWrong = 0 AND @SelectiveReturned = @SelectiveOrders AND @SelectiveReturned > 0 THEN N'PASS'
        ELSE N'FAIL'
    END,
    CONCAT(N'returned=', @SelectiveReturned, N'; wrong_customer_rows=', @SelectiveWrong, N'; table_rows=', @SelectiveOrders)
);

DECLARE @NullOnlyBefore bigint;
DECLARE @NullOnlyAfter bigint;
SELECT @NullOnlyBefore = COUNT_BIG(*)
FROM
(
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM #BeforeNull
    EXCEPT
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM #AfterNull
) AS d;
SELECT @NullOnlyAfter = COUNT_BIG(*)
FROM
(
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM #AfterNull
    EXCEPT
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM #BeforeNull
) AS d;

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'BeforeAndAfterMatchForNull',
    CASE WHEN @NullOnlyBefore = 0 AND @NullOnlyAfter = 0 THEN N'PASS' ELSE N'FAIL' END,
    CONCAT(N'only_before=', @NullOnlyBefore, N'; only_after=', @NullOnlyAfter)
);

DECLARE @SelOnlyBefore bigint;
DECLARE @SelOnlyAfter bigint;
SELECT @SelOnlyBefore = COUNT_BIG(*)
FROM
(
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM #BeforeSelective
    EXCEPT
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM #AfterSelective
) AS d;
SELECT @SelOnlyAfter = COUNT_BIG(*)
FROM
(
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM #AfterSelective
    EXCEPT
    SELECT OrderId, CustomerId, OrderDate, TotalAmount FROM #BeforeSelective
) AS d;

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'BeforeAndAfterMatchForSelective',
    CASE WHEN @SelOnlyBefore = 0 AND @SelOnlyAfter = 0 THEN N'PASS' ELSE N'FAIL' END,
    CONCAT(N'only_before=', @SelOnlyBefore, N'; only_after=', @SelOnlyAfter)
);

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'QueryTextMatchesExceptHint',
    CASE
        WHEN @BeforeNorm LIKE N'%' + @Fragment + N'%'
         AND @AfterNorm LIKE N'%' + @Fragment + N'%'
         AND @BeforeNorm NOT LIKE N'%ORDERBY%'
         AND @AfterNorm NOT LIKE N'%ORDERBY%'
         AND @BeforeNorm LIKE N'%DISABLE_OPTIONAL_PARAMETER_OPTIMIZATION%'
         AND @AfterNorm NOT LIKE N'%DISABLE_OPTIONAL_PARAMETER_OPTIMIZATION%'
        THEN N'PASS'
        ELSE N'FAIL'
    END,
    N'SELECT, WHERE, and absence of ORDER BY compared after whitespace removal'
);

EXEC sys.sp_query_store_flush_db;

DECLARE @QsOppo int = 0;
DECLARE @CacheOppo int = 0;
DECLARE @CapturedOppo int = 0;
DECLARE @QsDisabled int = 0;
DECLARE @CacheDisabled int = 0;

SELECT @QsOppo = COUNT(*)
FROM sys.query_store_query_variant AS variant_link
INNER JOIN sys.query_store_query AS parent_query
    ON parent_query.query_id = variant_link.parent_query_id
INNER JOIN sys.query_store_query AS variant_query
    ON variant_query.query_id = variant_link.query_variant_query_id
INNER JOIN sys.query_store_query_text AS variant_text
    ON variant_text.query_text_id = variant_query.query_text_id
WHERE parent_query.object_id = OBJECT_ID(N'dbo.SearchOrders_After')
  AND variant_text.query_sql_text LIKE N'%optional_predicate%';

SELECT @CacheOppo = COUNT(*)
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
WHERE st.objectid = OBJECT_ID(N'dbo.SearchOrders_After')
  AND qp.query_plan IS NOT NULL
  AND
  (
      CAST(qp.query_plan AS nvarchar(max)) LIKE N'%optional_predicate%'
      OR CAST(qp.query_plan AS nvarchar(max)) LIKE N'%OptionalParameterPredicate%'
  );

IF OBJECT_ID(N'dbo.CapturedPlan', N'U') IS NOT NULL
BEGIN
    SELECT @CapturedOppo = COUNT(*)
    FROM dbo.CapturedPlan
    WHERE HasOptionalPredicate = 1
      AND
      (
          ScenarioName LIKE N'%Enabled%'
          OR ScenarioName LIKE N'%SearchOrders_After%'
      );
END;

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'EnabledQueryHasOppoMetadata',
    CASE WHEN @QsOppo + @CacheOppo + @CapturedOppo > 0 THEN N'PASS' ELSE N'FAIL' END,
    CONCAT(N'query_store_optional_predicate=', @QsOppo, N'; plan_cache=', @CacheOppo, N'; captured_plans=', @CapturedOppo)
);

SELECT @QsDisabled = COUNT(*)
FROM sys.query_store_query_variant AS variant_link
INNER JOIN sys.query_store_query AS parent_query
    ON parent_query.query_id = variant_link.parent_query_id
INNER JOIN sys.query_store_query AS variant_query
    ON variant_query.query_id = variant_link.query_variant_query_id
INNER JOIN sys.query_store_query_text AS variant_text
    ON variant_text.query_text_id = variant_query.query_text_id
WHERE parent_query.object_id = OBJECT_ID(N'dbo.SearchOrders_Before')
  AND variant_text.query_sql_text LIKE N'%optional_predicate%';

SELECT @CacheDisabled = COUNT(*)
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
WHERE st.objectid = OBJECT_ID(N'dbo.SearchOrders_Before')
  AND qp.query_plan IS NOT NULL
  AND
  (
      CAST(qp.query_plan AS nvarchar(max)) LIKE N'%optional_predicate%'
      OR CAST(qp.query_plan AS nvarchar(max)) LIKE N'%OptionalParameterPredicate%'
  );

INSERT @Tests (TestName, Status, Detail)
VALUES
(
    N'DisabledQueryHasNoOppoMetadata',
    CASE WHEN @QsDisabled = 0 AND @CacheDisabled = 0 THEN N'PASS' ELSE N'FAIL' END,
    CONCAT(N'query_store_optional_predicate=', @QsDisabled, N'; plan_cache=', @CacheDisabled)
);

DECLARE @Passed int;
DECLARE @Failed int;
DECLARE @Id int = 0;
DECLARE @Name nvarchar(80);
DECLARE @Status nvarchar(10);
DECLARE @Detail nvarchar(1000);

SELECT @Passed = COUNT(*) FROM @Tests WHERE Status = N'PASS';
SELECT @Failed = COUNT(*) FROM @Tests WHERE Status = N'FAIL';

WHILE 1 = 1
BEGIN
    SELECT TOP (1)
        @Id = TestId,
        @Name = TestName,
        @Status = Status,
        @Detail = Detail
    FROM @Tests
    WHERE TestId > @Id
    ORDER BY TestId;

    IF @@ROWCOUNT = 0
        BREAK;

    PRINT CONCAT(N'TEST_RESULT|', @Name, N'|', @Status, N'|', REPLACE(@Detail, N'|', N'/'));
END;

PRINT CONCAT(N'TEST_TOTALS|passed=', @Passed, N'|failed=', @Failed, N'|skipped=0|not_run=0');

IF @Failed > 0
    THROW 50201, 'One or more correctness tests failed. See TEST_RESULT lines.', 1;
GO
