#Requires -Version 7.0
<# Read-only smoke: no credentials, no business writes, no device enrollment. #>
[CmdletBinding()]
param([string]$Directory = '.local/deployment')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deployment-common.ps1')
$context = Get-DeploymentContext $Directory
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
$health = & docker compose --env-file $context.Environment -f $context.Compose exec -T backend wget -q -O - http://127.0.0.1:8080/actuator/health
if ($LASTEXITCODE -ne 0 -or (($health -join "`n") | ConvertFrom-Json).status -ne 'UP') { throw 'Backend database health is not UP.' }
[ordered]@{publicUrl=$origin; frontend='PASS'; callbackFallback='PASS'; discovery='PASS'; anonymousApi='PASS'; backendHealth='PASS';
    authenticatedJourney='NOT_RUN'; nativeDeviceExecution='NOT_RUN'} | ConvertTo-Json
