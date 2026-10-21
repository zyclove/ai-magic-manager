#Requires -Version 7.0
<# Starts only the specified Compose project. Existing local runtime is untouched. #>
[CmdletBinding()]
param([string]$Directory = '.local/deployment', [switch]$Tls, [switch]$ExternalTlsProxy,
    [string]$IdentityAdminDirectory='', [string]$IdentityRuntimeDirectory='')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deployment-common.ps1')
. (Join-Path $PSScriptRoot 'family-identity-release-common.ps1')
. (Join-Path $PSScriptRoot 'deployment-provenance.ps1')
. (Join-Path $PSScriptRoot 'deployment-runtime-provenance.ps1')
$context = Get-DeploymentContext $Directory
$identityHostLock = Enter-IdentityReleaseHostLock $context.Root
$previousReleaseEnvironment = @{}
try {
$identityReleaseOverlay = Get-IdentityReleaseActiveOverlay $context.Root
if ($identityReleaseOverlay) {
    $identityTarget = Get-IdentityReleaseTarget (Join-Path $context.Root 'identity-release-target.json')
    if (($IdentityAdminDirectory -and [IO.Path]::GetFullPath($IdentityAdminDirectory) -cne $identityTarget.adminDirectory) -or
        ($IdentityRuntimeDirectory -and [IO.Path]::GetFullPath($IdentityRuntimeDirectory) -cne $identityTarget.runtimeDirectory)) { throw 'Identity configuration directories differ from the active release.' }
    $IdentityAdminDirectory=$identityTarget.adminDirectory; $IdentityRuntimeDirectory=$identityTarget.runtimeDirectory
}
$provenance = Read-DeploymentProvenance -Context $context
$manifest = $provenance.Manifest
$artifactRoot = $provenance.ArtifactRoot
$consumerIdentity = $context.Settings.consumerIdentity -eq $true
$releaseEnvironment = @{
    RELEASE_REVISION=$manifest.source.revision
    RELEASE_VERSION=$manifest.applicationVersion
    RELEASE_MANIFEST_SHA256=$provenance.ManifestSha256
    RELEASE_SOURCE_TREE_SHA256=$manifest.sourceTreeSha256
    RELEASE_ARTIFACT_TREE_SHA256=$manifest.artifactTreeSha256
}
foreach ($name in $releaseEnvironment.Keys) {
    $previousReleaseEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $releaseEnvironment[$name], 'Process')
}
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
if ($configuration.name -cne $context.Settings.projectName) { throw 'Compose project differs from the initialized deployment.' }
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
    $recipe = [IO.Path]::GetFullPath((Join-Path $context.Repository "deploy/containers/$service.Dockerfile")).Replace('\','/')
    if ($configuration.services.$service.build.dockerfile.Replace('\','/') -cne $recipe) { throw 'Compose Dockerfile does not match the verified release.' }
    foreach ($name in $releaseEnvironment.Keys) {
        if ($configuration.services.$service.build.args.$name -cne $releaseEnvironment[$name]) { throw 'Compose image provenance differs from the verified release.' }
    }
}
$edgeRecipes = @{
    '/etc/nginx/nginx.conf'='nginx.conf'
    '/etc/nginx/conf.d/default.conf'=$(if ($Tls) { 'tls.conf' } else { 'http.conf' })
    '/etc/nginx/includes/routes.conf'=$(if ($external) { 'routes.external-tls.conf' } else { 'routes.conf' })
}
foreach ($target in $edgeRecipes.Keys) {
    $mounts = @($configuration.services.edge.volumes | Where-Object { $_.target -ceq $target })
    $expectedSource = [IO.Path]::GetFullPath((Join-Path $context.Repository ("deploy/edge/" + $edgeRecipes[$target]))).Replace('\','/')
    if ($mounts.Count -ne 1 -or $mounts[0].type -cne 'bind' -or $mounts[0].read_only -ne $true -or $mounts[0].source.Replace('\','/') -cne $expectedSource) {
        throw 'Compose edge configuration does not match the verified release.'
    }
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
# Bind the receipt to the images actually running after Compose has finished,
# never mutable tags or labels supplied only on a container.
$bindings = @(Get-DeploymentImageBindings -ComposeArguments $arguments -Project $configuration.name -Labels $provenance.Labels -Context $context)
$verifiedAgain = Read-DeploymentProvenance -Context $context
if ($verifiedAgain.ManifestSha256 -cne $provenance.ManifestSha256) { throw 'Release manifest changed during startup.' }
Write-DeploymentRuntimeReceipt -Context $context -Provenance $provenance -Bindings $bindings -Project $configuration.name
Write-Output "Deployment is healthy: $($context.Settings.publicUrl)"
Write-Output 'Identity setup: /identity/admin/ (bootstrap-admin; password is the restricted bootstrap_admin file).'
} finally {
    foreach ($name in $previousReleaseEnvironment.Keys) {
        if ($null -eq $previousReleaseEnvironment[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $previousReleaseEnvironment[$name], 'Process') }
    }
    $identityHostLock.Dispose()
}
