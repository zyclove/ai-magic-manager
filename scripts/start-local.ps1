$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$runtimeRoot = Join-Path $projectRoot '.local/runtime'
foreach ($required in @('credentials.json', 'compose.yaml', 'start.ps1', 'start-frontend.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot $required))) {
        throw "Missing local runtime file: $required. Configure local dependencies and credentials before starting."
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'apps/guardian/build/web/index.html'))) {
    throw 'Build the web app first: cd apps/guardian; flutter build web --release --web-renderer html --pwa-strategy=none'
}
& (Join-Path $runtimeRoot 'start.ps1')
& (Join-Path $runtimeRoot 'start-frontend.ps1')
Write-Output 'Console: http://localhost:3000'
Write-Output 'Backend: http://localhost:8082'
Write-Output 'Identity: http://localhost:8081'
