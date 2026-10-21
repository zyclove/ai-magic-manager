#Requires -Version 7.0
<#
.SYNOPSIS
Creates a secret-free, read-only Android preparation report for family acceptance.
.DESCRIPTION
Verifies a specified APK with fixed Android SDK tools and compares its public
certificate digest. Device inventory uses only the local ADB server's bounded
host:devices-l protocol; it never starts ADB, installs or starts an application.
Preparation is not real SMS, WeChat, device or sales acceptance. Exit 2 means a
report was created with real acceptance blocked; exit 1 means no safe report.
#>
[CmdletBinding()]
param(
    [string]$EnvironmentId = 'family-cn-pilot',
    [string]$ParentApk = '',
    [string]$ExpectedCertificateSha256 = '',
    [string]$ParentWechatAppId = '',
    [string]$AndroidSdkDirectory = '',
    [string]$BuildToolsVersion = '35.0.0',
    [string]$OutputPath = ''
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function AssertNoLinks([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Linked paths are not accepted.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Invoke-BoundedSdkTool([string]$Executable, [string[]]$Arguments) {
    # Never invoke a shell or echo the tool output, file arguments or exceptions.
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { return @{success=$false; output=''; reason='SDK_TOOL_UNAVAILABLE'} }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $stdout = [Text.StringBuilder]::new()
        $buffers = @([char[]]::new(2048), [char[]]::new(2048))
        $readers = @($process.StandardOutput, $process.StandardError)
        $pending = @($readers[0].ReadAsync($buffers[0],0,2048), $readers[1].ReadAsync($buffers[1],0,2048))
        $total = 0
        while ($null -ne $pending[0] -or $null -ne $pending[1] -or -not $process.HasExited) {
            if ($watch.ElapsedMilliseconds -gt 10000) { throw 'SDK tool deadline exceeded.' }
            foreach ($index in 0,1) {
                if ($null -eq $pending[$index] -or -not $pending[$index].IsCompleted) { continue }
                $count = $pending[$index].GetAwaiter().GetResult()
                $total += $count
                if ($total -gt 65536) { throw 'SDK tool output limit exceeded.' }
                if ($count -eq 0) { $pending[$index]=$null; continue }
                if ($index -eq 0) { [void]$stdout.Append($buffers[$index],0,$count) }
                $pending[$index]=$readers[$index].ReadAsync($buffers[$index],0,2048)
            }
            if ($null -ne $pending[0] -or $null -ne $pending[1] -or -not $process.HasExited) {
                [Threading.Thread]::Sleep(10)
            }
        }
        return @{success=($process.ExitCode -eq 0); output=$stdout.ToString(); reason='SDK_TOOL_REJECTED'}
    } catch {
        return @{success=$false; output=''; reason='SDK_TOOL_FAILED_OR_LIMIT_EXCEEDED'}
    } finally {
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
        $process.Dispose()
    }
}

function Convert-AdbInventory([string]$Body) {
    # Raw serials exist only while parsing; aliases are new on every invocation.
    $items = [Collections.Generic.List[object]]::new()
    foreach ($line in ($Body -split "`n")) {
        $line=$line.TrimEnd("`r")
        if (-not $line) { continue }
        if ($items.Count -ge 64 -or $line -cnotmatch '^([^\s]{1,512})[ \t]+(device|offline|unauthorized|recovery|sideload|bootloader|no permissions)(?:[ \t]+.*)?$') {
            throw 'ADB inventory format is not recognized.'
        }
        $serial=$Matches[1]; $state=$Matches[2]
        $transport=if($serial.StartsWith('emulator-', [StringComparison]::Ordinal)){'emulator'}elseif($serial.Contains(':')){'network'}else{'usb-or-unknown'}
        $items.Add([ordered]@{deviceAlias=('android-'+[Guid]::NewGuid().ToString('N').Substring(0,12));
            state=$state;transport=$transport;productMetadataPresent=($line -cmatch '(?:^|\s)(?:product|model|device):')})
    }
    return ,$items.ToArray()
}

function Read-ExactAdbBytes([IO.Stream]$Stream, [int]$Count, [Diagnostics.Stopwatch]$Deadline) {
    $bytes=[byte[]]::new($Count)
    $offset=0
    while ($offset -lt $Count) {
        $remaining=3000-$Deadline.ElapsedMilliseconds
        if ($remaining -le 0) { throw 'ADB inventory deadline exceeded.' }
        $Stream.ReadTimeout=[int][Math]::Min(1000,$remaining)
        $read=$Stream.Read($bytes,$offset,$Count-$offset)
        if ($read -eq 0) { throw 'Incomplete ADB response.' }
        $offset += $read
    }
    return ,$bytes
}

function Read-LocalAdbInventory {
    $client=[Net.Sockets.TcpClient]::new()
    $deadline=[Diagnostics.Stopwatch]::StartNew()
    try {
        # A fixed local read request avoids adb CLI auto-start and remote socket env.
        $connection=$client.ConnectAsync('127.0.0.1',5037)
        if (-not $connection.Wait(1000)) { throw 'Local ADB unavailable.' }
        [void]$connection.GetAwaiter().GetResult()
        $stream=$client.GetStream(); $stream.ReadTimeout=1000; $stream.WriteTimeout=1000
        $request=[Text.Encoding]::ASCII.GetBytes('000ehost:devices-l')
        $stream.Write($request,0,$request.Length)
        $status=[Text.Encoding]::ASCII.GetString((Read-ExactAdbBytes $stream 4 $deadline))
        if ($status -cne 'OKAY') { throw 'Local ADB rejected inventory.' }
        $lengthText=[Text.Encoding]::ASCII.GetString((Read-ExactAdbBytes $stream 4 $deadline))
        if ($lengthText -cnotmatch '^[0-9a-fA-F]{4}$') { throw 'Invalid ADB response length.' }
        $length=[Convert]::ToInt32($lengthText,16)
        if ($length -gt 32768) { throw 'ADB response exceeds inventory limit.' }
        $body=$utf8.GetString((Read-ExactAdbBytes $stream $length $deadline))
        $devices=Convert-AdbInventory $body
        return @{available=$true; reason='LOCAL_ADB_INVENTORY_READ'; devices=$devices}
    } catch {
        return @{available=$false; reason='LOCAL_ADB_UNAVAILABLE_OR_INVALID'; devices=@()}
    } finally { $client.Dispose() }
}

$apkReadLock=$null
try {
    if ($EnvironmentId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{2,63}$' -or
        $BuildToolsVersion -cnotmatch '^\d+\.\d+\.\d+(?:-rc\d+)?$') { throw 'Invalid local configuration.' }
    if (-not $OutputPath) {
        $OutputPath=Join-Path $repository ('.cache/family-provider-acceptance-20261017-r3/android/preflight-'+[Guid]::NewGuid().ToString('N')+'.json')
    }
    $output=[IO.Path]::GetFullPath($OutputPath,$repository)
    $inside=$false
    foreach ($root in @('.cache','.local')) {
        $allowed=[IO.Path]::GetFullPath((Join-Path $repository $root))+[IO.Path]::DirectorySeparatorChar
        if ($output.StartsWith($allowed,$comparison)) { $inside=$true; break }
    }
    if (-not $inside) { throw 'Output is outside the local evidence directory.' }
    AssertNoLinks $output
    if (Test-Path -LiteralPath $output) { throw 'Existing evidence cannot be overwritten.' }
    $apkPath=$null
    if ($ParentApk) { $apkPath=[IO.Path]::GetFullPath($ParentApk,$repository); AssertNoLinks $apkPath }
    if (-not $AndroidSdkDirectory) {
        $AndroidSdkDirectory=if($env:ANDROID_SDK_ROOT){$env:ANDROID_SDK_ROOT}else{$env:ANDROID_HOME}
    }
    $sdkToolsPresent=$false; $signerJar=$null; $aapt=$null; $adbPresent=$false
    if ($AndroidSdkDirectory) {
        $sdk=[IO.Path]::GetFullPath($AndroidSdkDirectory,$repository); AssertNoLinks $sdk
        $tools=Join-Path $sdk ('build-tools/'+$BuildToolsVersion)
        $signerJar=Join-Path $tools 'lib/apksigner.jar'
        $aapt=Join-Path $tools $(if($IsWindows){'aapt.exe'}else{'aapt'})
        $adb=Join-Path $sdk $(if($IsWindows){'platform-tools/adb.exe'}else{'platform-tools/adb'})
        foreach($file in @($signerJar,$aapt,$adb)){ AssertNoLinks $file }
        $adbPresent=Test-Path -LiteralPath $adb -PathType Leaf
        $sdkToolsPresent=(Test-Path -LiteralPath $signerJar -PathType Leaf) -and (Test-Path -LiteralPath $aapt -PathType Leaf) -and $adbPresent
    }
    $java=Get-Command java -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $sdkToolsPresent=$sdkToolsPresent -and $null -ne $java
    $artifact=[ordered]@{present=$false; validFormat=$false; sha256=$null; bytes=$null;
        signatureVerified=$false; certificateSha256=$null; debugCertificateDetected=$null;
        manifestVerified=$false; applicationId=$null; debuggable=$null}
    if ($apkPath -and (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
        $artifact.present=$true
        $artifact.bytes=(Get-Item -LiteralPath $apkPath).Length
        if ($artifact.bytes -gt 0 -and $artifact.bytes -le 536870912) {
            try {
                # Keep the inspected Windows file read-only across both SDK commands.
                $apkReadLock=[IO.File]::Open($apkPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                if ($apkReadLock.Length -ne $artifact.bytes) { throw 'APK changed before inspection.' }
                $artifact.sha256=(Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
                $zip=[IO.Compression.ZipFile]::OpenRead($apkPath)
                try {
                    $names=@($zip.Entries | ForEach-Object FullName)
                    $artifact.validFormat=(@($names | Where-Object {$_ -ceq 'AndroidManifest.xml'}).Count -eq 1) -and
                        (@($names | Where-Object {$_ -ceq 'classes.dex'}).Count -eq 1)
                } finally { $zip.Dispose() }
            } catch { }
        }
    }
    if ($artifact.validFormat -and $sdkToolsPresent) {
        $signature=Invoke-BoundedSdkTool $java.Source @('-jar',$signerJar,'verify','--print-certs',$apkPath)
        if ($signature.success) {
            $certificateMatches=[regex]::Matches($signature.output,'(?m)^Signer #[0-9]+ certificate SHA-256 digest: ([a-fA-F0-9]{64})\r?$')
            $subjectMatches=[regex]::Matches($signature.output,'(?m)^Signer #1 certificate DN: [^\r\n]+\r?$')
            if ($certificateMatches.Count -eq 1 -and $subjectMatches.Count -eq 1 -and $certificateMatches[0].Value.StartsWith('Signer #1 ')) {
                $artifact.signatureVerified=$true
                $artifact.certificateSha256=$certificateMatches[0].Groups[1].Value.ToLowerInvariant()
                $artifact.debugCertificateDetected=$subjectMatches[0].Value -match '(?i)(?:^|[, :])CN\s*=\s*Android Debug(?:[,\r\n]|$)'
            }
        }
        $manifest=Invoke-BoundedSdkTool $aapt @('dump','badging',$apkPath)
        if ($manifest.success) {
            $packageMatches=[regex]::Matches($manifest.output,"(?m)^package: name='([A-Za-z0-9_.]{1,200})' versionCode='[0-9]{1,10}' versionName='[^'\r\n]{0,100}'[^\r\n]*\r?$")
            if ($packageMatches.Count -eq 1) {
                $artifact.manifestVerified=$true
                $artifact.applicationId=$packageMatches[0].Groups[1].Value
                $artifact.debuggable=$manifest.output -cmatch '(?m)^application-debuggable\r?$'
            }
        }
    }
    $devices=Read-LocalAdbInventory
    $authorized=@($devices.devices | Where-Object { $_.state -ceq 'device' }).Count
    $nonEmulator=@($devices.devices | Where-Object { $_.state -ceq 'device' -and $_.transport -cne 'emulator' }).Count
    $expectedValid=$ExpectedCertificateSha256 -cmatch '^[a-fA-F0-9]{64}$'
    $appIdFormat=$ParentWechatAppId -cmatch '^wx[0-9a-fA-F]{16}$'
    $checks=[Collections.Generic.List[object]]::new()
    function AddCheck([string]$Id,[string]$Label,[string]$Stage,[bool]$Passed,[string]$Reason,[string]$Action) {
        $checks.Add([ordered]@{id=$Id;label=$Label;stage=$Stage;status=$(if($Passed){'PASS'}else{'BLOCKED'});
            reasonCode=$(if($Passed){'LOCAL_PREPARATION_CHECK_PASSED'}else{$Reason});action=$Action})
    }
    AddCheck 'ANDROID_SDK_TOOLS' '安卓检查工具' '准备核对' $sdkToolsPresent 'SDK_TOOLS_UNAVAILABLE' '准备固定版本 SDK build-tools、platform-tools 和 Java；工具不自动安装。'
    AddCheck 'APK_ARTIFACT' '家长安装包版本' '准备核对' $artifact.validFormat 'APK_UNAVAILABLE_OR_INVALID' '选择本次正式家长 APK，工具只读取文件并登记摘要。'
    AddCheck 'EXPECTED_CERTIFICATE' '正式证书登记' '准备核对' $expectedValid 'EXPECTED_CERTIFICATE_REQUIRED' '填写管理员已核对的正式证书 SHA-256；不要填写签名密钥或密码。'
    AddCheck 'APK_SIGNATURE' '安装包签名有效' '准备核对' $artifact.signatureVerified 'APK_SIGNATURE_UNVERIFIED' '检查安装包签名与固定 SDK 工具；多签名包需另行审核。'
    AddCheck 'CERTIFICATE_MATCH' '证书与登记一致' '准备核对' ($expectedValid -and $artifact.signatureVerified -and $ExpectedCertificateSha256.ToLowerInvariant() -ceq $artifact.certificateSha256) 'CERTIFICATE_NOT_MATCHED' '核对正式证书的公有摘要和本次安装包。'
    AddCheck 'NON_DEBUG_CERTIFICATE' '使用正式证书' '准备核对' ($artifact.signatureVerified -and $artifact.debugCertificateDetected -ceq $false) 'DEBUG_OR_UNVERIFIED_CERTIFICATE' '调试证书不能作为正式微信验收；正式证书仍需在开放平台核对。'
    AddCheck 'APK_MANIFEST' '安装包信息可读取' '准备核对' $artifact.manifestVerified 'APK_MANIFEST_UNVERIFIED' '使用可读取真实清单的正式安装包，不以文件名推断包内配置。'
    AddCheck 'PARENT_PACKAGE' '家长端包名一致' '准备核对' ($artifact.manifestVerified -and $artifact.applicationId -ceq 'com.aimanager.parent') 'PARENT_PACKAGE_MISMATCH' '核对包名 com.aimanager.parent 和微信开放平台登记。'
    AddCheck 'NON_DEBUGGABLE_APK' '正式构建不可调试' '准备核对' ($artifact.manifestVerified -and $artifact.debuggable -ceq $false) 'DEBUGGABLE_OR_UNVERIFIED_APK' '选择不可调试的正式 APK；不修改已有安装包。'
    AddCheck 'DECLARED_WECHAT_APPID' '计划微信 AppID 已提供' '准备核对' $appIdFormat 'WECHAT_APPID_DECLARATION_REQUIRED' '提供计划构建的非秘密 AppID；声明不能证明包内值。'
    AddCheck 'ADB_SERVER_READY' '本机设备连接可读取' '准备核对' ($adbPresent -and $devices.available) 'LOCAL_ADB_UNAVAILABLE_OR_INVALID' '由设备负责人准备本机 ADB；工具不启动或停止服务。'
    AddCheck 'ANDROID_AUTHORIZED_DEVICE' '存在已授权设备连接' '准备核对' ($devices.available -and $nonEmulator -gt 0) 'AUTHORIZED_DEVICE_UNAVAILABLE' '连接并在本人设备确认调试授权；连接记录不能证明已安装或已通过真机操作。'
    AddCheck 'WECHAT_APPID_FROM_APK' '包内微信 AppID 核对' '真实联调' $false 'APK_APPID_NOT_VERIFIED' '当前 AppID 位于 BuildConfig，未从清单读取；需绑定正式构建和真机核对。'
    AddCheck 'REAL_SMS_DELIVERY' '真实短信送达' '真实联调' $false 'REAL_EXECUTION_NOT_OBSERVED' '接收人从正常安全登录界面收码并输入；不把号码或验证码写入报告。'
    AddCheck 'REAL_WECHAT_NATIVE_AUTH' '正式真机微信授权' '真实联调' $false 'REAL_EXECUTION_NOT_OBSERVED' '使用正式签名包和真实微信完成原生授权及取消、重复回调检查。'
    AddCheck 'SIGNED_DEVICE_ACCEPTANCE' '正式签名真机联调' '真实联调' $false 'REAL_EXECUTION_NOT_OBSERVED' '核对实际安装版本、开放平台登记和完整账号操作；准备检查不能代替验收。'
    $report=[ordered]@{schemaVersion=1;kind='family-android-acceptance-preflight';environmentId=$EnvironmentId;
        generatedAt=[DateTimeOffset]::UtcNow.ToString('O');readinessScope='local-artifact-and-connection-preparation-only';
        readinessStatus=$(if(@($checks|Where-Object{$_.stage -ceq '准备核对' -and $_.status -cne 'PASS'}).Count -eq 0){'PASS'}else{'BLOCKED'});
        acceptanceStatus='BLOCKED';salesAllowed=$false;providerRequestsPerformed=$false;deviceStateChanged=$false;
        artifact=$artifact;expectedCertificateConfigured=$expectedValid;
        wechatAppId=[ordered]@{declaredValuePresent=([bool]$ParentWechatAppId);declaredFormatValid=$appIdFormat;status='NOT_VERIFIED';apkValueVerified=$false;platformRegistrationVerified=$false};
        deviceInventory=[ordered]@{serverAvailable=$devices.available;reasonCode=$devices.reason;deviceCount=@($devices.devices).Count;
            authorizedDeviceCount=$authorized;authorizedNonEmulatorDeviceCount=$nonEmulator;physicalDeviceVerified=$false;
            serialPersisted=$false;stableDeviceIdentifierPersisted=$false;devices=@($devices.devices)};
        requiredChecks=$checks.ToArray();sourceSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($output)) -Force
    AssertNoLinks $output
    $stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$bytes=$utf8.GetBytes(($report|ConvertTo-Json -Depth 10));$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
    Write-Output '安卓准备报告已生成。真实短信、微信和真机联调仍待验收，购买保持关闭。'
    exit 2
} catch {
    Write-Error '安卓准备预检未完成：请检查本地文件和参数；已有记录未覆盖。'
    exit 1
} finally {
    if ($null -ne $apkReadLock) { $apkReadLock.Dispose() }
}
