$ErrorActionPreference = 'Stop'
$repoPath = 'D:\codes\mobile\ai-manager'
$phasePath = Join-Path $repoPath '.cache\guardian-browser80-20261023-r2'
$processInventory = @(Get-Process)
$sdkInventory = @($processInventory | Where-Object { $_.ProcessName -match '^(dart|dartaotruntime|flutter|flutter_tester|gen_snapshot|java|javaw|javac|mvn|gradle|go|gofmt|compile|link|vet|aapt2|asm|cgo|qemu-system-x86_64)$|\.test$' })
$unknownInventory = @($processInventory | Where-Object { [string]::IsNullOrWhiteSpace($_.ProcessName) -and $_.Id -notin @(0,4) })
$availableBytes = [long](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1024
$diskInventory = @(Get-PSDrive C,D | Select-Object Name,Free)
$head = (& git -C $repoPath rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne '45950b88a270e2fded2409e333fb126851b6f861') { throw 'Source commit changed' }
if (Test-Path -LiteralPath (Join-Path $phasePath 'attempt')) { throw 'Single-use candidate already has an attempt' }
if ($sdkInventory.Count -ne 0 -or $unknownInventory.Count -ne 0 -or $availableBytes -lt 2147483648 -or @($diskInventory | Where-Object { $_.Free -lt 2147483648 }).Count -gt 0) { throw 'Fresh exclusive SDK/resource gate refused' }
$gate = [ordered]@{status='ROOT_BROWSER80_R2_FRESH_PRELAUNCH_GATE_PASSED';atUtc=[DateTime]::UtcNow.ToString('o');grant='guardian-browser80-r2-root-20261023';sourceCommit=$head;processCount=$processInventory.Count;sdkCount=$sdkInventory.Count;unknownProcessNameCount=$unknownInventory.Count;availableRamBytes=$availableBytes;disks=$diskInventory;previousStockPostSha256='1f9ea49610f2e29827f21603ea503af9d6d7802144916950f381ba7591ed1359'}
$gateFile = Join-Path $repoPath '.cache\guardian-browser80-r2-root-preflight-system-20261023.json'
if (Test-Path -LiteralPath $gateFile) { throw 'Fresh gate receipt already exists' }
$gate | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 -LiteralPath $gateFile
$gate | ConvertTo-Json -Depth 8 -Compress
& C:\Python313\python.exe -I -B -u (Join-Path $repoPath '.cache\guardian-browser80-r2-root-timing-20261023.py') anchor
if ($LASTEXITCODE -ne 0) { throw 'Independent prelaunch anchor failed' }
& C:\Python313\python.exe -I -B -u (Join-Path $phasePath 'controller.py') a9951961c2d4a933567bd38446228bb177cc469cdbe23a8d9b42b816f11857be
exit $LASTEXITCODE
