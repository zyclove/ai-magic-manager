#Requires -Version 7.0
<# Binds a single existing consumer deployment to a verified immutable image. Does not start it. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DeploymentDirectory,
    [Parameter(Mandatory)][string]$AdminDirectory,
    [Parameter(Mandatory)][string]$RuntimeDirectory,
    [Parameter(Mandatory)][string]$BackendUrl,
    [Parameter(Mandatory)][ValidatePattern('^sha256:[0-9a-f]{64}$')][string]$IdentityImageId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ProviderJarSha256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'family-identity-release-common.ps1')
$created=$false;$verified=$false;$scratch=$null;$container=$null;$id=[Guid]::NewGuid().ToString('N')
try{
    $root=Assert-IdentityReleasePath ([IO.Path]::GetFullPath($DeploymentDirectory)) -Private
    $admin=Assert-IdentityReleasePath ([IO.Path]::GetFullPath($AdminDirectory)) -Private;$runtime=Assert-IdentityReleasePath ([IO.Path]::GetFullPath($RuntimeDirectory)) -Private
    $targetFile=Join-Path $root 'identity-release-target.json';if(Test-Path -LiteralPath $targetFile){throw 'Identity deployment target already exists.'}
    $inventory=Read-IdentityReleaseJson (Join-Path $runtime 'runtime-inventory.json');if($inventory.instances.Count -ne 1){throw 'This executor supports exactly one identity instance.'}
    $target=[ordered]@{schemaVersion=1;environmentId=$inventory.environmentId;instanceId=$inventory.instances[0].instanceId;backendUrl=$BackendUrl;deploymentDirectory=$root;adminDirectory=$admin;runtimeDirectory=$runtime;releaseDirectory=(Join-Path $admin 'release-preparations');vaultKeyFile=(Join-Path $admin 'provider-keyring.json');executorKeyFile=(Join-Path $runtime 'executor-key');observationKeyFile=(Join-Path $runtime 'observation-key');runtimeInventoryFile=(Join-Path $runtime 'runtime-inventory.json');identityImageId=$IdentityImageId;providerJarSha256=$ProviderJarSha256}
    # Validate the full fixed target before Docker. The temporary private file is not an active target.
    $temporary=Join-Path $root ('.identity-target-review-'+$id+'.json');Write-IdentityReleasePrivateFile $temporary ($target|ConvertTo-Json -Depth 8)
    try{
        $reviewedTarget=Get-IdentityReleaseTarget $temporary -Review
        $repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'));$local=[IO.Path]::GetFullPath((Join-Path $repository '.local'))+[IO.Path]::DirectorySeparatorChar
        if(-not $root.StartsWith($local,[StringComparison]::OrdinalIgnoreCase)){throw 'Use an existing repository consumer deployment.'}
        $deployment=Read-IdentityReleaseJson (Join-Path $root 'deployment.json');if($deployment.consumerIdentity -ne $true -or $deployment.schemaVersion -ne 1 -or $deployment.projectName -cnotmatch '^[a-z][a-z0-9-]{2,40}$'){throw 'Consumer deployment required.'}
        [void](Get-IdentityReleaseConfigurationArguments $admin $runtime $target.environmentId)
        $executor=Read-IdentityReleaseKey $target.executorKeyFile;$observation=Read-IdentityReleaseKey $target.observationKeyFile
        try{if([Security.Cryptography.CryptographicOperations]::FixedTimeEquals($executor,$observation)){throw 'Use independent machine keys.'}}finally{[Array]::Clear($executor,0,$executor.Length);[Array]::Clear($observation,0,$observation.Length)}
        $keyring=Read-IdentityReleaseJson $target.vaultKeyFile;if($keyring.keys.Count -lt 1 -or $keyring.keys.Count -gt 8){throw 'Identity vault key ring is unavailable.'}
        if((Invoke-IdentityReleaseDocker -Arguments @('image','inspect','--format','{{.Id}}',$IdentityImageId) -Timeout 15) -cne $IdentityImageId){throw 'Pinned identity image is unavailable.'}
        Test-IdentityReleaseComposeOwnership $reviewedTarget
        $scratch=Join-Path $repository ('.cache/family-provider-release-20261017-r2/runtime/tmp/target-'+$id);[void](New-Item -ItemType Directory -Path $scratch)
        if(-not $IsWindows){[IO.File]::SetUnixFileMode($scratch,[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)}
        $container='provider-image-inspect-'+$id;$label='com.aimanager.identity-image-inspection'
        [void](Invoke-IdentityReleaseDocker -Arguments @('create','--name',$container,'--network','none','--label',($label+'='+$id),'--entrypoint','/bin/true',$IdentityImageId) -Timeout 30);$created=$true
        $jar=Join-Path $scratch 'provider.jar';[void](Invoke-IdentityReleaseDocker -Arguments @('cp',($container+':/opt/keycloak/providers/consumer-identity-1.0.0.jar'),$jar) -Timeout 30)
        [void](Assert-IdentityReleasePath $jar)
        if((Get-FileHash -LiteralPath $jar -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ProviderJarSha256){throw 'Actual pinned image provider differs from the approved JAR.'}
        $zip=[IO.Compression.ZipFile]::OpenRead($jar);try{if(-not $zip.GetEntry('com/aimanager/identity/ConsumerProviderRuntime.class')){throw 'Pinned image has no runtime observation provider.'};foreach($entry in $zip.Entries){if($entry.FullName -match '(?i)(MysqlAcceptance|MysqlIdentityAcceptance|private-test-only-fixture)'){throw 'Pinned image contains private acceptance code.'}}}finally{$zip.Dispose()}
        Write-IdentityReleasePrivateFile $targetFile ($target|ConvertTo-Json -Depth 8);$verified=$true
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
    [Console]::Out.WriteLine('已绑定现有单实例部署和实际镜像；尚未发布配置或启动服务。')
}catch{[Console]::Error.WriteLine('身份发布目标准备失败；目录、权限、实例或实际镜像未通过。未修改现有服务。');exit 1}
finally{
    if($created){$owned=Invoke-IdentityReleaseDocker -Arguments @('inspect','--format',('{{index .Config.Labels "com.aimanager.identity-image-inspection"}}'),$container) -Timeout 15;if($owned -ceq $id){[void](Invoke-IdentityReleaseDocker -Arguments @('rm',$container) -Timeout 30)}else{throw 'Owned inspection container requires manual review.'}}
    if($scratch -and (Test-Path -LiteralPath $scratch)){
        $receipt=[ordered]@{id=$id;kind='owned-image-inspection';targetVerified=$verified;servicesStarted=$false;providerRequestsPerformed=$false;files=@(Get-ChildItem -LiteralPath $scratch -File|ForEach-Object{@{path=$_.Name;bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})}
        $out=Join-Path $PSScriptRoot '../.cache/family-provider-release-20261017-r2/runtime/out/target-inspection';[void](New-Item -ItemType Directory -Path $out -Force);[IO.File]::WriteAllText((Join-Path $out ($id+'.json')),($receipt|ConvertTo-Json -Depth 6))
        $resolved=Assert-IdentityReleasePath $scratch;$expected=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('../.cache/family-provider-release-20261017-r2/runtime/tmp/target-'+$id)));if($resolved -cne $expected){throw 'Inspection cleanup path changed.'};foreach($file in Get-ChildItem -LiteralPath $resolved -File){Remove-Item -LiteralPath $file.FullName -Force};Remove-Item -LiteralPath $resolved
    }
}
