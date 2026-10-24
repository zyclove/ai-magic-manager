$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if ($args.Count -ne 0) { throw 'Fixed process inventory accepts no arguments' }
if ($PSVersionTable.PSVersion.ToString() -ne '7.6.5') { throw 'Fixed PowerShell 7.6.5 required' }

$sampleStartedAtUtc = [DateTime]::UtcNow.ToString('o')
$rows = [Collections.Generic.List[object]]::new()
$providerErrors = [Collections.Generic.List[string]]::new()
$processObjects = @()
$enumerationSucceeded = $false
try {
    $processObjects = @(Microsoft.PowerShell.Management\Get-Process -ErrorAction Stop)
    $enumerationSucceeded = $true
    foreach ($processObject in $processObjects) {
        $rowPid = $null
        $rowName = $null
        $rowErrors = [Collections.Generic.List[string]]::new()
        try {
            $rowPid = $processObject.Id
            if ($rowPid -isnot [int] -or $rowPid -lt 0) { throw 'Invalid provider PID type/value' }
        } catch { $rowErrors.Add('pid: ' + $_.Exception.Message) }
        try {
            $rowName = $processObject.ProcessName
            if ($rowName -isnot [string] -or [string]::IsNullOrWhiteSpace($rowName)) { throw 'Empty/non-string process name' }
        } catch { $rowErrors.Add('name: ' + $_.Exception.Message) }
        $rows.Add([pscustomobject][ordered]@{pid = $rowPid; name = $rowName; errors = @($rowErrors.ToArray())})
    }
} catch { $providerErrors.Add('enumeration: ' + $_.Exception.Message) }
finally {
    foreach ($processObject in $processObjects) {
        try { $processObject.Dispose() }
        catch { $providerErrors.Add('dispose: ' + $_.Exception.Message) }
    }
}
$result = [ordered]@{
    schemaVersion = 1
    provider = 'PowerShell7 Get-Process / System.Diagnostics.Process'
    purpose = 'FULL_FRESH_NAME_INVENTORY_NOT_PROCESS_CONTROL_IDENTITY'
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    sampleStartedAtUtc = $sampleStartedAtUtc
    sampleFinishedAtUtc = [DateTime]::UtcNow.ToString('o')
    enumerationSucceeded = $enumerationSucceeded
    providerErrors = @($providerErrors.ToArray())
    rowCount = $rows.Count
    rows = @($rows.ToArray())
}
[Console]::WriteLine(($result | ConvertTo-Json -Depth 5 -Compress))
if (-not $enumerationSucceeded -or $providerErrors.Count -ne 0 -or $rows.Count -le 0) { exit 1 }
foreach ($row in $rows) { if ($row.errors.Count -ne 0) { exit 1 } }
exit 0
