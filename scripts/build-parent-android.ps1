#Requires -Version 7.0
<#
.SYNOPSIS
Builds and verifies a signed institution pilot APK for the parent app.
.DESCRIPTION
Run from a clean commit with real HTTPS endpoints. Signing secrets are read only
from environment variables supplied by a secret manager; none enter command
arguments, source files, or the release manifest.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Issuer,
    [Parameter(Mandatory)][string]$ApiUrl,
    [Parameter(Mandatory)][string]$ConsoleUrl,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$')][string]$BuildName,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$BuildNumber,
    [string]$FlutterCommand = 'flutter',
    [string]$ApkSignerPath = ''
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$app = Join-Path $root 'apps/parent'

function Assert-HttpsEndpoint([string]$Value, [string]$Name) {
    $parsed = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$parsed) -or
        $parsed.Scheme -ne 'https' -or
        -not $parsed.Host -or
        $parsed.UserInfo -or
        $parsed.Query -or
        $parsed.Fragment -or
        $parsed.Port -ne 443) {
        throw "$Name must be a standard HTTPS URL without credentials, query, or fragment."
    }
    return $parsed
}

$issuerUri = Assert-HttpsEndpoint $Issuer 'Issuer'
$apiUri = Assert-HttpsEndpoint $ApiUrl 'ApiUrl'
$consoleUri = Assert-HttpsEndpoint $ConsoleUrl 'ConsoleUrl'
if ($issuerUri.AbsolutePath -notmatch '/realms/[^/]+/?$') {
    throw 'Issuer must identify an OIDC realm.'
}
if ($apiUri.AbsolutePath.TrimEnd('/') -notlike '*/api/v1') {
    throw 'ApiUrl must end in /api/v1.'
}
if ($consoleUri.AbsolutePath -notmatch '/$') {
    throw 'ConsoleUrl must end with /.'
}

$secretNames = @('PARENT_ANDROID_KEYSTORE', 'PARENT_ANDROID_STORE_PASSWORD',
    'PARENT_ANDROID_KEY_ALIAS', 'PARENT_ANDROID_KEY_PASSWORD')
foreach ($name in $secretNames) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Missing signing secret: $name"
    }
}
$keystore = [Environment]::GetEnvironmentVariable('PARENT_ANDROID_KEYSTORE')
if (-not [IO.Path]::IsPathFullyQualified($keystore) -or
    -not (Test-Path -LiteralPath $keystore -PathType Leaf)) {
    throw 'PARENT_ANDROID_KEYSTORE must point to an existing absolute file.'
}
$keystoreFullPath = [IO.Path]::GetFullPath($keystore)
if ($keystoreFullPath.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The signing keystore must be stored outside the source tree.'
}

$flutter = Get-Command $FlutterCommand -ErrorAction SilentlyContinue
if (-not $flutter) { throw 'Flutter executable was not found.' }
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { throw 'Git executable was not found.' }
$changes = @(& $git.Source -C $root status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect source revision.' }
if ($changes.Count -ne 0) { throw 'Release builds require a clean committed source tree.' }
$revision = (& $git.Source -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[0-9a-f]{40}$') {
    throw 'Could not resolve the source revision.'
}

function Resolve-ApkSigner([string]$ExplicitPath) {
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw 'ApkSignerPath does not exist.'
        }
        return [IO.Path]::GetFullPath($ExplicitPath)
    }
    $command = Get-Command apksigner -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($sdk in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) {
        if (-not $sdk) { continue }
        $buildTools = Join-Path $sdk 'build-tools'
        if (-not (Test-Path -LiteralPath $buildTools -PathType Container)) { continue }
        $candidate = Get-ChildItem -LiteralPath $buildTools -Directory |
            Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
            ForEach-Object { Join-Path $_.FullName $(if ($IsWindows) { 'apksigner.bat' } else { 'apksigner' }) } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ($candidate) { return $candidate }
    }
    throw 'Android SDK apksigner was not found.'
}
$apksigner = Resolve-ApkSigner $ApkSignerPath

Push-Location -LiteralPath $app
try {
    & $flutter.Source pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
    $changesAfterResolution = @(& $git.Source -C $root status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $changesAfterResolution.Count -ne 0) {
        throw 'Dependency resolution changed the committed source tree.'
    }
    & $flutter.Source build apk --release --no-pub --build-name=$BuildName --build-number=$BuildNumber `
        "--dart-define=OIDC_ISSUER=$Issuer" "--dart-define=API_URL=$ApiUrl" "--dart-define=CONSOLE_URL=$ConsoleUrl"
    if ($LASTEXITCODE -ne 0) { throw 'Android release build failed.' }
} finally {
    Pop-Location
}

$apk = Join-Path $app 'build/app/outputs/flutter-apk/app-release.apk'
if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) { throw 'Release APK is missing.' }
& $apksigner verify --verbose --print-certs $apk
if ($LASTEXITCODE -ne 0) { throw 'Android APK signature verification failed.' }

$manifest = [ordered]@{
    schemaVersion = 1
    sourceRevision = $revision
    applicationId = 'com.aimanager.parent'
    versionName = $BuildName
    versionCode = $BuildNumber
    oidcIssuer = $Issuer
    apiUrl = $ApiUrl
    consoleUrl = $ConsoleUrl
    apkSha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
    signatureVerified = $true
    builtAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
}
$manifestPath = Join-Path $app 'build/parent-release-manifest.json'
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
Write-Output "Signed APK: $apk"
Write-Output "Release manifest: $manifestPath"
