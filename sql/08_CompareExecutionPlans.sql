/*
    08_CompareExecutionPlans.sql

    Executes the four scenarios and stores the plan XML SQL Server returns.
    Sources:
      - sys.dm_exec_query_statistics_xml after LAST_QUERY_PLAN_STATS execution
      - sys.dm_exec_query_plan for cached plans of the two procedures,
        plus cached plans in this database whose showplan contains
        OptionalParameterPredicate or optional_predicate

    Invoke-Demo.ps1 writes one .sqlplan file per captured row.
    This script does not invent plan XML.
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
    THROW 50080, 'Refusing to capture plans because the current database is not SqlServerOPPODemo.', 1;

ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = ON;
GO

DROP TABLE IF EXISTS dbo.CapturedPlan;
GO

CREATE TABLE dbo.CapturedPlan
(
    CaptureId int IDENTITY(1, 1) NOT NULL CONSTRAINT PK_CapturedPlan PRIMARY KEY,
    CapturedAt datetime2(0) NOT NULL CONSTRAINT DF_CapturedPlan_CapturedAt DEFAULT (SYSUTCDATETIME()),
    ScenarioName nvarchar(80) NOT NULL,
    ParameterState nvarchar(40) NOT NULL,
    OppoStatus nvarchar(20) NOT NULL,
    PlanSource nvarchar(40) NOT NULL,
    QueryVariantId int NULL,
    HasDispatcher bit NULL,
    HasOptionalPredicate bit NULL,
    StatementText nvarchar(max) NULL,
    PlanXml xml NULL
);
GO

IF OBJECT_ID(N'tempdb..#Sink') IS NOT NULL
    DROP TABLE #Sink;

CREATE TABLE #Sink
(
    OrderId int NOT NULL,
    CustomerId int NOT NULL,
    OrderDate datetime2(0) NOT NULL,
    TotalAmount decimal(18, 2) NOT NULL
);

DECLARE @SelectiveCustomerId int;
SELECT @SelectiveCustomerId = SelectiveCustomerId
FROM dbo.DemoSettings
WHERE SettingsId = 1;

DECLARE @Runs table
(
    RunOrder int NOT NULL,
    ScenarioName nvarchar(80) NOT NULL,
    ProcedureName sysname NOT NULL,
    ParameterState nvarchar(40) NOT NULL,
    OppoStatus nvarchar(20) NOT NULL,
    CustomerId int NULL
);

INSERT @Runs (RunOrder, ScenarioName, ProcedureName, ParameterState, OppoStatus, CustomerId)
VALUES
    (1, N'A_Disabled_NULL', N'SearchOrders_Before', N'NULL', N'Disabled', NULL),
    (2, N'B_Disabled_Selective', N'SearchOrders_Before', N'Selective', N'Disabled', @SelectiveCustomerId),
    (3, N'C_Enabled_NULL', N'SearchOrders_After', N'NULL', N'Enabled', NULL),
    (4, N'D_Enabled_Selective', N'SearchOrders_After', N'Selective', N'Enabled', @SelectiveCustomerId);

DECLARE @RunOrder int = 0;
DECLARE @ScenarioName nvarchar(80);
DECLARE @ProcedureName sysname;
DECLARE @ParameterState nvarchar(40);
DECLARE @OppoStatus nvarchar(20);
DECLARE @CustomerId int;
DECLARE @Plan xml;

WHILE 1 = 1
BEGIN
    SELECT TOP (1)
        @RunOrder = RunOrder,
        @ScenarioName = ScenarioName,
        @ProcedureName = ProcedureName,
        @ParameterState = ParameterState,
        @OppoStatus = OppoStatus,
        @CustomerId = CustomerId
    FROM @Runs
    WHERE RunOrder > @RunOrder
    ORDER BY RunOrder;

    IF @@ROWCOUNT = 0
        BREAK;

    TRUNCATE TABLE #Sink;

    IF @ProcedureName = N'SearchOrders_Before'
        INSERT #Sink (OrderId, CustomerId, OrderDate, TotalAmount)
        EXEC dbo.SearchOrders_Before @CustomerId = @CustomerId;
    ELSE
        INSERT #Sink (OrderId, CustomerId, OrderDate, TotalAmount)
        EXEC dbo.SearchOrders_After @CustomerId = @CustomerId;

    SET @Plan = NULL;

    SELECT TOP (1) @Plan = stats_xml.query_plan
    FROM sys.dm_exec_procedure_stats AS ps
    CROSS APPLY sys.dm_exec_query_statistics_xml(ps.plan_handle) AS stats_xml
    WHERE ps.database_id = DB_ID()
      AND ps.object_id = OBJECT_ID(N'dbo.' + @ProcedureName)
    ORDER BY ps.last_execution_time DESC;

    INSERT dbo.CapturedPlan (ScenarioName, ParameterState, OppoStatus, PlanSource, PlanXml)
    VALUES (@ScenarioName, @ParameterState, @OppoStatus, N'QueryStatisticsXml', @Plan);
END;

INSERT dbo.CapturedPlan (ScenarioName, ParameterState, OppoStatus, PlanSource, PlanXml)
SELECT
    CONCAT(N'Cache_', COALESCE(OBJECT_NAME(st.objectid), N'AdHoc')),
    N'Cached',
    CASE
        WHEN OBJECT_NAME(st.objectid) = N'SearchOrders_After' THEN N'Enabled'
        WHEN OBJECT_NAME(st.objectid) = N'SearchOrders_Before' THEN N'Disabled'
        ELSE N'Unknown'
    END,
    N'PlanCache',
    qp.query_plan
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
WHERE qp.query_plan IS NOT NULL
  AND
  (
      st.objectid IN (OBJECT_ID(N'dbo.SearchOrders_Before'), OBJECT_ID(N'dbo.SearchOrders_After'))
      OR qp.query_plan.exist('declare namespace p="http://schemas.microsoft.com/sqlserver/2004/07/showplan"; //p:QueryPlan[@QueryVariantID]') = 1
      OR qp.query_plan.exist('declare namespace p="http://schemas.microsoft.com/sqlserver/2004/07/showplan"; //p:Dispatcher/p:OptionalParameterPredicate') = 1
  );

;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
UPDATE c
SET
    QueryVariantId = c.PlanXml.value('(//QueryPlan/@QueryVariantID)[1]', 'int'),
    HasDispatcher = c.PlanXml.exist('//Dispatcher/OptionalParameterPredicate'),
    StatementText = c.PlanXml.value('(//StmtSimple/@StatementText)[1]', 'nvarchar(max)')
FROM dbo.CapturedPlan AS c
WHERE c.PlanXml IS NOT NULL;

UPDATE dbo.CapturedPlan
SET HasOptionalPredicate =
    CASE
        WHEN PlanXml IS NOT NULL
         AND
         (
             CAST(PlanXml AS nvarchar(max)) LIKE N'%optional_predicate%'
             OR CAST(PlanXml AS nvarchar(max)) LIKE N'%OptionalParameterPredicate%'
         )
        THEN 1
        ELSE 0
    END;

DROP TABLE #Sink;

PRINT N'Captured plans:';
SELECT
    CaptureId,
    ScenarioName,
    ParameterState,
    OppoStatus,
    PlanSource,
    QueryVariantId,
    HasDispatcher,
    HasOptionalPredicate,
    CASE
        WHEN StatementText LIKE N'%PLAN PER VALUE%' THEN N'yes'
        ELSE N'no'
    END AS StatementTextContainsPlanPerValue,
    CASE
        WHEN PlanXml IS NULL THEN N'no plan xml returned'
        ELSE N'xml stored'
    END AS PlanXmlState
FROM dbo.CapturedPlan
ORDER BY CaptureId;

;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT
    c.CaptureId,
    c.ScenarioName,
    c.PlanSource,
    rel.value('@NodeId', 'int') AS NodeId,
    rel.value('@PhysicalOp', 'nvarchar(128)') AS PhysicalOp,
    rel.value('@LogicalOp', 'nvarchar(128)') AS LogicalOp,
    rel.value('@EstimateRows', 'float') AS EstimateRows,
    rel.value('sum(RunTimeInformation/RunTimeCountersPerThread/@ActualRows)', 'float') AS ActualRows,
    rel.value('@EstimatedTotalSubtreeCost', 'float') AS EstimatedSubtreeCost,
    obj.value('@Index', 'nvarchar(256)') AS IndexName,
    obj.value('@IndexKind', 'nvarchar(128)') AS IndexKind
FROM dbo.CapturedPlan AS c
CROSS APPLY c.PlanXml.nodes('//RelOp') AS r(rel)
OUTER APPLY rel.nodes('IndexScan/Object') AS o(obj)
WHERE c.PlanXml IS NOT NULL
  AND rel.value('@PhysicalOp', 'nvarchar(128)') IN
  (
      N'Index Seek',
      N'Index Scan',
      N'Clustered Index Seek',
      N'Clustered Index Scan',
      N'Table Scan',
      N'Key Lookup'
  )
ORDER BY c.CaptureId, NodeId;
GO
