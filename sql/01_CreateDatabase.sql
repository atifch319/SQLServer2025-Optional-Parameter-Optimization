/*
    01_CreateDatabase.sql

    Creates only SqlServerOPPODemo, sets that database to compatibility level 170,
    enables Query Store, and turns OPTIONAL_PARAMETER_OPTIMIZATION on.
    It does not alter any other database.

    Run after 00_Prerequisites.sql.
*/
SET NOCOUNT ON;

IF DB_ID(N'SqlServerOPPODemo') IS NOT NULL
   AND DB_ID(N'SqlServerOPPODemo') <= 4
BEGIN
    THROW 50011, 'Refusing to continue: SqlServerOPPODemo is not a user database id.', 1;
END;

IF DB_ID(N'SqlServerOPPODemo') IS NULL
BEGIN
    PRINT N'Creating database SqlServerOPPODemo.';
    CREATE DATABASE SqlServerOPPODemo;
END
ELSE
BEGIN
    PRINT N'Database SqlServerOPPODemo already exists. Configuration statements will converge it.';
END;
GO

IF DB_ID(N'SqlServerOPPODemo') IS NULL
    THROW 50012, 'SqlServerOPPODemo was not created.', 1;
GO

ALTER DATABASE SqlServerOPPODemo SET COMPATIBILITY_LEVEL = 170;
GO
ALTER DATABASE SqlServerOPPODemo SET RECOVERY SIMPLE;
GO
ALTER DATABASE SqlServerOPPODemo SET AUTO_CLOSE OFF;
GO
ALTER DATABASE SqlServerOPPODemo SET QUERY_STORE = ON;
GO
ALTER DATABASE SqlServerOPPODemo SET QUERY_STORE
(
    OPERATION_MODE = READ_WRITE,
    QUERY_CAPTURE_MODE = ALL,
    MAX_STORAGE_SIZE_MB = 1024,
    INTERVAL_LENGTH_MINUTES = 1,
    DATA_FLUSH_INTERVAL_SECONDS = 60,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
    SIZE_BASED_CLEANUP_MODE = AUTO,
    MAX_PLANS_PER_QUERY = 200
);
GO

USE SqlServerOPPODemo;
GO

IF DB_NAME() <> N'SqlServerOPPODemo'
    THROW 50013, 'Refusing to change scoped configuration because the current database is not SqlServerOPPODemo.', 1;

ALTER DATABASE SCOPED CONFIGURATION SET OPTIONAL_PARAMETER_OPTIMIZATION = ON;
ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = ON;
GO

DECLARE @DataFile sysname;
DECLARE @LogFile sysname;
DECLARE @DataSizeMb int;
DECLARE @LogSizeMb int;
DECLARE @Sql nvarchar(max);

SELECT
    @DataFile = name,
    @DataSizeMb = size / 128
FROM sys.master_files
WHERE database_id = DB_ID(N'SqlServerOPPODemo')
  AND type = 0;

SELECT
    @LogFile = name,
    @LogSizeMb = size / 128
FROM sys.master_files
WHERE database_id = DB_ID(N'SqlServerOPPODemo')
  AND type = 1;

IF @DataFile IS NOT NULL AND @DataSizeMb < 256
BEGIN
    SET @Sql = N'ALTER DATABASE SqlServerOPPODemo MODIFY FILE (NAME = ' + QUOTENAME(@DataFile) + N', SIZE = 256MB, FILEGROWTH = 128MB);';
    EXEC sys.sp_executesql @Sql;
END;

IF @LogFile IS NOT NULL AND @LogSizeMb < 64
BEGIN
    SET @Sql = N'ALTER DATABASE SqlServerOPPODemo MODIFY FILE (NAME = ' + QUOTENAME(@LogFile) + N', SIZE = 64MB, FILEGROWTH = 64MB);';
    EXEC sys.sp_executesql @Sql;
END;
GO

USE SqlServerOPPODemo;
GO

DECLARE @Compatibility int;
DECLARE @Oppo int;

SELECT @Compatibility = compatibility_level
FROM sys.databases
WHERE name = N'SqlServerOPPODemo';

SELECT @Oppo = CONVERT(int, value)
FROM sys.database_scoped_configurations
WHERE name = N'OPTIONAL_PARAMETER_OPTIMIZATION';

IF @Compatibility <> 170
    THROW 50014, 'SqlServerOPPODemo compatibility level is not 170.', 1;

IF @Oppo <> 1
    THROW 50015, 'OPTIONAL_PARAMETER_OPTIMIZATION is not ON for SqlServerOPPODemo.', 1;

PRINT N'SqlServerOPPODemo is at compatibility level 170 and OPTIONAL_PARAMETER_OPTIMIZATION = ON.';
GO
