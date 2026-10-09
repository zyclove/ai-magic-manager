# Shared path and configuration validation; no evaluation of .env as shell code.
function Get-DeploymentContext([string]$Directory) {
    $repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
    $root = [IO.Path]::GetFullPath($Directory, $repository)
    $local = [IO.Path]::GetFullPath((Join-Path $repository '.local')) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $root.StartsWith($local, $comparison)) { throw 'Deployment workspace must be inside this repository .local directory.' }
    foreach ($name in @('deployment.json', '.env', 'secrets')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $name))) { throw 'Deployment workspace is not initialized.' }
    }
    $settings = Get-Content -LiteralPath (Join-Path $root 'deployment.json') -Raw | ConvertFrom-Json
    if ($settings.schemaVersion -ne 1) { throw 'Unsupported deployment workspace version.' }
    return @{ Root=$root; Repository=$repository; Settings=$settings; Compose=(Join-Path $repository 'deploy/compose/compose.yaml'); Environment=(Join-Path $root '.env') }
}
function Invoke-DeploymentNative([string]$Command, [string[]]$Arguments, [string]$LogPath) {
    & $Command @Arguments *> $LogPath
    if ($LASTEXITCODE -ne 0) { throw "Deployment command failed. Inspect the restricted log: $LogPath" }
}
