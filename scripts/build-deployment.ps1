#Requires -Version 7.0
<#
.SYNOPSIS
Verifies an isolated source snapshot and creates Docker build contexts.
.DESCRIPTION
No production service is stopped or replaced. A fresh snapshot prevents target/
and Flutter build output collisions with an already running local development.
#>
[CmdletBinding()]
param(
    [string]$Directory = '.local/deployment',
    [string]$SourceDirectory = (Split-Path $PSScriptRoot -Parent),
    [string]$MavenCommand = 'mvn',
    [string]$FlutterCommand = 'flutter',
    [string]$DartCommand = '',
    [string]$MavenRepository = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deployment-common.ps1')
$context = Get-DeploymentContext $Directory
$source = [IO.Path]::GetFullPath($SourceDirectory, $context.Repository)
foreach ($name in @('backend/pom.xml', 'apps/guardian/pubspec.yaml', 'packages/device_operations/pubspec.yaml')) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $name))) { throw 'Source snapshot is missing a required project.' }
}
foreach ($command in @($MavenCommand, $FlutterCommand)) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw 'Configure Maven and Flutter executable paths before building.' }
}
$hasDevicePolicy = Test-Path -LiteralPath (Join-Path $source 'packages/device_policy/pubspec.yaml')
if ($hasDevicePolicy) {
    if (-not $DartCommand) {
        $flutterPath = (Get-Command $FlutterCommand).Source
        $DartCommand = Join-Path (Split-Path $flutterPath -Parent) $(if ($IsWindows) { 'dart.bat' } else { 'dart' })
    }
    if (-not (Get-Command $DartCommand -ErrorAction SilentlyContinue)) { throw 'Configure the Dart executable path for device policy verification.' }
}
$snapshot = Join-Path $context.Root ('source-' + [Guid]::NewGuid().ToString('N'))
$logs = Join-Path $context.Root 'logs'
$null = New-Item -ItemType Directory -Path $snapshot
$null = New-Item -ItemType Directory -Path $logs -Force
function CopySourceTree([string]$From, [string]$To) {
    $null = New-Item -ItemType Directory -Path $To -Force
    foreach ($entry in Get-ChildItem -LiteralPath $From -Force) {
        if ($entry.Name -in @('.git', '.local', 'target', 'build', '.dart_tool', '__pycache__') -or $entry.Name -like '.flutter-plugins*') { continue }
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source snapshots must not contain symbolic links.' }
        if ($entry.PSIsContainer) { CopySourceTree $entry.FullName (Join-Path $To $entry.Name) }
        else { Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $To $entry.Name) }
    }
}
foreach ($name in @('backend', 'apps/guardian', 'packages')) { CopySourceTree (Join-Path $source $name) (Join-Path $snapshot $name) }
$mavenArgs = @('-B', '-f', (Join-Path $snapshot 'backend/pom.xml'), 'verify', '-Dbackend.artifact-name=manager-backend')
if ($MavenRepository) { $mavenArgs += "-Dmaven.repo.local=$([IO.Path]::GetFullPath($MavenRepository, $context.Repository))" }
Write-Output 'Verifying backend source snapshot...'
Invoke-DeploymentNative $MavenCommand $mavenArgs (Join-Path $logs 'backend-verify.log')
$projects = @('packages/device_operations', 'apps/guardian')
if ($hasDevicePolicy) { $projects += 'packages/device_policy' }
foreach ($name in $projects) {
    Push-Location -LiteralPath (Join-Path $snapshot $name)
    try {
        $label = switch ($name) { 'apps/guardian' { 'guardian' }; 'packages/device_policy' { 'device-policy' }; default { 'device-operations' } }
        $projectCommand = if ($name -eq 'packages/device_policy') { $DartCommand } else { $FlutterCommand }
        foreach ($operation in @('pub-get', 'analyze', 'test')) {
            $arguments = switch ($operation) { 'pub-get' { @('pub', 'get') }; 'test' { @('test', '--reporter', 'expanded') }; default { @('analyze') } }
            Invoke-DeploymentNative $projectCommand $arguments (Join-Path $logs "$label-$operation.log")
        }
    } finally { Pop-Location }
}
$origin = $context.Settings.publicUrl
$allowHttp = if ([Uri]::new($origin).Scheme -eq 'http') { 'true' } else { 'false' }
Push-Location -LiteralPath (Join-Path $snapshot 'apps/guardian')
try {
    Invoke-DeploymentNative $FlutterCommand @('build', 'web', '--release', '--web-renderer', 'html', '--pwa-strategy=none', '--no-web-resources-cdn',
        "--dart-define=API_URL=$origin/api/v1", "--dart-define=OIDC_ISSUER=$origin/identity/realms/ai-manager", "--dart-define=ALLOW_LOCAL_HTTP=$allowHttp") (Join-Path $logs 'guardian-release.log')
} finally { Pop-Location }
$releaseRoot = Join-Path $context.Root ('artifacts/release-' + [Guid]::NewGuid().ToString('N'))
$backendContext = Join-Path $releaseRoot 'backend'
$guardianContext = Join-Path $releaseRoot 'guardian'
$null = New-Item -ItemType Directory -Path $backendContext, $guardianContext
Copy-Item -LiteralPath (Join-Path $snapshot 'backend/target/manager-backend.jar') -Destination (Join-Path $backendContext 'manager-backend.jar')
Copy-Item -Path (Join-Path $snapshot 'apps/guardian/build/web/*') -Destination $guardianContext -Recurse -Force
$files = Get-ChildItem -LiteralPath $snapshot -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/](target|build|\.dart_tool)[\\/]' -and $_.Name -notlike '.flutter-plugins*' }
$sourceDigests = @($files | Sort-Object FullName | ForEach-Object { @{path=[IO.Path]::GetRelativePath($snapshot, $_.FullName).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()} })
$manifest = @{schemaVersion=1; builtAt=[DateTimeOffset]::UtcNow.ToString('O'); publicUrl=$origin; sourceFiles=$sourceDigests;
    artifactRoot=[IO.Path]::GetRelativePath($context.Root, $releaseRoot).Replace('\','/');
    backendSha256=(Get-FileHash -LiteralPath (Join-Path $backendContext 'manager-backend.jar') -Algorithm SHA256).Hash.ToLowerInvariant();
    guardianSha256=(Get-FileHash -LiteralPath (Join-Path $guardianContext 'main.dart.js') -Algorithm SHA256).Hash.ToLowerInvariant()}
$manifestJson = $manifest | ConvertTo-Json -Depth 8
$manifestJson | Set-Content -LiteralPath (Join-Path $releaseRoot 'release-manifest.json') -Encoding utf8
$updatedEnvironment = @(Get-Content -LiteralPath $context.Environment | Where-Object { -not $_.StartsWith('BACKEND_BUILD_CONTEXT=') -and -not $_.StartsWith('GUARDIAN_BUILD_CONTEXT=') })
$updatedEnvironment += "BACKEND_BUILD_CONTEXT='$($backendContext.Replace('\','/'))'"
$updatedEnvironment += "GUARDIAN_BUILD_CONTEXT='$($guardianContext.Replace('\','/'))'"
$updatedEnvironment | Set-Content -LiteralPath $context.Environment -Encoding utf8
$manifestJson | Set-Content -LiteralPath (Join-Path $context.Root 'release-manifest.json') -Encoding utf8
Write-Output "Verified build contexts ready: $($context.Root)"
