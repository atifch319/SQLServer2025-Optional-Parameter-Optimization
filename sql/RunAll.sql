/*
    Runs the SQL scripts in order from the sql directory.

    From a shell whose current directory is sql:

        sqlcmd -S "(localdb)\SqlServerOPPODemo" -E -b -I -i .\RunAll.sql

    09_StatisticsIO_Time.sql is intentionally not included. It returns the full
    search result on each measured execution. Run it with Invoke-Demo.ps1, or in
    SSMS with "Discard results after execution" enabled.

    12_ResetDemo.sql is not included. Run it when you want to clear the demo.
*/
:on error exit
:r .\00_Prerequisites.sql
:r .\01_CreateDatabase.sql
:r .\02_CreateTables.sql
:r .\03_GenerateData.sql
:r .\04_CreateIndexes.sql
:r .\05_VerifyConfiguration.sql
:r .\06_Before_OPPO_Disabled.sql
:r .\07_After_OPPO_Enabled.sql
:r .\08_CompareExecutionPlans.sql
:r .\10_QueryStoreAnalysis.sql
:r .\11_CheckOPPOEligibility.sql

PRINT N'SQL scripts through eligibility diagnostics finished.';
PRINT N'Run 09_StatisticsIO_Time.sql with Invoke-Demo.ps1 or SSMS result discard.';
PRINT N'Run 12_ResetDemo.sql only when you want to clear the demo data.';
GO
