# Execution plans

This folder holds actual execution plans captured from SQL Server. The files are produced by `Invoke-Demo.ps1` after `sql/08_CompareExecutionPlans.sql` stores the plan XML returned by SQL Server.

The repository does not contain hand-written plans. If this folder only has this README, the capture step has not been run on this copy of the project.

## Open a `.sqlplan` file in SSMS

1. Start SQL Server Management Studio.
2. Use **File > Open > File** and select a `.sqlplan` file, or drag the file onto SSMS.
3. SSMS opens the graphical plan. Actual plans include runtime row counts when SQL Server returned them.
4. Right-click an operator and choose **Properties** for estimated rows, actual rows, and object names.
5. On the plan, search the statement text for system-generated `PLAN PER VALUE` and `optional_predicate` metadata. That text is written by the engine. Do not copy it into application SQL.

You can also query the captured XML directly:

```sql
USE SqlServerOPPODemo;
SELECT
    ScenarioName,
    PlanSource,
    QueryVariantId,
    HasDispatcher,
    HasOptionalPredicate,
    StatementText
FROM dbo.CapturedPlan
ORDER BY CaptureId;
```

In the results grid, click the `PlanXml` value if you include that column in the query, then save it as a `.sqlplan` file.
