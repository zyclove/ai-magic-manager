$ErrorActionPreference='Stop'
$taskRepository='D:\codes\mobile\ai-manager'
$analysisDirectory=Join-Path $taskRepository '.cache\guardian-browser13-20261024-r5-typed-finder-current3cf'
$proposalFile=Join-Path $analysisDirectory 'proposal.json'
$grantFile=Join-Path $analysisDirectory 'root-sdk-grant.json'
$rootAttempt=Join-Path $analysisDirectory 'root-attempt'
$expectedProposalSha='1fa692d44a033e8ed6060e0b20803fcf565875177388807be17c3213a006cf02'
$expectedCommit='3cfbf535099ade86234661556d9e92db9069743a'
if($expectedProposalSha -notmatch '^[a-f0-9]{64}$'){throw 'Static launcher is disabled pending exact reviewed proposal'}
if($PSVersionTable.PSVersion.ToString() -ne '7.6.5'){throw 'Fixed reviewed PowerShell runtime required'}
foreach($taskPath in @($taskRepository,(Join-Path $taskRepository '.cache'),$analysisDirectory,$rootAttempt)){
    if((Test-Path -LiteralPath $taskPath)-and((Get-Item -LiteralPath $taskPath).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked task path refused'}
}
if(Test-Path -LiteralPath $rootAttempt){throw 'Root analysis attempt is single use'}
if(Test-Path -LiteralPath (Join-Path $analysisDirectory 'attempt')){throw 'Worker attempt already exists'}
if((Get-FileHash -LiteralPath $proposalFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedProposalSha){throw 'Proposal drift'}
$proposal=Get-Content -Raw -LiteralPath $proposalFile|ConvertFrom-Json
$grant=Get-Content -Raw -LiteralPath $grantFile|ConvertFrom-Json
$launcherSha=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
if($grant.status -ne 'ROOT_APPROVED_SINGLE_FIXED_TEST' -or $grant.proposalSha256 -ne $expectedProposalSha -or
   $grant.launcherSha256 -ne $launcherSha -or $grant.sourceCommit -ne $expectedCommit -or $grant.sdkCallsAllowed -ne 1){throw 'Fixed Root analysis grant mismatch'}
if($proposal.schemaVersion -ne 1 -or $proposal.phase -ne 'guardian-browser13' -or
   $proposal.sourceCommit -ne $expectedCommit -or $proposal.pythonExecutable -ne 'C:/Python313/python.exe'){throw 'Fixed analysis scope mismatch'}
if($proposal.budgets.outer -ne 180 -or $proposal.budgets.working -ne 174 -or $proposal.budgets.worker -ne 165 -or
   $proposal.budgets.command -ne 135 -or $proposal.budgets.commandCleanup -ne 140 -or $proposal.budgets.postflightReserve -ne 25){throw 'Budget drift'}
$candidateNames=@($proposal.candidateFiles|ForEach-Object{[string]$_.path}|Sort-Object)
if(($candidateNames -join '|') -ne 'analysis-host.py|owned_chrome_evidence.py|owned_job.py|process-inventory.ps1|reporter_contract.py|worker.py'){throw 'Unexpected analysis candidate set'}
function Test-AnalysisPins {
    foreach($analysisPin in @($proposal.candidateFiles)+@($proposal.runtimePins)){
        $analysisPinPath=if([IO.Path]::IsPathRooted([string]$analysisPin.path)){[string]$analysisPin.path}else{Join-Path $analysisDirectory ([string]$analysisPin.path)}
        $analysisPinItem=Get-Item -LiteralPath $analysisPinPath
        if(($analysisPinItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
           $analysisPinItem.Length -ne $analysisPin.bytes -or
           (Get-FileHash -LiteralPath $analysisPinPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $analysisPin.sha256){throw 'Candidate/runtime drift'}
    }
}
Test-AnalysisPins
$currentHead=& 'C:\Program Files\Git\cmd\git.exe' -c ("safe.directory=" + $taskRepository.Replace('\','/')) -C $taskRepository rev-parse HEAD
if($LASTEXITCODE -ne 0 -or $currentHead -ne $expectedCommit){throw 'Current source commit changed'}
$analysisProcesses=@(Get-Process)
$analysisSdk=@($analysisProcesses|Where-Object{$_.ProcessName -match '^(dart|dartaotruntime|flutter|flutter_tester|gen_snapshot|java|javaw|javac|mvn|gradle|go|gofmt|compile|link|vet|aapt2|asm|cgo|qemu-system-x86_64)$|\.test$'})
$analysisUnknown=@($analysisProcesses|Where-Object{[string]::IsNullOrWhiteSpace($_.ProcessName)-and $_.Id -notin @(0,4)})
$analysisMemory=& C:\Python313\python.exe -I -B -c 'import psutil; print(psutil.virtual_memory().available)'
if($LASTEXITCODE -ne 0){throw 'Fresh memory probe failed'}
$analysisDisks=@(Get-PSDrive C,D|Select-Object Name,Free)
if($analysisSdk.Count -or $analysisUnknown.Count -or [long]$analysisMemory -lt 2147483648 -or
   @($analysisDisks|Where-Object{$_.Free -lt 2147483648}).Count){throw 'Fresh exclusive resource gate refused before analysis'}
New-Item -ItemType Directory -Path $rootAttempt|Out-Null
$rootTemp=Join-Path $rootAttempt 'tmp'
New-Item -ItemType Directory -Path $rootTemp|Out-Null
$rootReceipt=[ordered]@{
    status='ROOT_FIXED_BROWSER13_STARTED';atUtc=[DateTime]::UtcNow.ToString('o');sourceCommit=$expectedCommit
    proposalSha256=$expectedProposalSha;launcherSha256=$launcherSha;sdkCount=$analysisSdk.Count;unknownCount=$analysisUnknown.Count
    availableRamBytes=[long]$analysisMemory;disks=$analysisDisks;maximumHostSeconds=180;reusedBudget=$false
    grant='guardian-browser13-current-head3cfbf535-single-sdk-call';applicationTestsRequested=$true
}
$rootReceipt|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $rootAttempt 'preflight.json') -Encoding utf8
$startInfo=[Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName='C:\Python313\python.exe'
$startInfo.UseShellExecute=$false
$startInfo.CreateNoWindow=$true
$startInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$startInfo.WorkingDirectory=$analysisDirectory
foreach($argument in @('-I','-B','-u',(Join-Path $analysisDirectory 'analysis-host.py'),'analyze',$expectedProposalSha)){$startInfo.ArgumentList.Add($argument)}
$startInfo.Environment.Clear()
foreach($environmentName in @('SystemRoot','WINDIR','COMSPEC','USERPROFILE','LOCALAPPDATA','APPDATA','ProgramFiles','ProgramFiles(x86)','ProgramData','NUMBER_OF_PROCESSORS')){
    $environmentValue=[Environment]::GetEnvironmentVariable($environmentName,'Process')
    if($null -ne $environmentValue){$startInfo.Environment[$environmentName]=$environmentValue}
}
$startInfo.Environment['PATH']='C:\Windows\System32;C:\Program Files\Git\cmd;D:\softwares\flutter\bin\cache\dart-sdk\bin'
$startInfo.Environment['TEMP']=$rootTemp
$startInfo.Environment['TMP']=$rootTemp
$ownedHost=[Diagnostics.Process]::new()
$ownedHost.StartInfo=$startInfo
$hostStarted=$false;$hostSignaled=$false;$rootForced=$false;$cleanupAttempted=$false
$hostId=$null;$hostCreation=$null;$hostExit=$null;$hostCode=$null;$firstSignaled=$null;$failure=$null
$rootWatch=[Diagnostics.Stopwatch]::StartNew()
try {
    if(-not $ownedHost.Start()){throw 'Owned analysis host creation failed'}
    $hostStarted=$true
    $retainedHostHandle=$ownedHost.Handle
    $hostId=$ownedHost.Id
    $hostCreation=[string]$ownedHost.StartTime.ToUniversalTime().ToFileTimeUtc()
    while($true){
        $remaining=180-$rootWatch.Elapsed.TotalSeconds
        $boundedWait=[int][Math]::Max(0,[Math]::Min(50,[Math]::Floor($remaining*1000)))
        $signaled=$ownedHost.WaitForExit($boundedWait)
        $observed=$rootWatch.Elapsed.TotalSeconds
        if($signaled){$hostSignaled=$true;$firstSignaled=$observed;break}
        if($observed -ge 180){
            $rootForced=$true;$cleanupAttempted=$true
            $ownedHost.Kill()
            $hostSignaled=$ownedHost.WaitForExit(2000)
            if(-not $hostSignaled){throw 'Exact owned host did not terminate after emergency cleanup'}
            break
        }
    }
    if($hostSignaled){$hostCode=$ownedHost.ExitCode;$hostExit=[string]$ownedHost.ExitTime.ToUniversalTime().ToFileTimeUtc()}
} catch {
    $failure=$_.Exception.GetType().FullName+': '+$_.Exception.Message
    if($hostStarted -and -not $cleanupAttempted){
        $rootForced=$true;$cleanupAttempted=$true
        try {$ownedHost.Kill();$hostSignaled=$ownedHost.WaitForExit(2000)} catch {$failure+='; exact-host cleanup: '+$_.Exception.Message}
        if($hostSignaled){$hostCode=$ownedHost.ExitCode;$hostExit=[string]$ownedHost.ExitTime.ToUniversalTime().ToFileTimeUtc()}
    }
} finally {$ownedHost.Dispose()}
$pinsAfter=$false
try {Test-AnalysisPins;$pinsAfter=$true} catch {$failure+='; post pins: '+$_.Exception.Message}
$timely=$hostSignaled -and $null -ne $firstSignaled -and $firstSignaled -lt 180
$accepted=$null -eq $failure -and -not $rootForced -and $timely -and $hostCode -eq 0 -and $pinsAfter
$rootReceipt.status=if($accepted){'ROOT_HOST_TERMINAL_PENDING_INDEPENDENT_BROWSER13_POST'}else{'ROOT_HOST_BROWSER13_NOT_ACCEPTED'}
$rootReceipt.hostPid=$hostId
$rootReceipt.sameHandleCreationFiletime=$hostCreation
$rootReceipt.sameHandleExitFiletime=$hostExit
$rootReceipt.sameHandleSignaled=$hostSignaled
$rootReceipt.actualHostExitCode=$hostCode
$rootReceipt.firstWaitSignaledElapsedSeconds=$firstSignaled
$rootReceipt.rootForcedOwnHost=$rootForced
$rootReceipt.emergencyCleanupAttempted=$cleanupAttempted
$rootReceipt.failure=$failure
$rootReceipt.hostTimelyAgainstOriginalRootAnchor=$timely
$rootReceipt.candidateRuntimePinsMatchAfter=$pinsAfter
$rootReceipt.rootHostTerminalAccepted=$accepted
$rootReceipt.testAccepted=$false
$rootReceipt.rootElapsedBeforeReceiptSeconds=$rootWatch.Elapsed.TotalSeconds
$rootReceipt|ConvertTo-Json -Depth 9|Set-Content -LiteralPath (Join-Path $rootAttempt 'result.json') -Encoding utf8
$rootReceipt|ConvertTo-Json -Depth 9 -Compress
if($accepted){exit 0}else{exit 1}
