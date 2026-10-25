#Requires -Version 7.0
<#
.SYNOPSIS
One entry point for the existing, isolated AI Manager deployment workflow.
.DESCRIPTION
Use -Plan to inspect an action without executing it. No action installs tools,
clears data, stops another deployment, or reads credentials into its output.
Build and start retain all checks in the existing deployment scripts.
.EXAMPLE
./scripts/manager.ps1 doctor
.EXAMPLE
./scripts/manager.ps1 init -Directory .local/demo -ProjectName ai-manager-demo -Plan
.EXAMPLE
./scripts/manager.ps1 build -Directory .local/demo -Offline
.EXAMPLE
./scripts/manager.ps1 status -Directory .local/demo
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('doctor', 'init', 'build', 'init-ledger', 'start', 'status', 'verify')]
    [string]$Action = 'doctor',
    [string]$Directory = '.local/deployment',
    [string]$PublicUrl,
    [ValidateRange(1, 65535)][int]$EdgePort,
    [ValidatePattern('^[a-z][a-z0-9-]{2,40}$')][string]$ProjectName,
    [string]$SourceDirectory,
    [string]$MavenCommand,
    [string]$FlutterCommand,
    [string]$DartCommand,
    [string]$MavenRepository,
    [string]$IdentityAdminDirectory,
    [string]$IdentityRuntimeDirectory,
    [switch]$ConsumerIdentity,
    [switch]$ExternalTlsProxy,
    [switch]$Tls,
    [switch]$Offline,
    [Alias('DryRun')][switch]$Plan,
    [switch]$Help
)
$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$allowed = @{
    doctor = @()
    init = @('Directory', 'PublicUrl', 'EdgePort', 'ProjectName', 'ExternalTlsProxy', 'ConsumerIdentity')
    build = @('Directory', 'SourceDirectory', 'MavenCommand', 'FlutterCommand', 'DartCommand', 'MavenRepository', 'ConsumerIdentity', 'Offline')
    'init-ledger' = @('Directory')
    start = @('Directory', 'Tls', 'ExternalTlsProxy', 'IdentityAdminDirectory', 'IdentityRuntimeDirectory')
    status = @('Directory')
    verify = @('Directory')
}
$forward = @{}
foreach ($name in $PSBoundParameters.Keys) {
    if ($name -in @('Action', 'Plan', 'Help', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')) { continue }
    if ($name -notin $allowed[$Action]) { throw "Parameter -$name does not apply to action '$Action'." }
    $value = $PSBoundParameters[$name]
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { throw "Parameter -$name must not be empty." }
    $forward[$name] = $value
}

$repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if ($Action -ne 'doctor') {
    $root = [IO.Path]::GetFullPath($Directory, $repository)
    $local = [IO.Path]::GetFullPath((Join-Path $repository '.local')) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $root.StartsWith($local, $comparison)) { throw 'Deployment directory must be inside this repository .local directory.' }
    $forward.Directory = $root
}
if ($Action -eq 'init') {
    # Show the effective public entry and project in plans, not just overrides.
    foreach ($item in @(@{name='PublicUrl'; value='http://localhost:18090'},
        @{name='EdgePort'; value=18090}, @{name='ProjectName'; value='ai-manager-repro'})) {
        if (-not $forward.ContainsKey($item.name)) { $forward[$item.name] = $item.value }
    }
}
if ($PSBoundParameters.ContainsKey('PublicUrl')) {
    $origin = $null
    if (-not [Uri]::TryCreate($PublicUrl, [UriKind]::Absolute, [ref]$origin) -or
        $origin.Scheme -notin @('http', 'https') -or $origin.UserInfo -or $origin.Query -or
        $origin.Fragment -or $origin.AbsolutePath -ne '/') {
        throw 'PublicUrl must be an HTTP(S) origin without credentials, path, query, or fragment.'
    }
}
$entries = @{
    init = 'initialize-deployment.ps1'
    build = 'build-deployment.ps1'
    'init-ledger' = 'initialize-erasure-ledger.ps1'
    start = 'start-deployment.ps1'
    verify = 'verify-deployment.ps1'
}
if ($Plan) {
    $parameters = [ordered]@{}
    foreach ($name in @($forward.Keys | Sort-Object)) {
        $value = $forward[$name]
        $parameters[$name] = if ($value -is [Management.Automation.SwitchParameter]) { $value.IsPresent } else { $value }
    }
    [ordered]@{
        action = $Action
        entry = if ($entries.ContainsKey($Action)) { 'scripts/' + $entries[$Action] } else { 'scripts/manager.ps1' }
        parameters = $parameters
        mode = 'PLAN_ONLY'
        effect = switch ($Action) {
            doctor { 'Check command availability only; no SDK commands or service access.' }
            init { 'Create a new isolated workspace; refuse to overwrite an existing directory.' }
            build { 'Verify an isolated source snapshot and build artifacts; may resolve dependencies unless -Offline is selected.' }
            'init-ledger' { 'Explicit one-time provisioning of a NEW erasure ledger; starts its database and builds/runs the initializer. Never used for routine startup or recovery.' }
            start { 'Validate release provenance, then build/start this selected Compose project.' }
            status { 'Read selected deployment metadata and list containers with its exact Compose project label.' }
            verify { 'Check selected release provenance, HTTP entry, OIDC discovery, and backend health.' }
        }
    } | ConvertTo-Json -Depth 5
    return
}

if ($Action -eq 'doctor') {
    $tools = @(
        @{ name='docker'; purpose='Run the selected Compose deployment' }
        @{ name='git'; purpose='Bind the source revision when building release artifacts' }
        @{ name='java'; purpose='Build backend artifacts' }
        @{ name='mvn'; purpose='Build backend artifacts' }
        @{ name='flutter'; purpose='Build Flutter applications' }
    )
    $availability = foreach ($tool in $tools) {
        [ordered]@{
            tool = $tool.name
            available = $null -ne (Get-Command $tool.name -CommandType Application -ErrorAction SilentlyContinue)
            purpose = $tool.purpose
        }
    }
    [ordered]@{
        powershell = $PSVersionTable.PSVersion.ToString()
        tools = @($availability)
        missingTools = @($availability | Where-Object { -not $_.available } | ForEach-Object { $_.tool })
        scope = 'Command availability only; versions, Compose support, daemon health, and platform compatibility are not verified.'
        next = 'Use init -Plan to inspect initialization; see docs/deployment-quickstart.md.'
    } | ConvertTo-Json -Depth 5
    return
}
if ($Action -eq 'status') {
    . (Join-Path $PSScriptRoot 'deployment-common.ps1')
    $context = Get-DeploymentContext $forward.Directory
    $project = $context.Settings.projectName
    if ($project -isnot [string] -or $project -cnotmatch '^[a-z][a-z0-9-]{2,40}$') { throw 'Deployment project name is invalid.' }
    $docker = Get-Command docker -CommandType Application -ErrorAction Stop
    & $docker.Source container ls --all --filter "label=com.docker.compose.project=$project" --format 'table {{.Names}}\t{{.State}}\t{{.Status}}\t{{.Ports}}'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    return
}
$LASTEXITCODE = 0
& (Join-Path $PSScriptRoot $entries[$Action]) @forward
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
