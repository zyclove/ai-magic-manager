#Requires -Version 7.0
<#
.SYNOPSIS
Produces a secret-free, offline readiness report for real family identity acceptance.
.DESCRIPTION
Reads only an existing deployment and fixed provider secret files. It never sends
SMS, exchanges a WeChat code, starts a service, changes configuration or enables
sales. Exit 2 means real provider acceptance remains blocked; exit 1 means no
report could be safely created. Even a format-ready report is not a release gate.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{2,63}$')][string]$EnvironmentId,
    [string]$IdentityProviderJar = '',
    [string]$ParentApk = '',
    [string]$ParentWechatAppId = '',
    [string]$OutputPath = '',
    [string]$VerifyManifest = ''
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$cacheRoot = [IO.Path]::GetFullPath((Join-Path $repository '.cache'))
$localRoot = [IO.Path]::GetFullPath((Join-Path $repository '.local'))
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function AssertNoLinks([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Linked input and output paths are not accepted.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}
function ReadBoundedText([string]$Path, [int]$Maximum) {
    AssertNoLinks $Path
    $stream = [IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -gt $Maximum) { throw 'Input is too large.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($bytes)
        return $utf8.GetString($bytes).TrimStart([char]0xfeff)
    } finally { $stream.Dispose() }
}
function ReadSecret([string]$Path, [string]$Kind) {
    $result = @{present=$false; validFormat=$false; value=''}
    try {
        # Unlike JSON/env files, provider secrets must not silently accept a UTF-8 BOM.
        AssertNoLinks $Path
        $stream = [IO.File]::OpenRead($Path)
        try {
            if ($stream.Length -gt 8192) { return $result }
            $bytes = [byte[]]::new([int]$stream.Length); $stream.ReadExactly($bytes)
            $value = $utf8.GetString($bytes)
        } finally { $stream.Dispose() }
        if ($value.EndsWith("`n")) { $value=$value.Substring(0,$value.Length-1) }
        if ($value.EndsWith("`r")) { $value=$value.Substring(0,$value.Length-1) }
        $result.present = -not [string]::IsNullOrWhiteSpace($value)
        if ($value.IndexOfAny([char[]]@("`n","`r",[char]0,[char]0xfeff)) -ge 0) { return $result }
        $valid = switch ($Kind) {
            'hmac' { $utf8.GetByteCount($value) -ge 32 }
            'accessId' { $value -cmatch '^[A-Za-z0-9._-]{16,128}$' }
            'accessSecret' { $value -cmatch '^[A-Za-z0-9+/=_-]{16,128}$' }
            'sts' { $value -eq '' -or $value -cmatch '^[A-Za-z0-9+/=._-]{16,8192}$' }
            'wechat' { $value -cmatch '^[0-9a-fA-F]{32}$' }
        }
        if ($value -match '^(not[-_ ]?real|change[-_ ]?me|your[-_ ]|replace[-_ ]|example|test-secret)') { $valid=$false }
        $result.validFormat = [bool]$valid
        if ($valid) { $result.value=$value }
    } catch { } # Never include an exception message, secret content or secret path in a report.
    return $result
}
function ReadEnvironment([string]$Path) {
    $result = @{valid=$false; values=@{}}
    try {
        $text = ReadBoundedText $Path 65536
        foreach ($line in $text -split "`n") {
            $line=$line.Trim()
            if (-not $line -or $line.StartsWith('#')) { continue }
            if ($line -cnotmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { return $result }
            $name=$Matches[1]; $value=$Matches[2].Trim()
            if ($result.values.ContainsKey($name)) { return $result }
            if ($value.StartsWith("'")) {
                if ($value -cnotmatch "^'([^']*)'$" ) { return $result }; $value=$Matches[1]
            } elseif ($value.StartsWith('"')) {
                if ($value -cnotmatch '^"([^"`$]*)"$') { return $result }; $value=$Matches[1]
            } elseif ($value -cmatch '[\s`$;|&<>]') { return $result }
            if ($value.IndexOfAny([char[]]@([char]0,"`r","`n")) -ge 0) { return $result }
            $result.values[$name]=$value
        }
        $result.valid=$true
    } catch { }
    return $result
}
function Artifact([string]$Path, [string]$Kind) {
    $result=[ordered]@{present=$false; validFormat=$false; sha256=$null}
    if (-not $Path) { return $result }
    try {
        $absolute=[IO.Path]::GetFullPath($Path,$repository); AssertNoLinks $absolute
        if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { return $result }
        $result.present=$true
        $result.sha256=(Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant()
        $zip=[IO.Compression.ZipFile]::OpenRead($absolute)
        try {
            $names=@($zip.Entries | ForEach-Object FullName)
            if ($Kind -eq 'identity') {
                $required=@('META-INF/beans.xml',
                    'META-INF/services/org.keycloak.authentication.AuthenticatorFactory',
                    'META-INF/services/org.keycloak.protocol.ProtocolMapper',
                    'META-INF/services/org.keycloak.services.resource.RealmResourceProviderFactory')
                $result.validFormat=(@($required | Where-Object { $names -cnotcontains $_ }).Count -eq 0)
            } else { $result.validFormat=$names -ccontains 'AndroidManifest.xml' -and $names -ccontains 'classes.dex' }
        } finally { $zip.Dispose() }
    } catch { }
    return $result
}
function DigestText([string]$Value) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($Value))).ToLowerInvariant()
}
$checks=[Collections.Generic.List[object]]::new()
function AddCheck([string]$Id,[string]$Label,[string]$Stage,[bool]$Passed,[string]$Reason,[string]$Action) {
    $checks.Add([ordered]@{id=$Id; label=$Label; stage=$Stage; status=$(if($Passed){'PASS'}else{'BLOCKED'});
        reasonCode=$(if($Passed){'LOCAL_FORMAT_CHECK_PASSED'}else{$Reason}); action=$Action})
}

try {
    $deployment=[IO.Path]::GetFullPath($Directory,$repository); AssertNoLinks $deployment
    if (-not $OutputPath) {
        $OutputPath=Join-Path $cacheRoot ('family-identity-provider-acceptance/preflight-'+[Guid]::NewGuid().ToString('N')+'.json')
    }
    $output=[IO.Path]::GetFullPath($OutputPath,$repository)
    $insideOutputRoot=$false
    foreach($root in @($cacheRoot,$localRoot)) {
        if($output.StartsWith($root+[IO.Path]::DirectorySeparatorChar,$comparison)) { $insideOutputRoot=$true; break }
    }
    if (-not $insideOutputRoot) { throw 'Output must stay inside repository .cache or .local.' }
    AssertNoLinks $output
    if (Test-Path -LiteralPath $output) { throw 'Output already exists.' }
    $environment=ReadEnvironment (Join-Path $deployment '.env'); $envValues=$environment.values
    AddCheck 'CONFIGURATION_FILE' '部署配置可读取' '配置准备' $environment.valid 'CONFIGURATION_UNAVAILABLE' '在独立验收部署准备有效配置文件；不在文件中保存供应商密钥。'
    $settings=$null
    try { $settings=ReadBoundedText (Join-Path $deployment 'deployment.json') 65536 | ConvertFrom-Json -AsHashtable } catch { }
    $consumerMode=$null -ne $settings -and $settings.schemaVersion -eq 1 -and $settings.consumerIdentity -ceq $true
    AddCheck 'CONSUMER_DEPLOYMENT' '独立家庭身份部署' '配置准备' $consumerMode 'CONSUMER_DEPLOYMENT_UNAVAILABLE' '使用独立消费者验收部署；不要覆盖已有身份域。'
    $origin=$null
    $https=$environment.valid -and [Uri]::TryCreate($envValues.PUBLIC_URL,[UriKind]::Absolute,[ref]$origin) -and
        $origin.Scheme -eq 'https' -and -not $origin.UserInfo -and -not $origin.Query -and -not $origin.Fragment -and
        $origin.AbsolutePath -eq '/' -and $null -ne $settings -and $settings.publicUrl -ceq $envValues.PUBLIC_URL
    AddCheck 'HTTPS_ORIGIN' '安全连接地址' '配置准备' $https 'HTTPS_ORIGIN_REQUIRED' '真实供应商与真机联调使用与部署一致的 HTTPS 入口。'
    $secretDefinitions=[ordered]@{
        consumer_otp_hmac_key='hmac'; consumer_sms_access_key_id='accessId'; consumer_sms_access_key_secret='accessSecret';
        consumer_sms_security_token='sts'; consumer_wechat_app_secret='wechat'
    }
    $privateSecrets=@{}; $publicSecrets=[ordered]@{}
    foreach ($entry in $secretDefinitions.GetEnumerator()) {
        $secret=ReadSecret (Join-Path $deployment ('secrets/'+$entry.Key)) $entry.Value
        $privateSecrets[$entry.Key]=$secret
        $publicSecrets[$entry.Key]=[ordered]@{present=$secret.present; validFormat=$secret.validFormat}
    }
    $secretFilesValid=@($publicSecrets.Values | Where-Object { -not $_.validFormat }).Count -eq 0
    AddCheck 'SECRET_FILES_FORMAT' '受限密钥文件格式' '配置准备' $secretFilesValid 'SECRET_FILE_MISSING_OR_INVALID' '补齐固定密钥文件；每项为单行 UTF-8，STS 未使用时保留空文件。'
    $directSecretNames=@('CONSUMER_OTP_HMAC_KEY','ALIYUN_SMS_ACCESS_KEY_ID','ALIYUN_SMS_ACCESS_KEY_SECRET','ALIYUN_SMS_SECURITY_TOKEN','WECHAT_NATIVE_APP_SECRET')
    $fileBacked=$environment.valid -and @($directSecretNames | Where-Object { $envValues.ContainsKey($_) -and $envValues[$_] }).Count -eq 0
    AddCheck 'FILE_BACKED_CREDENTIALS' '密钥使用文件配置' '配置准备' $fileBacked 'INLINE_SECRET_NOT_ALLOWED' '供应商密钥仅写入受限秘密文件，不放入 .env、App 或验收记录。'
    $sign=$envValues.ALIYUN_SMS_SIGN_NAME; $template=$envValues.ALIYUN_SMS_TEMPLATE_CODE
    $smsFormat=$environment.valid -and $privateSecrets.consumer_otp_hmac_key.validFormat -and
        $privateSecrets.consumer_sms_access_key_id.validFormat -and $privateSecrets.consumer_sms_access_key_secret.validFormat -and
        $privateSecrets.consumer_sms_security_token.validFormat -and -not [string]::IsNullOrWhiteSpace($sign) -and
        $sign.Length -le 32 -and $template -cmatch '^SMS_[0-9]{1,32}$'
    AddCheck 'SMS_CONFIGURATION_FORMAT' '短信配置格式' '配置准备' $smsFormat 'SMS_CONFIGURATION_MISSING_OR_INVALID' '准备中国站 RAM 权限、已审核签名及 code 模板；格式有效不代表已送达。'
    $appId=$envValues.WECHAT_NATIVE_APP_ID
    $wechatFormat=$environment.valid -and $appId -cmatch '^wx[0-9a-fA-F]{16}$' -and $privateSecrets.consumer_wechat_app_secret.validFormat
    AddCheck 'WECHAT_CONFIGURATION_FORMAT' '微信移动应用配置格式' '配置准备' $wechatFormat 'WECHAT_CONFIGURATION_MISSING_OR_INVALID' '准备已审核移动应用 AppID 和服务端 AppSecret。'
    $appMatch=$wechatFormat -and $ParentWechatAppId -cmatch '^wx[0-9a-fA-F]{16}$' -and $appId -ceq $ParentWechatAppId
    AddCheck 'APPID_CONFIGURATION_MATCH' '家长端与身份服务 AppID 配套' '配置准备' $appMatch 'APPID_CONFIGURATION_UNCONFIRMED' '核对计划构建 AppID；安装包内配置、包名和正式签名仍需真机验收。'
    $flagsValid=$environment.valid
    foreach ($flag in @('CONSUMER_PHONE_ENABLED','CONSUMER_WECHAT_ENABLED','FAMILY_ACCOUNT_SECURITY_ENABLED','FAMILY_SALES_ENABLED')) {
        if ($envValues[$flag] -cnotin @('true','false')) { $flagsValid=$false }
    }
    AddCheck 'FEATURE_FLAGS_FORMAT' '入口开关可识别' '配置准备' $flagsValid 'FEATURE_FLAGS_INVALID' '配置使用明确的 true/false；预检不修改开关。'
    AddCheck 'SALES_DISABLED' '联调期间购买关闭' '配置准备' ($environment.valid -and $envValues.FAMILY_SALES_ENABLED -ceq 'false') 'SALES_MUST_REMAIN_DISABLED' '真实账号、设备、支付和发布验收全部通过前保持购买关闭。'
    $artifacts=[ordered]@{identityProvider=(Artifact $IdentityProviderJar 'identity');parentApk=(Artifact $ParentApk 'parent')}
    AddCheck 'IDENTITY_ARTIFACT_BOUND' '身份扩展版本已登记' '版本核对' $artifacts.identityProvider.validFormat 'IDENTITY_ARTIFACT_UNAVAILABLE' '提供本次扩展 JAR；摘要和资源检查不替代实际运行。'
    AddCheck 'PARENT_ARTIFACT_BOUND' '家长安装包版本已登记' '版本核对' $artifacts.parentApk.validFormat 'PARENT_ARTIFACT_UNAVAILABLE' '提供本次家长 APK；调试包不能替代正式签名真机验收。'
    $sourcePaths=@(
        'identity-extensions/src/main/java/com/aimanager/identity/ConsumerConfiguration.java',
        'identity-extensions/src/main/java/com/aimanager/identity/ConsumerAuthenticator.java',
        'identity-extensions/src/main/java/com/aimanager/identity/ConsumerAccountFlow.java',
        'identity-extensions/src/main/java/com/aimanager/identity/ConsumerAccountResource.java',
        'identity-extensions/src/main/java/com/aimanager/identity/ConsumerIdentityTransactions.java',
        'identity-extensions/src/main/java/com/aimanager/identity/AliyunSms.java',
        'identity-extensions/src/main/java/com/aimanager/identity/WechatNative.java',
        'apps/parent/lib/core/parent_session.dart',
        'apps/parent/android/app/src/main/kotlin/com/aimanager/parent/ConsumerWeChatAuthBridge.kt',
        'scripts/test_family_identity_providers.ps1'
    )
    $sourceFiles=@(foreach($path in $sourcePaths | Sort-Object){
        $hash=$null; try {$hash=(Get-FileHash -LiteralPath (Join-Path $repository $path) -Algorithm SHA256).Hash.ToLowerInvariant()}catch{}
        [ordered]@{path=$path;sha256=$hash}
    })
    AddCheck 'SOURCE_VERSION_BOUND' '验收源码版本已登记' '版本核对' (@($sourceFiles | Where-Object { -not $_.sha256 }).Count -eq 0) 'SOURCE_VERSION_UNAVAILABLE' '验收结果绑定当前源码；重新构建后重新核验。'
    $nonSecret=[ordered]@{}
    foreach($key in @('PUBLIC_URL','CONSUMER_PHONE_ENABLED','CONSUMER_WECHAT_ENABLED','FAMILY_ACCOUNT_SECURITY_ENABLED','FAMILY_SALES_ENABLED','ALIYUN_SMS_SIGN_NAME','ALIYUN_SMS_TEMPLATE_CODE','WECHAT_NATIVE_APP_ID')){$nonSecret[$key]=$envValues[$key]}
    $nonSecret.parentWechatAppId=$ParentWechatAppId
    $configurationHash=DigestText ($nonSecret|ConvertTo-Json -Compress -Depth 4)
    $realCases=@(
        @('REAL_SMS_DELIVERY','真实短信发送与接收','核对批准接收人的短信送达、错误次数及限流；不记录号码或验证码。'),
        @('REAL_WECHAT_NATIVE_AUTH','真机微信授权','正式签名真机通过原生授权和 PKCE 回调；授权码仅在内存和安全链路中使用。'),
        @('CHANGE_PHONE_E2E','更换手机号','原号和新号均实际收码；用户、家庭、设备、订单和会员保持不变。'),
        @('RECOVER_PHONE_E2E','已绑定微信找回账号','原号不可用时通过既有微信验证后换号；未知微信不能认领原账号。'),
        @('BIND_WECHAT_E2E','绑定微信','真实微信授权并验证当前手机号，绑定原账号后可重新登录。'),
        @('UNBIND_WECHAT_E2E','解绑微信','真实当前手机号验证后解除；手机号仍可登录，原微信不可再次进入该账号。'),
        @('IDENTITY_CONFLICTS','手机号与微信冲突','用两组已授权测试账号检查手机号占用、微信占用、旧操作和跨账号拒绝。'),
        @('OLD_SESSION_REVOKED','其他设备旧登录失效','保留第二设备旧会话，验证旧访问令牌和刷新被拒绝，新会话正常。'),
        @('INTERRUPTION_RECOVERY','取消与掉网后核对','真实中断浏览器、掉网和杀进程，查询原操作结果，不自动重复更改。'),
        @('MYSQL_CONCURRENCY_ROLLBACK','MySQL 并发与回滚','在目标 MySQL 版本验证行锁、RR 并发、回滚释放及多节点失效；H2 不能替代。'),
        @('SIGNED_DEVICE_BUILD','正式签名与安装包配置','核对正式包名、证书、包内 AppID、微信平台登记以及本次 APK 摘要。'),
        @('LOG_REDACTION','真实链路不留敏感内容','实际核对入口、代理、APM、崩溃及供应商出站日志，不记录查询、表单、令牌或验证码。')
    )
    foreach($case in $realCases){AddCheck $case[0] $case[1] '真实联调' $false 'REAL_EXECUTION_NOT_OBSERVED' $case[2]}
    $review=[ordered]@{requested=[bool]$VerifyManifest;status='BLOCKED';reasonCode='NOT_REQUESTED';scope='local-preflight-binding-only'}
    if($VerifyManifest){
        try{
            $previous=ReadBoundedText ([IO.Path]::GetFullPath($VerifyManifest,$repository)) 131072 | ConvertFrom-Json -AsHashtable
            $same=$previous.schemaVersion -eq 1 -and $previous.kind -ceq 'family-identity-provider-preflight' -and
                $previous.environmentId -ceq $EnvironmentId -and $previous.acceptanceStatus -ceq 'BLOCKED' -and
                $previous.salesAllowed -ceq $false -and $previous.providerRequestsPerformed -ceq $false -and
                $previous.nonSecretConfigurationSha256 -ceq $configurationHash -and
                ($previous.artifacts|ConvertTo-Json -Compress -Depth 6) -ceq ($artifacts|ConvertTo-Json -Compress -Depth 6) -and
                ($previous.sourceFiles|ConvertTo-Json -Compress -Depth 6) -ceq ($sourceFiles|ConvertTo-Json -Compress -Depth 6)
            $priorCases=@($previous.requiredChecks|Where-Object {$_.stage -ceq '真实联调'})
            if($priorCases.Count -ne $realCases.Count -or @($priorCases|Where-Object {$_.status -cne 'BLOCKED'}).Count -ne 0){$same=$false}
            foreach($case in $realCases){if(@($priorCases|Where-Object {$_.id -ceq $case[0]}).Count -ne 1){$same=$false}}
            $timestamp=[DateTimeOffset]::Parse($previous.generatedAt)
            if($timestamp -gt [DateTimeOffset]::UtcNow.AddMinutes(1) -or $timestamp -lt [DateTimeOffset]::UtcNow.AddDays(-1)){$same=$false}
            if($same){$review.status='PASS';$review.reasonCode='CURRENT_BINDINGS_MATCH'}else{$review.reasonCode='MANIFEST_BINDING_OR_STATUS_INVALID'}
        }catch{$review.reasonCode='MANIFEST_UNAVAILABLE_OR_INVALID'}
    }
    $report=[ordered]@{
        schemaVersion=1;kind='family-identity-provider-preflight';environmentId=$EnvironmentId;
        generatedAt=[DateTimeOffset]::UtcNow.ToString('O');
        readinessStatus=$(if(@($checks|Where-Object{$_.stage -cne '真实联调' -and $_.status -cne 'PASS'}).Count -eq 0){'PASS'}else{'BLOCKED'});
        acceptanceStatus='BLOCKED';salesAllowed=$false;providerRequestsPerformed=$false;
        credentials=$publicSecrets;artifacts=$artifacts;sourceFiles=$sourceFiles;
        nonSecretConfigurationSha256=$configurationHash;secretRotationVerified=$false;evidenceReview=$review;
        requiredChecks=@($checks)
    }
    $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($output)) -Force
    AssertNoLinks $output
    $stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=$utf8.GetBytes(($report|ConvertTo-Json -Depth 10));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    $privateSecrets.Clear();$envValues.Clear()
    Write-Output '供应商预检报告已生成。真实短信、微信与账号联调尚未验收，购买保持关闭。'
    exit 2
}catch{
    Write-Error '身份供应商预检未完成：请检查参数和受限本地文件；已有记录未覆盖。'
    exit 1
}
