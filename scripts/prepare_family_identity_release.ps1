#Requires -Version 7.0
<#
.SYNOPSIS
Prepares one authenticated, disabled identity configuration version without applying it.
.DESCRIPTION
Decrypts the fixed release JWE with a restricted local key ring into a new restricted
directory. Never overwrites a deployment, sends provider requests, executes Compose,
restarts services, changes a realm or enables consumer login or sales.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundleFile,
    [Parameter(Mandatory)][string]$KeyFile,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$EnvironmentId,
    [Parameter(Mandatory)][string]$VersionId,
    [string]$DeploymentDirectory = ''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
$repository=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
$utf8=[Text.UTF8Encoding]::new($false,$true)
$allowedRoots=@([IO.Path]::GetFullPath((Join-Path $repository '.cache')),[IO.Path]::GetFullPath((Join-Path $repository '.local')))
$secretFiles=[ordered]@{
    CONSUMER_OTP_HMAC_KEY='consumer_otp_hmac_key'
    ALIYUN_SMS_ACCESS_KEY_ID='consumer_sms_access_key_id'
    ALIYUN_SMS_ACCESS_KEY_SECRET='consumer_sms_access_key_secret'
    ALIYUN_SMS_SECURITY_TOKEN='consumer_sms_security_token'
    WECHAT_NATIVE_APP_SECRET='consumer_wechat_app_secret'
}
$plaintext=$null;$keyBytes=$null;$aes=$null

function AssertNoLinks([string]$Path){
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if(Test-Path -LiteralPath $current){
            if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked path'}
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if($parent -eq $current){break};$current=$parent
    }
}
function SafePath([string]$Path){
    $absolute=[IO.Path]::GetFullPath($Path,$repository)
    $inside=$false
    foreach($root in $allowedRoots){
        if($absolute.StartsWith($root+[IO.Path]::DirectorySeparatorChar,$comparison)){$inside=$true;break}
    }
    if(-not $inside){throw 'Path is outside the selected restricted roots'}
    AssertNoLinks $absolute
    return $absolute
}
function RestrictedPermissions([string]$Path){
    if($IsWindows){
        $current=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $allowed=@($current.Value,'S-1-5-18','S-1-5-32-544')
        $acl=Get-Acl -LiteralPath $Path
        if($allowed -cnotcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value){throw 'Unrestricted owner'}
        foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
            if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $allowed -cnotcontains $rule.IdentityReference.Value){throw 'Unrestricted permissions'}
        }
    }else{
        $mode=[int][IO.File]::GetUnixFileMode($Path)
        if(($mode -band 63) -ne 0){throw 'Unrestricted permissions'}
    }
}
function RestrictDirectory([string]$Path){
    if($IsWindows){
        $current=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=[Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($current);$acl.SetAccessRuleProtection($true,$false)
        foreach($sid in @($current,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){
            $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,
                ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    }else{[IO.File]::SetUnixFileMode($Path,([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute))}
    RestrictedPermissions $Path
}
function ReadText([string]$Path,[int]$Maximum){
    AssertNoLinks $Path
    $stream=[IO.File]::OpenRead($Path)
    try{
        if($stream.Length -gt $Maximum){throw 'Oversized input'}
        $bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes)
        $text=$utf8.GetString($bytes)
        if($text.Length -gt 0 -and $text[0] -eq [char]0xfeff){throw 'BOM is unsupported'}
        return $text
    }finally{$stream.Dispose()}
}
function CheckJsonNames([System.Text.Json.JsonElement]$Element){
    if($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object){
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($property in $Element.EnumerateObject()){
            if(-not $names.Add($property.Name)){throw 'Duplicate JSON property'}
            CheckJsonNames $property.Value
        }
    }elseif($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array){
        foreach($item in $Element.EnumerateArray()){CheckJsonNames $item}
    }
}
function ParseJson([string]$Text){
    $options=[System.Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=16
    $document=[System.Text.Json.JsonDocument]::Parse($Text,$options)
    try{CheckJsonNames $document.RootElement}finally{$document.Dispose()}
    return ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 16
}
function Properties($Object,[string[]]$Names){
    if($Object -isnot [Collections.IDictionary] -or $Object.Count -ne $Names.Count){throw 'Invalid object'}
    foreach($name in $Object.Keys){if($Names -cnotcontains $name){throw 'Unexpected property'}}
}
function SchemaOne($Value){if(($Value -isnot [long] -and $Value -isnot [int]) -or $Value -ne 1){throw 'Unsupported schema'}}
function UrlBytes([string]$Value){
    if($Value -cnotmatch '^[A-Za-z0-9_-]+$'){throw 'Invalid base64url'}
    $encoded=$Value.Replace('-','+').Replace('_','/')
    switch($encoded.Length % 4){0{} 2{$encoded+='=='} 3{$encoded+='='} default{throw 'Invalid base64url'}}
    $bytes=[Convert]::FromBase64String($encoded)
    if([Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_') -cne $Value){throw 'Noncanonical base64url'}
    return ,$bytes
}
function NewFile([string]$Path,[string]$Text){
    AssertNoLinks $Path
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{
        if(-not $IsWindows){[IO.File]::SetUnixFileMode($Path,([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite))}
        RestrictedPermissions $Path
        $bytes=$utf8.GetBytes($Text);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
    }finally{$stream.Dispose()}
}
try{
    if($EnvironmentId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{2,63}$' -or $VersionId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){throw 'Invalid target binding'}
    if($DeploymentDirectory){
        $selected=[IO.Path]::GetFullPath($DeploymentDirectory,$repository);AssertNoLinks $selected
        if($selected -eq [IO.Path]::GetPathRoot($selected) -or -not (Test-Path -LiteralPath $selected -PathType Container)){throw 'Invalid deployment root'}
        RestrictedPermissions $selected
        $deployment=ParseJson (ReadText (Join-Path $selected 'deployment.json') 65536)
        SchemaOne $deployment.schemaVersion
        if($deployment.consumerIdentity -isnot [bool] -or -not $deployment.consumerIdentity){throw 'Consumer deployment required'}
        $allowedRoots+=,$selected
    }
    $bundlePath=SafePath $BundleFile;$keyPath=SafePath $KeyFile;$output=SafePath $OutputDirectory
    if(-not (Test-Path -LiteralPath $bundlePath -PathType Leaf) -or -not (Test-Path -LiteralPath $keyPath -PathType Leaf)){throw 'Input file required'}
    if(Test-Path -LiteralPath $output){throw 'Output already exists'}
    if(-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($output)) -PathType Container)){throw 'Existing output parent required'}
    RestrictedPermissions $keyPath
    $outer=ParseJson (ReadText $bundlePath 131072)
    Properties $outer @('schemaVersion','environmentId','versionId','protectedPayload');SchemaOne $outer.schemaVersion
    if($outer.environmentId -isnot [string] -or $outer.versionId -isnot [string] -or $outer.environmentId -cne $EnvironmentId -or $outer.versionId -cne $VersionId){throw 'Target binding mismatch'}
    if($outer.protectedPayload -isnot [string] -or $outer.protectedPayload.Length -gt 98304){throw 'Invalid JWE'}
    $parts=$outer.protectedPayload.Split('.')
    if($parts.Count -ne 5 -or $parts[1] -cne '' -or $parts[0].Length -gt 8192){throw 'Invalid JWE'}
    $header=ParseJson ($utf8.GetString((UrlBytes $parts[0])))
    Properties $header @('alg','enc','kid','typ','cty','purpose','environmentId','versionId')
    foreach($value in $header.Values){if($value -isnot [string]){throw 'Invalid JWE header type'}}
    if($header.alg -cne 'dir' -or $header.enc -cne 'A256GCM' -or $header.typ -cne 'family-identity-provider-release+jwe' -or $header.cty -cne 'application/json' -or $header.purpose -cne 'family-identity-provider-release-v1' -or $header.environmentId -cne $EnvironmentId -or $header.versionId -cne $VersionId -or $header.kid -isnot [string] -or $header.kid -cnotmatch '^[A-Za-z0-9._-]{1,64}$'){throw 'Invalid JWE binding'}
    $ring=ParseJson (ReadText $keyPath 65536);Properties $ring @('keys')
    if($ring.keys -isnot [array] -or $ring.keys.Count -lt 1 -or $ring.keys.Count -gt 8){throw 'Invalid key ring'}
    $kids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($key in $ring.keys){
        Properties $key @('kty','use','alg','kid','k')
        foreach($value in $key.Values){if($value -isnot [string]){throw 'Invalid key property type'}}
        if($key.kty -cne 'oct' -or $key.use -cne 'enc' -or $key.alg -cne 'dir' -or $key.kid -isnot [string] -or $key.kid -cnotmatch '^[A-Za-z0-9._-]{1,64}$' -or -not $kids.Add($key.kid) -or $key.k -isnot [string]){throw 'Invalid key ring'}
        $candidate=UrlBytes $key.k
        if($candidate.Length -ne 32){throw 'Invalid key length'}
        if($key.kid -ceq $header.kid){$keyBytes=$candidate}else{[Array]::Clear($candidate,0,$candidate.Length)}
    }
    if($null -eq $keyBytes){throw 'Unknown key'}
    $iv=UrlBytes $parts[2];$cipher=UrlBytes $parts[3];$tag=UrlBytes $parts[4]
    if($iv.Length -ne 12 -or $tag.Length -ne 16 -or $cipher.Length -gt 65536){throw 'Invalid encrypted content'}
    $plaintext=[byte[]]::new($cipher.Length);$aes=[Security.Cryptography.AesGcm]::new($keyBytes,16)
    $aes.Decrypt($iv,$cipher,$tag,$plaintext,$utf8.GetBytes($parts[0]))
    $payload=ParseJson ($utf8.GetString($plaintext))
    Properties $payload @('schemaVersion','versionId','settings','credentials');SchemaOne $payload.schemaVersion
    if($payload.versionId -isnot [string] -or $payload.versionId -cne $VersionId){throw 'Payload binding mismatch'}
    $settings=$payload.settings
    Properties $settings @('smsSignName','smsTemplateCode','wechatAppId','parentPackageName','parentCertificateSha256')
    foreach($value in $settings.Values){if($value -isnot [string]){throw 'Invalid setting'}}
    if([string]::IsNullOrWhiteSpace($settings.smsSignName) -or $settings.smsSignName.Length -gt 32){throw 'Invalid SMS sign'}
    $unsafe=[char[]]@(39,34,96,36,59,38,124,60,62,0xfeff)
    if($settings.smsSignName.IndexOfAny($unsafe) -ge 0){throw 'Invalid SMS sign'}
    foreach($character in $settings.smsSignName.ToCharArray()){if([char]::IsControl($character)){throw 'Invalid SMS sign'}}
    if($settings.smsTemplateCode -cnotmatch '^SMS_[0-9]{1,32}$' -or $settings.wechatAppId -cnotmatch '^wx[0-9a-fA-F]{16}$' -or $settings.parentPackageName -cne 'com.aimanager.parent' -or $settings.parentCertificateSha256 -cnotmatch '^[0-9a-fA-F]{64}$'){throw 'Invalid provider settings'}
    $settings.parentCertificateSha256=$settings.parentCertificateSha256.ToLowerInvariant()
    $credentials=$payload.credentials;Properties $credentials @($secretFiles.Keys)
    foreach($name in $secretFiles.Keys){
        $value=$credentials[$name]
        if($value -isnot [string] -or $utf8.GetByteCount($value) -gt 8192 -or $value.IndexOfAny([char[]]@(0,10,13,0xfeff)) -ge 0 -or $value -match '^(not[-_ ]?real|change[-_ ]?me|your[-_ ]|replace[-_ ]|example|test-secret)'){throw 'Invalid credential'}
        $valid=switch($name){
            'CONSUMER_OTP_HMAC_KEY'{-not [string]::IsNullOrWhiteSpace($value) -and $utf8.GetByteCount($value) -ge 32}
            'ALIYUN_SMS_ACCESS_KEY_ID'{$value -cmatch '^[A-Za-z0-9._-]{16,128}$'}
            'ALIYUN_SMS_ACCESS_KEY_SECRET'{$value -cmatch '^[A-Za-z0-9+/=_-]{16,128}$'}
            'ALIYUN_SMS_SECURITY_TOKEN'{$value -ceq '' -or $value -cmatch '^[A-Za-z0-9+/=._-]{16,8192}$'}
            'WECHAT_NATIVE_APP_SECRET'{$value -cmatch '^[0-9a-fA-F]{32}$'}
        }
        if(-not $valid){throw 'Invalid credential'}
    }
    # No decrypted output exists until every layer has passed authentication and validation.
    AssertNoLinks $output
    [void](New-Item -ItemType Directory -Path $output)
    RestrictDirectory $output
    $secrets=Join-Path $output 'secrets';[void](New-Item -ItemType Directory -Path $secrets);RestrictDirectory $secrets
    $environment=@('CONSUMER_PHONE_ENABLED=false','CONSUMER_WECHAT_ENABLED=false','FAMILY_ACCOUNT_SECURITY_ENABLED=false','FAMILY_SALES_ENABLED=false',
        ("ALIYUN_SMS_SIGN_NAME='"+$settings.smsSignName+"'"),('ALIYUN_SMS_TEMPLATE_CODE='+$settings.smsTemplateCode),('WECHAT_NATIVE_APP_ID='+$settings.wechatAppId)) -join "`n"
    NewFile (Join-Path $output 'family-identity.env') ($environment+"`n")
    foreach($name in $secretFiles.Keys){NewFile (Join-Path $secrets $secretFiles[$name]) $credentials[$name]}
    $statuses=[ordered]@{};foreach($name in $secretFiles.Keys){$statuses[$name]=@{configured=(-not [string]::IsNullOrWhiteSpace($credentials[$name]))}}
    $manifest=[ordered]@{schemaVersion=1;kind='family-identity-provider-prepared-release';environmentId=$EnvironmentId;versionId=$VersionId;
        preparedAt=[DateTimeOffset]::UtcNow.ToString('o');state='APPLY_REQUIRED';applied=$false;runtimeVerified=$false;providerRequestsPerformed=$false;
        acceptanceStatus='BLOCKED';salesAllowed=$false;permissionsRestricted=$true;settings=$settings;credentials=$statuses;
        nonSecretConfigurationSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($environment+"`n"))).ToLowerInvariant();
        files=@('family-identity.env','prepared-release.json','NEXT_STEPS.md')+@($secretFiles.Values|ForEach-Object{'secrets/'+$_})}
    $steps=@'
# 身份配置版本已准备，尚未生效

本目录包含受限秘密文件。不要上传 Git、发送到聊天、加入普通备份、截图或日志；不要改变目录权限。凭据格式通过不证明供应商可用。

1. 由授权部署管理员核对环境、配置版本、正式 APK/JAR 与目标部署。此处 family-identity.env 只是供应商配置片段，不能替代部署完整 .env。原部署、数据库及身份域均未修改。
2. 先在独立消费者验收环境审查完整版本。按部署流程将固定秘密文件与非秘密配置一致合并到受控部署；审查后受控重新创建 identity。共享 FAMILY_ACCOUNT_SECURITY_ENABLED 将来启用时还需协调 backend 门禁与重建。不要在运行实例中单独覆盖一项秘密，不执行数据库清空或 realm 重新导入。
3. 当前所有消费者、账号安全及销售开关均为 false。需要真实联调时，只在已授权隔离环境由部署管理员单独审查计划后开放测试入口；本工具没有启用或重启命令。
4. 采集所有目标实例的真实配置版本、镜像和身份扩展摘要、健康及当前开关回执；未完成一致性核对前保持 APPLY_REQUIRED。健康页或数据库保存记录不能证明配置已生效。
5. 依 docs/family-identity-provider-acceptance.md 完成实际收码、正式签名真机微信、账号换绑与恢复、旧会话拒绝和中断恢复。短信提交成功不等于送达；未知结果不能自动重发。微信 code 只走原生 SDK 与正常 OIDC/PKCE，不粘贴到管理员工具。
6. 回退必须是另一个受控部署计划：确认历史凭据仍有效、AppID 绑定范围与当前版本兼容，随后重新创建并采集全部实例回执。不要恢复旧用户身份、会话或已解除绑定。

准备不会解除销售条件。正式购买仍须设备、账号、支付退款及发布验收全部通过。
'@
    NewFile (Join-Path $output 'NEXT_STEPS.md') $steps
    NewFile (Join-Path $output 'prepared-release.json') ($manifest|ConvertTo-Json -Depth 8)
    [Console]::Out.WriteLine('已准备未启用的身份配置版本；需受控部署与真实联调。')
    exit 0
}catch{
    # Preserve a partial owned output for review; never recursively remove a selected directory.
    [Console]::Error.WriteLine('身份配置准备失败；输入、目标范围、完整性或权限未通过。未执行部署或供应商请求。')
    exit 1
}finally{
    if($null -ne $aes){$aes.Dispose()}
    if($null -ne $plaintext){[Array]::Clear($plaintext,0,$plaintext.Length)}
    if($null -ne $keyBytes){[Array]::Clear($keyBytes,0,$keyBytes.Length)}
}
