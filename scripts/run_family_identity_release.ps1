#Requires -Version 7.0
<# Executes only a server-approved single-node identity operation. Never enables consumer services or sales. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TargetFile,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')][string]$OperationId)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'family-identity-release-common.ps1')
$key=$null;$hostLock=$null;$client=$null;$stage='TARGET';$journal=$null;$journalPath=$null
function Machine([string]$Action,[string]$Outcome='',[string]$QueryOperationId=$OperationId,[string]$QueryClaimId=$journal.claimId){
    $nonce=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).TrimEnd('=').Replace('+','-').Replace('/','_');$issued=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $body=[ordered]@{environmentId=$target.environmentId;operationId=$QueryOperationId;claimId=$QueryClaimId;nonce=$nonce;issuedAt=$issued;proof=(Get-IdentityReleaseProof $key @('family-identity-executor-request-v1',$Action,$target.environmentId,$QueryOperationId,$QueryClaimId,$nonce,[string]$issued,$Outcome))}
    if($Action -ceq 'REPORT'){$body.outcome=$Outcome}
    $suffix=switch($Action){'CLAIM'{''} 'QUERY'{'/query'} 'BEGIN'{'/begin'} 'REPORT'{'/outcomes'} 'ABANDON_BEFORE_BEGIN'{'/abandon'}}
    $url=$target.backendUrl.TrimEnd('/')+'/api/v1/platform/identity-provider-executor/claims'+$suffix
    $content=[Net.Http.StringContent]::new(($body|ConvertTo-Json -Compress),[Text.Encoding]::UTF8,'application/json');$message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$url);$message.Content=$content;$deadline=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(15));$response=$null;$memory=$null
    try{
        $response=$client.SendAsync($message,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$deadline.Token).GetAwaiter().GetResult();if(-not $response.IsSuccessStatusCode){throw 'Machine request not accepted.'}
        if($response.Content.Headers.ContentLength -gt 32768){throw 'Machine response is oversized.'}
        $stream=$response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult();try{$memory=[IO.MemoryStream]::new();$buffer=[byte[]]::new(4096);while(($count=$stream.ReadAsync($buffer,0,$buffer.Length,$deadline.Token).GetAwaiter().GetResult()) -gt 0){$memory.Write($buffer,0,$count);if($memory.Length -gt 32768){throw 'Machine response is oversized.'}};$text=[Text.UTF8Encoding]::new($false,$true).GetString($memory.ToArray())}finally{$stream.Dispose();if($memory){$memory.Dispose()}}
        $document=[Text.Json.JsonDocument]::Parse($text);try{Test-IdentityJsonNames $document.RootElement}finally{$document.Dispose()};$reply=ConvertFrom-Json -InputObject $text -AsHashtable
        Test-IdentityReleaseProperties $reply @('operationId','claimId','state','executionAllowed','canFinalizeHostPointer','currentConfirmedOperationId','canClearPendingHostPointer','environmentId','versionId','preparationId','providerJarSha256','parentApkSha256','kind')
        if($reply.operationId -cne $QueryOperationId -or $reply.claimId -cne $QueryClaimId -or $reply.environmentId -cne $target.environmentId -or $reply.executionAllowed -isnot [bool] -or $reply.canFinalizeHostPointer -isnot [bool] -or $reply.canClearPendingHostPointer -isnot [bool] -or $reply.providerJarSha256 -cnotmatch '^[0-9a-f]{64}$' -or $reply.parentApkSha256 -cnotmatch '^[0-9a-f]{64}$' -or $reply.kind -cnotin @('PUBLISH','ROLLBACK') -or $reply.state -cnotin @('WAITING_EXECUTOR','CLAIMED','EXECUTION_UNKNOWN','APPLIED_CLOSED','CANCELLED')){throw 'Machine response binding is invalid.'}
        if($null -ne $reply.currentConfirmedOperationId -and $reply.currentConfirmedOperationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'){throw 'Machine current confirmation binding is invalid.'}
        foreach($name in @('versionId','preparationId')){if($reply[$name] -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'){throw 'Machine response version binding is invalid.'}}
        return $reply
    }finally{$message.Dispose();$deadline.Dispose();if($response){$response.Dispose()}}
}
function SaveJournal([string]$Phase){$journal.phase=$Phase;Write-IdentityReleasePrivateFile $journalPath ($journal|ConvertTo-Json -Depth 8) -Replace}
function SavePointer($Reply,[string]$State){
    $active=[ordered]@{schemaVersion=1;environmentId=$target.environmentId;operationId=$OperationId;versionId=$Reply.versionId;claimId=$journal.claimId;state=$State;overlaySha256=$journal.overlaySha256;versionProof=$journal.versionProof}
    $active.proof=Get-IdentityReleaseProof $key @('family-identity-host-active-v1',$active.environmentId,$active.operationId,$active.versionId,$active.claimId,$active.state,$active.overlaySha256,$active.versionProof)
    Write-IdentityReleasePrivateFile (Join-Path $target._root 'identity-release-active.json') ($active|ConvertTo-Json) -Replace
}
function RestoreCancelledPointer($Reply){
    if($Reply.state -cne 'CANCELLED'){return}
    $path=Join-Path $target._root 'identity-release-active.json';if(-not(Test-Path -LiteralPath $path)){return};$pending=Read-IdentityReleaseJson $path
    if($pending.operationId -cne $OperationId){return}
    if($pending.state -cne 'EXECUTION_UNKNOWN'){throw 'Cancelled operation has an unexpected host pointer.'}
    [void](Get-IdentityReleaseVerifiedOverlay $target._root $pending -AllowPending)
    if($journal.Contains('previousPointer') -and $null -ne $journal.previousPointer){
        $previous=$journal.previousPointer;if($Reply.currentConfirmedOperationId -cne $previous.operationId){throw 'Previous confirmed release is no longer current.'}
        $current=Machine 'QUERY' '' $previous.operationId $previous.claimId
        if(-not $current.canFinalizeHostPointer -or $current.versionId -cne $previous.versionId -or $current.providerJarSha256 -cne $target.providerJarSha256){throw 'Previous confirmed release cannot be restored.'}
        [void](Get-IdentityReleaseVerifiedOverlay $target._root $previous)
        Write-IdentityReleasePrivateFile $path ($previous|ConvertTo-Json -Depth 8) -Replace
    }elseif($Reply.canClearPendingHostPointer -and $null -eq $Reply.currentConfirmedOperationId){[void](Assert-IdentityReleasePath $path -Private);Remove-Item -LiteralPath $path -Force}
    else{throw 'First release cancellation is awaiting server confirmation.'}
}
function AbandonBeforeBegin(){
    SaveJournal 'ABANDON_REQUESTED';$abandoned=Machine 'ABANDON_BEFORE_BEGIN'
    if($abandoned.state -ceq 'CANCELLED'){RestoreCancelledPointer $abandoned;SaveJournal 'ABANDONED'}
}
function Docker([string[]]$Arguments,[int]$Timeout=180){
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Command docker -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)};$process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{[void]$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if(-not $process.WaitForExit($Timeout*1000)){try{$process.Kill($true)}catch{};throw 'Identity executor command result is unknown.'};$output=$stdout.GetAwaiter().GetResult();$errorOutput=$stderr.GetAwaiter().GetResult();if($process.ExitCode -ne 0){throw 'Identity executor command failed.'};return $output.Trim()}
    finally{$process.Dispose()}
}
try{
    $target=Get-IdentityReleaseTarget $TargetFile;$key=Read-IdentityReleaseKey $target.executorKeyFile
    $hostLock=Enter-IdentityReleaseHostLock $target._root
    [void](Assert-IdentityReleasePath (Join-Path $target._root '.env') -Private)
    $envText=[IO.File]::ReadAllText((Join-Path $target._root '.env'))
    foreach($name in @('CONSUMER_PHONE_ENABLED','CONSUMER_WECHAT_ENABLED','FAMILY_ACCOUNT_SECURITY_ENABLED','FAMILY_SALES_ENABLED')){if($envText -notmatch ('(?m)^'+$name+'=(?:''false''|false)\r?$')){throw 'This executor requires closed consumer and sales switches.'}}
    $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(15)
    $journalPath=Join-Path $target._root ('identity-release-'+$OperationId+'.json');$resuming=Test-Path -LiteralPath $journalPath;$stage='IMAGE'
    if(-not $resuming){
        if((Invoke-IdentityReleaseDocker -Arguments @('image','inspect','--format','{{.Id}}',$target.identityImageId) -Timeout 15) -cne $target.identityImageId){throw 'Pinned identity image is unavailable.'}
        Test-IdentityReleaseComposeOwnership $target
    };$stage='CLAIM'
    if($resuming){$journal=Read-IdentityReleaseJson $journalPath;if($journal.operationId -cne $OperationId -or $journal.environmentId -cne $target.environmentId){throw 'Host journal does not match the operation.'};$reply=Machine 'QUERY'
        if($reply.state -ceq 'CANCELLED'){RestoreCancelledPointer $reply;SaveJournal 'ABANDONED';[Console]::Out.WriteLine('原操作已取消；未重复执行身份重启。');exit 2}
        if($reply.state -ceq 'APPLIED_CLOSED' -and $journal.Contains('overlaySha256')){
            $currentPointer=Read-IdentityReleaseJson (Join-Path $target._root 'identity-release-active.json')
            if(-not $reply.canFinalizeHostPointer -or $currentPointer.operationId -cne $OperationId){[Console]::Out.WriteLine('已查询历史操作；当前运行版本保持不变。');exit 2}
            if($reply.providerJarSha256 -cne $target.providerJarSha256){throw 'Pinned provider differs from this confirmed operation.'}
            $overlay=Join-Path $target._root ('identity-provider-releases/'+$OperationId+'/identity-runtime.compose.json');if((Get-FileHash -LiteralPath $overlay -Algorithm SHA256).Hash.ToLowerInvariant() -cne $journal.overlaySha256 -or (Get-IdentityReleaseVersionProof $key $target._root $OperationId) -cne $journal.versionProof){throw 'Host release files changed.'};SavePointer $reply 'APPLIED_CLOSED';SaveJournal 'CONFIRMED';[Console]::Out.WriteLine('配置已由身份进程确认；消费者入口和销售仍关闭。');exit 0
        }
        if($reply.state -ceq 'CLAIMED' -and $journal.phase -cin @('BEGIN_REQUESTED','ABANDON_REQUESTED','ABANDONED')){AbandonBeforeBegin;[Console]::Out.WriteLine('尚未执行的原操作已安全取消；未重启身份服务。');exit 2}
        if($journal.phase -cin @('BEGIN_REQUESTED','EXECUTION_UNKNOWN','REPORTING','CONFIRMED','ABANDON_REQUESTED','ABANDONED')){[Console]::Out.WriteLine('已查询原操作；执行结果尚需管理端核对，不重复重启。');exit 2}
        if($reply.state -cne 'CLAIMED'){throw 'Original operation is not resumable.'};SaveJournal 'CLAIMED'
    }else{
        $previous=$null;if(Test-Path -LiteralPath (Join-Path $target._root 'identity-release-active.json')){[void](Get-IdentityReleaseActiveOverlay $target._root);$previous=Read-IdentityReleaseJson (Join-Path $target._root 'identity-release-active.json')}
        $journal=[ordered]@{schemaVersion=1;operationId=$OperationId;environmentId=$target.environmentId;claimId=[Guid]::NewGuid().ToString();phase='CLAIM_REQUESTED';previousPointer=$previous}
        Write-IdentityReleasePrivateFile $journalPath ($journal|ConvertTo-Json);$reply=Machine 'CLAIM';if($reply.state -cne 'CLAIMED'){throw 'Operation was not claimed.'};SaveJournal 'CLAIMED'
    }
    # A resumable, never-started claim must recheck deployment ownership immediately before it can consume BEGIN.
    if($resuming){
        if((Invoke-IdentityReleaseDocker -Arguments @('image','inspect','--format','{{.Id}}',$target.identityImageId) -Timeout 15) -cne $target.identityImageId){throw 'Pinned identity image is unavailable.'}
        Test-IdentityReleaseComposeOwnership $target
    }
    if($reply.providerJarSha256 -cne $target.providerJarSha256){throw 'Approved provider differs from this fixed host target.'}
    $releases=Join-Path $target._root 'identity-provider-releases';if(-not (Test-Path -LiteralPath $releases)){[void](New-Item -ItemType Directory -Path $releases)};[void](Assert-IdentityReleasePath $releases -Private)
    $versionDirectory=Join-Path $releases $OperationId;$stage='PREPARE'
    if(-not (Test-Path -LiteralPath $versionDirectory)){
        & (Join-Path $PSScriptRoot 'prepare_family_identity_release.ps1') -BundleFile (Join-Path $target.releaseDirectory ($reply.preparationId+'.json')) -KeyFile $target.vaultKeyFile -OutputDirectory $versionDirectory -EnvironmentId $target.environmentId -VersionId $reply.versionId -DeploymentDirectory $target._root | Out-Null
        if($LASTEXITCODE -ne 0){throw 'Identity release preparation failed.'}
    }
    $prepared=Read-IdentityReleaseJson (Join-Path $versionDirectory 'prepared-release.json');if($prepared.environmentId -cne $target.environmentId -or $prepared.versionId -cne $reply.versionId -or $prepared.applied -ne $false){throw 'Prepared release is not bound to this operation.'}
    $environment=[ordered]@{CONSUMER_PHONE_ENABLED='false';CONSUMER_WECHAT_ENABLED='false';CONSUMER_ACCOUNT_SECURITY_ENABLED='false';IDENTITY_PROVIDER_ENVIRONMENT_ID=$target.environmentId;IDENTITY_PROVIDER_VERSION_ID=$reply.versionId;IDENTITY_PROVIDER_OPERATION_ID=$OperationId;IDENTITY_PROVIDER_INSTANCE_ID=$target.instanceId;IDENTITY_PROVIDER_OBSERVATION_KEY_FILE='/run/identity-provider-observation-key';ALIYUN_SMS_SIGN_NAME=$prepared.settings.smsSignName;ALIYUN_SMS_TEMPLATE_CODE=$prepared.settings.smsTemplateCode;WECHAT_NATIVE_APP_ID=$prepared.settings.wechatAppId}
    foreach($entry in @{CONSUMER_OTP_HMAC_KEY='consumer_otp_hmac_key';ALIYUN_SMS_ACCESS_KEY_ID='consumer_sms_access_key_id';ALIYUN_SMS_ACCESS_KEY_SECRET='consumer_sms_access_key_secret';ALIYUN_SMS_SECURITY_TOKEN='consumer_sms_security_token';WECHAT_NATIVE_APP_SECRET='consumer_wechat_app_secret'}.GetEnumerator()){$environment[$entry.Key+'_FILE']='/run/identity-provider-version/secrets/'+$entry.Value}
    $overlayPath=Join-Path $versionDirectory 'identity-runtime.compose.json'
    $overlay=@{services=@{identity=@{image=$target.identityImageId;pull_policy='never';environment=$environment;volumes=@(@{type='bind';source=$versionDirectory.Replace('\','/');target='/run/identity-provider-version';read_only=$true;bind=@{create_host_path=$false}},@{type='bind';source=$target.observationKeyFile.Replace('\','/');target='/run/identity-provider-observation-key';read_only=$true;bind=@{create_host_path=$false}})}}}
    if(-not (Test-Path -LiteralPath $overlayPath)){Write-IdentityReleasePrivateFile $overlayPath ($overlay|ConvertTo-Json -Depth 14)}
    $stage='BEGIN';$journal.overlaySha256=(Get-FileHash -LiteralPath $overlayPath -Algorithm SHA256).Hash.ToLowerInvariant();$journal.versionProof=Get-IdentityReleaseVersionProof $key $target._root $OperationId;SaveJournal 'PREPARED'
    # Persist the pending identity version before sending BEGIN. A lost ticket reply cannot make ordinary start select an older version.
    SavePointer $reply 'EXECUTION_UNKNOWN';SaveJournal 'BEGIN_REQUESTED'
    $begun=Machine 'BEGIN';if($begun.executionAllowed -ne $true -or $begun.state -cne 'EXECUTION_UNKNOWN' -or $begun.versionId -cne $reply.versionId -or $begun.preparationId -cne $reply.preparationId -or $begun.providerJarSha256 -cne $target.providerJarSha256 -or $begun.parentApkSha256 -cne $reply.parentApkSha256){if($begun.state -ceq 'CLAIMED'){AbandonBeforeBegin};throw 'Execution was not authorized for this original claim.'}
    SavePointer $begun 'EXECUTION_UNKNOWN';SaveJournal 'EXECUTION_UNKNOWN'
    try{
        $repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $arguments=@('compose','--project-directory',$target._root,'--env-file',(Join-Path $target._root '.env'),'-p',$target._project,'-f',(Join-Path $repository 'deploy/compose/compose.yaml'),'-f',(Join-Path $repository 'deploy/compose/compose.family.yaml'))+(Get-IdentityReleaseConfigurationArguments $target.adminDirectory $target.runtimeDirectory $target.environmentId)+@('-f',(Join-Path $repository 'deploy/compose/compose.identity-runtime-image.yaml'),'-f',$overlayPath,'up','-d','--no-deps','--no-build','--pull','never','--force-recreate','--wait','--wait-timeout','120','identity')
        [void](Docker $arguments);SaveJournal 'REPORTING';$finished=Machine 'REPORT' 'FINISHED'
        if($finished.state -ceq 'APPLIED_CLOSED' -and $finished.canFinalizeHostPointer -and $finished.providerJarSha256 -ceq $target.providerJarSha256){SavePointer $finished 'APPLIED_CLOSED';SaveJournal 'CONFIRMED';[Console]::Out.WriteLine('配置已由身份进程确认；消费者入口和销售仍关闭。');exit 0}
        [Console]::Out.WriteLine('已执行受控重建，尚待身份进程核对；不会重复重启。');exit 2
    }catch{try{[void](Machine 'REPORT' 'UNKNOWN')}catch{};throw}
}catch{
    if($journal -and $journal.phase -cin @('CLAIMED','PREPARED')){try{AbandonBeforeBegin}catch{}}
    [Console]::Error.WriteLine('身份发布未完成（EXECUTOR_'+$stage+'）；请查询管理端原操作。未启用消费者入口或销售，不自动重复重启。');exit 1
}
finally{if($client){$client.Dispose()};if($hostLock){$hostLock.Dispose()};if($key){[Array]::Clear($key,0,$key.Length)}}
