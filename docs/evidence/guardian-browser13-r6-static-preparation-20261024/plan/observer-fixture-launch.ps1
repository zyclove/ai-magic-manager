$ErrorActionPreference='Stop'
$taskDirectory=Join-Path $PSScriptRoot 'observer-fixture-host'
if(Test-Path -LiteralPath $taskDirectory){throw 'Single use fixture host'}
New-Item -ItemType Directory -Path $taskDirectory | Out-Null
$taskInfo=[Diagnostics.ProcessStartInfo]::new()
$taskInfo.FileName='C:\Python313\python.exe'
$taskInfo.UseShellExecute=$false
$taskInfo.CreateNoWindow=$true
$taskInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$taskInfo.WorkingDirectory=$PSScriptRoot
$taskInfo.RedirectStandardOutput=$true
$taskInfo.RedirectStandardError=$true
foreach($taskArgument in @('-I','-B','-S',(Join-Path $PSScriptRoot 'observer-fixture.py'))){$taskInfo.ArgumentList.Add($taskArgument)}
$taskHost=[Diagnostics.Process]::new()
$taskHost.StartInfo=$taskInfo
$taskWatch=[Diagnostics.Stopwatch]::StartNew()
$taskForced=$false
if(-not $taskHost.Start()){throw 'Task fixture host did not start'}
$taskHandle=$taskHost.Handle
$taskPid=$taskHost.Id
$taskCreation=[string]$taskHost.StartTime.ToUniversalTime().ToFileTimeUtc()
$taskTerminal=$taskHost.WaitForExit(10000)
$taskObserved=$taskWatch.Elapsed.TotalSeconds
if(-not $taskTerminal){$taskForced=$true;$taskHost.Kill();$taskTerminal=$taskHost.WaitForExit(1000)}
$taskCode=if($taskTerminal){$taskHost.ExitCode}else{$null}
$taskOutput=$taskHost.StandardOutput.ReadToEnd()
$taskErrors=$taskHost.StandardError.ReadToEnd()
$taskResult=[ordered]@{status='NOT_ACCEPTED';pid=$taskPid;creationFiletime=$taskCreation;terminal=$taskTerminal;forced=$taskForced;exitCode=$taskCode;firstObservedTerminalSeconds=$taskObserved;limitSeconds=10;nativeReadPathOnly=$true;sdkOrChromeStarted=$false}
if($taskTerminal -and -not $taskForced -and $taskCode -eq 0 -and $taskObserved -lt 10){$taskResult.status='OWNED_OBSERVER_FIXTURE_HOST_NATURAL_ZERO'}
[IO.File]::WriteAllText((Join-Path $taskDirectory 'stdout.json'),$taskOutput)
[IO.File]::WriteAllText((Join-Path $taskDirectory 'stderr.txt'),$taskErrors)
$taskResult|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $taskDirectory 'result.json') -Encoding utf8
$taskHost.Dispose()
$taskResult|ConvertTo-Json -Compress
if($taskResult.status -eq 'OWNED_OBSERVER_FIXTURE_HOST_NATURAL_ZERO'){exit 0}else{exit 1}
