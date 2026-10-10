#Requires -Version 7.0
<#
.SYNOPSIS
Creates an independent, ignored deployment workspace without starting services.
.DESCRIPTION
Generates distinct database/bootstrap secrets and an ES256 JWK using .NET's
cryptographic APIs. Existing directories are never overwritten. HTTP is limited
to loopback; production uses HTTPS termination and the TLS Compose override.
#>
[CmdletBinding()]
param(
    [string]$Directory = '.local/deployment',
    [string]$PublicUrl = 'http://localhost:18090',
    [ValidateRange(1, 65535)][int]$EdgePort = 18090,
    [ValidatePattern('^[a-z][a-z0-9-]{2,40}$')][string]$ProjectName = 'ai-manager-repro'
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$localRoot = [IO.Path]::GetFullPath((Join-Path $repository '.local'))
$destination = [IO.Path]::GetFullPath($Directory, $repository)
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if (-not $destination.StartsWith($localRoot + [IO.Path]::DirectorySeparatorChar, $comparison)) {
    throw 'Deployment directory must be inside this repository .local directory.'
}
$uri = $null
if (-not [Uri]::TryCreate($PublicUrl, [UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
    $uri.AbsolutePath -ne '/' -or $uri.Host -notmatch '^[A-Za-z0-9.:-]+$') {
    throw 'PublicUrl must be an HTTP(S) origin without user information, path, query or fragment.'
}
if ($uri.Scheme -eq 'http' -and ($uri.Host -notin @('localhost', '127.0.0.1', '[::1]') -or $uri.Port -ne $EdgePort)) {
    throw 'HTTP is limited to a loopback origin whose port matches EdgePort.'
}
if ($uri.Port -ne $EdgePort) { throw 'PublicUrl port must match EdgePort (including HTTPS).' }
if (Test-Path -LiteralPath $destination) { throw 'Deployment directory already exists; preserve it and use a new directory.' }
$origin = $uri.GetLeftPart([UriPartial]::Authority)
$utf8 = [Text.UTF8Encoding]::new($false)
function WriteNewFile([string]$Path, [string]$Content) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes = $utf8.GetBytes($Content); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
}
function RandomSecret { return [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant() }
function Base64Url([byte[]]$Bytes) { return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function EnvValue([string]$Value) {
    if ($Value.Contains("`n") -or $Value.Contains("`r") -or $Value.Contains("'")) { throw 'Configuration path contains an unsupported character.' }
    return "'$($Value.Replace('\', '/'))'"
}

# Secure the empty directory before writing any secret. Compose file-backed
# secrets retain host permissions; Linux containers use the initializing UID.
$null = New-Item -ItemType Directory -Path $destination
if ($IsWindows) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $destination /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to restrict deployment directory permissions.' }
    $appUid = '10001'; $appGid = '10001'
} else {
    & chmod 700 -- $destination
    if ($LASTEXITCODE -ne 0) { throw 'Failed to restrict deployment directory permissions.' }
    $appUid = (& id -u).Trim(); $appGid = (& id -g).Trim()
    if ($appUid -eq '0') { throw 'Initialize as a non-root deployment user so file-backed secrets are readable without root containers.' }
}
$secrets = Join-Path $destination 'secrets'
$null = New-Item -ItemType Directory -Path $secrets
foreach ($name in @('mysql_root', 'mysql_app', 'identity_root', 'identity_app', 'bootstrap_admin')) {
    WriteNewFile (Join-Path $secrets $name) (RandomSecret)
}
$key = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
try {
    $parameters = $key.ExportParameters($true)
    $public = [ordered]@{ kty='EC'; crv='P-256'; alg='ES256'; use='sig'; kid=('deploy-' + [Guid]::NewGuid().ToString('N')); key_ops=@('verify'); x=(Base64Url $parameters.Q.X); y=(Base64Url $parameters.Q.Y) }
    $private = [ordered]@{}; foreach ($item in $public.GetEnumerator()) { $private[$item.Key] = $item.Value }
    $private['key_ops'] = @('sign'); $private['d'] = Base64Url $parameters.D
    WriteNewFile (Join-Path $secrets 'signing.jwk') ($private | ConvertTo-Json -Depth 8)
    WriteNewFile (Join-Path $destination 'verification.jwks') (@{keys=@($public)} | ConvertTo-Json -Depth 8)
} finally { $key.Dispose() }

$realm = Get-Content -LiteralPath (Join-Path $repository 'deploy/keycloak/realm-template.json') -Raw | ConvertFrom-Json
$client = $realm.clients | Where-Object clientId -eq 'ai-manager-guardian'
$client.redirectUris = @("$origin/auth/callback")
$client.webOrigins = @($origin)
$client.attributes.'post.logout.redirect.uris' = "$origin/"
if ($uri.Scheme -eq 'http') { $realm.sslRequired = 'none' } # Only the already-validated loopback deployment.
WriteNewFile (Join-Path $destination 'realm.json') ($realm | ConvertTo-Json -Depth 40)
$artifactRoot = Join-Path $destination 'artifacts'
$null = New-Item -ItemType Directory -Path (Join-Path $artifactRoot 'backend'), (Join-Path $artifactRoot 'guardian')
$environment = [ordered]@{
    COMPOSE_PROJECT_NAME=$ProjectName; REPOSITORY_ROOT=$repository; DEPLOYMENT_ROOT=$destination
    BACKEND_BUILD_CONTEXT=(Join-Path $artifactRoot 'backend'); GUARDIAN_BUILD_CONTEXT=(Join-Path $artifactRoot 'guardian')
    PUBLIC_URL=$origin; EDGE_PORT="$EdgePort"; EDGE_BIND_ADDRESS='127.0.0.1'; APP_UID=$appUid; APP_GID=$appGid
    MYSQL_IMAGE='mysql:8.4.11@sha256:6ea90827b1100f8f2ae306a539f86d2c264a26ed435a2a9f75551dd5c3aeb242'
    KEYCLOAK_BASE_IMAGE='quay.io/keycloak/keycloak:26.8.0@sha256:b0f60d489d51c5d113390bdf5461d4c06e6051be026c05549f2e1e10ec352bcc'
    JAVA_RUNTIME_IMAGE='eclipse-temurin:17-jre-alpine@sha256:3c472129dc75a8d1d7a3f2df5b2093a8077e4493deff046754d4764d0371de63'
    EDGE_BASE_IMAGE='nginx:1.28-alpine@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236'
    BACKEND_IMAGE="ai-manager/backend:$ProjectName"; IDENTITY_IMAGE="ai-manager/identity:$ProjectName"; EDGE_IMAGE="ai-manager/edge:$ProjectName"
}
WriteNewFile (Join-Path $destination '.env') (($environment.GetEnumerator() | ForEach-Object { "$($_.Key)=$(EnvValue $_.Value)" }) -join "`n")
WriteNewFile (Join-Path $destination 'deployment.json') (@{publicUrl=$origin; edgePort=$EdgePort; projectName=$ProjectName; schemaVersion=1; applicationVersion='1.0.0'} | ConvertTo-Json)
if (-not $IsWindows) {
    & chmod -R go-rwx -- $destination
    if ($LASTEXITCODE -ne 0) { throw 'Failed to restrict deployment file permissions.' }
}
Write-Output "Deployment workspace created: $destination"
Write-Output 'Credentials were written to restricted secret files; no services were started.'
