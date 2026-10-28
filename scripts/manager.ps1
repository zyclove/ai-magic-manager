#Requires -Version 7.0
<#
.SYNOPSIS
独立部署环境的统一入口：预览、初始化、构建、启动与恢复。
.DESCRIPTION
使用 -Plan 先查看动作和非秘密参数，不创建文件或执行命令。所有动作均不自动安装工具、
清空环境、停止其他部署，或将凭据写入输出；实际动作保留底层完整校验。

doctor 只盘点所选 Toolset 的命令是否可找到：默认 Build，已有环境可选 Runtime。
它不执行 SDK，也不证明版本、Compose 插件、服务健康或部署已经可用。
缺少命令时，先按 missingTools 与 next 补齐对应命令或指定已有工具，再重跑同档位检查。
init -Plan 与实际初始化共用地址、端口和 TLS 校验；预览不会读取部署凭据或检查服务。
build -Offline 要求已有完整依赖缓存，缓存缺失时失败；需要联网解析时由维护者明确移除该参数。

首次部署依次完成 init、build、init-ledger、start。init-ledger 仅用于全新账本的一次性初始化，
会启动其数据库并运行初始化器，不用于正常重启或故障恢复。每条命令单独执行，失败后先核对日志。
start 通过 up --build 更新指定项目的发布；resume 仅恢复同批已有容器，不构建或创建容器。
resume 保留原发布记录、镜像、挂载、身份、账本及健康校验，并要求 Compose 支持 start 等待健康；
缺少容器、记录不符或能力不足时拒绝恢复，不改成重新部署。
.PARAMETER Action
doctor 盘点工具；init 创建新环境；build 构建产物；init-ledger 初始化新账本；
start 更新并启动发布；resume 恢复已有容器；status 只读查看状态；verify 核验发布及入口。
.PARAMETER Directory
建议使用仓库 .local 下的独立环境目录，默认为 .local/deployment；以下首次部署示例统一使用 .local/demo。
.EXAMPLE
./scripts/manager.ps1 doctor
./scripts/manager.ps1 doctor -Toolset Runtime

按用途选择工具盘点；Runtime 不把缺少源码构建工具列为运行工具缺失。
.EXAMPLE
./scripts/manager.ps1 init -Directory .local/demo -ProjectName ai-manager-demo -Plan
./scripts/manager.ps1 init -Directory .local/demo -ProjectName ai-manager-demo
./scripts/manager.ps1 build -Directory .local/demo -Offline
./scripts/manager.ps1 init-ledger -Directory .local/demo
./scripts/manager.ps1 start -Directory .local/demo
./scripts/manager.ps1 status -Directory .local/demo
./scripts/manager.ps1 verify -Directory .local/demo

全新环境的完整顺序：预览不等于创建环境；init-ledger 仅对新账本执行一次。
Offline 需先准备完整缓存；按顺序逐条执行，失败时停止后续步骤。
.EXAMPLE
./scripts/manager.ps1 resume -Directory .local/demo -Plan
./scripts/manager.ps1 resume -Directory .local/demo

已有环境恢复；TLS、代理及身份配置沿用该环境原启动参数，不重复初始化账本。
.EXAMPLE
./scripts/manager.ps1 status -Active

只读查看控制台当前已选环境，不会隐式选作构建或发布目标。
.LINK
docs/deployment-quickstart.md
.LINK
docs/deployment-runbook.md
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('doctor', 'init', 'build', 'init-ledger', 'start', 'resume', 'status', 'verify')]
    [string]$Action = 'doctor',
    [ValidateSet('Build', 'Runtime')][string]$Toolset = 'Build',
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
    [switch]$Active,
    [Alias('DryRun')][switch]$Plan,
    [switch]$Help
)
$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$allowed = @{
    doctor = @('Toolset', 'MavenCommand', 'FlutterCommand', 'DartCommand')
    init = @('Directory', 'PublicUrl', 'EdgePort', 'ProjectName', 'ExternalTlsProxy', 'ConsumerIdentity')
    build = @('Directory', 'SourceDirectory', 'MavenCommand', 'FlutterCommand', 'DartCommand', 'MavenRepository', 'ConsumerIdentity', 'Offline')
    'init-ledger' = @('Directory')
    start = @('Directory', 'Tls', 'ExternalTlsProxy', 'IdentityAdminDirectory', 'IdentityRuntimeDirectory')
    resume = @('Directory', 'Tls', 'ExternalTlsProxy', 'IdentityAdminDirectory', 'IdentityRuntimeDirectory')
    status = @('Directory', 'Active')
    verify = @('Directory')
}
$forward = @{}
foreach ($name in $PSBoundParameters.Keys) {
    if ($name -in @('Action', 'Plan', 'Help', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')) { continue }
    if ($name -notin $allowed[$Action]) {
        $actionParameters = @($allowed[$Action] | Sort-Object | ForEach-Object { "-$_" }) -join ', '
        throw "Parameter -$name does not apply to action '$Action'. Allowed parameters for '$Action': $actionParameters. Use -Plan to preview or -Help for examples."
    }
    $value = $PSBoundParameters[$name]
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { throw "Parameter -$name must not be empty." }
    $forward[$name] = $value
}
if ($Action -eq 'doctor') {
    $forward.Toolset = if ($Toolset -ieq 'Runtime') { 'Runtime' } else { 'Build' }
    if ($forward.Toolset -eq 'Runtime') {
        foreach ($name in @('MavenCommand', 'FlutterCommand', 'DartCommand')) {
            if ($forward.ContainsKey($name)) { throw "Parameter -$name requires doctor -Toolset Build." }
        }
    }
}

$repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
# Explicit filesystem options share the repository base across every launcher.
# Normalize strings only: a plan must not inspect identity files or invoke tools.
foreach ($name in @('SourceDirectory', 'MavenRepository', 'IdentityAdminDirectory', 'IdentityRuntimeDirectory')) {
    if ($forward.ContainsKey($name)) {
        $forward[$name] = [IO.Path]::GetFullPath([string]$forward[$name], $repository)
    }
}
[char[]]$pathSeparators = @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
foreach ($name in @('MavenCommand', 'FlutterCommand', 'DartCommand')) {
    if (-not $forward.ContainsKey($name)) { continue }
    $command = [string]$forward[$name]
    if ([IO.Path]::IsPathRooted($command) -or $command.IndexOfAny($pathSeparators) -ge 0) {
        $forward[$name] = [IO.Path]::GetFullPath($command, $repository)
    }
    # Bare command names retain normal PATH resolution.
}
if ($Active -and $PSBoundParameters.ContainsKey('Directory')) {
    throw 'Parameters -Active and -Directory cannot be combined.'
}
if ($Action -ne 'doctor' -and -not $Active) {
    $root = [IO.Path]::GetFullPath($Directory, $repository)
    $local = [IO.Path]::GetFullPath((Join-Path $repository '.local')) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $root.StartsWith($local, $comparison)) { throw 'Deployment directory must be inside this repository .local directory.' }
    $forward.Directory = $root
}
if ($Action -eq 'init') {
    # Resolve defaults once for both the plan and the actual initializer.
    # Explicit settings are never rewritten; both entry points validate the pair.
    if (-not $forward.ContainsKey('PublicUrl')) {
        $localPort = if ($forward.ContainsKey('EdgePort')) { $forward.EdgePort } else { 18090 }
        $forward.PublicUrl = "http://localhost:$localPort"
    }
    if (-not $forward.ContainsKey('EdgePort')) {
        # Read the default port without a cast error echoing a malformed URL.
        $publicOrigin = $null
        if (-not [Uri]::TryCreate($forward.PublicUrl, [UriKind]::Absolute, [ref]$publicOrigin) -or
            $publicOrigin.Scheme -notin @('http', 'https')) {
            throw 'PublicUrl must be an HTTP(S) origin without credentials, path, query, or fragment.'
        }
        $forward.EdgePort = if ($ExternalTlsProxy) { 18090 } else { $publicOrigin.Port }
    }
    if ($forward.EdgePort -lt 1 -or $forward.EdgePort -gt 65535) {
        throw 'Public entry port must be between 1 and 65535.'
    }
    if (-not $forward.ContainsKey('ProjectName')) { $forward.ProjectName = 'ai-manager-repro' }
    . (Join-Path $PSScriptRoot 'deployment-common.ps1')
    $null = Get-DeploymentOrigin -PublicUrl $forward.PublicUrl -EdgePort $forward.EdgePort -ExternalTlsProxy:$ExternalTlsProxy
}
$entries = @{
    init = 'initialize-deployment.ps1'
    build = 'build-deployment.ps1'
    'init-ledger' = 'initialize-erasure-ledger.ps1'
    start = 'start-deployment.ps1'
    resume = 'start-deployment.ps1'
    verify = 'verify-deployment.ps1'
}
if ($Action -eq 'resume') { $forward.ResumeExisting = $true }
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
        selection = if ($Active) { 'ACTIVE_CONSOLE' } elseif ($Action -eq 'doctor') { 'NONE' } else { 'DIRECTORY' }
        mode = 'PLAN_ONLY'
        effect = switch ($Action) {
            doctor { 'Check command availability only; no SDK commands or service access.' }
            init { 'Create a new isolated workspace; refuse to overwrite an existing directory.' }
            build { 'Verify an isolated source snapshot and build artifacts; may resolve dependencies unless -Offline is selected.' }
            'init-ledger' { 'Explicit one-time provisioning of a NEW erasure ledger; starts its database and builds/runs the initializer. Never used for routine startup or recovery.' }
            start { 'Validate release provenance, then build/start this selected Compose project.' }
            resume { 'Validate the prior runtime receipt, then start existing containers only; no build, creation or receipt replacement.' }
            status { 'Read selected deployment metadata and list containers with its exact Compose project label.' }
            verify { 'Check selected release provenance, HTTP entry, OIDC discovery, and backend health.' }
        }
    } | ConvertTo-Json -Depth 5
    return
}

if ($Action -eq 'doctor') {
    . (Join-Path $PSScriptRoot 'tool-discovery.ps1')
    $tools = @(@{ name='docker'; command='docker'; purpose='Run the selected Compose deployment' })
    if ($forward.Toolset -eq 'Build') {
        $tools += @(
            @{ name='git'; command='git'; purpose='Bind the source revision when building release artifacts' }
            @{ name='java'; command='java'; purpose='Build backend artifacts' }
            @{ name='mvn'; command=$(if ($forward.ContainsKey('MavenCommand')) { $forward.MavenCommand } else { 'mvn' }); purpose='Build backend artifacts' }
            @{ name='flutter'; command=$(if ($forward.ContainsKey('FlutterCommand')) { $forward.FlutterCommand } else { 'flutter' }); purpose='Build Flutter applications' }
        )
        if ($forward.ContainsKey('DartCommand')) {
            $tools += @{ name='dart'; command=$forward.DartCommand; purpose='Use the explicitly configured Dart command for client verification' }
        }
    }
    $availability = foreach ($tool in $tools) {
        $commandKinds = [Management.Automation.CommandTypes]::Application
        if ($tool.name -in @('mvn', 'flutter', 'dart')) {
            $commandKinds = $commandKinds -bor [Management.Automation.CommandTypes]::ExternalScript
        }
        [ordered]@{
            tool = $tool.name
            command = $tool.command
            available = $null -ne (Find-DeploymentToolCommand -Command ([string]$tool.command) -CommandTypes $commandKinds)
            purpose = $tool.purpose
        }
    }
    $missingTools = @($availability | Where-Object { -not $_.available } | ForEach-Object { $_.tool })
    if ($missingTools.Count -gt 0) {
        $next = 'Resolve missing commands: ' + ($missingTools -join ', ') + '. Make them available on PATH.'
        $commandOverrides = @{
            mvn = '-MavenCommand'
            flutter = '-FlutterCommand'
            dart = '-DartCommand'
        }
        $overrides = @($missingTools | Where-Object { $commandOverrides.ContainsKey($_) } |
            ForEach-Object { $commandOverrides[$_] })
        if ($overrides.Count -gt 0) {
            $next += ' Existing build tools can instead be selected with ' + ($overrides -join ', ') + '.'
        }
        $next += " Run doctor -Toolset $($forward.Toolset) again; see docs/deployment-quickstart.md."
    } else {
        $next = if ($forward.Toolset -eq 'Runtime') { 'Use status -Active -Plan to inspect the selected existing environment; see docs/deployment-quickstart.md.' } else { 'Use init -Plan to inspect initialization; see docs/deployment-quickstart.md.' }
    }
    [ordered]@{
        powershell = $PSVersionTable.PSVersion.ToString()
        toolset = $forward.Toolset
        tools = @($availability)
        missingTools = $missingTools
        scope = 'Command availability only; versions, Compose support, daemon health, and platform compatibility are not verified.'
        next = $next
    } | ConvertTo-Json -Depth 5
    return
}
if ($Action -eq 'status') {
    . (Join-Path $PSScriptRoot 'deployment-common.ps1')
    $selection = $null
    if ($Active) {
        . (Join-Path $PSScriptRoot 'console-activation.ps1')
        $selection = Get-ActiveConsoleSelection -RepositoryRoot $repository
        if ($null -eq $selection) { throw 'No active console deployment is selected. Use status -Directory for an explicit environment.' }
        $statusDirectory = $selection.deploymentDirectory
    } else {
        $statusDirectory = $forward.Directory
    }
    $context = Get-DeploymentContext $statusDirectory
    $project = $context.Settings.projectName
    if ($project -isnot [string] -or $project -cnotmatch '^[a-z][a-z0-9-]{2,40}$') { throw 'Deployment project name is invalid.' }
    if ($Active) {
        if ($project -cne $selection.project -or $context.Settings.publicUrl -cne $selection.publicUrl) {
            throw 'Active console metadata changed; select the current environment again.'
        }
        Write-Output "Project: $project"
        Write-Output "Public URL: $($selection.publicUrl)"
    }
    $docker = Get-Command docker -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    & $docker.Source container ls --all --filter "label=com.docker.compose.project=$project" --format 'table {{.Names}}\t{{.State}}\t{{.Status}}\t{{.Ports}}'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    return
}
$LASTEXITCODE = 0
& (Join-Path $PSScriptRoot $entries[$Action]) @forward
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
