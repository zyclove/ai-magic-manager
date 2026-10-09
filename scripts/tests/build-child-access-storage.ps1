param(
  [Parameter(Mandatory=$true)][string]$ChildDirectory,
  [Parameter(Mandatory=$true)][string]$ArtifactsDirectory,
  [string]$FlutterCommand='flutter',
  [string[]]$Phases=@('write_pending','replay_pending','offline_expire_pause',
    'verify_checking_reject','verify_blocked','apply_removal','verify_removed','cleanup')
)
$ErrorActionPreference='Stop'
$childRoot=(Resolve-Path -LiteralPath $ChildDirectory).Path
if(-not(Test-Path -LiteralPath (Join-Path $childRoot 'integration_test/access_storage_test.dart'))){
  throw 'Expected child integration source is missing'
}
$allowed=@('write_pending','replay_pending','offline_expire_pause',
  'verify_checking_reject','verify_blocked','apply_removal','verify_removed','cleanup')
if($Phases.Count -eq 0 -or @($Phases | Where-Object {$_ -notin $allowed}).Count){
  throw 'Unknown native storage phase'
}
New-Item -ItemType Directory -Path $ArtifactsDirectory -Force | Out-Null
$artifactRoot=(Resolve-Path -LiteralPath $ArtifactsDirectory).Path
Push-Location $childRoot
try {
  foreach($phase in $Phases){
    $log=Join-Path $artifactRoot "build-$phase.log"
    & $FlutterCommand build apk --debug --no-pub --target integration_test/access_storage_test.dart "--dart-define=ACCESS_STORE_PHASE=$phase" *> $log
    if($LASTEXITCODE -ne 0){throw "Build failed for $phase; inspect its local log"}
    $source=Join-Path $childRoot 'build/app/outputs/flutter-apk/app-debug.apk'
    $target=Join-Path $artifactRoot "$phase.apk"
    Copy-Item -LiteralPath $source -Destination $target
    $hash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output "$phase APK SHA256 $hash"
  }
} finally { Pop-Location }
