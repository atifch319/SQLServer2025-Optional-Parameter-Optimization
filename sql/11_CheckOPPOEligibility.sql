/*
    11_CheckOPPOEligibility.sql

    Lists extended events and the skip-reason map from THIS engine, then
    captures a short session while running:
      - a local-variable query (not eligible for OPPO)
      - the same predicate with OPTION (RECOMPILE)
      - dbo.SearchOrders_After (the enabled demo procedure)
      - dbo.SearchOrders_Before (the disable-hint procedure)

    Event names checked before use:
      optional_parameter_optimization_skipped_reason
      query_with_optional_parameter_predicate

    The session is dropped before this script exits.
    OPPO (NULL versus not NULL) is not parameter-sensitive plan optimization
    (cardinality ranges for a parameter value). A query can engage either,
    both, or neither.
*/
USE SqlServerOPPODemo;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF DB_NAME() <> N'SqlServerOPPODemo'
    THROW 50110, 'Refusing to run eligibility checks because the current database is not SqlServerOPPODemo.', 1;

PRINT N'=== FEATURE AND EVENT AVAILABILITY ===';
SELECT
    name,
    CONVERT(int, value) AS configuration_value,
    is_value_default
FROM sys.database_scoped_configurations
WHERE name IN (N'OPTIONAL_PARAMETER_OPTIMIZATION', N'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION')
ORDER BY name;

SELECT
    name,
    description
FROM sys.dm_xe_objects
WHERE object_type = N'event'
  AND name IN
  (
      N'optional_parameter_optimization_skipped_reason',
      N'query_with_optional_parameter_predicate',
      N'parameter_sensitive_plan_optimization_skipped_reason',
      N'query_with_parameter_sensitivity'
  )
ORDER BY name;

PRINT N'=== MAP NAMES RELATED TO OPPO OR PSP ===';
SELECT DISTINCT name
FROM sys.dm_xe_map_values
WHERE name LIKE N'%opo%'
   OR name LIKE N'%optional_parameter%'
   OR name LIKE N'%parameter_sensitive%'
ORDER BY name;

PRINT N'=== opo_skipped_reason_enum FROM THIS BUILD ===';
SELECT map_key, map_value
FROM sys.dm_xe_map_values
WHERE name = N'opo_skipped_reason_enum'
ORDER BY map_key;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_objects
    WHERE object_type = N'event'
      AND name = N'optional_parameter_optimization_skipped_reason'
)
    THROW 50111, 'Event optional_parameter_optimization_skipped_reason is not available on this engine.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_xe_objects
    WHERE object_type = N'event'
      AND name = N'query_with_optional_parameter_predicate'
)
    THROW 50112, 'Event query_with_optional_parameter_predicate is not available on this engine.', 1;
GO

IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'oppo_demo_diagnostics')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'oppo_demo_diagnostics')
        ALTER EVENT SESSION oppo_demo_diagnostics ON SERVER STATE = STOP;
    DROP EVENT SESSION oppo_demo_diagnostics ON SERVER;
END;
GO

CREATE EVENT SESSION oppo_demo_diagnostics ON SERVER
ADD EVENT sqlserver.optional_parameter_optimization_skipped_reason
(
    ACTION (sqlserver.sql_text, sqlserver.database_name)
),
ADD EVENT sqlserver.query_with_optional_parameter_predicate
(
    ACTION (sqlserver.sql_text, sqlserver.database_name)
)
ADD TARGET package0.ring_buffer (SET max_memory = 4096)
WITH
(
    MAX_MEMORY = 8 MB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 1 SECONDS,
    TRACK_CAUSALITY = OFF,
    STARTUP_STATE = OFF
);
GO

ALTER EVENT SESSION oppo_demo_diagnostics ON SERVER STATE = START;
GO

BEGIN TRY
    DECLARE @SelectiveCustomerId int;
    DECLARE @LocalCustomerId int;

    SELECT @SelectiveCustomerId = SelectiveCustomerId
    FROM dbo.DemoSettings
    WHERE SettingsId = 1;

    SET @LocalCustomerId = @SelectiveCustomerId;

    PRINT N'Running an ineligible local-variable query.';
    SELECT TOP (1)
        OrderId,
        CustomerId,
        OrderDate,
        TotalAmount
    FROM dbo.Orders
    WHERE CustomerId = @LocalCustomerId
       OR @LocalCustomerId IS NULL;

    PRINT N'Running the predicate with OPTION (RECOMPILE).';
    EXEC sys.sp_executesql
        N'SELECT TOP (1) OrderId, CustomerId, OrderDate, TotalAmount
          FROM dbo.Orders
          WHERE CustomerId = @CustomerId
             OR @CustomerId IS NULL
          OPTION (RECOMPILE);',
        N'@CustomerId int',
        @CustomerId = @SelectiveCustomerId;

    PRINT N'Running dbo.SearchOrders_After for both parameter states.';
    CREATE TABLE #Sink
    (
        OrderId int NOT NULL,
        CustomerId int NOT NULL,
        OrderDate datetime2(0) NOT NULL,
        TotalAmount decimal(18, 2) NOT NULL
    );

    INSERT #Sink (OrderId, CustomerId, OrderDate, TotalAmount)
    EXEC dbo.SearchOrders_After @CustomerId = NULL;

    TRUNCATE TABLE #Sink;

    INSERT #Sink (OrderId, CustomerId, OrderDate, TotalAmount)
    EXEC dbo.SearchOrders_After @CustomerId = @SelectiveCustomerId;

    TRUNCATE TABLE #Sink;

    PRINT N'Running dbo.SearchOrders_Before for both parameter states.';
    INSERT #Sink (OrderId, CustomerId, OrderDate, TotalAmount)
    EXEC dbo.SearchOrders_Before @CustomerId = NULL;

    TRUNCATE TABLE #Sink;

    INSERT #Sink (OrderId, CustomerId, OrderDate, TotalAmount)
    EXEC dbo.SearchOrders_Before @CustomerId = @SelectiveCustomerId;

    DROP TABLE #Sink;

    WAITFOR DELAY '00:00:02';

    PRINT N'=== EXTENDED EVENT FIELDS ===';
    ;WITH target_xml AS
    (
        SELECT CAST(t.target_data AS xml) AS target_data
        FROM sys.dm_xe_session_targets AS t
        INNER JOIN sys.dm_xe_sessions AS s
            ON s.address = t.event_session_address
        WHERE s.name = N'oppo_demo_diagnostics'
          AND t.target_name = N'ring_buffer'
    )
    SELECT
        event_node.value('@name', 'nvarchar(256)') AS event_name,
        event_node.value('@timestamp', 'nvarchar(40)') AS event_timestamp,
        data_node.value('@name', 'nvarchar(128)') AS field_name,
        COALESCE(
            data_node.value('(value/text())[1]', 'nvarchar(max)'),
            data_node.value('(text/text())[1]', 'nvarchar(max)')
        ) AS field_value
    FROM target_xml
    CROSS APPLY target_data.nodes('/RingBufferTarget/event') AS events(event_node)
    CROSS APPLY event_node.nodes('data') AS fields(data_node)
    ORDER BY event_timestamp, event_name, field_name;
END TRY
BEGIN CATCH
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'oppo_demo_diagnostics')
        ALTER EVENT SESSION oppo_demo_diagnostics ON SERVER STATE = STOP;
    IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'oppo_demo_diagnostics')
        DROP EVENT SESSION oppo_demo_diagnostics ON SERVER;
    THROW;
END CATCH;
GO

IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'oppo_demo_diagnostics')
    ALTER EVENT SESSION oppo_demo_diagnostics ON SERVER STATE = STOP;
GO

IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'oppo_demo_diagnostics')
    DROP EVENT SESSION oppo_demo_diagnostics ON SERVER;
GO

PRINT N'Eligibility session oppo_demo_diagnostics has been dropped.';
GO
