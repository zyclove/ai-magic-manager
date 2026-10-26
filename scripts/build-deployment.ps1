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
    [switch]$ConsumerIdentity,
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'

function Resolve-DeploymentFlutterInstallation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Command)

    # Inspect explicit links without requiring their final target to exist first.
    # For PATH names, accept file-backed commands only; never infer a SDK from
    # a function, alias, or the contents of a shell/package-manager shim.
    if ([IO.Path]::IsPathRooted($Command) -or $Command.Contains('/') -or $Command.Contains('\')) {
        $candidate = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Command)
    } else {
        $entryCommand = Get-Command $Command -ErrorAction Stop | Select-Object -First 1
        if ($entryCommand.CommandType -notin @('Application', 'ExternalScript') -or
            [string]::IsNullOrWhiteSpace($entryCommand.Source)) {
            throw 'FlutterCommand must name an SDK bin entry or a file symbolic link to it.'
        }
        $candidate = [IO.Path]::GetFullPath($entryCommand.Source)
    }
    $comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $visited = [Collections.Generic.HashSet[string]]::new($comparer)
    for ($hop = 0; $hop -le 16; $hop++) {
        if (-not $visited.Add($candidate)) { throw 'Flutter command symbolic link cycle detected.' }
        try {
            $entry = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        } catch {
            throw 'Flutter command cannot resolve to an existing file (missing target or cycle).'
        }
        if ($entry -isnot [IO.FileInfo]) { throw 'Flutter command must resolve to an existing file.' }
        if ($entry.LinkType -eq 'SymbolicLink') {
            if ($hop -eq 16) { throw 'Flutter command exceeds the maximum of 16 symbolic links.' }
            $targets = @($entry.Target)
            if ($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace($targets[0])) {
                throw 'Flutter command has an unsupported symbolic link target.'
            }
            $candidate = [IO.Path]::GetFullPath([string]$targets[0], [IO.Path]::GetDirectoryName($entry.FullName))
            continue
        }
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Flutter command contains an unsupported reparse point.'
        }
        $bin = [IO.Path]::GetDirectoryName($entry.FullName)
        $tool = Join-Path $bin 'cache/flutter_tools.snapshot'
        if ((Split-Path $bin -Leaf) -ne 'bin') {
            throw 'FlutterCommand must point to the installed SDK bin entry or a symbolic link to it.'
        }
        # Flutter dependency preparation may generate this snapshot. Keep the
        # existence check at the original pre-Maven gate after preparation.
        return [pscustomobject]@{
            FlutterPath = $entry.FullName
            DefaultDartCommand = Join-Path $bin $(if ($IsWindows) { 'dart.bat' } else { 'dart' })
            FlutterTool = $tool
        }
    }
}

. (Join-Path $PSScriptRoot 'deployment-common.ps1')
. (Join-Path $PSScriptRoot 'deployment-provenance.ps1')
$context = Get-DeploymentContext $Directory
if (($context.Settings.consumerIdentity -eq $true) -ne $ConsumerIdentity.IsPresent) {
    throw 'ConsumerIdentity must match the initialized deployment.'
}
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
if ($ConsumerIdentity) {
    $required += @('identity-extensions/pom.xml', 'identity-extensions/maven-settings.xml',
        'identity-extensions/src/main/resources/META-INF/services/org.keycloak.authentication.AuthenticatorFactory',
        'identity-extensions/src/main/resources/META-INF/services/org.keycloak.protocol.ProtocolMapper',
        'deploy/keycloak/entrypoint.sh', 'deploy/containers/keycloak.Dockerfile')
}
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf)) { throw 'Source snapshot is missing a required project file.' }
}
if (-not (Get-Command $MavenCommand -ErrorAction SilentlyContinue)) { throw 'Configure Maven and Flutter executable paths before building.' }
$flutterInstallation = Resolve-DeploymentFlutterInstallation -Command $FlutterCommand
$flutterPath = $flutterInstallation.FlutterPath
# Use the same resolved installation for every invocation, even if its original
# PATH link is switched while the build is in progress.
$FlutterCommand = $flutterPath
if (-not $DartCommand) {
    $DartCommand = $flutterInstallation.DefaultDartCommand
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
        # Provider binaries can enter a release only from this snapshot's successful SPI verification.
        if ($entry.Name -eq 'providers' -and (Split-Path $From -Leaf) -eq 'keycloak') { continue }
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source snapshots must not contain symbolic links.' }
        if ($entry.PSIsContainer) { CopySourceTree $entry.FullName (Join-Path $To $entry.Name) }
        else { Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $To $entry.Name) }
    }
}
foreach ($name in @('backend', 'packages') + $applicationPaths) { CopySourceTree (Join-Path $source $name) (Join-Path $snapshot $name) }
$verifiedProjects = @()
if ($ConsumerIdentity) {
    foreach ($name in @('identity-extensions', 'deploy/keycloak', 'deploy/containers')) {
        CopySourceTree (Join-Path $source $name) (Join-Path $snapshot $name)
    }
}
# These are the exact bytes given to verification, including frozen source
# directories that have no Git metadata. Never label such a copy with an
# ancestor checkout's HEAD. Generated SDK output is excluded on both reads.
$sourceDigests = @(Get-DeploymentFileInventory -Root $snapshot -ExcludeGenerated)
$sourceTreeSha256 = Get-DeploymentTreeSha256 -Files $sourceDigests
$recipeDigests = @(Get-DeploymentRecipeInventory -Repository $context.Repository)
$recipeTreeSha256 = Get-DeploymentTreeSha256 -Files $recipeDigests
if ($ConsumerIdentity) {
    $identityArgs = @('-B', '-f', (Join-Path $snapshot 'identity-extensions/pom.xml'),
        '-s', (Join-Path $snapshot 'identity-extensions/maven-settings.xml'), 'verify', '-DfailIfNoTests=true')
    if ($Offline) { $identityArgs += '-o' }
    if ($MavenRepository) { $identityArgs += "-Dmaven.repo.local=$([IO.Path]::GetFullPath($MavenRepository, $context.Repository))" }
    Write-Output 'Verifying consumer identity source snapshot...'
    Invoke-DeploymentNative $MavenCommand $identityArgs (Join-Path $logs 'consumer-identity-verify.log')
    if (-not (Test-Path -LiteralPath (Join-Path $snapshot 'identity-extensions/target/consumer-identity-1.0.0.jar') -PathType Leaf)) {
        throw 'Consumer identity verification did not produce the expected provider JAR.'
    }
    $verifiedProjects += @{path='identity-extensions'; toolkit='maven'; analysis='compiled'; tests='passed'}
}
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
$flutterTool = $flutterInstallation.FlutterTool
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
$identityProviderHash = $null
if ($ConsumerIdentity) {
    $identityContext = Join-Path $releaseRoot 'keycloak'
    CopySourceTree (Join-Path $snapshot 'deploy/keycloak') (Join-Path $identityContext 'keycloak')
    CopySourceTree (Join-Path $snapshot 'deploy/containers') (Join-Path $identityContext 'containers')
    $providerDirectory = Join-Path $identityContext 'keycloak/providers'
    $null = New-Item -ItemType Directory -Path $providerDirectory
    $provider = Join-Path $providerDirectory 'consumer-identity-1.0.0.jar'
    Copy-Item -LiteralPath (Join-Path $snapshot 'identity-extensions/target/consumer-identity-1.0.0.jar') -Destination $provider
    $identityProviderHash = (Get-FileHash -LiteralPath $provider -Algorithm SHA256).Hash.ToLowerInvariant()
}
try { Assert-DeploymentInventory -Root $snapshot -Files $sourceDigests -ExcludeGenerated }
catch { throw 'Verification source inputs changed during the build; rebuild from a stable source.' }
if ((Get-DeploymentTreeSha256 -Files @(Get-DeploymentRecipeInventory -Repository $context.Repository)) -cne $recipeTreeSha256) {
    throw 'Deployment recipes changed during verification; rebuild from a stable source.'
}
$artifactDigests = @(Get-DeploymentFileInventory -Root $releaseRoot)
$manifest = @{schemaVersion=1; applicationVersion='1.0.0'; builtAt=[DateTimeOffset]::UtcNow.ToString('O'); publicUrl=$origin; sourceFiles=$sourceDigests;
    provenanceVersion=1; source=@{kind='content-snapshot'; revision="sha256:$sourceTreeSha256"}; sourceTreeSha256=$sourceTreeSha256;
    artifactFiles=$artifactDigests; artifactTreeSha256=(Get-DeploymentTreeSha256 -Files $artifactDigests);
    recipeFiles=$recipeDigests; recipeTreeSha256=$recipeTreeSha256;
    consumerIdentity=$ConsumerIdentity.IsPresent; identityProviderSha256=$identityProviderHash;
    verifiedProjects=$verifiedProjects; interoperabilityProperties=@($interopPaths.Keys) + @(
        'device.dart.command', 'device.flutter.command', 'parent.dart.command', 'parent.flutter.tool',
        'parent.package', 'guardian.dart.command', 'guardian.flutter.tool', 'guardian.package');
    artifactRoot=[IO.Path]::GetRelativePath($context.Root, $releaseRoot).Replace('\','/');
    backendSha256=(Get-FileHash -LiteralPath (Join-Path $backendContext 'manager-backend.jar') -Algorithm SHA256).Hash.ToLowerInvariant();
    guardianSha256=(Get-FileHash -LiteralPath (Join-Path $guardianContext 'main.dart.js') -Algorithm SHA256).Hash.ToLowerInvariant()}
$manifestJson = $manifest | ConvertTo-Json -Depth 8
$manifestJson | Set-Content -LiteralPath (Join-Path $releaseRoot 'release-manifest.json') -Encoding utf8
$updatedEnvironment = @(Get-Content -LiteralPath $context.Environment | Where-Object { -not $_.StartsWith('BACKEND_BUILD_CONTEXT=') -and -not $_.StartsWith('GUARDIAN_BUILD_CONTEXT=') -and -not $_.StartsWith('KEYCLOAK_BUILD_CONTEXT=') })
$updatedEnvironment += "BACKEND_BUILD_CONTEXT='$($backendContext.Replace('\','/'))'"
$updatedEnvironment += "GUARDIAN_BUILD_CONTEXT='$($guardianContext.Replace('\','/'))'"
$selectedIdentityContext = if ($ConsumerIdentity) { $identityContext } else { Join-Path $context.Repository 'deploy' }
$updatedEnvironment += "KEYCLOAK_BUILD_CONTEXT='$($selectedIdentityContext.Replace('\','/'))'"
$updatedEnvironment | Set-Content -LiteralPath $context.Environment -Encoding utf8
$manifestJson | Set-Content -LiteralPath (Join-Path $context.Root 'release-manifest.json') -Encoding utf8
Write-Output "Verified build contexts ready: $($context.Root)"
