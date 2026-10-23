#Requires -Version 7.0
<# Tests only the activation predicate. Never invokes Docker or starts services. #>
[CmdletBinding()]
param([string]$EvidenceDirectory)
$ErrorActionPreference = 'Stop'
$taskRepository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $EvidenceDirectory) { throw 'Provide a fresh evidence directory inside the project .cache.' }
$taskDirectory = [IO.Path]::GetFullPath($EvidenceDirectory, $taskRepository)
$cachePrefix = [IO.Path]::GetFullPath((Join-Path $taskRepository '.cache')) + [IO.Path]::DirectorySeparatorChar
if (-not $taskDirectory.StartsWith($cachePrefix, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $taskDirectory)) {
    throw 'The test requires a new directory inside the project .cache.'
}
New-Item -ItemType Directory -Path $taskDirectory | Out-Null
$tokens = $parseErrors = $null
$scriptPath = Join-Path $taskRepository 'scripts/start-console.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'The launcher must parse without errors.' }
$predicate = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-ActivationReceipt' }, $true))
if ($predicate.Count -ne 1) { throw 'Expected one activation predicate.' }
. ([ScriptBlock]::Create($predicate[0].Extent.Text))
# The predicate sees only synthetic local metadata within this fresh fixture.
$repository = Join-Path $taskDirectory 'fixture'
$localRoot = Join-Path $repository '.local'
New-Item -ItemType Directory -Path $localRoot -Force | Out-Null
$configuration = [pscustomobject]@{publicUrl='http://localhost:18101'}
$valid = @{schemaVersion=1; state='COMMITTED'; project='fixture-console'; publicUrl='http://localhost:18101'}
$cases = @(
    @{name='canonical committed receipt'; changes=@{}; expected=$true},
    @{name='wrong project'; changes=@{project='other-console'}; expected=$false},
    @{name='wrong public URL'; changes=@{publicUrl='http://localhost:18102'; origin='http://localhost:18101'}; expected=$false},
    @{name='uncommitted receipt'; changes=@{state='PREPARED'; origin='http://localhost:18101'}; expected=$false},
    @{name='unsupported schema'; changes=@{schemaVersion=2; origin='http://localhost:18101'}; expected=$false},
    @{name='origin alone is not canonical URL'; changes=@{publicUrl=$null; origin='http://localhost:18101'}; expected=$false}
)
$results = @()
foreach ($case in $cases) {
    $record = $valid.Clone()
    foreach ($entry in $case.changes.GetEnumerator()) { $record[$entry.Key] = $entry.Value }
    $fileName = 'receipt-' + $results.Count + '.json'
    [IO.File]::WriteAllText((Join-Path $localRoot $fileName), ($record | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $target = [pscustomobject]@{projectName='fixture-console'; activationReceipt=".local/$fileName"}
    $actual = [bool](Test-ActivationReceipt $target)
    $results += [pscustomobject]@{name=$case.name; expected=$case.expected; actual=$actual; matched=($actual -eq $case.expected)}
}
$missing = [bool](Test-ActivationReceipt ([pscustomobject]@{projectName='fixture-console'; activationReceipt='.local/missing.json'}))
$results += [pscustomobject]@{name='missing receipt'; expected=$false; actual=$missing; matched=(-not $missing)}
$escapedRejected = $false
try { Test-ActivationReceipt ([pscustomobject]@{projectName='fixture-console'; activationReceipt='outside.json'}) | Out-Null }
catch { $escapedRejected = $_.Exception.Message -ceq 'Activation receipt must remain inside this project .local directory.' }
$results += [pscustomobject]@{name='receipt outside project local directory'; expected=$true; actual=$escapedRejected; matched=$escapedRejected}
$failures = @($results | Where-Object { -not $_.matched })
$receipt = [ordered]@{scope='Activation predicate only; synthetic metadata'; cases=$results.Count; failures=$failures.Count; results=$results; sdkStarted=$false; dockerInvoked=$false; servicesChanged=$false}
[IO.File]::WriteAllText((Join-Path $taskDirectory 'result.json'), ($receipt | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 6 -Compress
if ($failures.Count) { exit 1 }
