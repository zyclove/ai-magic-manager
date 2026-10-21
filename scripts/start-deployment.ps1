#Requires -Version 7.0
<# Starts only the specified Compose project. Existing local runtime is untouched. #>
[CmdletBinding()]
param([string]$Directory = '.local/deployment', [switch]$Tls, [switch]$ExternalTlsProxy,
    [string]$IdentityAdminDirectory='', [string]$IdentityRuntimeDirectory='')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deployment-common.ps1')
. (Join-Path $PSScriptRoot 'family-identity-release-common.ps1')
$context = Get-DeploymentContext $Directory
$identityHostLock = Enter-IdentityReleaseHostLock $context.Root
try {
$identityReleaseOverlay = Get-IdentityReleaseActiveOverlay $context.Root
if ($identityReleaseOverlay) {
    $identityTarget = Get-IdentityReleaseTarget (Join-Path $context.Root 'identity-release-target.json')
    if (($IdentityAdminDirectory -and [IO.Path]::GetFullPath($IdentityAdminDirectory) -cne $identityTarget.adminDirectory) -or
        ($IdentityRuntimeDirectory -and [IO.Path]::GetFullPath($IdentityRuntimeDirectory) -cne $identityTarget.runtimeDirectory)) { throw 'Identity configuration directories differ from the active release.' }
    $IdentityAdminDirectory=$identityTarget.adminDirectory; $IdentityRuntimeDirectory=$identityTarget.runtimeDirectory
}
if (-not (Test-Path -LiteralPath (Join-Path $context.Root 'release-manifest.json'))) { throw 'Verified build contexts are missing; run build-deployment.ps1 first.' }
$manifest = Get-Content -LiteralPath (Join-Path $context.Root 'release-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $manifest.publicUrl -ne $context.Settings.publicUrl -or $manifest.artifactRoot -notmatch '^artifacts/release-[0-9a-f]{32}$') { throw 'Invalid release manifest.' }
$artifactRoot = Join-Path $context.Root $manifest.artifactRoot
$consumerIdentity = $context.Settings.consumerIdentity -eq $true
if (($manifest.consumerIdentity -eq $true) -ne $consumerIdentity) { throw 'Consumer identity mode differs from the verified release.' }
if ($consumerIdentity) {
    $provider = Join-Path $artifactRoot 'keycloak/keycloak/providers/consumer-identity-1.0.0.jar'
    if (-not (Test-Path -LiteralPath $provider -PathType Leaf) -or $manifest.identityProviderSha256 -notmatch '^[0-9a-f]{64}$' -or
        (Get-FileHash -LiteralPath $provider -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.identityProviderSha256) {
        throw 'Identity provider changed since verification.'
    }
}
foreach ($file in @('backend/manager-backend.jar', 'guardian/index.html', 'guardian/main.dart.js')) {
    if (-not (Test-Path -LiteralPath (Join-Path $artifactRoot $file))) { throw 'Verified build contexts are missing; run build-deployment.ps1 first.' }
}
if ((Get-FileHash -LiteralPath (Join-Path $artifactRoot 'backend/manager-backend.jar')).Hash.ToLowerInvariant() -ne $manifest.backendSha256 -or
    (Get-FileHash -LiteralPath (Join-Path $artifactRoot 'guardian/main.dart.js')).Hash.ToLowerInvariant() -ne $manifest.guardianSha256) { throw 'Build artifact changed since verification.' }
$https = [Uri]::new($context.Settings.publicUrl).Scheme -eq 'https'
$external = $context.Settings.externalTlsProxy -eq $true
if ($external -ne $ExternalTlsProxy.IsPresent) { throw 'External TLS proxy mode must match the initialized deployment.' }
if ($external) {
    if (-not $https -or ([Uri]::new($context.Settings.publicUrl)).Port -ne 443 -or $Tls) {
        throw 'External TLS proxy requires a standard HTTPS origin and cannot use the local TLS override.'
    }
} elseif ($https -ne $Tls.IsPresent) {
    throw 'HTTPS requires -Tls; loopback HTTP must not use the TLS override.'
}
$arguments = @('compose', '--env-file', $context.Environment, '-f', $context.Compose)
$identityConfigurationArguments = Get-IdentityReleaseConfigurationArguments $IdentityAdminDirectory $IdentityRuntimeDirectory
if ($identityConfigurationArguments.Count -gt 0) { $arguments += $identityConfigurationArguments }
if ($consumerIdentity) { $arguments += @('-f', (Join-Path $context.Repository 'deploy/compose/compose.family.yaml')) }
if ($identityReleaseOverlay) { $arguments += @('-f', (Join-Path $context.Repository 'deploy/compose/compose.identity-runtime-image.yaml'), '-f', $identityReleaseOverlay) }
if ($Tls) {
    foreach ($name in @('tls.crt', 'tls.key')) {
        if (-not (Test-Path -LiteralPath (Join-Path $context.Root "secrets/$name"))) { throw 'Provide the TLS certificate and private key before starting HTTPS.' }
    }
    $arguments += @('-f', (Join-Path $context.Repository 'deploy/compose/compose.tls.yaml'))
}
if ($external) {
    $arguments += @('-f', (Join-Path $context.Repository 'deploy/compose/compose.external-tls.yaml'))
}
$logs = Join-Path $context.Root 'logs'
$configurationJson = & docker @arguments config --format json
if ($LASTEXITCODE -ne 0) { throw 'Compose configuration validation failed.' }
$configuration = ($configurationJson -join "`n") | ConvertFrom-Json
if ($external) {
    $published = @($configuration.services.edge.ports)
    if ($published.Count -ne 1 -or $published[0].host_ip -ne '127.0.0.1' -or
        [int]$published[0].published -ne [int]$context.Settings.edgePort -or
        [int]$published[0].target -ne 8080) {
        throw 'External TLS proxy edge must publish only the configured loopback HTTP port.'
    }
}
foreach ($service in @('backend', 'edge')) {
    $expected = [IO.Path]::GetFullPath((Join-Path $artifactRoot $(if ($service -eq 'backend') { 'backend' } else { 'guardian' }))).Replace('\','/')
    if ($configuration.services.$service.build.context.Replace('\','/') -ne $expected) { throw 'Compose build context does not match the verified release.' }
}
if ($consumerIdentity) {
    if ($identityReleaseOverlay) {
        if ($configuration.services.identity.PSObject.Properties.Name -contains 'build' -or
            $configuration.services.identity.image -cne $identityTarget.identityImageId -or
            $configuration.services.identity.pull_policy -cne 'never') { throw 'Active identity release must use its pinned image without rebuilding.' }
    } else {
        $expectedIdentity = [IO.Path]::GetFullPath((Join-Path $artifactRoot 'keycloak')).Replace('\','/')
        if ($configuration.services.identity.build.context.Replace('\','/') -ne $expectedIdentity) { throw 'Identity build context does not match the verified release.' }
    }
}
if ($configuration.services.backend.environment.OIDC_ISSUER_URI -ne "$($context.Settings.publicUrl)/identity/realms/ai-manager") { throw 'Compose issuer differs from the verified client origin.' }
$receiptPath = Join-Path $context.Root 'erasure-ledger-initialized.json'
if (-not (Test-Path -LiteralPath $receiptPath)) { throw 'Explicit ledger initialization is required; run initialize-erasure-ledger.ps1 once for a new ledger.' }
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
if ($receipt.schemaVersion -ne 1 -or $receipt.ledgerId -cne $configuration.services.backend.environment.ERASURE_LEDGER_ID -or $configuration.services.backend.environment.ERASURE_RECOVERY_REQUIRED -ne 'true') { throw 'Ledger identity or mandatory recovery protection differs from the initialized deployment.' }
$buildArguments = @('--build')
Invoke-DeploymentNative 'docker' ($arguments + @('up', '-d') + $buildArguments + @('--wait', '--wait-timeout', '300')) (Join-Path $logs 'compose-start.log')
Write-Output "Deployment is healthy: $($context.Settings.publicUrl)"
Write-Output 'Identity setup: /identity/admin/ (bootstrap-admin; password is the restricted bootstrap_admin file).'
} finally { $identityHostLock.Dispose() }
