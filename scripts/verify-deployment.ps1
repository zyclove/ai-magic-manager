#Requires -Version 7.0
<# Read-only smoke: no credentials, no business writes, no device enrollment. #>
[CmdletBinding()]
param([string]$Directory = '.local/deployment')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deployment-common.ps1')
. (Join-Path $PSScriptRoot 'deployment-provenance.ps1')
. (Join-Path $PSScriptRoot 'deployment-runtime-provenance.ps1')
$context = Get-DeploymentContext $Directory
$provenance = Read-DeploymentProvenance -Context $context
$arguments = @('compose', '--env-file', $context.Environment, '-f', $context.Compose)
$bindings = @(Get-DeploymentImageBindings -ComposeArguments $arguments -Project $context.Settings.projectName -Labels $provenance.Labels -Context $context)
Assert-DeploymentRuntimeReceipt -Context $context -Provenance $provenance -Bindings $bindings -Project $context.Settings.projectName
$origin = $context.Settings.publicUrl
function Fetch([string]$Path) {
    return Invoke-WebRequest -Uri "$origin$Path" -TimeoutSec 20 -SkipHttpErrorCheck
}
$root = Fetch '/'
if ($root.StatusCode -ne 200 -or $root.Content -notmatch '<title>智能管家') { throw 'Management frontend entry check failed.' }
if ($root.Headers['X-Content-Type-Options'] -notcontains 'nosniff') { throw 'Frontend response security header is missing.' }
$callback = Fetch '/auth/callback?code=smoke-placeholder&state=smoke-placeholder'
if ($callback.StatusCode -ne 200 -or $callback.Content -ne $root.Content) { throw 'OAuth callback SPA fallback is not configured.' }
$document = Fetch '/identity/realms/ai-manager/.well-known/openid-configuration'
if ($document.StatusCode -ne 200) { throw 'OIDC discovery is not available.' }
$discovery = $document.Content | ConvertFrom-Json
$issuer = "$origin/identity/realms/ai-manager"
if ($discovery.issuer -ne $issuer -or $discovery.token_endpoint -ne "$issuer/protocol/openid-connect/token") { throw 'OIDC issuer or endpoints differ from the browser origin.' }
$anonymous = Fetch '/api/v1/me'
if ($anonymous.StatusCode -ne 401) { throw 'Anonymous management API must return HTTP 401.' }
$problemText = if ($anonymous.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($anonymous.Content) } else { $anonymous.Content }
$problem = $problemText | ConvertFrom-Json
if ($problem.errorCode -ne 'UNAUTHENTICATED' -or -not $problem.correlationId) { throw 'Anonymous error contract differs from the client contract.' }
$health = & docker @arguments exec -T backend wget -q -O - http://127.0.0.1:8080/actuator/health
if ($LASTEXITCODE -ne 0 -or (($health -join "`n") | ConvertFrom-Json).status -ne 'UP') { throw 'Backend database health is not UP.' }
# HTTP checks take time. A deployment replacement during those requests must
# invalidate this observation instead of reporting the earlier image as current.
$finalProvenance = Read-DeploymentProvenance -Context $context
if ($finalProvenance.ManifestSha256 -cne $provenance.ManifestSha256) { throw 'Release changed during verification; verify the current release again.' }
$finalBindings = @(Get-DeploymentImageBindings -ComposeArguments $arguments -Project $context.Settings.projectName -Labels $finalProvenance.Labels -Context $context)
Assert-DeploymentRuntimeReceipt -Context $context -Provenance $finalProvenance -Bindings $finalBindings -Project $context.Settings.projectName
$initialImages = Get-DeploymentRuntimeBindingMap -Bindings $bindings
$finalImages = Get-DeploymentRuntimeBindingMap -Bindings $finalBindings
foreach ($service in @('backend', 'edge')) {
    if ($initialImages[$service].imageId -cne $finalImages[$service].imageId) { throw 'Running image changed during verification; verify the current release again.' }
}
[ordered]@{publicUrl=$origin; releaseProvenance='PASS'; releaseManifestSha256=$provenance.ManifestSha256;
    sourceRevision=$provenance.Manifest.source.revision; images=$finalBindings;
    frontend='PASS'; callbackFallback='PASS'; discovery='PASS'; anonymousApi='PASS'; backendHealth='PASS';
    authenticatedJourney='NOT_RUN'; nativeDeviceExecution='NOT_RUN'} | ConvertTo-Json -Depth 8
