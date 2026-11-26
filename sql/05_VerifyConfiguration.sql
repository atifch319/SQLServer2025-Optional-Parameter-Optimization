/*
    05_VerifyConfiguration.sql

    Read-only verification of engine version, compatibility level 170,
    OPTIONAL_PARAMETER_OPTIMIZATION, row counts, the search index, and statistics.
    Throws if the demo database is not in the expected state.
*/
USE SqlServerOPPODemo;
GO

SET NOCOUNT ON;

IF DB_NAME() <> N'SqlServerOPPODemo'
    THROW 50050, 'Refusing to verify because the current database is not SqlServerOPPODemo.', 1;

DECLARE @Major int = TRY_CONVERT(int, CONVERT(nvarchar(20), SERVERPROPERTY('ProductMajorVersion')));
DECLARE @Compatibility int;
DECLARE @Oppo int;
DECLARE @CustomerCount int;
DECLARE @OrderCount int;
DECLARE @SelectiveCustomerId int;
DECLARE @SelectiveOrderCount int;
DECLARE @ActualCustomers bigint;
DECLARE @ActualOrders bigint;
DECLARE @SelectiveOrders bigint;

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

PRINT N'=== CONFIGURATION ===';
PRINT CONCAT(N'ProductVersion=', CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')));
PRINT CONCAT(N'ProductLevel=', CONVERT(nvarchar(128), SERVERPROPERTY('ProductLevel')));
PRINT CONCAT(N'ProductUpdateLevel=', COALESCE(CONVERT(nvarchar(128), SERVERPROPERTY('ProductUpdateLevel')), N'(null)'));
PRINT CONCAT(N'Edition=', CONVERT(nvarchar(128), SERVERPROPERTY('Edition')));
PRINT CONCAT(N'EngineEdition=', CONVERT(nvarchar(20), SERVERPROPERTY('EngineEdition')));
PRINT CONCAT(N'IsLocalDB=', CONVERT(nvarchar(20), SERVERPROPERTY('IsLocalDB')));
PRINT CONCAT(N'CompatibilityLevel=', @Compatibility);
PRINT CONCAT(N'OPTIONAL_PARAMETER_OPTIMIZATION=', @Oppo);

SELECT
    name,
    CONVERT(int, value) AS configuration_value,
    is_value_default
FROM sys.database_scoped_configurations
WHERE name IN
(
    N'OPTIONAL_PARAMETER_OPTIMIZATION',
    N'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION',
    N'LAST_QUERY_PLAN_STATS'
)
ORDER BY name;

SELECT
    desired_state_desc,
    actual_state_desc,
    readonly_reason,
    current_storage_size_mb,
    query_capture_mode_desc
FROM sys.database_query_store_options;

PRINT N'=== ROW COUNTS ===';
SELECT
    @ActualCustomers AS CustomerRows,
    @ActualOrders AS OrderRows,
    @SelectiveCustomerId AS SelectiveCustomerId,
    @SelectiveOrders AS SelectiveCustomerOrders;

SELECT
    s.name AS stats_name,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    sp.modification_counter,
    sp.steps
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE s.object_id IN (OBJECT_ID(N'dbo.Customers'), OBJECT_ID(N'dbo.Orders'))
ORDER BY s.object_id, s.stats_id;

IF @Major IS NULL OR @Major < 17
    THROW 50051, 'Connected engine is not SQL Server 2025 (major version 17).', 1;

IF @Compatibility <> 170
    THROW 50052, 'Compatibility level is not 170.', 1;

IF @Oppo <> 1
    THROW 50053, 'OPTIONAL_PARAMETER_OPTIMIZATION is not ON.', 1;

IF @ActualCustomers <> @CustomerCount OR @ActualOrders <> @OrderCount OR @SelectiveOrders <> @SelectiveOrderCount
    THROW 50054, 'Row counts do not match dbo.DemoSettings. Run 03_GenerateData.sql.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes AS i
    INNER JOIN sys.index_columns AS ic
        ON ic.object_id = i.object_id
       AND ic.index_id = i.index_id
    INNER JOIN sys.columns AS c
        ON c.object_id = ic.object_id
       AND c.column_id = ic.column_id
    WHERE i.object_id = OBJECT_ID(N'dbo.Orders')
      AND i.name = N'IX_Orders_CustomerId'
      AND c.name = N'CustomerId'
      AND ic.is_included_column = 0
      AND ic.key_ordinal = 1
)
    THROW 50055, 'IX_Orders_CustomerId is missing CustomerId as the key column.', 1;

IF
(
    SELECT COUNT(*)
    FROM sys.indexes AS i
    INNER JOIN sys.index_columns AS ic
        ON ic.object_id = i.object_id
       AND ic.index_id = i.index_id
    INNER JOIN sys.columns AS c
        ON c.object_id = ic.object_id
       AND c.column_id = ic.column_id
    WHERE i.object_id = OBJECT_ID(N'dbo.Orders')
      AND i.name = N'IX_Orders_CustomerId'
      AND ic.is_included_column = 1
      AND c.name IN (N'OrderDate', N'TotalAmount')
) <> 2
    THROW 50056, 'IX_Orders_CustomerId does not include OrderDate and TotalAmount.', 1;

IF EXISTS
(
    SELECT 1
    FROM sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE s.object_id = OBJECT_ID(N'dbo.Orders')
      AND sp.last_updated IS NULL
)
    THROW 50057, 'dbo.Orders has statistics with no last_updated value.', 1;

PRINT N'Verification passed.';
GO
