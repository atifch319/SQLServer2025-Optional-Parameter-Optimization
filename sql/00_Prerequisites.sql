/*
    00_Prerequisites.sql

    Read-only check that the connected engine is SQL Server 2025 (17.x).
    This script does not create a database and does not change compatibility
    levels. Run it before 01_CreateDatabase.sql.

    sqlcmd:
        sqlcmd -S "(localdb)\SqlServerOPPODemo" -E -b -I -i .\00_Prerequisites.sql
*/
SET NOCOUNT ON;

DECLARE @Major int = TRY_CONVERT(int, CONVERT(nvarchar(20), SERVERPROPERTY('ProductMajorVersion')));
DECLARE @Version nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion'));
DECLARE @Level nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('ProductLevel'));
DECLARE @Update nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('ProductUpdateLevel'));
DECLARE @Edition nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));
DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @IsLocalDb int = CONVERT(int, SERVERPROPERTY('IsLocalDB'));

PRINT N'=== PREREQUISITE CHECK (READ ONLY) ===';
PRINT N'ProductVersion: ' + COALESCE(@Version, N'(null)');
PRINT N'ProductLevel: ' + COALESCE(@Level, N'(null)');
PRINT N'ProductUpdateLevel: ' + COALESCE(@Update, N'(null)');
PRINT N'Edition: ' + COALESCE(@Edition, N'(null)');
PRINT N'EngineEdition: ' + COALESCE(CONVERT(nvarchar(20), @EngineEdition), N'(null)');
PRINT N'IsLocalDB: ' + COALESCE(CONVERT(nvarchar(20), @IsLocalDb), N'(null)');
PRINT N'ServerName: ' + COALESCE(@@SERVERNAME, N'(null)');
PRINT @@VERSION;

IF @Major IS NULL OR @Major < 17
BEGIN
    THROW 50010, 'SQL Server 2025 (product major version 17) is required. No database was changed.', 1;
END;

PRINT N'Prerequisite passed: product major version is 17 or higher.';
PRINT N'Engine version and database compatibility level are different settings.';
PRINT N'This check does not read or alter any user database.';
GO
