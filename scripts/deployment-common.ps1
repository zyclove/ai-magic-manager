# Shared path and configuration validation; no evaluation of .env as shell code.
function Get-DeploymentOrigin([string]$PublicUrl, [int]$EdgePort, [switch]$ExternalTlsProxy) {
    if ($EdgePort -lt 1 -or $EdgePort -gt 65535) {
        throw 'EdgePort must be between 1 and 65535. Choose a valid listening port before initializing the environment.'
    }
    $uri = $null
    if (-not [Uri]::TryCreate($PublicUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.AbsolutePath -ne '/' -or $uri.Host -notmatch '^[A-Za-z0-9.:-]+$') {
        throw 'PublicUrl must be an HTTP(S) origin without user information, path, query or fragment. Set a plain HTTP(S) host and port without credentials.'
    }
    if ($uri.Port -lt 1 -or $uri.Port -gt 65535) {
        throw 'PublicUrl port must be between 1 and 65535. Choose a valid public entry port.'
    }
    if ($uri.Scheme -eq 'http' -and ($uri.Host -notin @('localhost', '127.0.0.1', '[::1]') -or $uri.Port -ne $EdgePort)) {
        throw 'HTTP is limited to a loopback origin whose port matches EdgePort. Use HTTPS for a public host, or match the localhost URL port to EdgePort.'
    }
    if ($ExternalTlsProxy) {
        if ($uri.Scheme -ne 'https' -or $uri.Port -ne 443) {
            throw 'ExternalTlsProxy requires a standard HTTPS public origin. Use an HTTPS origin on port 443, or remove ExternalTlsProxy for a direct local entry.'
        }
    } elseif ($uri.Port -ne $EdgePort) {
        throw 'PublicUrl port must match EdgePort (including HTTPS). Set matching ports, or use ExternalTlsProxy for a public HTTPS proxy.'
    }
    return $uri
}

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
