/*
    10_QueryStoreAnalysis.sql

    Reads Query Store catalog views confirmed on SQL Server 2025:
      sys.query_store_query
      sys.query_store_query_text
      sys.query_store_plan
      sys.query_store_query_variant
      sys.query_store_runtime_stats

    sys.query_store_query_variant columns used here are query_variant_query_id,
    parent_query_id, and dispatcher_plan_id.

    That view is shared by multiplan features, including parameter-sensitive plan
    optimization and optional parameter plan optimization. A variant row by itself
    does not identify which feature created it. OPPO-specific evidence is the
    system-generated optional_predicate marker in the statement or plan text.
    This script only displays text returned by Query Store. It does not insert
    PLAN PER VALUE into application SQL.

    Microsoft documents that dispatcher plans do not produce Query Store runtime
    statistics. Variant plans can. Compile duration columns are microseconds.
*/
USE SqlServerOPPODemo;
GO

SET NOCOUNT ON;

IF DB_NAME() <> N'SqlServerOPPODemo'
    THROW 50100, 'Refusing to read Query Store because the current database is not SqlServerOPPODemo.', 1;

EXEC sys.sp_query_store_flush_db;

PRINT N'=== QUERY STORE STATE ===';
SELECT
    desired_state_desc,
    actual_state_desc,
    readonly_reason,
    current_storage_size_mb,
    query_capture_mode_desc
FROM sys.database_query_store_options;

PRINT N'=== PROCEDURE STATEMENTS ===';
SELECT
    q.query_id,
    OBJECT_NAME(q.object_id) AS procedure_name,
    q.query_hash,
    t.query_sql_text,
    p.plan_id,
    p.plan_type,
    p.plan_type_desc,
    p.count_compiles,
    p.last_compile_duration AS last_compile_duration_microseconds
FROM sys.query_store_query AS q
INNER JOIN sys.query_store_query_text AS t
    ON t.query_text_id = q.query_text_id
LEFT JOIN sys.query_store_plan AS p
    ON p.query_id = q.query_id
WHERE q.object_id IN
(
    OBJECT_ID(N'dbo.SearchOrders_Before'),
    OBJECT_ID(N'dbo.SearchOrders_After')
)
ORDER BY procedure_name, q.query_id, p.plan_id;

PRINT N'=== PARENT, DISPATCHER, AND VARIANT LINKS ===';
SELECT
    parent_query.query_id AS parent_query_id,
    OBJECT_NAME(parent_query.object_id) AS parent_procedure_name,
    parent_text.query_sql_text AS parent_query_text,
    variant_link.dispatcher_plan_id,
    dispatcher_plan.plan_type_desc AS dispatcher_plan_type,
    variant_query.query_id AS variant_query_id,
    variant_text.query_sql_text AS variant_query_text,
    CASE
        WHEN variant_text.query_sql_text LIKE N'%optional_predicate%' THEN N'yes'
        ELSE N'no'
    END AS variant_text_contains_optional_predicate,
    variant_plan.plan_id AS variant_plan_id,
    variant_plan.plan_type_desc AS variant_plan_type,
    variant_plan.count_compiles AS variant_count_compiles,
    variant_plan.last_compile_duration AS variant_last_compile_duration_microseconds
FROM sys.query_store_query_variant AS variant_link
INNER JOIN sys.query_store_query AS parent_query
    ON parent_query.query_id = variant_link.parent_query_id
INNER JOIN sys.query_store_query_text AS parent_text
    ON parent_text.query_text_id = parent_query.query_text_id
INNER JOIN sys.query_store_query AS variant_query
    ON variant_query.query_id = variant_link.query_variant_query_id
INNER JOIN sys.query_store_query_text AS variant_text
    ON variant_text.query_text_id = variant_query.query_text_id
LEFT JOIN sys.query_store_plan AS dispatcher_plan
    ON dispatcher_plan.plan_id = variant_link.dispatcher_plan_id
LEFT JOIN sys.query_store_plan AS variant_plan
    ON variant_plan.query_id = variant_query.query_id
WHERE parent_query.object_id IN
(
    OBJECT_ID(N'dbo.SearchOrders_Before'),
    OBJECT_ID(N'dbo.SearchOrders_After')
)
   OR variant_query.object_id IN
(
    OBJECT_ID(N'dbo.SearchOrders_Before'),
    OBJECT_ID(N'dbo.SearchOrders_After')
)
ORDER BY parent_query.query_id, variant_query.query_id, variant_plan.plan_id;

PRINT N'=== VARIANT RUNTIME STATS (WEIGHTED ACROSS INTERVALS) ===';
SELECT
    variant_plan.plan_id,
    OBJECT_NAME(parent_query.object_id) AS parent_procedure_name,
    SUM(runtime.count_executions) AS count_executions,
    SUM(runtime.avg_duration * runtime.count_executions) / NULLIF(SUM(runtime.count_executions), 0) AS weighted_avg_duration_microseconds,
    SUM(runtime.avg_cpu_time * runtime.count_executions) / NULLIF(SUM(runtime.count_executions), 0) AS weighted_avg_cpu_microseconds,
    SUM(runtime.avg_logical_io_reads * runtime.count_executions) / NULLIF(SUM(runtime.count_executions), 0) AS weighted_avg_logical_io_reads,
    SUM(runtime.avg_rowcount * runtime.count_executions) / NULLIF(SUM(runtime.count_executions), 0) AS weighted_avg_rowcount
FROM sys.query_store_query_variant AS variant_link
INNER JOIN sys.query_store_query AS parent_query
    ON parent_query.query_id = variant_link.parent_query_id
INNER JOIN sys.query_store_plan AS variant_plan
    ON variant_plan.query_id = variant_link.query_variant_query_id
INNER JOIN sys.query_store_runtime_stats AS runtime
    ON runtime.plan_id = variant_plan.plan_id
WHERE parent_query.object_id IN
(
    OBJECT_ID(N'dbo.SearchOrders_Before'),
    OBJECT_ID(N'dbo.SearchOrders_After')
)
GROUP BY variant_plan.plan_id, OBJECT_NAME(parent_query.object_id)
ORDER BY parent_procedure_name, variant_plan.plan_id;

PRINT N'=== QUERY TEXT CONTAINING SYSTEM-GENERATED OPPO MARKERS ===';
SELECT
    t.query_text_id,
    t.query_sql_text
FROM sys.query_store_query_text AS t
WHERE t.query_sql_text LIKE N'%optional_predicate%'
   OR t.query_sql_text LIKE N'%PLAN PER VALUE%';
GO
