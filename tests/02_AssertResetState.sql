/*
    02_AssertResetState.sql

    Run after 12_ResetDemo.sql and before the data load is repeated.
*/
USE SqlServerOPPODemo;
GO

SET NOCOUNT ON;

IF DB_NAME() <> N'SqlServerOPPODemo'
    THROW 50210, 'Reset assertions refused to run because the current database is not SqlServerOPPODemo.', 1;

DECLARE @Tests table
(
    TestId int IDENTITY(1, 1) NOT NULL,
    TestName nvarchar(80) NOT NULL,
    Status nvarchar(10) NOT NULL,
    Detail nvarchar(400) NOT NULL
);

DECLARE @Compatibility int;
DECLARE @Oppo int;
DECLARE @Orders bigint;
DECLARE @Customers bigint;
DECLARE @IndexCount int;
DECLARE @ProcCount int;

SELECT @Compatibility = compatibility_level
FROM sys.databases
WHERE name = N'SqlServerOPPODemo';

SELECT @Oppo = CONVERT(int, value)
FROM sys.database_scoped_configurations
WHERE name = N'OPTIONAL_PARAMETER_OPTIMIZATION';

SELECT @Orders = COUNT_BIG(*) FROM dbo.Orders;
SELECT @Customers = COUNT_BIG(*) FROM dbo.Customers;

SELECT @IndexCount = COUNT(*)
FROM sys.indexes
WHERE object_id = OBJECT_ID(N'dbo.Orders')
  AND name = N'IX_Orders_CustomerId';

SELECT @ProcCount = COUNT(*)
FROM sys.procedures
WHERE name IN (N'SearchOrders_Before', N'SearchOrders_After');

INSERT @Tests (TestName, Status, Detail)
VALUES
    (N'ResetDatabaseRemains', N'PASS', N'SqlServerOPPODemo is the current database'),
    (N'ResetCompatibility170', CASE WHEN @Compatibility = 170 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'compatibility_level=', @Compatibility)),
    (N'ResetOppoStillOn', CASE WHEN @Oppo = 1 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'OPTIONAL_PARAMETER_OPTIMIZATION=', @Oppo)),
    (N'ResetOrdersEmpty', CASE WHEN @Orders = 0 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'orders=', @Orders)),
    (N'ResetCustomersEmpty', CASE WHEN @Customers = 0 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'customers=', @Customers)),
    (N'ResetSearchIndexRemoved', CASE WHEN @IndexCount = 0 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'index_count=', @IndexCount)),
    (N'ResetSearchProceduresRemoved', CASE WHEN @ProcCount = 0 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'procedure_count=', @ProcCount));

DECLARE @Passed int;
DECLARE @Failed int;
DECLARE @Id int = 0;
DECLARE @Name nvarchar(80);
DECLARE @Status nvarchar(10);
DECLARE @Detail nvarchar(400);

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
    THROW 50211, 'Reset state assertions failed.', 1;
GO
