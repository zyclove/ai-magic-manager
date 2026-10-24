param(
    [Parameter(Mandatory=$true)][string]$RootTerminalChunk,
    [Parameter(Mandatory=$true)][int]$RootActualExitCode,
    [Parameter(Mandatory=$true)][string]$PostTerminalChunk,
    [Parameter(Mandatory=$true)][int]$PostActualExitCode
)
$ErrorActionPreference='Stop'
$taskRepository='D:\codes\mobile\ai-manager'
$taskAnalysis=Join-Path $taskRepository '.cache\guardian-browser13-20261024-r2-manager-proof'
$taskPost=Join-Path $taskRepository '.cache\guardian-browser13-post-20261024-r2-manager-proof\post.json'
$taskOutput=Join-Path $taskAnalysis 'root-attempt'
$taskInventory=Join-Path $taskOutput 'post-process-inventory.json'
$taskRelease=Join-Path $taskOutput 'release.json'
if(Test-Path -LiteralPath $taskInventory){throw 'Single-use process inventory already exists'}
if(Test-Path -LiteralPath $taskRelease){throw 'Single-use release already exists'}
foreach($taskPath in @($taskRepository,(Join-Path $taskRepository '.cache'),$taskAnalysis,$taskOutput)){
    if((Get-Item -LiteralPath $taskPath).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked task path refused'}
}
$taskResult=Get-Content -Raw -LiteralPath (Join-Path $taskOutput 'result.json')|ConvertFrom-Json
$taskPostResult=Get-Content -Raw -LiteralPath $taskPost|ConvertFrom-Json
$taskHostResult=Get-Content -Raw -LiteralPath (Join-Path $taskAnalysis 'attempt\result.json')|ConvertFrom-Json
if($taskResult.sameHandleSignaled -isnot [bool] -or -not $taskResult.sameHandleSignaled -or
   $null -eq $taskResult.sameHandleCreationFiletime -or $null -eq $taskResult.sameHandleExitFiletime){throw 'Actual owned host terminal identity missing'}
$taskProcesses=@(Get-Process|Select-Object Id,ProcessName|Sort-Object Id)
$taskSdk=@($taskProcesses|Where-Object{$_.ProcessName -match '^(dart|dartaotruntime|flutter|flutter_tester|gen_snapshot|java|javaw|javac|mvn|gradle|go|gofmt|compile|link|vet|aapt2|asm|cgo|qemu-system-x86_64)$|\.test$'})
$taskUnknown=@($taskProcesses|Where-Object{[string]::IsNullOrWhiteSpace($_.ProcessName)-and $_.Id -notin @(0,4)})
$taskMemory=& C:\Python313\python.exe -I -B -c 'import psutil; print(psutil.virtual_memory().available)'
if($LASTEXITCODE -ne 0){throw 'Fresh memory probe failed'}
$taskProcesses|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $taskInventory -Encoding utf8
$taskConsistent=$RootActualExitCode -eq 0 -and $PostActualExitCode -eq 0 -and
    $taskResult.rootHostTerminalAccepted -is [bool] -and $taskResult.rootHostTerminalAccepted -and
    $taskPostResult.status -eq 'DERIVED_BROWSER13_CONSISTENT_PENDING_ROOT_RELEASE'
$taskOwnedPids=@($taskResult.hostPid,$taskHostResult.terminal.pid,$taskHostResult.workerReceipt.commandTerminalState.pid)|Where-Object{$null -ne $_}
$taskReleased=$taskSdk.Count -eq 0 -and $taskUnknown.Count -eq 0 -and
    @($taskProcesses|Where-Object{$_.Id -in $taskOwnedPids}).Count -eq 0
$taskReceipt=[ordered]@{
    status=if($taskConsistent -and $taskReleased){'GUARDIAN_BROWSER13_ACCEPTED_AND_WINDOW_RELEASED'}else{'BROWSER13_NOT_ACCEPTED_OR_RELEASE_INCOMPLETE'}
    atUtc=[DateTime]::UtcNow.ToString('o')
    sourceCommit='006ee45850c9b6b0f90570d9478bced3beb0e0fe'
    actualRootToolTerminalChunk=$RootTerminalChunk;actualRootToolExitCode=$RootActualExitCode
    actualPostToolTerminalChunk=$PostTerminalChunk;actualPostToolExitCode=$PostActualExitCode
    hostPid=$taskResult.hostPid;hostCreationFiletime=$taskResult.sameHandleCreationFiletime;hostExitFiletime=$taskResult.sameHandleExitFiletime
    fixedLauncherDisposedOwnHostHandle=$true;ownLiveSdkHandle=$false
    sdkCount=$taskSdk.Count;sdkProcesses=$taskSdk;unknownCount=$taskUnknown.Count
    knownOwnedPids=$taskOwnedPids
    availableRamBytes=[long]$taskMemory;disks=@(Get-PSDrive C,D|Select-Object Name,Free)
    processInventoryFile=$taskInventory;processInventorySha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $taskInventory).Hash.ToLowerInvariant()
    fixedPostFile=$taskPost;fixedPostSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $taskPost).Hash.ToLowerInvariant()
    resultConsistent=$taskConsistent;windowReleased=$taskReleased;testAccepted=($taskConsistent -and $taskReleased)
    applicationTestsRun=($taskHostResult.testsRun -is [bool] -and $taskHostResult.testsRun);deployed=$false;nextSdkGrant=$false
}
$taskReceipt|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $taskRelease -Encoding utf8
$taskReceipt|ConvertTo-Json -Depth 8 -Compress
if($taskConsistent -and $taskReleased){exit 0}else{exit 1}
