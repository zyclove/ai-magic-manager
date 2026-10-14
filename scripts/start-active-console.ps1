#Requires -Version 7.0
<# Start the committed local console using its verified frozen release. #>
[CmdletBinding()]
param([switch]$CheckOnly, [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'console-activation.ps1')
$selection = Get-ActiveConsoleSelection -RepositoryRoot $repository
if ($null -eq $selection) { throw 'No activated console is configured. Finish the local deployment before starting.' }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker Desktop is required.' }
$compose = @('compose', '-p', $selection.project, '--env-file', (Join-Path $selection.deploymentDirectory '.env'),
    '-f', (Join-Path $selection.sourceDirectory 'deploy/compose/compose.yaml'))
$rows = @(& docker @compose ps --format json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the activated console.' }
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
