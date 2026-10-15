#Requires -Version 7.0
<# Start the committed local console using its verified frozen release. #>
[CmdletBinding()]
param([switch]$CheckOnly, [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$runtimeDirectory = Join-Path $repository '.local/runtime'
$runtimeLeasePath = Join-Path $runtimeDirectory 'console-runtime.lock'
$runtimeLease = $null
try {
    foreach ($runtimePath in @((Join-Path $repository '.local'), $runtimeDirectory, $runtimeLeasePath)) {
        if ((Test-Path -LiteralPath $runtimePath) -and
            ((Get-Item -LiteralPath $runtimePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The console runtime path cannot contain a link.'
        }
    }
    if (-not (Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
        throw 'No activated console runtime is configured.'
    }
    try {
        $runtimeLease = [IO.File]::Open($runtimeLeasePath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw 'Another console startup, backup or update is in progress. Wait for it to finish.'
    }
. (Join-Path $PSScriptRoot 'console-activation.ps1')
$selection = Get-ActiveConsoleSelection -RepositoryRoot $repository
if ($null -eq $selection) { throw 'No activated console is configured. Finish the local deployment before starting.' }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker Desktop is required.' }
$compose = @('compose', '-p', $selection.project, '--env-file', (Join-Path $selection.deploymentDirectory '.env'),
    '-f', (Join-Path $selection.sourceDirectory 'deploy/compose/compose.yaml'))
$inspection = @(& docker @compose ps --format json 2>$null)
$inspectionExit = $LASTEXITCODE
if ($inspectionExit -ne 0) {
    if ($CheckOnly) { throw 'The Docker engine is unavailable. Start the console before checking it.' }
    $dockerHost = [Environment]::GetEnvironmentVariable('DOCKER_HOST', 'Process')
    if (-not [string]::IsNullOrEmpty($dockerHost)) {
        throw 'An explicit Docker host is configured. Restore that connection before starting the console.'
    }
    $dockerContext = @(& docker context show 2>$null)
    if ($LASTEXITCODE -ne 0 -or $dockerContext.Count -ne 1 -or $dockerContext[0].Trim() -cne 'desktop-linux') {
        throw 'The selected Docker context is unavailable. Restore that connection before starting the console.'
    }
    Write-Output 'Starting Docker Desktop. Waiting up to 120 seconds for the local engine.'
    & docker desktop start --timeout 120 *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop could not start. Open Docker Desktop and resolve its startup error.' }
    $inspection = @(& docker @compose ps --format json 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'The local Docker engine is still unavailable after startup.' }
}
$rows = @($inspection | ConvertFrom-Json)
$required = @('backend', 'database', 'edge', 'erasure-database', 'identity', 'identity-database')
$healthy = $rows.Count -eq 6
foreach ($name in $required) {
    $matches = @($rows | Where-Object { $_.Service -ceq $name })
    if ($matches.Count -ne 1 -or $matches[0].Project -cne $selection.project -or
        $matches[0].State -cne 'running' -or $matches[0].Health -cne 'healthy') { $healthy = $false }
}
$originalProject = [Environment]::GetEnvironmentVariable('COMPOSE_PROJECT_NAME', 'Process')
$originalProjectExists = Test-Path -LiteralPath 'Env:COMPOSE_PROJECT_NAME'
$originalEdgePort = [Environment]::GetEnvironmentVariable('EDGE_PORT', 'Process')
$originalEdgePortExists = Test-Path -LiteralPath 'Env:EDGE_PORT'
try {
    [Environment]::SetEnvironmentVariable('COMPOSE_PROJECT_NAME', $selection.project, 'Process')
    # A temporary staging listener must never override the selected deployment's .env.
    Remove-Item -LiteralPath 'Env:EDGE_PORT' -ErrorAction SilentlyContinue
    if (-not $healthy) {
        if ($CheckOnly) { throw 'The activated console is not healthy. Start it before using the console.' }
        $edgeIds = @(& docker ps --filter 'label=com.docker.compose.service=edge' --format '{{.ID}}')
        if ($LASTEXITCODE -ne 0) { throw 'Unable to check other console services.' }
        if ($edgeIds.Count -gt 0) {
            $edges = @(& docker inspect @edgeIds | ConvertFrom-Json)
            if ($LASTEXITCODE -ne 0 -or $edges.Count -ne $edgeIds.Count) { throw 'Unable to inspect other console listeners.' }
            $selectedPort = ([Uri]$selection.publicUrl).Port.ToString([Globalization.CultureInfo]::InvariantCulture)
            foreach ($edge in $edges) {
                $edgeProject = $edge.Config.Labels.'com.docker.compose.project'
                if ($edge.Config.Labels.'com.docker.compose.service' -cne 'edge' -or [string]::IsNullOrWhiteSpace($edgeProject)) {
                    throw 'Unexpected console listener metadata.'
                }
                if ($edgeProject -ceq $selection.project) { continue }
                foreach ($port in $edge.NetworkSettings.Ports.PSObject.Properties) {
                    foreach ($binding in @($port.Value)) {
                        if ($null -ne $binding -and $binding.HostPort -ceq $selectedPort) {
                            throw 'Another console uses the selected public port. Resolve that listener before starting.'
                        }
                    }
                }
            }
        }
        $consoleLogDirectory = Join-Path $selection.deploymentDirectory 'logs'
        $consoleLogAttributes = $null
        try {
            $consoleLogAttributes = [IO.File]::GetAttributes($consoleLogDirectory)
        } catch [IO.FileNotFoundException] {
        } catch [IO.DirectoryNotFoundException] {
        }
        if ($null -eq $consoleLogAttributes) {
            New-Item -ItemType Directory -Path $consoleLogDirectory -ErrorAction Stop | Out-Null
            $consoleLogAttributes = [IO.File]::GetAttributes($consoleLogDirectory)
        }
        if (($consoleLogAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($consoleLogAttributes -band [IO.FileAttributes]::Directory) -eq 0) {
            throw 'The activated console log path must be a directory without links.'
        }
        $global:LASTEXITCODE = 0
        & (Join-Path $selection.sourceDirectory 'scripts/start-deployment.ps1') -Directory '.local/deployment'
        if ($LASTEXITCODE -ne 0) { throw 'The activated console could not be started.' }
    }
    $global:LASTEXITCODE = 0
    & (Join-Path $selection.sourceDirectory 'scripts/verify-deployment.ps1') -Directory '.local/deployment'
    if ($LASTEXITCODE -ne 0) { throw 'The activated console did not pass verification.' }
} finally {
    if ($originalProjectExists) {
        [Environment]::SetEnvironmentVariable('COMPOSE_PROJECT_NAME', $originalProject, 'Process')
    } elseif (Test-Path -LiteralPath 'Env:COMPOSE_PROJECT_NAME') {
        Remove-Item -LiteralPath 'Env:COMPOSE_PROJECT_NAME'
    }
    if ($originalEdgePortExists) {
        [Environment]::SetEnvironmentVariable('EDGE_PORT', $originalEdgePort, 'Process')
    } elseif (Test-Path -LiteralPath 'Env:EDGE_PORT') {
        Remove-Item -LiteralPath 'Env:EDGE_PORT'
    }
}
Write-Output "Console ready: $($selection.publicUrl)/"
if (-not $NoBrowser -and -not $CheckOnly) {
    Start-Process -FilePath "$($selection.publicUrl)/"
}
} finally {
    if ($null -ne $runtimeLease) { $runtimeLease.Dispose() }
}
