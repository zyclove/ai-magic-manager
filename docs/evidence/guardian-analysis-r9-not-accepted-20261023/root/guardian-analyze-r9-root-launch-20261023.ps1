$ErrorActionPreference='Stop'
$repoPath='D:\codes\mobile\ai-manager'
$candidatePath=Join-Path $repoPath '.cache\guardian-analyze-20261023-r9'
$all=@(Get-Process)
$sdk=@($all|Where-Object{$_.ProcessName -match '^(dart|dartaotruntime|flutter|flutter_tester|gen_snapshot|java|javaw|javac|mvn|gradle|go|gofmt|compile|link|vet|aapt2|asm|cgo|qemu-system-x86_64)$|\.test$'})
$unknown=@($all|Where-Object{[string]::IsNullOrWhiteSpace($_.ProcessName)-and $_.Id -notin @(0,4)})
$availableText=& C:\Python313\python.exe -I -B -c 'import psutil; print(psutil.virtual_memory().available)'
if($LASTEXITCODE -ne 0){throw 'Fresh memory read failed'}
$available=[long]$availableText
$disks=@(Get-PSDrive C,D|Select-Object Name,Free)
$head=(& git -C $repoPath rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $head -ne 'a2b5ca6ef2398397e4208065090b7c1d65992358'){throw 'Current source changed'}
if($sdk.Count -or $unknown.Count -or $available -lt 2147483648 -or @($disks|Where-Object{$_.Free -lt 2147483648}).Count){throw 'Fresh exclusive SDK/resource gate refused'}
if(Test-Path -LiteralPath (Join-Path $candidatePath 'attempt')){throw 'Candidate already consumed'}
$gate=[ordered]@{status='ROOT_R9_FRESH_PRELAUNCH_GATE_PASSED';atUtc=[DateTime]::UtcNow.ToString('o');grant='guardian-analyze-r9-root-20261023';sourceCommit=$head;sdkCount=$sdk.Count;unknownProcessNameCount=$unknown.Count;availableRamBytes=$available;memorySource='existing psutil, read-only';processCount=$all.Count;disks=$disks}
$gatePath=Join-Path $repoPath '.cache\guardian-analyze-r9-root-preflight-system-20261023.json'
if(Test-Path -LiteralPath $gatePath){throw 'Preflight receipt already exists'}
$gate|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $gatePath -Encoding utf8
$gate|ConvertTo-Json -Depth 8 -Compress
& C:\Python313\python.exe -I -B -u (Join-Path $repoPath '.cache\guardian-analyze-r9-root-timing-20261023.py') anchor
if($LASTEXITCODE -ne 0){throw 'Independent QPC anchor failed'}
& C:\Python313\python.exe -I -B -u (Join-Path $candidatePath 'controller.py') 8f106238ac96a77822fba2bdb596aba33aa27878ffc19a6e0ddd566ed863eecf
exit $LASTEXITCODE
