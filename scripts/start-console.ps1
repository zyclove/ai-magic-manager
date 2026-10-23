#Requires -Version 7.0
<# Restores the configured, verified local console without initializing databases. #>
[CmdletBinding()]
param([switch]$CheckOnly, [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$localRoot = Join-Path $repository '.local'
$configurationPath = Join-Path $localRoot 'console-launcher.json'
if (-not (Test-Path -LiteralPath $configurationPath)) {
    throw 'Local console configuration is missing: .local/console-launcher.json'
}
$configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
if ($configuration.schemaVersion -ne 1) { throw 'Unsupported console configuration.' }
function Test-ActivationReceipt($Target) {
    if (-not $Target.activationReceipt) { return $true }
    $receiptPath = [IO.Path]::GetFullPath($Target.activationReceipt, $repository)
    if (-not $receiptPath.StartsWith($localRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Activation receipt must remain inside this project .local directory.'
    }
    if (-not (Test-Path -LiteralPath $receiptPath)) { return $false }
    $activation = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    return $activation.schemaVersion -eq 1 -and $activation.state -ceq 'COMMITTED' -and
        $activation.project -ceq $Target.projectName -and $activation.publicUrl -ceq $configuration.publicUrl
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker Desktop is required.' }
$runningProjects = @(& docker ps --filter 'label=com.docker.compose.service=edge' --format '{{.Label "com.docker.compose.project"}}')
if ($LASTEXITCODE -ne 0) { throw 'Start Docker Desktop, then run this script again.' }
$active = @($configuration.deployments | Where-Object { $_.projectName -in $runningProjects })
if ($active.Count -gt 1) { throw 'Multiple configured consoles are running; inspect the deployment before restarting.' }
if ($active.Count -eq 1) {
    $selection = $active[0]
} else {
    $preferred = $configuration.defaultProjectName
    $switchReceipt = Join-Path $localRoot 'runtime/v1-current-switch.json'
    if (Test-Path -LiteralPath $switchReceipt) {
        $receipt = Get-Content -LiteralPath $switchReceipt -Raw | ConvertFrom-Json
        if ($receipt.project -in $configuration.deployments.projectName) { $preferred = $receipt.project }
    }
    $choices = @($configuration.deployments | Where-Object { $_.projectName -eq $preferred })
    if ($choices.Count -ne 1) { throw 'No unique verified console is configured.' }
    $selection = $choices[0]
}
if (-not (Test-ActivationReceipt $selection)) {
    throw 'The new console update is not confirmed yet. Wait for its deployment to complete.'
}
$source = [IO.Path]::GetFullPath($selection.sourceDirectory, $repository)
if (-not $source.StartsWith($localRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Configured deployment source must remain inside this project .local directory.'
}
$deployment = Join-Path $source '.local/deployment'
$settings = Get-Content -LiteralPath (Join-Path $deployment 'deployment.json') -Raw | ConvertFrom-Json
if ($settings.projectName -cne $selection.projectName -or $settings.publicUrl -cne $configuration.publicUrl) {
    throw 'Configured project or public URL does not match the deployment.'
}
$compose = @('compose', '--env-file', (Join-Path $deployment '.env'), '-f', (Join-Path $source 'deploy/compose/compose.yaml'))
$services = @(& docker @compose ps --format json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the selected console services.' }
$required = @('backend', 'database', 'edge', 'erasure-database', 'identity', 'identity-database')
$healthy = $services.Count -eq $required.Count
foreach ($name in $required) {
    $service = @($services | Where-Object { $_.Service -ceq $name })
    if ($service.Count -ne 1 -or $service[0].Project -cne $selection.projectName -or
        $service[0].State -ne 'running' -or $service[0].Health -ne 'healthy') { $healthy = $false }
}
if (-not $healthy) {
    if ($CheckOnly) { throw 'The selected console is not healthy; run without -CheckOnly to start it.' }
    # A switch initializes the candidate ledger before releasing the old port.
    # Do not reclaim that port while any unconfirmed candidate service exists.
    foreach ($candidate in $configuration.deployments) {
        if (-not (Test-ActivationReceipt $candidate)) {
            $candidateContainers = @(& docker ps -a --filter "label=com.docker.compose.project=$($candidate.projectName)" --format '{{.Names}}')
            if ($LASTEXITCODE -ne 0) { throw 'Unable to check whether another deployment is updating.' }
            if ($candidateContainers.Count -gt 0) {
                throw 'A console update is in progress or incomplete. Do not restart either deployment until it finishes.'
            }
        }
    }
    & (Join-Path $source 'scripts/start-deployment.ps1') -Directory '.local/deployment'
}
# Always use the release's own scripts and artifacts, never the changing working tree.
& (Join-Path $source 'scripts/verify-deployment.ps1') -Directory '.local/deployment'
Write-Output "Console ready: $($configuration.publicUrl)/"
Write-Output "Project: $($selection.projectName)"
if (-not $NoBrowser -and -not $CheckOnly) { Start-Process -FilePath "$($configuration.publicUrl)/" }
