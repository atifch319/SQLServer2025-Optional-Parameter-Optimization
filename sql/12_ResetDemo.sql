/*
    12_ResetDemo.sql

    Returns SqlServerOPPODemo to an empty, runnable state:
      - drops the diagnostic extended event session if this script left one
      - clears this database's procedure cache and Query Store
      - drops the two search procedures
      - drops IX_Orders_CustomerId
      - removes order and customer rows

    The database, compatibility level 170, OPTIONAL_PARAMETER_OPTIMIZATION,
    Query Store, and dbo.DemoSettings remain. Run 03, 04, 06, and 07 to load
    and demonstrate again.

    This script never drops a database other than the dedicated demo database,
    and the executable path does not drop SqlServerOPPODemo.

    Full teardown, run manually only when you intend to remove the demo:

        USE master;
        ALTER DATABASE SqlServerOPPODemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DROP DATABASE SqlServerOPPODemo;
*/
USE SqlServerOPPODemo;
GO

SET NOCOUNT ON;

IF DB_NAME() <> N'SqlServerOPPODemo'
    THROW 50120, 'Refusing to reset because the current database is not SqlServerOPPODemo.', 1;

IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'oppo_demo_diagnostics')
    ALTER EVENT SESSION oppo_demo_diagnostics ON SERVER STATE = STOP;

IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'oppo_demo_diagnostics')
    DROP EVENT SESSION oppo_demo_diagnostics ON SERVER;
GO

USE SqlServerOPPODemo;
GO

ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
GO

ALTER DATABASE SqlServerOPPODemo SET QUERY_STORE CLEAR;
GO

USE SqlServerOPPODemo;
GO

-- CapturedPlan and PerformanceMeasurement are left in place so a completed
-- measurement can still be queried after the business data is cleared.
-- Scripts 08 and 09 drop and recreate those tables when they run again.
DROP PROCEDURE IF EXISTS dbo.SearchOrders_Before;
DROP PROCEDURE IF EXISTS dbo.SearchOrders_After;
DROP INDEX IF EXISTS IX_Orders_CustomerId ON dbo.Orders;

TRUNCATE TABLE dbo.Orders;
DELETE FROM dbo.Customers;

PRINT N'Reset finished. Row counts and remaining search objects:';
SELECT
    (SELECT COUNT_BIG(*) FROM dbo.Orders) AS OrderRows,
    (SELECT COUNT_BIG(*) FROM dbo.Customers) AS CustomerRows;

SELECT name
FROM sys.procedures
WHERE name IN (N'SearchOrders_Before', N'SearchOrders_After');

SELECT name
FROM sys.indexes
WHERE object_id = OBJECT_ID(N'dbo.Orders')
  AND name = N'IX_Orders_CustomerId';
GO
