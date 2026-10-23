param([Parameter(Mandatory=$true)][ValidateSet('natural-zero','natural-nonzero','deadline','nested-owned-child')][string]$Case)
$ErrorActionPreference='Stop'
$repoPath='D:\codes\mobile\ai-manager'
$candidatePath=Join-Path $repoPath '.cache\guardian-supervisor-20261023-r1'
$outputRoot=Join-Path $repoPath '.cache\guardian-supervisor-root-qualification-20261023-r1'
$casePath=Join-Path $outputRoot $Case
$manifestSha='f6f0b42cb8277399eeb7b5f01e6c36b8e9ad63ef57e4800bf98aa8f6cba7061d'
foreach($directory in @($repoPath,(Join-Path $repoPath '.cache'),$candidatePath,$outputRoot)){
    if((Test-Path -LiteralPath $directory) -and ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked task path refused'}
}
if(Test-Path -LiteralPath $casePath){throw 'Root case is single-use'}
if(Test-Path -LiteralPath (Join-Path $candidatePath "qualification-attempts\$Case")){throw 'Candidate case already consumed'}
$manifestPath=Join-Path $candidatePath 'manifest.json'
if((Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant() -ne $manifestSha){throw 'Manifest drift'}
$manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
function Check-Pins {
    foreach($pin in @($manifest.candidateFiles)+@($manifest.runtimePins)){
        $pinPath=if($pin.absolute){[string]$pin.path}else{Join-Path $candidatePath $pin.path}
        $item=Get-Item -LiteralPath $pinPath
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne $pin.bytes -or (Get-FileHash -Algorithm SHA256 -LiteralPath $pinPath).Hash.ToLowerInvariant() -ne $pin.sha256){throw 'Candidate/runtime drift'}
    }
}
Check-Pins
$all=@(Get-Process)
$sdk=@($all|Where-Object{$_.ProcessName -match '^(dart|dartaotruntime|flutter|flutter_tester|gen_snapshot|java|javaw|javac|mvn|gradle|go|gofmt|compile|link|vet|aapt2|asm|cgo|qemu-system-x86_64)$|\.test$'})
$unknown=@($all|Where-Object{[string]::IsNullOrWhiteSpace($_.ProcessName)-and $_.Id -notin @(0,4)})
$memory=& C:\Python313\python.exe -I -B -c 'import psutil; print(psutil.virtual_memory().available)'
if($LASTEXITCODE -ne 0){throw 'Fresh memory unavailable'}
$disks=@(Get-PSDrive C,D|Select-Object Name,Free)
if($sdk.Count -or $unknown.Count -or [long]$memory -lt 2147483648 -or @($disks|Where-Object{$_.Free -lt 2147483648}).Count){throw 'Fresh exclusive resource gate refused; no qualification started'}
$definition=Get-Content -Raw -LiteralPath (Join-Path $candidatePath 'qualification-cases.json')|ConvertFrom-Json
$caseDefinition=$definition.cases.$Case
$maximumSeconds=[double]$caseDefinition.workSeconds+[double]$caseDefinition.cleanupSeconds
New-Item -ItemType Directory -Path $casePath -Force|Out-Null
$tempPath=Join-Path $casePath 'tmp'
New-Item -ItemType Directory -Path $tempPath|Out-Null
$receipt=[ordered]@{status='ROOT_QUALIFICATION_STARTED';case=$Case;grant='guardian-supervisor-fixed-qualification-root-20261023-r1';atUtc=[DateTime]::UtcNow.ToString('o');sdkCount=$sdk.Count;unknownCount=$unknown.Count;availableRamBytes=[long]$memory;disks=$disks;manifestSha256=$manifestSha;maximumHostSeconds=$maximumSeconds;reusedBudget=$false;scope='One fixed no-SDK qualification case; no real controller.'}
$receipt|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $casePath 'preflight.json') -Encoding utf8
$startInfo=[Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName='C:\Python313\python.exe'
$startInfo.UseShellExecute=$false
$startInfo.CreateNoWindow=$true
$startInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$startInfo.WorkingDirectory=$candidatePath
foreach($argument in @('-I','-B','-u',(Join-Path $candidatePath 'supervisor.py'),'qualify',$Case,$manifestSha)){$startInfo.ArgumentList.Add($argument)}
$startInfo.Environment['TEMP']=$tempPath
$startInfo.Environment['TMP']=$tempPath
$ownedProcess=[Diagnostics.Process]::new()
$ownedProcess.StartInfo=$startInfo
$started=$false
$firstSignaledSeconds=$null
$rootForced=$false
$cleanupAttempted=$false
$hostExitCode=$null
$hostExitFiletime=$null
$hostCreationFiletime=$null
$failure=$null
$hostId=$null
$watch=[Diagnostics.Stopwatch]::StartNew()
try {
    if(-not $ownedProcess.Start()){throw 'Owned host creation failed'}
    $started=$true
    # Force acquisition and retain this exact process handle before waiting.
    $retainedHandle=$ownedProcess.Handle
    $hostId=$ownedProcess.Id
    $hostCreationFiletime=[string]$ownedProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
    while($true){
        $remaining=$maximumSeconds-$watch.Elapsed.TotalSeconds
        $milliseconds=[int][Math]::Max(0,[Math]::Min(50,[Math]::Floor($remaining*1000)))
        $signaled=$ownedProcess.WaitForExit($milliseconds)
        $observed=$watch.Elapsed.TotalSeconds
        if($signaled){$firstSignaledSeconds=$observed;break}
        if($observed -ge $maximumSeconds){
            $rootForced=$true
            $cleanupAttempted=$true
            $ownedProcess.Kill()
            if(-not $ownedProcess.WaitForExit(2000)){throw 'Owned host did not terminate after exact-handle cleanup'}
            break
        }
    }
    $hostExitCode=$ownedProcess.ExitCode
    $hostExitFiletime=[string]$ownedProcess.ExitTime.ToUniversalTime().ToFileTimeUtc()
} catch {
    $failure=$_.Exception.GetType().FullName+': '+$_.Exception.Message
    if($started -and -not $cleanupAttempted){
        $rootForced=$true
        $cleanupAttempted=$true
        try {
            $ownedProcess.Kill()
            [void]$ownedProcess.WaitForExit(2000)
        } catch {
            $failure+='; own-host cleanup: '+$_.Exception.Message
        }
    }
} finally {
    $ownedProcess.Dispose()
}
Check-Pins
$observationPath=Join-Path $candidatePath "qualification-attempts\$Case\observation.json"
$observation=if(Test-Path -LiteralPath $observationPath){Get-Content -Raw -LiteralPath $observationPath|ConvertFrom-Json}else{$null}
$timely=$null -ne $firstSignaledSeconds -and $firstSignaledSeconds -lt $maximumSeconds
$accepted=$null -eq $failure -and -not $rootForced -and $timely -and $hostExitCode -eq 0 -and $observation.case -eq $Case -and $observation.expectedOutcomeObservedBeforeOutput -eq $true -and $observation.candidateAndRuntimePinsMatchAfter -eq $true -and $observation.terminal.activeProcesses -eq 0 -and $observation.terminal.exitCode -eq $caseDefinition.expectedExitCode -and $observation.forcedCleanupRequested -eq $caseDefinition.expectsForcedCleanup -and $observation.sdkCalls -eq 0 -and $observation.realControllerInvoked -eq $false
$receipt.status=if($accepted){'FIXED_CASE_EXPECTED_OUTCOME_AND_ACTUAL_HOST_EXIT_OBSERVED'}else{'FIXED_CASE_QUALIFICATION_NOT_ACCEPTED'}
$receipt.hostPid=$hostId
$receipt.sameHandleCreationFiletimeUtcDomain=$hostCreationFiletime
$receipt.sameHandleExitFiletimeUtcDomain=$hostExitFiletime
$receipt.firstWaitSignaledElapsedSeconds=$firstSignaledSeconds
$receipt.hostActualExitCode=$hostExitCode
$receipt.rootForcedOwnHost=$rootForced
$receipt.rootEmergencyCleanupAttempted=$cleanupAttempted
$receipt.failure=$failure
$receipt.hostTimelyAgainstEarlierRootAnchor=$timely
$receipt.rawObservationPath=$observationPath
$receipt.postPinsMatch=$true
$receipt.qualificationAccepted=$accepted
$receipt.analysisAccepted=$false
$receipt.realControllerStarted=$false
$receipt.rootElapsedBeforeReceiptSeconds=$watch.Elapsed.TotalSeconds
$receipt|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $casePath 'result.json') -Encoding utf8
$receipt|ConvertTo-Json -Depth 10 -Compress
if($accepted){exit 0}else{exit 1}
