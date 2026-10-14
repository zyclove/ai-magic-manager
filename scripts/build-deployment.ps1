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
    [string]$MavenRepository = '',
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deployment-common.ps1')
$context = Get-DeploymentContext $Directory
$source = [IO.Path]::GetFullPath($SourceDirectory, $context.Repository)
$applicationPaths = @('apps/guardian', 'apps/child', 'apps/parent')
$interopPaths = [ordered]@{
    'device.policy.package' = 'packages/device_policy'
    'device.identity.package' = 'packages/device_identity'
    'device.access.package' = 'packages/device_access'
    'device.child.package' = 'apps/child'
    'observation.device.package' = 'packages/device_observation'
    'observation.guardian.package' = 'apps/guardian'
    'usage.report.device.package' = 'packages/device_reports'
    'usage.report.guardian.package' = 'apps/guardian'
    'diagnostic.guardian.package' = 'apps/guardian'
}
$required = @('backend/pom.xml', 'packages/device_operations/pubspec.yaml') + @(@($applicationPaths) + @($interopPaths.Values) | Select-Object -Unique | ForEach-Object { "$_/pubspec.yaml" })
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf)) { throw 'Source snapshot is missing a required project file.' }
}
foreach ($command in @($MavenCommand, $FlutterCommand)) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw 'Configure Maven and Flutter executable paths before building.' }
}
$flutterPath = (Get-Command $FlutterCommand).Source
if (-not $DartCommand) {
    $DartCommand = Join-Path (Split-Path $flutterPath -Parent) $(if ($IsWindows) { 'dart.bat' } else { 'dart' })
}
if (-not (Get-Command $DartCommand -ErrorAction SilentlyContinue)) { throw 'Configure the Dart executable path for client verification.' }
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
foreach ($name in @('backend', 'packages') + $applicationPaths) { CopySourceTree (Join-Path $source $name) (Join-Path $snapshot $name) }
$projects = @(
    foreach ($path in $applicationPaths + @(Get-ChildItem -LiteralPath (Join-Path $snapshot 'packages') -Filter 'pubspec.yaml' -Recurse -File | Sort-Object FullName | ForEach-Object { [IO.Path]::GetRelativePath($snapshot, $_.DirectoryName).Replace('\', '/') })) {
        $pubspecPath = Join-Path $snapshot "$path/pubspec.yaml"
        if (-not (Test-Path -LiteralPath $pubspecPath -PathType Leaf)) { throw 'A project manifest is missing from the source snapshot.' }
        $pubspec = Get-Content -LiteralPath $pubspecPath -Raw
        $toolkit = if ($pubspec -match '(?m)^\s+sdk:\s*flutter\s*$') { 'flutter' } else { 'dart' }
        @{ Path=$path; Toolkit=$toolkit; Command=$(if ($toolkit -eq 'flutter') { $FlutterCommand } else { $DartCommand }); Label=$path.Replace('/', '-').Replace('_', '-') }
    }
)
# Resolve every package before the backend launches real HTTP clients. All
# interoperability paths are from this snapshot, never another working copy.
foreach ($project in $projects) {
    Write-Output "Preparing $($project.Path)..."
    Push-Location -LiteralPath (Join-Path $snapshot $project.Path)
    try {
        $pubArguments = @('pub', 'get')
        if ($Offline) { $pubArguments += '--offline' }
        Invoke-DeploymentNative $project.Command $pubArguments (Join-Path $logs "$($project.Label)-pub-get.log")
    } finally { Pop-Location }
}
$mavenArgs = @('-B', '-f', (Join-Path $snapshot 'backend/pom.xml'), 'verify', '-Dbackend.artifact-name=manager-backend', '-DreuseForks=false')
if ($Offline) { $mavenArgs += '-o' }
if ($MavenRepository) { $mavenArgs += "-Dmaven.repo.local=$([IO.Path]::GetFullPath($MavenRepository, $context.Repository))" }
# The Spring HTTP fixture launches Dart directly, so resolve the SDK executable
# rather than passing a Windows batch wrapper to Java ProcessBuilder. Resolve
# package dependencies before Maven; a skipped cross-SDK test is not evidence.
$dartExecutable = (Get-Command $DartCommand).Source
if ($IsWindows -and [IO.Path]::GetExtension($dartExecutable) -in @('.bat', '.cmd')) {
    $dartExecutable = Join-Path (Split-Path $dartExecutable -Parent) 'cache/dart-sdk/bin/dart.exe'
}
if (-not (Test-Path -LiteralPath $dartExecutable -PathType Leaf)) { throw 'Device HTTP interoperability requires a directly executable Dart SDK.' }
$mavenArgs += "-Ddevice.dart.command=$dartExecutable"
$mavenArgs += "-Ddevice.flutter.command=$flutterPath"
$flutterSdk = Split-Path (Split-Path $flutterPath -Parent) -Parent
$flutterTool = Join-Path $flutterSdk 'bin/cache/flutter_tools.snapshot'
if (-not (Test-Path -LiteralPath $flutterTool -PathType Leaf)) {
    throw 'Parent and guardian HTTP interoperability require the installed Flutter tools snapshot.'
}
$mavenArgs += "-Dparent.dart.command=$dartExecutable"
$mavenArgs += "-Dparent.flutter.tool=$flutterTool"
$mavenArgs += "-Dparent.package=$(Join-Path $snapshot 'apps/parent')"
$mavenArgs += "-Dguardian.dart.command=$dartExecutable"
$mavenArgs += "-Dguardian.flutter.tool=$flutterTool"
$mavenArgs += "-Dguardian.package=$(Join-Path $snapshot 'apps/guardian')"
foreach ($property in $interopPaths.Keys) {
    $mavenArgs += "-D${property}=$(Join-Path $snapshot $interopPaths[$property])"
}
Write-Output 'Verifying backend source snapshot...'
Invoke-DeploymentNative $MavenCommand $mavenArgs (Join-Path $logs 'backend-verify.log')
$verifiedProjects = @()
foreach ($project in $projects) {
    Write-Output "Verifying $($project.Path)..."
    Push-Location -LiteralPath (Join-Path $snapshot $project.Path)
    try {
        $analysisArguments = @('analyze')
        if ($project.Toolkit -eq 'flutter') { $analysisArguments += '--no-pub' }
        Invoke-DeploymentNative $project.Command $analysisArguments (Join-Path $logs "$($project.Label)-analyze.log")
        $hasTests = (Test-Path -LiteralPath 'test') -and @(Get-ChildItem -LiteralPath 'test' -Filter '*_test.dart' -Recurse -File).Count -gt 0
        if ($hasTests) {
            $testArguments = @('test', '--reporter', 'expanded')
            if ($project.Toolkit -eq 'flutter') { $testArguments += '--no-pub' }
            Invoke-DeploymentNative $project.Command $testArguments (Join-Path $logs "$($project.Label)-test.log")
        }
        $verifiedProjects += @{path=$project.Path; toolkit=$project.Toolkit; analysis='passed'; tests=$(if ($hasTests) { 'passed' } else { 'not-present' })}
    } finally { Pop-Location }
}
$origin = $context.Settings.publicUrl
$allowHttp = if ([Uri]::new($origin).Scheme -eq 'http') { 'true' } else { 'false' }
Push-Location -LiteralPath (Join-Path $snapshot 'apps/guardian')
try {
    Invoke-DeploymentNative $FlutterCommand @('build', 'web', '--release', '--no-pub', '--web-renderer', 'html', '--pwa-strategy=none', '--no-web-resources-cdn',
        "--dart-define=API_URL=$origin/api/v1", "--dart-define=OIDC_ISSUER=$origin/identity/realms/ai-manager", "--dart-define=ALLOW_LOCAL_HTTP=$allowHttp") (Join-Path $logs 'guardian-release.log')
} finally { Pop-Location }
$releaseRoot = Join-Path $context.Root ('artifacts/release-' + [Guid]::NewGuid().ToString('N'))
$backendContext = Join-Path $releaseRoot 'backend'
$guardianContext = Join-Path $releaseRoot 'guardian'
$null = New-Item -ItemType Directory -Path $backendContext, $guardianContext
Copy-Item -LiteralPath (Join-Path $snapshot 'backend/target/manager-backend.jar') -Destination (Join-Path $backendContext 'manager-backend.jar')
Copy-Item -Path (Join-Path $snapshot 'apps/guardian/build/web/*') -Destination $guardianContext -Recurse -Force
$files = Get-ChildItem -LiteralPath $snapshot -Recurse -File | Where-Object {
    $relative = [IO.Path]::GetRelativePath($snapshot, $_.FullName)
    $relative -notmatch '(^|[\\/])(target|build|\.dart_tool|\.local)[\\/]' -and $_.Name -notlike '.flutter-plugins*'
}
$sourceDigests = @($files | Sort-Object FullName | ForEach-Object { @{path=[IO.Path]::GetRelativePath($snapshot, $_.FullName).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()} })
$manifest = @{schemaVersion=1; applicationVersion='1.0.0'; builtAt=[DateTimeOffset]::UtcNow.ToString('O'); publicUrl=$origin; sourceFiles=$sourceDigests;
    verifiedProjects=$verifiedProjects; interoperabilityProperties=@($interopPaths.Keys) + @(
        'device.dart.command', 'device.flutter.command', 'parent.dart.command', 'parent.flutter.tool',
        'parent.package', 'guardian.dart.command', 'guardian.flutter.tool', 'guardian.package');
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
