#Requires -Version 5.1
<#
    Invoke-Demo.ps1

    Builds SqlServerOPPODemo, runs the SQL demonstration, exports actual plans,
    and writes results from SQL Server output.

    The script never prints SQL_PASSWORD or SQLCMDPASSWORD.
    It refuses to run unless the database name is SqlServerOPPODemo.
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$Database,
    [switch]$SkipResetRerun,
    [switch]$ReportOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSCommandPath
$SqlDir = Join-Path $Root 'sql'
$TestDir = Join-Path $Root 'tests'
$PlanDir = Join-Path $Root 'execution-plans'
$ResultDir = Join-Path $Root 'results'
$RawDir = Join-Path $ResultDir 'raw'
$script:Phases = New-Object System.Collections.Generic.List[object]
$script:Fatal = $null
$script:ExitCode = 0
$script:MeasureMessages = New-Object System.Collections.Generic.List[string]

function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $splitAt = $trimmed.IndexOf('=')
        if ($splitAt -lt 1) { continue }
        $name = $trimmed.Substring(0, $splitAt).Trim()
        $value = $trimmed.Substring($splitAt + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if (-not (Test-Path -LiteralPath "Env:$name")) {
            Set-Item -Path "Env:$name" -Value $value
        }
    }
}

function Add-Phase {
    param([string]$Name, [string]$Status, [string]$Detail)
    $script:Phases.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Detail = $Detail
    }) | Out-Null
}

function Get-DemoConnectionString {
    param([string]$InitialCatalog)
    if ($env:SQL_USER) {
        return "Server=$($script:Server);Database=$InitialCatalog;User ID=$($env:SQL_USER);Password=$($env:SQL_PASSWORD);Application Name=SqlServerOPPODemo;TrustServerCertificate=True;"
    }
    return "Server=$($script:Server);Database=$InitialCatalog;Integrated Security=True;Application Name=SqlServerOPPODemo;TrustServerCertificate=True;"
}

function Invoke-SqlCmdFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InitialCatalog
    )
    $leaf = Split-Path -Leaf $Path
    $logPath = Join-Path $RawDir ($leaf + '.log')
    $argList = @('-S', $script:Server, '-d', $InitialCatalog, '-b', '-I', '-w', '4096', '-s', '|', '-i', $Path)
    if (-not $env:SQL_USER) {
        $argList = @('-E') + $argList
    }
    $previousUser = $env:SQLCMDUSER
    $previousPassword = $env:SQLCMDPASSWORD
    try {
        if ($env:SQL_USER) {
            $env:SQLCMDUSER = $env:SQL_USER
            $env:SQLCMDPASSWORD = $env:SQL_PASSWORD
        }
        $output = & sqlcmd @argList 2>&1
        $code = $LASTEXITCODE
        $output | Out-File -FilePath $logPath -Encoding utf8
        $output | ForEach-Object { Write-Host $_ }
        if ($code -ne 0) {
            throw "sqlcmd exited with code $code for $leaf. Log: $logPath"
        }
    }
    finally {
        if ($env:SQL_USER) {
            if ($null -eq $previousUser) { Remove-Item Env:SQLCMDUSER -ErrorAction SilentlyContinue }
            else { $env:SQLCMDUSER = $previousUser }
            if ($null -eq $previousPassword) { Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue }
            else { $env:SQLCMDPASSWORD = $previousPassword }
        }
    }
}

function Invoke-SqlGoFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InitialCatalog
    )
    Add-Type -AssemblyName System.Data
    $text = Get-Content -LiteralPath $Path -Raw
    $batches = [regex]::Split($text, "(?m)^\s*GO\s*(?:--.*)?$")
    $connection = New-Object System.Data.SqlClient.SqlConnection (Get-DemoConnectionString -InitialCatalog $InitialCatalog)
    $sink = $script:MeasureMessages
    $handler = {
        param($sender, $eventArgs)
        foreach ($sqlError in $eventArgs.Errors) {
            $sink.Add([string]$sqlError.Message)
        }
    }.GetNewClosure()
    $connection.add_InfoMessage($handler)
    $connection.Open()
    try {
        foreach ($batch in $batches) {
            if ([string]::IsNullOrWhiteSpace($batch)) { continue }
            $command = $connection.CreateCommand()
            $command.CommandTimeout = 0
            $command.CommandText = $batch
            # ExecuteNonQuery consumes rowsets inside SqlClient. PowerShell does not
            # format or store the order rows, and STATISTICS messages still arrive.
            [void]$command.ExecuteNonQuery()
        }
    }
    finally {
        $connection.remove_InfoMessage($handler)
        $connection.Close()
    }
}

function Invoke-SqlTable {
    param(
        [Parameter(Mandatory = $true)][string]$InitialCatalog,
        [Parameter(Mandatory = $true)][string]$Query
    )
    Add-Type -AssemblyName System.Data
    $connection = New-Object System.Data.SqlClient.SqlConnection (Get-DemoConnectionString -InitialCatalog $InitialCatalog)
    $connection.Open()
    try {
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 0
        $command.CommandText = $Query
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
        $table = New-Object System.Data.DataTable
        [void]$adapter.Fill($table)
        return ,$table
    }
    finally {
        $connection.Close()
    }
}

function Export-CapturedPlans {
    Add-Type -AssemblyName System.Data
    $connection = New-Object System.Data.SqlClient.SqlConnection (Get-DemoConnectionString -InitialCatalog $script:Database)
    $connection.Open()
    try {
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 0
        $command.CommandText = @"
SELECT CaptureId, ScenarioName, PlanSource, PlanXml
FROM dbo.CapturedPlan
WHERE PlanXml IS NOT NULL
ORDER BY CaptureId;
"@
        $reader = $command.ExecuteReader()
        $count = 0
        while ($reader.Read()) {
            $id = $reader.GetInt32(0)
            $scenario = $reader.GetString(1)
            $source = $reader.GetString(2)
            $xmlValue = $reader.GetValue(3)
            if ($null -eq $xmlValue -or $xmlValue -is [System.DBNull]) { continue }
            $xml = [string]$xmlValue
            if ([string]::IsNullOrWhiteSpace($xml)) { continue }
            $safe = ($scenario + '.' + $source + '.' + $id) -replace '[^\w\.\-]', '_'
            $path = Join-Path $PlanDir ($safe + '.sqlplan')
            $utf8 = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($path, $xml, $utf8)
            $count += 1
        }
        $reader.Close()
        return $count
    }
    finally {
        $connection.Close()
    }
}

function Save-StatisticsXmlPlans {
    Add-Type -AssemblyName System.Data
    $connection = New-Object System.Data.SqlClient.SqlConnection (Get-DemoConnectionString -InitialCatalog $script:Database)
    $connection.Open()
    try {
        $lookup = $connection.CreateCommand()
        $lookup.CommandText = 'SELECT SelectiveCustomerId FROM dbo.DemoSettings WHERE SettingsId = 1;'
        $selective = [int]$lookup.ExecuteScalar()
        $runs = @(
            @{ Name = 'A_Disabled_NULL'; Proc = 'dbo.SearchOrders_Before'; Oppo = 'Disabled'; Parameter = 'NULL'; Value = $null },
            @{ Name = 'B_Disabled_Selective'; Proc = 'dbo.SearchOrders_Before'; Oppo = 'Disabled'; Parameter = [string]$selective; Value = $selective },
            @{ Name = 'C_Enabled_NULL'; Proc = 'dbo.SearchOrders_After'; Oppo = 'Enabled'; Parameter = 'NULL'; Value = $null },
            @{ Name = 'D_Enabled_Selective'; Proc = 'dbo.SearchOrders_After'; Oppo = 'Enabled'; Parameter = [string]$selective; Value = $selective }
        )
        $saved = 0
        foreach ($run in $runs) {
            $command = $connection.CreateCommand()
            $command.CommandTimeout = 0
            $command.CommandText = @"
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET ARITHABORT ON;
SET STATISTICS XML ON;
EXEC $($run.Proc) @CustomerId = @CustomerId;
"@
            $parameter = $command.Parameters.Add('@CustomerId', [System.Data.SqlDbType]::Int)
            if ($null -eq $run.Value) { $parameter.Value = [System.DBNull]::Value } else { $parameter.Value = [int]$run.Value }
            $reader = $command.ExecuteReader()
            $planXml = $null
            do {
                if ($reader.FieldCount -eq 1) {
                    while ($reader.Read()) {
                        $value = $reader.GetValue(0)
                        if ($null -eq $value -or $value -is [System.DBNull]) { continue }
                        $text = [string]$value
                        if ($text.Contains('ShowPlanXML')) { $planXml = $text }
                    }
                }
                else {
                    while ($reader.Read()) { }
                }
            } while ($reader.NextResult())
            $reader.Close()
            if ([string]::IsNullOrWhiteSpace($planXml)) {
                throw "SET STATISTICS XML did not return a showplan for $($run.Name)."
            }
            $path = Join-Path $PlanDir ($run.Name + '.statistics-xml.sqlplan')
            $utf8 = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($path, $planXml, $utf8)
            $insert = $connection.CreateCommand()
            $insert.CommandTimeout = 0
            $insert.CommandText = @"
INSERT dbo.CapturedPlan (ScenarioName, ParameterState, OppoStatus, PlanSource, PlanXml)
VALUES (@ScenarioName, @ParameterState, @OppoStatus, N'StatisticsXml', @PlanXml);
"@
            [void]$insert.Parameters.Add('@ScenarioName', [System.Data.SqlDbType]::NVarChar, 80)
            [void]$insert.Parameters.Add('@ParameterState', [System.Data.SqlDbType]::NVarChar, 40)
            [void]$insert.Parameters.Add('@OppoStatus', [System.Data.SqlDbType]::NVarChar, 20)
            [void]$insert.Parameters.Add('@PlanXml', [System.Data.SqlDbType]::Xml)
            $insert.Parameters['@ScenarioName'].Value = $run.Name
            $insert.Parameters['@ParameterState'].Value = $run.Parameter
            $insert.Parameters['@OppoStatus'].Value = $run.Oppo
            $insert.Parameters['@PlanXml'].Value = $planXml
            [void]$insert.ExecuteNonQuery()
            $saved += 1
        }
        return $saved
    }
    finally {
        $connection.Close()
    }
}

function Get-Median {
    param($Values)
    $items = @($Values | ForEach-Object { $_ })
    if ($items.Count -eq 0) { return $null }
    $sorted = @($items | Sort-Object)
    $mid = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return $sorted[$mid] }
    return ($sorted[$mid - 1] + $sorted[$mid]) / 2
}

function Get-MeasureRows {
    param($Messages)
    $text = [string]::Join("`n", $Messages)
    $rows = New-Object System.Collections.Generic.List[object]
    $pair = [regex]::Matches($text, '(?s)### MEASURE BEGIN\|([^\r\n]+)\r?\n(.*?)### MEASURE END\|\1')
    foreach ($match in $pair) {
        $key = $match.Groups[1].Value
        $block = $match.Groups[2].Value
        $parts = $key.Split('|')
        if ($parts.Count -lt 5) { continue }
        $logical = $null
        $physical = $null
        $io = [regex]::Matches($block, "Table 'Orders'\. Scan count (\d+), logical reads (\d+), physical reads (\d+)")
        if ($io.Count -gt 0) {
            $logical = [int64]0
            $physical = [int64]0
            foreach ($item in $io) {
                $logical += [int64]$item.Groups[2].Value
                $physical += [int64]$item.Groups[3].Value
            }
        }
        $cpu = $null
        $elapsed = $null
        $timeMatches = [regex]::Matches($block, 'SQL Server Execution Times:\s+CPU time = (\d+) ms,\s+elapsed time = (\d+) ms')
        if ($timeMatches.Count -gt 0) {
            $cpuValues = @()
            $elapsedValues = @()
            foreach ($item in $timeMatches) {
                $cpuValues += [int]$item.Groups[1].Value
                $elapsedValues += [int]$item.Groups[2].Value
            }
            $cpu = ($cpuValues | Measure-Object -Maximum).Maximum
            $elapsed = ($elapsedValues | Measure-Object -Maximum).Maximum
        }
        $compileCpu = $null
        $compileElapsed = $null
        $compileMatches = [regex]::Matches($block, 'parse and compile time:\s+CPU time = (\d+) ms,\s+elapsed time = (\d+) ms')
        if ($compileMatches.Count -gt 0) {
            $compileCpu = 0
            $compileElapsed = 0
            foreach ($item in $compileMatches) {
                $compileCpu += [int]$item.Groups[1].Value
                $compileElapsed += [int]$item.Groups[2].Value
            }
        }
        $rows.Add([pscustomobject]@{
            Scenario = $parts[0]
            OppoStatus = $parts[1]
            Parameter = $parts[2]
            CacheState = $parts[3]
            RunNumber = [int]$parts[4]
            LogicalReads = $logical
            PhysicalReads = $physical
            CpuMs = $cpu
            ElapsedMs = $elapsed
            CompileCpuMs = $compileCpu
            CompileElapsedMs = $compileElapsed
            ExecutionTimeLines = $timeMatches.Count
            PlanShape = $null
        }) | Out-Null
    }
    foreach ($message in $Messages) {
        $shape = [regex]::Match($message, '^### PLAN SHAPE\|(?<scenario>[^|]+)\|(?<cache>[^|]+)\|(?<run>\d+)\|(?<shape>.*)$')
        if (-not $shape.Success) { continue }
        $row = $rows | Where-Object {
            $_.Scenario -eq $shape.Groups['scenario'].Value -and
            $_.CacheState -eq $shape.Groups['cache'].Value -and
            $_.RunNumber -eq [int]$shape.Groups['run'].Value
        } | Select-Object -First 1
        if ($null -ne $row) { $row.PlanShape = $shape.Groups['shape'].Value }
    }
    return $rows
}

function Format-Cell {
    param($Value)
    if ($null -eq $Value) { return 'not in output' }
    return [string]$Value
}

function Format-SqlValue {
    param($Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return 'null' }
    return [string]$Value
}

function Get-TestTotalsFromLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($text, 'TEST_TOTALS\|passed=(\d+)\|failed=(\d+)\|skipped=(\d+)\|not_run=(\d+)')
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        Passed = [int]$match.Groups[1].Value
        Failed = [int]$match.Groups[2].Value
        Skipped = [int]$match.Groups[3].Value
        NotRun = [int]$match.Groups[4].Value
    }
}

function Write-Reports {
    $measurePath = Join-Path $RawDir '09_StatisticsIO_Time.log'
    if (-not $ReportOnly) {
        [System.IO.File]::WriteAllLines($measurePath, $script:MeasureMessages, (New-Object System.Text.UTF8Encoding $false))
    }
    $measureRows = @(Get-MeasureRows -Messages $script:MeasureMessages)

    $versionText = 'not queried'
    $versionStringText = 'not queried'
    $compatText = 'not queried'
    $oppoText = 'not queried'
    $pspText = 'not queried'
    $editionText = 'not queried'
    $levelText = 'not queried'
    $updateText = 'not queried'
    $engineEditionText = 'not queried'
    $localDbText = 'not queried'
    $rowText = 'not queried'
    $indexText = 'not queried'
    $statsText = 'not queried'
    $variantText = 'not queried'
    $operatorText = 'not queried'
    $dmvText = 'not queried'
    try {
        $info = Invoke-SqlTable -InitialCatalog 'master' -Query @"
SELECT
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) AS ProductVersion,
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductLevel')) AS ProductLevel,
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductUpdateLevel')) AS ProductUpdateLevel,
    CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) AS Edition,
    CONVERT(nvarchar(20), SERVERPROPERTY('EngineEdition')) AS EngineEdition,
    CONVERT(nvarchar(20), SERVERPROPERTY('IsLocalDB')) AS IsLocalDB,
    REPLACE(REPLACE(CONVERT(nvarchar(1000), @@VERSION), CHAR(13), ' '), CHAR(10), ' ') AS VersionString;
"@
        if ($info.Rows.Count -gt 0) {
            $versionStringText = [string]$info.Rows[0]['VersionString']
            $versionText = [string]$info.Rows[0]['ProductVersion']
            $levelText = [string]$info.Rows[0]['ProductLevel']
            $updateText = [string]$info.Rows[0]['ProductUpdateLevel']
            $editionText = [string]$info.Rows[0]['Edition']
            $engineEditionText = [string]$info.Rows[0]['EngineEdition']
            $localDbText = [string]$info.Rows[0]['IsLocalDB']
        }
    }
    catch {
        $versionText = 'query failed: ' + $_.Exception.Message
    }

    try {
        $config = Invoke-SqlTable -InitialCatalog $script:Database -Query @"
SELECT d.compatibility_level,
       CONVERT(int, oppo.value) AS oppo_value,
       CONVERT(int, oppo.is_value_default) AS oppo_is_default,
       CONVERT(int, psp.value) AS psp_value,
       CONVERT(int, psp.is_value_default) AS psp_is_default
FROM sys.databases AS d
CROSS JOIN sys.database_scoped_configurations AS oppo
CROSS JOIN sys.database_scoped_configurations AS psp
WHERE d.name = N'SqlServerOPPODemo'
  AND oppo.name = N'OPTIONAL_PARAMETER_OPTIMIZATION'
  AND psp.name = N'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION';
"@
        if ($config.Rows.Count -gt 0) {
            $compatText = [string]$config.Rows[0]['compatibility_level']
            $oppoText = [string]$config.Rows[0]['oppo_value'] + ' (is_value_default=' + [string]$config.Rows[0]['oppo_is_default'] + ')'
            $pspText = [string]$config.Rows[0]['psp_value'] + ' (is_value_default=' + [string]$config.Rows[0]['psp_is_default'] + ')'
        }
    }
    catch {
        $compatText = 'query failed: ' + $_.Exception.Message
    }

    try {
        $rows = Invoke-SqlTable -InitialCatalog $script:Database -Query @"
SELECT
    (SELECT COUNT_BIG(*) FROM dbo.Customers) AS customers,
    (SELECT COUNT_BIG(*) FROM dbo.Orders) AS orders,
    (SELECT SelectiveCustomerId FROM dbo.DemoSettings WHERE SettingsId = 1) AS selective_customer,
    (SELECT SelectiveOrderCount FROM dbo.DemoSettings WHERE SettingsId = 1) AS selective_setting,
    (SELECT COUNT_BIG(*) FROM dbo.Orders WHERE CustomerId = (SELECT SelectiveCustomerId FROM dbo.DemoSettings WHERE SettingsId = 1)) AS selective_orders;
"@
        if ($rows.Rows.Count -gt 0) {
            $rowText = 'customers=' + $rows.Rows[0]['customers'] + '; orders=' + $rows.Rows[0]['orders'] + '; selective_customer=' + $rows.Rows[0]['selective_customer'] + '; selective_orders=' + $rows.Rows[0]['selective_orders'] + '; selective_setting=' + $rows.Rows[0]['selective_setting']
        }
    }
    catch {
        $rowText = 'query failed: ' + $_.Exception.Message
    }

    try {
        $indexes = Invoke-SqlTable -InitialCatalog $script:Database -Query @"
SELECT i.name AS index_name, i.type_desc, c.name AS column_name, ic.key_ordinal, ic.is_included_column
FROM sys.indexes AS i
INNER JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'dbo.Orders')
ORDER BY i.index_id, ic.key_ordinal, ic.index_column_id;
"@
        $lines = @()
        foreach ($indexRow in $indexes.Rows) {
            $lines += ('- ' + $indexRow['index_name'] + ' ' + $indexRow['type_desc'] + ' column=' + $indexRow['column_name'] + ' key_ordinal=' + $indexRow['key_ordinal'] + ' included=' + $indexRow['is_included_column'])
        }
        if ($lines.Count -eq 0) { $indexText = 'no index rows returned' } else { $indexText = ($lines -join "`n") }
    }
    catch {
        $indexText = 'query failed: ' + $_.Exception.Message
    }

    try {
        $stats = Invoke-SqlTable -InitialCatalog $script:Database -Query @"
SELECT OBJECT_NAME(s.object_id) AS table_name, s.name AS stats_name, sp.last_updated, sp.rows, sp.rows_sampled, sp.modification_counter
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE s.object_id IN (OBJECT_ID(N'dbo.Customers'), OBJECT_ID(N'dbo.Orders'))
ORDER BY table_name, s.stats_id;
"@
        $lines = @()
        foreach ($statsRow in $stats.Rows) {
            $lines += ('- ' + $statsRow['table_name'] + '.' + $statsRow['stats_name'] + ' rows=' + $statsRow['rows'] + ' sampled=' + $statsRow['rows_sampled'] + ' modified=' + $statsRow['modification_counter'] + ' updated=' + $statsRow['last_updated'])
        }
        if ($lines.Count -eq 0) { $statsText = 'no statistics rows returned' } else { $statsText = ($lines -join "`n") }
    }
    catch {
        $statsText = 'query failed: ' + $_.Exception.Message
    }

    try {
        $variants = Invoke-SqlTable -InitialCatalog $script:Database -Query @"
EXEC sys.sp_query_store_flush_db;
SELECT
    OBJECT_NAME(parent_query.object_id) AS parent_procedure,
    variant_link.dispatcher_plan_id,
    variant_link.query_variant_query_id,
    CASE WHEN variant_text.query_sql_text LIKE N'%optional_predicate%' THEN 1 ELSE 0 END AS has_optional_predicate
FROM sys.query_store_query_variant AS variant_link
INNER JOIN sys.query_store_query AS parent_query ON parent_query.query_id = variant_link.parent_query_id
INNER JOIN sys.query_store_query AS variant_query ON variant_query.query_id = variant_link.query_variant_query_id
INNER JOIN sys.query_store_query_text AS variant_text ON variant_text.query_text_id = variant_query.query_text_id
WHERE parent_query.object_id IN (OBJECT_ID(N'dbo.SearchOrders_Before'), OBJECT_ID(N'dbo.SearchOrders_After'));
"@
        if ($variants.Rows.Count -eq 0) {
            $variantText = 'Query Store returned no variant rows for the two search procedures.'
        }
        else {
            $lines = @()
            foreach ($variantRow in $variants.Rows) {
                $lines += ('- parent=' + $variantRow['parent_procedure'] + ' dispatcher_plan_id=' + $variantRow['dispatcher_plan_id'] + ' variant_query_id=' + $variantRow['query_variant_query_id'] + ' optional_predicate=' + $variantRow['has_optional_predicate'])
            }
            $variantText = ($lines -join "`n")
        }
    }
    catch {
        $variantText = 'query failed: ' + $_.Exception.Message
    }

    try {
        $operators = Invoke-SqlTable -InitialCatalog $script:Database -Query @"
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT c.CaptureId, c.ScenarioName, c.PlanSource,
       c.PlanXml.value('(//QueryPlan/@QueryVariantID)[1]', 'int') AS QueryVariantId,
       c.PlanXml.exist('//Dispatcher/OptionalParameterPredicate') AS HasDispatcher,
       CASE
           WHEN CAST(c.PlanXml AS nvarchar(max)) LIKE N'%optional_predicate(%'
             OR CAST(c.PlanXml AS nvarchar(max)) LIKE N'%OptionalParameterPredicate%' THEN 1
           ELSE 0
       END AS HasOptionalPredicate,
       rel.value('@PhysicalOp', 'nvarchar(128)') AS PhysicalOp,
       rel.value('@EstimateRows', 'float') AS EstimateRows,
       rel.value('sum(RunTimeInformation/RunTimeCountersPerThread/@ActualRows)', 'float') AS ActualRows,
       rel.value('(RunTimeInformation/RunTimeCountersPerThread/@ActualLogicalReads)[1]', 'bigint') AS ActualLogicalReads
FROM dbo.CapturedPlan AS c
CROSS APPLY c.PlanXml.nodes('//RelOp') AS r(rel)
WHERE c.PlanSource = N'StatisticsXml'
  AND rel.value('@PhysicalOp', 'nvarchar(128)') IN
      (N'Index Seek', N'Index Scan', N'Clustered Index Seek', N'Clustered Index Scan', N'Table Scan', N'Key Lookup');
"@
        if ($operators.Rows.Count -eq 0) {
            $operatorText = 'The showplan shred returned no access operators.'
        }
        else {
            $lines = @('| Capture | Scenario | Source | Variant | Dispatcher | optional_predicate | Operator | Estimated rows | Actual rows | Actual logical reads |', '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
            foreach ($operatorRow in $operators.Rows) {
                $lines += ('| ' + (Format-SqlValue $operatorRow['CaptureId']) + ' | ' + (Format-SqlValue $operatorRow['ScenarioName']) + ' | ' + (Format-SqlValue $operatorRow['PlanSource']) + ' | ' + (Format-SqlValue $operatorRow['QueryVariantId']) + ' | ' + (Format-SqlValue $operatorRow['HasDispatcher']) + ' | ' + (Format-SqlValue $operatorRow['HasOptionalPredicate']) + ' | ' + (Format-SqlValue $operatorRow['PhysicalOp']) + ' | ' + (Format-SqlValue $operatorRow['EstimateRows']) + ' | ' + (Format-SqlValue $operatorRow['ActualRows']) + ' | ' + (Format-SqlValue $operatorRow['ActualLogicalReads']) + ' |')
            }
            $operatorText = ($lines -join "`n")
        }
    }
    catch {
        $operatorText = 'query failed: ' + $_.Exception.Message
    }

    try {
        $dmv = Invoke-SqlTable -InitialCatalog $script:Database -Query @"
SELECT ScenarioName, OppoStatus, ParameterState, CacheState, RunNumber,
       LogicalReads, PhysicalReads, CpuTimeMicroseconds, ElapsedTimeMicroseconds, PlanShape
FROM dbo.PerformanceMeasurement
ORDER BY MeasurementId;
"@
        if ($dmv.Rows.Count -eq 0) {
            $dmvText = 'dbo.PerformanceMeasurement returned no rows.'
        }
        else {
            $lines = @('| Scenario | OPPO | Parameter | Cache | Run | Logical reads | Physical reads | CPU microseconds | Elapsed microseconds | Plan shape |', '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
            foreach ($dmvRow in $dmv.Rows) {
                $lines += ('| ' + (Format-SqlValue $dmvRow['ScenarioName']) + ' | ' + (Format-SqlValue $dmvRow['OppoStatus']) + ' | ' + (Format-SqlValue $dmvRow['ParameterState']) + ' | ' + (Format-SqlValue $dmvRow['CacheState']) + ' | ' + (Format-SqlValue $dmvRow['RunNumber']) + ' | ' + (Format-SqlValue $dmvRow['LogicalReads']) + ' | ' + (Format-SqlValue $dmvRow['PhysicalReads']) + ' | ' + (Format-SqlValue $dmvRow['CpuTimeMicroseconds']) + ' | ' + (Format-SqlValue $dmvRow['ElapsedTimeMicroseconds']) + ' | ' + (Format-SqlValue $dmvRow['PlanShape']) + ' |')
            }
            $dmvText = ($lines -join "`n")
        }
    }
    catch {
        $dmvText = 'query failed: ' + $_.Exception.Message
    }

    $initialTotals = Get-TestTotalsFromLog -Path (Join-Path $RawDir '01_CorrectnessTests.initial.log')
    $resetTotals = Get-TestTotalsFromLog -Path (Join-Path $RawDir '02_AssertResetState.log')
    $rerunTotals = Get-TestTotalsFromLog -Path (Join-Path $RawDir '01_CorrectnessTests.after-reset.log')

    function Format-Totals($Totals, [string]$Missing) {
        if ($null -eq $Totals) { return $Missing }
        return 'passed=' + $Totals.Passed + ' failed=' + $Totals.Failed + ' skipped=' + $Totals.Skipped + ' not_run=' + $Totals.NotRun
    }

    $ioLines = @('| Scenario | OPPO | Parameter | Cache | Run | Logical reads | Physical reads | CPU ms | Elapsed ms | Compile CPU ms | Compile elapsed ms | Plan shape |', '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
    if ($measureRows.Count -eq 0) {
        $ioLines += '| not parsed |  |  |  |  |  |  |  |  |  |  | See results/raw/09_StatisticsIO_Time.log |'
    }
    else {
        foreach ($measureRow in $measureRows) {
            $ioLines += ('| ' + $measureRow.Scenario + ' | ' + $measureRow.OppoStatus + ' | ' + $measureRow.Parameter + ' | ' + $measureRow.CacheState + ' | ' + $measureRow.RunNumber + ' | ' + (Format-Cell $measureRow.LogicalReads) + ' | ' + (Format-Cell $measureRow.PhysicalReads) + ' | ' + (Format-Cell $measureRow.CpuMs) + ' | ' + (Format-Cell $measureRow.ElapsedMs) + ' | ' + (Format-Cell $measureRow.CompileCpuMs) + ' | ' + (Format-Cell $measureRow.CompileElapsedMs) + ' | ' + (Format-Cell $measureRow.PlanShape) + ' |')
        }
    }

    $summaryLines = @('| Scenario | OPPO | Parameter | Cold logical reads | Warm runs | Warm median logical reads | Warm median CPU ms | Warm median elapsed ms |', '| --- | --- | --- | --- | --- | --- | --- | --- |')
        $groups = @($measureRows | Group-Object Scenario)
    if ($groups.Count -eq 0) {
        $summaryLines += '| not parsed |  |  |  |  |  |  |  |'
    }
    foreach ($group in $groups) {
        $cold = @($group.Group | Where-Object { $_.RunNumber -eq 0 } | Select-Object -First 1)
        $warm = @($group.Group | Where-Object { $_.RunNumber -gt 0 -and $null -ne $_.LogicalReads })
        $warmCpu = @($group.Group | Where-Object { $_.RunNumber -gt 0 -and $null -ne $_.CpuMs })
        $warmElapsed = @($group.Group | Where-Object { $_.RunNumber -gt 0 -and $null -ne $_.ElapsedMs })
        $first = $group.Group | Select-Object -First 1
        $coldReads = if ($cold.Count -eq 0) { 'not in output' } else { Format-Cell $cold[0].LogicalReads }
        $summaryLines += ('| ' + $first.Scenario + ' | ' + $first.OppoStatus + ' | ' + $first.Parameter + ' | ' + $coldReads + ' | ' + $warm.Count + ' | ' + (Format-Cell (Get-Median @($warm | ForEach-Object { [double]$_.LogicalReads }))) + ' | ' + (Format-Cell (Get-Median @($warmCpu | ForEach-Object { [double]$_.CpuMs }))) + ' | ' + (Format-Cell (Get-Median @($warmElapsed | ForEach-Object { [double]$_.ElapsedMs }))) + ' |')
    }

    $cpu = 'not queried'
    $memoryGb = 'not queried'
    try {
        $cpu = [string](Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
        $memoryGb = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
    }
    catch {
        $cpu = 'query failed'
    }
    $sdkText = 'not queried'
    try { $sdkText = (& dotnet --list-sdks 2>&1 | Out-String).Trim() } catch { $sdkText = 'dotnet not available' }
    $dockerText = 'not queried'
    try {
        $dockerText = (& docker info --format '{{.ServerVersion}}' 2>&1 | Out-String).Trim()
        if ($dockerText -match 'error|cannot find|failed') {
            $dockerText = 'Docker CLI responded, but the engine was not available. ' + $dockerText
        }
    } catch {
        $dockerText = 'Docker CLI is installed on this machine; the engine query did not succeed. ' + $_.Exception.Message
    }

    $parallelText = 'NonParallelPlanReason was not read from D_Enabled_Selective.statistics-xml.sqlplan.'
    $selectivePlan = Join-Path $PlanDir 'D_Enabled_Selective.statistics-xml.sqlplan'
    if (Test-Path -LiteralPath $selectivePlan) {
        $selectivePlanText = Get-Content -LiteralPath $selectivePlan -Raw
        $parallelMatch = [regex]::Match($selectivePlanText, 'NonParallelPlanReason="([^"]+)"')
        if ($parallelMatch.Success) {
            $parallelText = 'D_Enabled_Selective.statistics-xml.sqlplan NonParallelPlanReason=' + $parallelMatch.Groups[1].Value + '.'
        }
    }

    $readAheadCounts = @{}
    foreach ($messageLine in $script:MeasureMessages) {
        if ($messageLine -match "Table 'Orders'\. Scan count \d+, logical reads \d+, physical reads (\d+), page server reads \d+, read-ahead reads (\d+)") {
            $readAheadKey = 'physical reads ' + $Matches[1] + ', read-ahead reads ' + $Matches[2]
            if (-not $readAheadCounts.ContainsKey($readAheadKey)) { $readAheadCounts[$readAheadKey] = 0 }
            $readAheadCounts[$readAheadKey] = $readAheadCounts[$readAheadKey] + 1
        }
    }
    $readAheadLines = @()
    foreach ($readAheadKey in ($readAheadCounts.Keys | Sort-Object)) {
        $readAheadLines += ('- ' + $readAheadKey + ' (' + $readAheadCounts[$readAheadKey] + ' Orders lines)')
    }
    if ($readAheadLines.Count -eq 0) {
        $readAheadText = 'No Orders STATISTICS IO lines were parsed for read-ahead.'
    }
    else {
        $readAheadText = "Orders STATISTICS IO lines in the measurement log, grouped by physical reads and read-ahead reads. The comparison table uses physical reads only.`n`n" + ($readAheadLines -join "`n")
    }

    $phaseLines = @('| Phase | Status | Detail |', '| --- | --- | --- |')
    foreach ($phase in $script:Phases) {
        $detail = ($phase.Detail -replace '\|', '/').Trim()
        if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
        $phaseLines += ('| ' + $phase.Name + ' | ' + $phase.Status + ' | ' + $detail + ' |')
    }
    if (-not $ReportOnly) {
        $phaseFile = Join-Path $RawDir 'benchmark-phases.json'
        $script:Phases | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $phaseFile -Encoding UTF8
    }

    $fatalText = 'none'
    if ($script:Fatal) { $fatalText = $script:Fatal }

    $generated = @"
Generated by Invoke-Demo.ps1 from SQL Server output. Do not treat these figures as a guarantee on other hardware.

## Engine

- @@VERSION: $versionStringText
- Product version: $versionText
- Product level: $levelText
- Product update level: $updateText
- Edition: $editionText
- EngineEdition: $engineEditionText
- IsLocalDB: $localDbText
- Compatibility level: $compatText
- OPTIONAL_PARAMETER_OPTIMIZATION value: $oppoText
- PARAMETER_SENSITIVE_PLAN_OPTIMIZATION value: $pspText

## Data, indexes, and statistics

These catalog values were queried when the report was written. ``12_ResetDemo.sql`` clears the tables and the full runner then reloads them with the same generator and ``dbo.DemoSettings``. Statistics timestamps are the last ``UPDATE STATISTICS``, which is that reload when the reset phase ran. ``dbo.CapturedPlan`` and ``dbo.PerformanceMeasurement`` are not dropped by the reset, and scripts 08 and 09 are not rerun, so the plan and measurement tables still describe the measured executions.

$rowText

$indexText

$statsText

## Plan operators from captured actual-plan XML

$operatorText

Estimated rows are the showplan ``EstimateRows`` values. They are not rewritten to equal actual rows. A null variant id means that showplan had no ``QueryVariantID`` attribute. The plan-shape value ``actual-plan-unavailable`` is written by script 09 when ``sys.dm_exec_query_statistics_xml`` returns no XML for the procedure handle. The operators above come from ``SET STATISTICS XML`` plans stored in ``dbo.CapturedPlan`` and ``execution-plans/*.statistics-xml.sqlplan``.

$parallelText

## Query Store variant rows

These rows are the catalog at report time. The full runner clears Query Store during reset and then recreates the procedures, so the ids below belong to that later compilation. A variant row is OPPO evidence here only because ``optional_predicate`` is 1. The measurement plans are the STATISTICS XML files, not these Query Store ids.

$variantText

## STATISTICS IO and TIME

A CPU or elapsed value of 0 ms is the value STATISTICS TIME returned. SQL Server reports those counters in whole milliseconds. Logical and physical reads are the sum of ``Table 'Orders'`` counters inside each measure marker. CPU and elapsed time are the maximum ``SQL Server Execution Times`` values inside that marker. Parse and compile time is summed separately and is not added to execution time. A blank parse means the message was not present. ``not in output`` means the parser did not find that counter.

$readAheadText

### Every run

$($ioLines -join "`n")

### Cold run and warm median

Warm median uses runs numbered 1 and above. The median of an even count is the mean of the two middle values.

$($summaryLines -join "`n")

## Statement counters from sys.dm_exec_query_stats

These are the values stored in ``dbo.PerformanceMeasurement`` from ``sys.dm_exec_query_stats`` immediately after each measured execution. A null counter is a null returned for that procedure statement, not a zero. STATISTICS IO and the STATISTICS XML plans are the source for logical reads when this column is null. ``last_physical_reads`` on a cold scan can include read-ahead pages; the STATISTICS IO physical-reads column above does not.

$dmvText

## Tests

- Initial correctness: $(Format-Totals $initialTotals 'not run')
- Reset state: $(Format-Totals $resetTotals 'not run')
- Correctness after reset and reload: $(Format-Totals $rerunTotals 'not run')

## Machine

- Processor: $cpu
- Physical memory GB: $memoryGb
- dotnet --list-sdks: $sdkText
- docker info: $dockerText

## Phases

$($phaseLines -join "`n")

Fatal error: $fatalText
"@

    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Join-Path $ResultDir 'MEASUREMENTS.md'), $generated, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $ResultDir 'VALIDATION_REPORT.md'), $generated, $utf8)

    $readmePath = Join-Path $Root 'README.md'
    if (Test-Path -LiteralPath $readmePath) {
        $readme = [System.IO.File]::ReadAllText($readmePath)
        $pattern = '(?s)<!-- VALIDATION_SNAPSHOT_START -->.*?<!-- VALIDATION_SNAPSHOT_END -->'
        if ([regex]::IsMatch($readme, $pattern)) {
            $replacement = "<!-- VALIDATION_SNAPSHOT_START -->`r`n" + $generated + "`r`n<!-- VALIDATION_SNAPSHOT_END -->"
            $updated = [regex]::Replace($readme, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
            [System.IO.File]::WriteAllText($readmePath, $updated, $utf8)
        }
    }
}

Import-DotEnv -Path (Join-Path $Root '.env')
if (-not $Server) {
    if ($env:SQL_SERVER) { $Server = $env:SQL_SERVER } else { $Server = '(localdb)\SqlServerOPPODemo' }
}
if (-not $Database) { $Database = 'SqlServerOPPODemo' }
if ($env:SQL_DATABASE -and $env:SQL_DATABASE -ne 'SqlServerOPPODemo' -and -not $PSBoundParameters.ContainsKey('Database')) {
    throw 'SQL_DATABASE must stay SqlServerOPPODemo. These scripts do not change any other database.'
}
if ($Database -ne 'SqlServerOPPODemo') {
    throw 'This runner only uses the dedicated database SqlServerOPPODemo.'
}
$script:Server = $Server
$script:Database = $Database

New-Item -ItemType Directory -Force -Path $RawDir | Out-Null
New-Item -ItemType Directory -Force -Path $PlanDir | Out-Null

try {
    if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
        throw 'sqlcmd was not found on PATH.'
    }

    if ($ReportOnly) {
        foreach ($line in Get-Content -LiteralPath (Join-Path $RawDir '09_StatisticsIO_Time.log')) {
            $script:MeasureMessages.Add([string]$line)
        }
        $phaseFile = Join-Path $RawDir 'benchmark-phases.json'
        if (Test-Path -LiteralPath $phaseFile) {
            $savedPhases = Get-Content -LiteralPath $phaseFile -Raw | ConvertFrom-Json
            for ($phaseIndex = 0; $phaseIndex -lt $savedPhases.Count; $phaseIndex++) {
                Add-Phase -Name ([string]$savedPhases[$phaseIndex].Name) -Status ([string]$savedPhases[$phaseIndex].Status) -Detail ([string]$savedPhases[$phaseIndex].Detail)
            }
        }
        Add-Phase -Name 'Report only' -Status 'completed' -Detail 'Reloaded the measurement log and queried SQL Server again.'
    }
    else {

    Add-Phase -Name 'Connection target' -Status 'recorded' -Detail ("server=" + $script:Server + "; database=" + $script:Database)

    if ($script:Server -eq '(localdb)\SqlServerOPPODemo') {
        $localDbExe = 'C:\Program Files\Microsoft SQL Server\170\Tools\Binn\SqlLocalDB.exe'
        if (-not (Test-Path -LiteralPath $localDbExe)) {
            throw "SQL Server 2025 SqlLocalDB.exe was not found at $localDbExe"
        }
        & $localDbExe info SqlServerOPPODemo | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & $localDbExe create SqlServerOPPODemo 17.0
            if ($LASTEXITCODE -ne 0) { throw 'LocalDB create SqlServerOPPODemo 17.0 failed.' }
        }
        & $localDbExe start SqlServerOPPODemo | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'LocalDB start SqlServerOPPODemo failed.' }
        Add-Phase -Name 'Start LocalDB SqlServerOPPODemo' -Status 'completed' -Detail 'instance start command returned 0'
    }

    $setup = @(
        '00_Prerequisites.sql',
        '01_CreateDatabase.sql',
        '02_CreateTables.sql',
        '03_GenerateData.sql',
        '04_CreateIndexes.sql',
        '05_VerifyConfiguration.sql',
        '06_Before_OPPO_Disabled.sql',
        '07_After_OPPO_Enabled.sql',
        '08_CompareExecutionPlans.sql'
    )
    foreach ($file in $setup) {
        $catalog = 'master'
        if ($file -ne '00_Prerequisites.sql' -and $file -ne '01_CreateDatabase.sql') { $catalog = $script:Database }
        Write-Host "Running $file"
        Invoke-SqlCmdFile -Path (Join-Path $SqlDir $file) -InitialCatalog $catalog
        Add-Phase -Name $file -Status 'completed' -Detail 'sqlcmd exit 0'
    }

    $planCount = Export-CapturedPlans
    Add-Phase -Name 'Export sqlplan files' -Status 'completed' -Detail ("files=" + $planCount)
    $actualCount = Save-StatisticsXmlPlans
    Add-Phase -Name 'STATISTICS XML actual plans' -Status 'completed' -Detail ("files=" + $actualCount)

    Write-Host 'Running 09_StatisticsIO_Time.sql'
    Invoke-SqlGoFile -Path (Join-Path $SqlDir '09_StatisticsIO_Time.sql') -InitialCatalog $script:Database
    Add-Phase -Name '09_StatisticsIO_Time.sql' -Status 'completed' -Detail ("messages=" + $script:MeasureMessages.Count)

    foreach ($file in @('10_QueryStoreAnalysis.sql', '11_CheckOPPOEligibility.sql')) {
        Write-Host "Running $file"
        Invoke-SqlCmdFile -Path (Join-Path $SqlDir $file) -InitialCatalog $script:Database
        Add-Phase -Name $file -Status 'completed' -Detail 'sqlcmd exit 0'
    }

    Write-Host 'Running correctness tests'
    $initialLog = Join-Path $RawDir '01_CorrectnessTests.initial.log'
    $testOutput = & sqlcmd -S $script:Server -d $script:Database -E -b -I -w 4096 -s '|' -i (Join-Path $TestDir '01_CorrectnessTests.sql') 2>&1
    $testCode = $LASTEXITCODE
    $testOutput | Out-File -FilePath $initialLog -Encoding utf8
    $testOutput | ForEach-Object { Write-Host $_ }
    if ($testCode -ne 0) { throw "Initial correctness tests failed with sqlcmd exit $testCode." }
    Add-Phase -Name 'Correctness tests' -Status 'completed' -Detail 'sqlcmd exit 0'

    if ($SkipResetRerun) {
        Add-Phase -Name 'Reset and rerun' -Status 'skipped' -Detail 'SkipResetRerun was set'
    }
    else {
        Write-Host 'Resetting and rerunning'
        Invoke-SqlCmdFile -Path (Join-Path $SqlDir '12_ResetDemo.sql') -InitialCatalog $script:Database
        Add-Phase -Name '12_ResetDemo.sql' -Status 'completed' -Detail 'sqlcmd exit 0'
        $resetOutput = & sqlcmd -S $script:Server -d $script:Database -E -b -I -w 4096 -s '|' -i (Join-Path $TestDir '02_AssertResetState.sql') 2>&1
        $resetCode = $LASTEXITCODE
        $resetOutput | Out-File -FilePath (Join-Path $RawDir '02_AssertResetState.log') -Encoding utf8
        $resetOutput | ForEach-Object { Write-Host $_ }
        if ($resetCode -ne 0) { throw "Reset assertions failed with sqlcmd exit $resetCode." }
        Add-Phase -Name 'Reset assertions' -Status 'completed' -Detail 'sqlcmd exit 0'
        foreach ($file in @('03_GenerateData.sql', '04_CreateIndexes.sql', '06_Before_OPPO_Disabled.sql', '07_After_OPPO_Enabled.sql')) {
            Write-Host "Rerunning $file"
            Invoke-SqlCmdFile -Path (Join-Path $SqlDir $file) -InitialCatalog $script:Database
            Add-Phase -Name ("rerun " + $file) -Status 'completed' -Detail 'sqlcmd exit 0'
        }
        $rerunOutput = & sqlcmd -S $script:Server -d $script:Database -E -b -I -w 4096 -s '|' -i (Join-Path $TestDir '01_CorrectnessTests.sql') 2>&1
        $rerunCode = $LASTEXITCODE
        $rerunOutput | Out-File -FilePath (Join-Path $RawDir '01_CorrectnessTests.after-reset.log') -Encoding utf8
        $rerunOutput | ForEach-Object { Write-Host $_ }
        if ($rerunCode -ne 0) { throw "Correctness tests after reset failed with sqlcmd exit $rerunCode." }
        Add-Phase -Name 'Correctness tests after reset' -Status 'completed' -Detail 'sqlcmd exit 0'
        }
    }
}
catch {
    $script:Fatal = $_.Exception.Message
    $script:ExitCode = 1
    Write-Host "FAILED: $($script:Fatal)"
}
finally {
    try { Write-Reports } catch { Write-Host "Report generation failed: $($_.Exception.Message)"; $script:ExitCode = 1 }
}

exit $script:ExitCode
