# Shared host-side checks. This file does not execute Docker or provider requests.
function Assert-IdentityReleasePath([string]$Path,[switch]$Private){
    Set-StrictMode -Version 3.0
    $absolute=[IO.Path]::GetFullPath($Path)
    for($cursor=$absolute;$cursor;$cursor=[IO.Path]::GetDirectoryName($cursor)){
        if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked identity deployment path refused.'}
        if($cursor -eq [IO.Path]::GetPathRoot($cursor)){break}
    }
    if($Private -and (Test-Path -LiteralPath $absolute)){
        if($IsWindows){
            $allowed=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544');$acl=Get-Acl -LiteralPath $absolute
            if($allowed -cnotcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value){throw 'Identity deployment owner is not restricted.'}
            foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq 'Allow' -and $allowed -cnotcontains $rule.IdentityReference.Value){throw 'Identity deployment permissions are not restricted.'}}
        }elseif(([int][IO.File]::GetUnixFileMode($absolute) -band 63) -ne 0){throw 'Identity deployment permissions are not restricted.'}
    };return $absolute
}
function Enter-IdentityReleaseHostLock([string]$DeploymentRoot){
    Set-StrictMode -Version 3.0
    [void](Assert-IdentityReleasePath $DeploymentRoot);$path=Join-Path $DeploymentRoot 'identity-release-host.lock';[void](Assert-IdentityReleasePath $path)
    for($attempt=0;$attempt -lt 5;$attempt++){
        try{return [IO.FileStream]::new($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch [IO.IOException]{if($attempt -eq 4){throw 'Another identity release or deployment start is in progress; retry after it completes.'};Start-Sleep -Milliseconds 100}
    }
}
function Read-IdentityReleaseJson([string]$Path){
    Set-StrictMode -Version 3.0
    [void](Assert-IdentityReleasePath $Path -Private);$stream=[IO.File]::OpenRead($Path);try{if($stream.Length -gt 65536){throw 'Identity deployment file is oversized.'};$bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes)}finally{$stream.Dispose()}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);$document=[Text.Json.JsonDocument]::Parse($text)
    try{Test-IdentityJsonNames $document.RootElement}finally{$document.Dispose()}
    return ConvertFrom-Json -InputObject $text -AsHashtable -Depth 24
}
function Test-IdentityJsonNames([Text.Json.JsonElement]$Element){
    Set-StrictMode -Version 3.0
    if($Element.ValueKind -eq 'Object'){$names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($item in $Element.EnumerateObject()){if(-not $names.Add($item.Name)){throw 'Duplicate identity deployment property.'};Test-IdentityJsonNames $item.Value}}
    elseif($Element.ValueKind -eq 'Array'){foreach($item in $Element.EnumerateArray()){Test-IdentityJsonNames $item}}
}
function Test-IdentityReleaseProperties($Object,[string[]]$Properties){
    Set-StrictMode -Version 3.0
    if($Object -isnot [Collections.IDictionary] -or $Object.Count -ne $Properties.Count){throw 'Identity deployment schema is invalid.'};foreach($name in $Object.Keys){if($Properties -cnotcontains $name){throw 'Identity deployment property is invalid.'}}
}
function Read-IdentityReleaseKey([string]$Path){
    Set-StrictMode -Version 3.0
    [void](Assert-IdentityReleasePath $Path -Private);$stream=[IO.File]::OpenRead($Path);try{if($stream.Length -gt 45){throw 'Identity deployment key is invalid.'};$bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes)}finally{$stream.Dispose()};$encoded=[Text.Encoding]::ASCII.GetString($bytes).TrimEnd([char[]]@(10,13))
    if($encoded -cnotmatch '^[A-Za-z0-9_-]{43}$'){throw 'Identity deployment key is invalid.'};$key=[Convert]::FromBase64String($encoded.Replace('-','+').Replace('_','/')+'=')
    if($key.Length -ne 32 -or [Convert]::ToBase64String($key).TrimEnd('=').Replace('+','-').Replace('/','_') -cne $encoded){throw 'Identity deployment key is invalid.'};return ,$key
}
function Get-IdentityReleaseProof([byte[]]$Key,[string[]]$Values){
    Set-StrictMode -Version 3.0
    $hmac=[Security.Cryptography.HMACSHA256]::new($Key);$stream=[IO.MemoryStream]::new()
    try{foreach($value in $Values){$bytes=[Text.Encoding]::UTF8.GetBytes($value);$prefix=[Text.Encoding]::ASCII.GetBytes([string]$bytes.Length+':');$stream.Write($prefix);$stream.Write($bytes)};return [Convert]::ToBase64String($hmac.ComputeHash($stream.ToArray())).TrimEnd('=').Replace('+','-').Replace('/','_')}
    finally{$hmac.Dispose();$stream.Dispose()}
}
function Invoke-IdentityReleaseDocker([string[]]$Arguments,[int]$Timeout=180){
    Set-StrictMode -Version 3.0
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Command docker -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)};$process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{[void]$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if(-not $process.WaitForExit($Timeout*1000)){try{$process.Kill($true)}catch{};throw 'Identity host command result is unknown.'};$output=$stdout.GetAwaiter().GetResult();[void]$stderr.GetAwaiter().GetResult();if($process.ExitCode -ne 0){throw 'Identity host command failed.'};return $output.Trim()}
    finally{$process.Dispose()}
}
function Write-IdentityReleasePrivateFile([string]$Path,[string]$Text,[switch]$Replace){
    Set-StrictMode -Version 3.0
    [void](Assert-IdentityReleasePath $Path);$parent=[IO.Path]::GetDirectoryName($Path);[void](Assert-IdentityReleasePath $parent -Private);$temporary=Join-Path $parent ('.identity-write-'+[Guid]::NewGuid().ToString('N'))
    $stream=$null
    try{
        if($IsWindows){$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$acl=[Security.AccessControl.FileSecurity]::new();$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false);foreach($allowed in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){[void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($allowed,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))};$stream=[IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($temporary),[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough,$acl)}
        else{$options=[IO.FileStreamOptions]::new();$options.Mode=[IO.FileMode]::CreateNew;$options.Access=[IO.FileAccess]::Write;$options.UnixCreateMode=[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite;$stream=[IO.FileStream]::new($temporary,$options)}
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Text);$stream.Write($bytes);$stream.Flush($true);$stream.Dispose();$stream=$null
        [IO.File]::Move($temporary,$Path,$Replace.IsPresent)
    }finally{if($null -ne $stream){$stream.Dispose()};if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Get-IdentityReleaseTarget([string]$TargetFile,[switch]$Review){
    Set-StrictMode -Version 3.0
    $target=Read-IdentityReleaseJson $TargetFile
    Test-IdentityReleaseProperties $target @('schemaVersion','environmentId','instanceId','backendUrl','deploymentDirectory','adminDirectory','runtimeDirectory','releaseDirectory','vaultKeyFile','executorKeyFile','observationKeyFile','runtimeInventoryFile','identityImageId','providerJarSha256')
    if($target.schemaVersion -ne 1 -or $target.environmentId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{2,63}$' -or $target.instanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{2,63}$' -or $target.identityImageId -cnotmatch '^sha256:[0-9a-f]{64}$' -or $target.providerJarSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Identity release target is invalid.'}
    $root=Assert-IdentityReleasePath $target.deploymentDirectory -Private;$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'));$local=[IO.Path]::GetFullPath((Join-Path $repository '.local'))+[IO.Path]::DirectorySeparatorChar;$comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $file=[IO.Path]::GetFullPath($TargetFile);$reviewFile=$Review -and [IO.Path]::GetDirectoryName($file) -ceq $root -and [IO.Path]::GetFileName($file) -cmatch '^\.identity-target-review-[0-9a-f]{32}\.json$'
    if(-not $root.StartsWith($local,$comparison) -or ($file -cne (Join-Path $root 'identity-release-target.json') -and -not $reviewFile)){throw 'Identity release target must bind its selected deployment.'}
    $deployment=Read-IdentityReleaseJson (Join-Path $root 'deployment.json');if($deployment.schemaVersion -ne 1 -or $deployment.consumerIdentity -ne $true -or $deployment.projectName -cnotmatch '^[a-z][a-z0-9-]{2,40}$'){throw 'A consumer identity deployment is required.'}
    $inventory=Read-IdentityReleaseJson $target.runtimeInventoryFile
    Test-IdentityReleaseProperties $inventory @('schemaVersion','environmentId','instances')
    if($inventory.schemaVersion -ne 1 -or $inventory.environmentId -cne $target.environmentId -or $inventory.instances -isnot [array] -or $inventory.instances.Count -ne 1 -or $inventory.instances[0].instanceId -cne $target.instanceId){throw 'This executor requires exactly one bound identity instance.'}
    Test-IdentityReleaseProperties $inventory.instances[0] @('instanceId','url','keyFile')
    if($inventory.instances[0].keyFile -cne '/run/identity-provider-runtime/observation-key'){throw 'Identity runtime observation key binding differs.'}
    foreach($name in @('releaseDirectory','vaultKeyFile','executorKeyFile','observationKeyFile','runtimeInventoryFile')){[void](Assert-IdentityReleasePath $target[$name] -Private)}
    if($target.releaseDirectory -cne (Join-Path $target.adminDirectory 'release-preparations') -or $target.vaultKeyFile -cne (Join-Path $target.adminDirectory 'provider-keyring.json') -or
        $target.executorKeyFile -cne (Join-Path $target.runtimeDirectory 'executor-key') -or $target.observationKeyFile -cne (Join-Path $target.runtimeDirectory 'observation-key') -or $target.runtimeInventoryFile -cne (Join-Path $target.runtimeDirectory 'runtime-inventory.json')){throw 'Identity release infrastructure references are not bound.'}
    [void](Get-IdentityReleaseConfigurationArguments $target.adminDirectory $target.runtimeDirectory $target.environmentId)
    $executor=Read-IdentityReleaseKey $target.executorKeyFile;$observation=Read-IdentityReleaseKey $target.observationKeyFile
    try{if([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($executor,$observation)){throw 'Use independent machine keys.'}}finally{[Array]::Clear($executor,0,$executor.Length);[Array]::Clear($observation,0,$observation.Length)}
    $uri=[Uri]::new($target.backendUrl);if(-not $uri.IsAbsoluteUri -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/' -or ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback))){throw 'Identity executor requires a fixed HTTPS or loopback backend origin.'}
    $target['_root']=$root;$target['_project']=$deployment.projectName;return $target
}
function Get-IdentityReleaseConfigurationArguments([string]$AdminDirectory,[string]$RuntimeDirectory,[string]$EnvironmentId=''){
    Set-StrictMode -Version 3.0
    $arguments=[Collections.Generic.List[string]]::new();$environment=$EnvironmentId
    foreach($entry in @(@{root=$AdminDirectory;file='identity-admin.env';rootKey='IDENTITY_PROVIDER_ADMIN_ROOT';keys=@('IDENTITY_PROVIDER_ADMIN_ROOT','IDENTITY_PROVIDER_ACTIVE_KEY_ID','IDENTITY_PROVIDER_ENVIRONMENT_ID');overlay='compose.identity-admin.yaml'},@{root=$RuntimeDirectory;file='identity-runtime.env';rootKey='IDENTITY_PROVIDER_RUNTIME_ROOT';keys=@('IDENTITY_PROVIDER_RUNTIME_ROOT','IDENTITY_PROVIDER_ENVIRONMENT_ID');overlay='compose.identity-runtime-control.yaml'})){
        if(-not $entry.root){continue};$root=Assert-IdentityReleasePath $entry.root -Private;$file=Join-Path $root $entry.file;[void](Assert-IdentityReleasePath $file -Private)
        $values=@{};foreach($line in [IO.File]::ReadAllLines($file)){if($line -cnotmatch "^([A-Z_]+)='([^'`r`n]*)'$" -or $entry.keys -cnotcontains $Matches[1] -or $values.ContainsKey($Matches[1])){throw 'Identity configuration fragment has an unexpected value.'};$values[$Matches[1]]=$Matches[2]}
        if($values.Count -ne $entry.keys.Count -or $values[$entry.rootKey] -cne $root.Replace('\','/') -or $values.IDENTITY_PROVIDER_ENVIRONMENT_ID -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{2,63}$'){throw 'Identity configuration fragment does not match its directory.'}
        if($environment -and $environment -cne $values.IDENTITY_PROVIDER_ENVIRONMENT_ID){throw 'Identity configuration environment aliases differ.'};$environment=$values.IDENTITY_PROVIDER_ENVIRONMENT_ID
        $arguments.Add('--env-file');$arguments.Add($file);$arguments.Add('-f');$arguments.Add((Join-Path $PSScriptRoot ('../deploy/compose/'+$entry.overlay)))
    };return ,$arguments.ToArray()
}
function Test-IdentityReleaseComposeOwnership($Target){
    Set-StrictMode -Version 3.0
    $containers=Invoke-IdentityReleaseDocker -Arguments @('ps','--all','--filter',('label=com.docker.compose.project='+$Target._project),'--filter','label=com.docker.compose.service=identity','--format','{{.ID}}') -Timeout 15
    $ids=@($containers -split '[\r\n]+'|Where-Object{$_})
    if($ids.Count -gt 1){throw 'Identity deployment has multiple existing instances.'}
    if($ids.Count -eq 1){
        if($ids[0] -cnotmatch '^[0-9a-f]{12,64}$'){throw 'Identity container ownership is invalid.'}
        $json=Invoke-IdentityReleaseDocker -Arguments @('inspect','--format','{{json .Config.Labels}}',$ids[0]) -Timeout 15;$labels=ConvertFrom-Json -InputObject $json -AsHashtable
        if($labels['com.docker.compose.project'] -cne $Target._project -or $labels['com.docker.compose.service'] -cne 'identity' -or -not $labels.ContainsKey('com.docker.compose.project.working_dir')){throw 'Identity container belongs to a different deployment.'}
        $directory=[IO.Path]::GetFullPath($labels['com.docker.compose.project.working_dir']);$comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
        if(-not $directory.Equals($Target._root,$comparison)){throw 'Compose project already belongs to another deployment directory.'}
    }else{
        $manifest=Read-IdentityReleaseJson (Join-Path $Target._root 'release-manifest.json')
        if($manifest.schemaVersion -ne 1 -or $manifest.consumerIdentity -ne $true -or $manifest.artifactRoot -cnotmatch '^artifacts/release-[0-9a-f]{32}$' -or $manifest.identityProviderSha256 -cne $Target.providerJarSha256){throw 'Fresh identity deployment requires a verified consumer release.'}
        $jar=Join-Path $Target._root ($manifest.artifactRoot+'/keycloak/keycloak/providers/consumer-identity-1.0.0.jar');[void](Assert-IdentityReleasePath $jar -Private)
        if((Get-FileHash -LiteralPath $jar -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Target.providerJarSha256){throw 'Fresh deployment identity provider changed.'}
    }
}
function Get-IdentityReleaseActiveOverlay([string]$DeploymentRoot){
    Set-StrictMode -Version 3.0
    $pointer=Join-Path $DeploymentRoot 'identity-release-active.json';if(-not (Test-Path -LiteralPath $pointer)){return $null}
    return Get-IdentityReleaseVerifiedOverlay $DeploymentRoot (Read-IdentityReleaseJson $pointer)
}
function Get-IdentityReleaseVerifiedOverlay([string]$DeploymentRoot,$Active,[switch]$AllowPending){
    Set-StrictMode -Version 3.0
    $target=Get-IdentityReleaseTarget (Join-Path $DeploymentRoot 'identity-release-target.json');$active=$Active
    Test-IdentityReleaseProperties $active @('schemaVersion','environmentId','operationId','versionId','claimId','state','overlaySha256','versionProof','proof')
    if($active.schemaVersion -ne 1 -or $active.environmentId -cne $target.environmentId -or ($active.state -cne 'APPLIED_CLOSED' -and -not($AllowPending -and $active.state -ceq 'EXECUTION_UNKNOWN'))){throw 'Identity release is awaiting runtime confirmation; ordinary restart is blocked.'}
    foreach($field in @('operationId','versionId','claimId')){if($active[$field] -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'){throw 'Identity active release binding is invalid.'}}
    $key=Read-IdentityReleaseKey $target.executorKeyFile
    try{$proof=Get-IdentityReleaseProof $key @('family-identity-host-active-v1',$active.environmentId,$active.operationId,$active.versionId,$active.claimId,$active.state,$active.overlaySha256,$active.versionProof);$actualVersionProof=Get-IdentityReleaseVersionProof $key $DeploymentRoot $active.operationId}finally{[Array]::Clear($key,0,$key.Length)}
    if($active.proof -cne $proof){throw 'Identity active release authentication failed.'}
    if($active.versionProof -cne $actualVersionProof){throw 'Identity active release secret files changed.'}
    $overlay=Join-Path $DeploymentRoot ('identity-provider-releases/'+$active.operationId+'/identity-runtime.compose.json');[void](Assert-IdentityReleasePath $overlay -Private)
    if((Get-FileHash -LiteralPath $overlay -Algorithm SHA256).Hash.ToLowerInvariant() -cne $active.overlaySha256){throw 'Identity active release files changed.'};return $overlay
}
function Get-IdentityReleaseVersionProof([byte[]]$Key,[string]$DeploymentRoot,[string]$OperationId){
    Set-StrictMode -Version 3.0
    $values=[Collections.Generic.List[string]]::new();$values.Add('family-identity-host-version-v1');$values.Add($OperationId)
    foreach($name in @('consumer_otp_hmac_key','consumer_sms_access_key_id','consumer_sms_access_key_secret','consumer_sms_security_token','consumer_wechat_app_secret')){
        $path=Join-Path $DeploymentRoot ('identity-provider-releases/'+$OperationId+'/secrets/'+$name);[void](Assert-IdentityReleasePath $path -Private);$stream=[IO.File]::OpenRead($path)
        try{if($stream.Length -gt 8192){throw 'Identity release secret file is invalid.'};$bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes);$values.Add([Text.UTF8Encoding]::new($false,$true).GetString($bytes))}finally{$stream.Dispose()}
    };return Get-IdentityReleaseProof $Key $values.ToArray()
}
