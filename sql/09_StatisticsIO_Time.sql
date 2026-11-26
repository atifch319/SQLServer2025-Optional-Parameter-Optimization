/*
    09_StatisticsIO_Time.sql

    Repeated measurements for the four scenarios.

    SET STATISTICS IO and SET STATISTICS TIME are on during each measured batch.
    The batch is only the procedure call plus the marker PRINT statements.
    Invoke-Demo.ps1 runs this script through SqlClient and drains result rows
    without writing them to the log. In SSMS, enable
    Tools > Options > Query Results > SQL Server > Results to Grid >
    "Discard results after execution" before running this script, or the grid
    will hold every order returned by the NULL parameter.

    Each scenario has one cold run and MeasuredRuns warm runs (default 5).
    Cold means the demo database procedure cache was cleared. When this is the
    only user database on LocalDB, the cold run also runs CHECKPOINT and
    DBCC DROPCLEANBUFFERS. That buffer-pool command is instance-wide, so the
    script refuses it when another user database exists or the engine is not LocalDB.

    dbo.PerformanceMeasurement stores sys.dm_exec_query_stats values read
    immediately after each execution. Those counters are statement counters.
    STATISTICS IO/TIME text is returned to the client and parsed by the runner.
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
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'SqlServerOPPODemo'
    THROW 50090, 'Refusing to measure because the current database is not SqlServerOPPODemo.', 1;

DROP TABLE IF EXISTS dbo.PerformanceMeasurement;
GO

CREATE TABLE dbo.PerformanceMeasurement
(
    MeasurementId int IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PerformanceMeasurement PRIMARY KEY,
    CapturedAt datetime2(0) NOT NULL CONSTRAINT DF_PerformanceMeasurement_CapturedAt DEFAULT (SYSUTCDATETIME()),
    ScenarioName nvarchar(80) NOT NULL,
    OppoStatus nvarchar(20) NOT NULL,
    ParameterState nvarchar(40) NOT NULL,
    CacheState nvarchar(40) NOT NULL,
    RunNumber int NOT NULL,
    LogicalReads bigint NULL,
    PhysicalReads bigint NULL,
    CpuTimeMicroseconds bigint NULL,
    ElapsedTimeMicroseconds bigint NULL,
    CounterSource nvarchar(80) NOT NULL,
    PlanShape nvarchar(1000) NULL
);
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

DECLARE @SelectiveCustomerId int;
DECLARE @MeasuredRuns int;
DECLARE @AllowBufferPoolClear bit = 0;
DECLARE @Scenario int;
DECLARE @Run int;
DECLARE @CacheState nvarchar(40);
DECLARE @ScenarioName nvarchar(80);
DECLARE @OppoStatus nvarchar(20);
DECLARE @ParameterLabel nvarchar(40);
DECLARE @CustomerId int;
DECLARE @ProcedureName sysname;
DECLARE @LogicalReads bigint;
DECLARE @PhysicalReads bigint;
DECLARE @CpuMicroseconds bigint;
DECLARE @ElapsedMicroseconds bigint;
DECLARE @Plan xml;
DECLARE @PlanShape nvarchar(1000);
DECLARE @Marker nvarchar(200);
DECLARE @Access nvarchar(800);
DECLARE @Variant nvarchar(40);
DECLARE @Dispatcher int;

SELECT
    @SelectiveCustomerId = SelectiveCustomerId,
    @MeasuredRuns = MeasuredRuns
FROM dbo.DemoSettings
WHERE SettingsId = 1;

IF CAST(SERVERPROPERTY('IsLocalDB') AS int) = 1
   AND DB_NAME() = N'SqlServerOPPODemo'
   AND NOT EXISTS
   (
       SELECT 1
       FROM sys.databases
       WHERE database_id > 4
         AND name <> N'SqlServerOPPODemo'
   )
BEGIN
    SET @AllowBufferPoolClear = 1;
END;

PRINT CONCAT(N'AllowBufferPoolClear=', @AllowBufferPoolClear);
PRINT CONCAT(N'MeasuredRuns=', @MeasuredRuns);
PRINT CONCAT(N'SelectiveCustomerId=', @SelectiveCustomerId);
PRINT N'User databases on this instance:';

SELECT name
FROM sys.databases
WHERE database_id > 4
ORDER BY name;

SET @Scenario = 1;
WHILE @Scenario <= 4
BEGIN
    SET @ProcedureName = CASE WHEN @Scenario IN (1, 2) THEN N'SearchOrders_Before' ELSE N'SearchOrders_After' END;
    SET @OppoStatus = CASE WHEN @Scenario IN (1, 2) THEN N'Disabled' ELSE N'Enabled' END;
    SET @CustomerId = CASE WHEN @Scenario IN (1, 3) THEN NULL ELSE @SelectiveCustomerId END;
    SET @ParameterLabel = CASE WHEN @CustomerId IS NULL THEN N'NULL' ELSE CONVERT(nvarchar(40), @CustomerId) END;
    SET @ScenarioName = CASE @Scenario
        WHEN 1 THEN N'A_Disabled_NULL'
        WHEN 2 THEN N'B_Disabled_Selective'
        WHEN 3 THEN N'C_Enabled_NULL'
        ELSE N'D_Enabled_Selective'
    END;

    SET @Run = 0;
    WHILE @Run <= @MeasuredRuns
    BEGIN
        SET @CacheState = CASE
            WHEN @Run = 0 AND @AllowBufferPoolClear = 1 THEN N'Cold'
            WHEN @Run = 0 THEN N'CacheClearedBufferPoolNotCleared'
            ELSE N'Warm'
        END;

        IF @Run = 0
        BEGIN
            ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
            IF @AllowBufferPoolClear = 1
            BEGIN
                CHECKPOINT;
                DBCC DROPCLEANBUFFERS;
            END;
        END;

        SET @LogicalReads = NULL;
        SET @PhysicalReads = NULL;
        SET @CpuMicroseconds = NULL;
        SET @ElapsedMicroseconds = NULL;
        SET @Plan = NULL;
        SET @PlanShape = N'actual-plan-unavailable';
        SET @Access = NULL;
        SET @Variant = NULL;
        SET @Dispatcher = NULL;

        SET @Marker = CONCAT(
            N'### MEASURE BEGIN|', @ScenarioName, N'|', @OppoStatus, N'|',
            @ParameterLabel, N'|', @CacheState, N'|', @Run);
        RAISERROR (@Marker, 0, 1) WITH NOWAIT;

        IF @ProcedureName = N'SearchOrders_Before'
            EXEC dbo.SearchOrders_Before @CustomerId = @CustomerId;
        ELSE
            EXEC dbo.SearchOrders_After @CustomerId = @CustomerId;

        SET @Marker = CONCAT(
            N'### MEASURE END|', @ScenarioName, N'|', @OppoStatus, N'|',
            @ParameterLabel, N'|', @CacheState, N'|', @Run);
        RAISERROR (@Marker, 0, 1) WITH NOWAIT;

        SELECT TOP (1)
            @LogicalReads = qs.last_logical_reads,
            @PhysicalReads = qs.last_physical_reads,
            @CpuMicroseconds = qs.last_worker_time,
            @ElapsedMicroseconds = qs.last_elapsed_time
        FROM sys.dm_exec_procedure_stats AS ps
        INNER JOIN sys.dm_exec_query_stats AS qs
            ON qs.plan_handle = ps.plan_handle
        WHERE ps.database_id = DB_ID()
          AND ps.object_id = OBJECT_ID(N'dbo.' + @ProcedureName)
        ORDER BY qs.last_execution_time DESC;

        SELECT TOP (1) @Plan = stats_xml.query_plan
        FROM sys.dm_exec_procedure_stats AS ps
        CROSS APPLY sys.dm_exec_query_statistics_xml(ps.plan_handle) AS stats_xml
        WHERE ps.database_id = DB_ID()
          AND ps.object_id = OBJECT_ID(N'dbo.' + @ProcedureName)
        ORDER BY ps.last_execution_time DESC;

        IF @Plan IS NOT NULL
        BEGIN
            ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
            SELECT @Access = STRING_AGG(
                CONCAT(
                    ops.PhysicalOp,
                    N' est=', COALESCE(CONVERT(nvarchar(40), CONVERT(decimal(18, 2), ops.EstimateRows)), N'?'),
                    N' act=', COALESCE(CONVERT(nvarchar(40), CONVERT(decimal(18, 2), ops.ActualRows)), N'?')
                ),
                N' | ')
            FROM
            (
                SELECT
                    rel.value('@PhysicalOp', 'nvarchar(128)') AS PhysicalOp,
                    rel.value('@EstimateRows', 'float') AS EstimateRows,
                    rel.value('sum(RunTimeInformation/RunTimeCountersPerThread/@ActualRows)', 'float') AS ActualRows
                FROM @Plan.nodes('//RelOp') AS r(rel)
            ) AS ops
            WHERE ops.PhysicalOp IN
            (
                N'Index Seek', N'Index Scan', N'Clustered Index Seek', N'Clustered Index Scan',
                N'Table Scan', N'Key Lookup', N'Nested Loops', N'Hash Match', N'Merge Join',
                N'Sort', N'Parallelism', N'Filter'
            );

            ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
            SELECT
                @Variant = @Plan.value('(//QueryPlan/@QueryVariantID)[1]', 'nvarchar(40)'),
                @Dispatcher = @Plan.exist('//Dispatcher/OptionalParameterPredicate');

            SET @PlanShape = CONCAT(
                COALESCE(@Access, N'no-access-operator-matched'),
                N' | QueryVariantID=', COALESCE(@Variant, N'none'),
                N' | OptionalParameterDispatcher=', COALESCE(CONVERT(nvarchar(10), @Dispatcher), N'0'));
        END;

        INSERT dbo.PerformanceMeasurement
        (
            ScenarioName,
            OppoStatus,
            ParameterState,
            CacheState,
            RunNumber,
            LogicalReads,
            PhysicalReads,
            CpuTimeMicroseconds,
            ElapsedTimeMicroseconds,
            CounterSource,
            PlanShape
        )
        VALUES
        (
            @ScenarioName,
            @OppoStatus,
            @ParameterLabel,
            @CacheState,
            @Run,
            @LogicalReads,
            @PhysicalReads,
            @CpuMicroseconds,
            @ElapsedMicroseconds,
            N'sys.dm_exec_query_stats',
            @PlanShape
        );

        PRINT CONCAT(N'### PLAN SHAPE|', @ScenarioName, N'|', @CacheState, N'|', @Run, N'|', @PlanShape);

        SET @Run += 1;
    END;

    SET @Scenario += 1;
END;
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

SELECT
    ScenarioName,
    OppoStatus,
    ParameterState,
    CacheState,
    RunNumber,
    LogicalReads,
    PhysicalReads,
    CpuTimeMicroseconds,
    ElapsedTimeMicroseconds,
    CounterSource,
    PlanShape
FROM dbo.PerformanceMeasurement
ORDER BY MeasurementId;
GO
