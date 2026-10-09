param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('negative','write_pending','replay_pending','offline_expire_pause',
    'verify_checking_reject','verify_blocked','apply_removal','verify_removed','cleanup')]
  [string]$Phase,
  [Parameter(Mandatory=$true)][string]$ChildDirectory,
  [Parameter(Mandatory=$true)][string]$ArtifactsDirectory,
  [string]$AdbCommand='adb',
  [string]$FlutterCommand='flutter',
  [ValidatePattern('^emulator-[0-9]+$')][string]$Serial='emulator-5580'
)
$ErrorActionPreference='Stop'
$package='com.aimanager.child.debug'
$avd=(& $AdbCommand -s $Serial emu avd name 2>$null) -join ' '
if($LASTEXITCODE -ne 0 -or $avd -notmatch '^AIManagerChildApi34\s+OK\s*$'){
  throw 'Refuse installation outside the dedicated AIManagerChildApi34 emulator'
}
$boot=(& $AdbCommand -s $Serial shell getprop sys.boot_completed 2>$null) -join ''
if($LASTEXITCODE -ne 0 -or $boot.Trim() -ne '1'){throw 'Owned emulator is not ready'}
$childRoot=(Resolve-Path -LiteralPath $ChildDirectory).Path
$artifactRoot=(Resolve-Path -LiteralPath $ArtifactsDirectory).Path
$binaryPhase=if($Phase -eq 'negative'){'replay_pending'}else{$Phase}
$apk=Join-Path $artifactRoot "$binaryPhase.apk"
if(-not(Test-Path -LiteralPath $apk)){throw 'Expected prebuilt fixture APK is missing'}
$log=Join-Path $artifactRoot "drive-$Phase.log"
Push-Location $childRoot
try {
  & $FlutterCommand drive --driver=test_driver/access_storage_driver.dart --target=integration_test/access_storage_test.dart "--use-application-binary=$apk" --keep-app-running --no-pub -d $Serial *> $log
  $driverExit=$LASTEXITCODE
} finally { Pop-Location }
$text=Get-Content -LiteralPath $log -Raw
$nativePid=((& $AdbCommand -s $Serial shell pidof $package 2>$null) -join '').Trim()
if($nativePid -notmatch '^[1-9][0-9]*$'){
  throw 'No unique native process to correlate; do not advance to another phase'
}
# Flutter console subscription can miss output emitted before it attaches.
# Read the actual Android buffer for this exact live PID, never another run.
$nativeLog=(& $AdbCommand -s $Serial shell logcat -d "--pid=$nativePid" -s flutter:I 2>$null) -join "`n"
$nativeLogExit=$LASTEXITCODE
$nativeLog | Set-Content -LiteralPath (Join-Path $artifactRoot "native-$Phase.log") -Encoding utf8
# Always stop this known debug process before reporting a driver failure.
& $AdbCommand -s $Serial shell am force-stop $package
if($LASTEXITCODE -ne 0){throw 'Could not stop the owned debug process'}
$remaining=((& $AdbCommand -s $Serial shell pidof $package 2>$null) -join '').Trim()
if($remaining){throw 'Native process still exists; do not advance'}
if($nativeLogExit -ne 0){throw 'Native PID log could not be read'}
if($Phase -eq 'negative'){
  if($driverExit -eq 0 -or "$text`n$nativeLog" -notmatch 'Requires oracle from the preceding native process'){
    throw 'Negative control did not fail for the required missing native state'
  }
  $result=@{phase=$Phase;pid=[int]$nativePid;expectedMissingStateFailure=$true}
}else{
  if($driverExit -ne 0){throw 'Native driver failed; inspect its local log'}
  $reports=[regex]::Matches($nativeLog,'ACCESS_STORAGE_RESULT (\{[^\r\n]*\})')
  if($reports.Count -ne 1){throw 'Native result marker is missing or ambiguous'}
  $result=$reports[0].Groups[1].Value | ConvertFrom-Json -AsHashtable
  if($result.phase -ne $Phase -or $result.pid -ne [int]$nativePid){
    throw 'Native phase/PID does not match the prebuilt APK and running process'
  }
}
$result.driverExitCode=$driverExit
$result.processStopped=$true
$result.nativeLogPidVerified=$true
$result.apkSha256=(Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactRoot "evidence-$Phase.json") -Encoding utf8
$result | ConvertTo-Json -Depth 8 -Compress
exit 0
