#Requires -Version 7.0
<# Starts only the specified Compose project. Existing local runtime is untouched. #>
[CmdletBinding()]
param([string]$Directory = '.local/deployment', [switch]$Tls)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deployment-common.ps1')
$context = Get-DeploymentContext $Directory
if (-not (Test-Path -LiteralPath (Join-Path $context.Root 'release-manifest.json'))) { throw 'Verified build contexts are missing; run build-deployment.ps1 first.' }
$manifest = Get-Content -LiteralPath (Join-Path $context.Root 'release-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $manifest.publicUrl -ne $context.Settings.publicUrl -or $manifest.artifactRoot -notmatch '^artifacts/release-[0-9a-f]{32}$') { throw 'Invalid release manifest.' }
$artifactRoot = Join-Path $context.Root $manifest.artifactRoot
foreach ($file in @('backend/manager-backend.jar', 'guardian/index.html', 'guardian/main.dart.js')) {
    if (-not (Test-Path -LiteralPath (Join-Path $artifactRoot $file))) { throw 'Verified build contexts are missing; run build-deployment.ps1 first.' }
}
if ((Get-FileHash -LiteralPath (Join-Path $artifactRoot 'backend/manager-backend.jar')).Hash.ToLowerInvariant() -ne $manifest.backendSha256 -or
    (Get-FileHash -LiteralPath (Join-Path $artifactRoot 'guardian/main.dart.js')).Hash.ToLowerInvariant() -ne $manifest.guardianSha256) { throw 'Build artifact changed since verification.' }
$https = [Uri]::new($context.Settings.publicUrl).Scheme -eq 'https'
if ($https -ne $Tls.IsPresent) { throw 'HTTPS requires -Tls; loopback HTTP must not use the TLS override.' }
$arguments = @('compose', '--env-file', $context.Environment, '-f', $context.Compose)
if ($Tls) {
    foreach ($name in @('tls.crt', 'tls.key')) {
        if (-not (Test-Path -LiteralPath (Join-Path $context.Root "secrets/$name"))) { throw 'Provide the TLS certificate and private key before starting HTTPS.' }
    }
    $arguments += @('-f', (Join-Path $context.Repository 'deploy/compose/compose.tls.yaml'))
}
$logs = Join-Path $context.Root 'logs'
$configurationJson = & docker @arguments config --format json
if ($LASTEXITCODE -ne 0) { throw 'Compose configuration validation failed.' }
$configuration = ($configurationJson -join "`n") | ConvertFrom-Json
foreach ($service in @('backend', 'edge')) {
    $expected = [IO.Path]::GetFullPath((Join-Path $artifactRoot $(if ($service -eq 'backend') { 'backend' } else { 'guardian' }))).Replace('\','/')
    if ($configuration.services.$service.build.context.Replace('\','/') -ne $expected) { throw 'Compose build context does not match the verified release.' }
}
if ($configuration.services.backend.environment.OIDC_ISSUER_URI -ne "$($context.Settings.publicUrl)/identity/realms/ai-manager") { throw 'Compose issuer differs from the verified client origin.' }
Invoke-DeploymentNative 'docker' ($arguments + @('up', '-d', '--build', '--wait', '--wait-timeout', '300')) (Join-Path $logs 'compose-start.log')
Write-Output "Deployment is healthy: $($context.Settings.publicUrl)"
Write-Output 'Identity setup: /identity/admin/ (bootstrap-admin; password is the restricted bootstrap_admin file).'
