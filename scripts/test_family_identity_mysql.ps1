<#
Isolated identity acceptance. All creates, verifies and cleans only resources bearing its run label.
For interactive use: Start returns after creation; Verify checks readiness and runs once; Cleanup is
required after either success or failure. The original lifecycle.json permits safe cleanup after an
interrupted executor. UserRowProbe writes diagnostic-only evidence and never a full verification.
SMS and WeChat transport are private fixtures; no real supplier acceptance or sales are enabled.
#>
[CmdletBinding()]
param(
    [switch]$PlanOnly,
    [switch]$SqlDiagnostics,
    [switch]$UserRowProbe,
    [switch]$FederatedIdentityProbe,
    [ValidateSet('All','Start','Verify','Cleanup')][string]$Phase='All',
    [string]$OutputDirectory,
    [string]$JavaHome = 'C:/Program Files/Java/jdk-17',
    [string]$MavenRepository,
    [string]$ProviderJar
)
$ErrorActionPreference = 'Stop'
if($UserRowProbe -and $FederatedIdentityProbe){throw 'Select one focused diagnostic at a time.'}
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$plan = [ordered]@{
    resourcePrefix='account-mysql-'; networkInternal=$true; hostPorts=@(); persistentVolumes=@();
    mysqlTmpfs=$true; realSupplierAcceptance=$false; salesEnabled=$false; fixtureExcludedFromProduction=$true
    identityHostname='https://127.0.0.1:8443/identity';identityRelativePath='/identity';tlsHostnameVerification=$true;trustAllCertificates=$false
    keycloakStartMode='start';httpListenerEnabled=$false
    defaultEvidenceDirectory='.cache/family-identity-acceptance/mysql-<run-id>'
}
if ($PlanOnly) { $plan | ConvertTo-Json -Depth 5; exit 0 }
function AssertNoReparseAncestors([string]$path) {
    $current=[IO.Path]::GetFullPath($path)
    while($current){
        if(Test-Path -LiteralPath $current){
            if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Evidence path or ancestor is a reparse point; refused before Docker or file writes.'}
        }
        $parent=[IO.Directory]::GetParent($current)
        if($null -eq $parent){break};$current=$parent.FullName
    }
}
function AssertProductionJar([string]$path){
    AssertNoReparseAncestors $path
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'Production provider JAR is missing.'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($path)
    try{
        $names=@{};$total=0L
        foreach($entry in $zip.Entries){
            if($names.ContainsKey($entry.FullName)){throw 'Production provider JAR has duplicate entries.'};$names[$entry.FullName]=$true
            $total+=$entry.Length
            if($total -gt 16777216 -or $entry.FullName -match '(^/|(^|/)\.\.(/|$)|\\)'){throw 'Production provider JAR is invalid.'}
            if($entry.FullName -match '(?i)(MysqlAcceptance|MysqlIdentityAcceptance|private-test-only-fixture)'){throw 'Production provider JAR contains an acceptance fixture; refused.'}
            if($entry.FullName.StartsWith('META-INF/services/')){
                $reader=[IO.StreamReader]::new($entry.Open())
                try{$registration=$reader.ReadToEnd()}finally{$reader.Dispose()}
                if($registration -match '(?i)(MysqlAcceptance|MysqlIdentityAcceptance|private-test-only-fixture)'){throw 'Production provider JAR registers an acceptance fixture; refused.'}
            }
        }
        foreach($expected in @('ConsumerAuthenticator','ConsumerAccountFlow','ConsumerClaimsMapper')){
            if(-not $names.ContainsKey('com/aimanager/identity/'+$expected+'.class')){throw 'Production provider JAR is missing an expected production class.'}
        }
    }finally{$zip.Dispose()}
    return $true
}
if (-not $OutputDirectory) {
    if($Phase -in @('Verify','Cleanup')){throw 'Resume phases require the original evidence directory.'}
    $OutputDirectory=Join-Path $repository ('.cache/family-identity-acceptance/mysql-'+[Guid]::NewGuid().ToString('N'))
}
$output=[IO.Path]::GetFullPath($OutputDirectory)
$local=[IO.Path]::GetFullPath((Join-Path $repository '.local'))+[IO.Path]::DirectorySeparatorChar
$cache=[IO.Path]::GetFullPath((Join-Path $repository '.cache'))+[IO.Path]::DirectorySeparatorChar
AssertNoReparseAncestors $output
if (-not ($output.StartsWith($cache,[StringComparison]::OrdinalIgnoreCase) -or $output.StartsWith($local,[StringComparison]::OrdinalIgnoreCase))) {
    throw 'Use an isolated evidence directory below this repository .cache directory; existing .local evidence remains supported.'
}
if($Phase -in @('All','Start') -and (Test-Path -LiteralPath $output)){throw 'Use a new isolated evidence directory below this repository .cache directory.'}
if($Phase -in @('Verify','Cleanup') -and -not (Test-Path -LiteralPath $output -PathType Container)){throw 'Original evidence directory is missing.'}
if (-not $MavenRepository) { $MavenRepository=Join-Path $repository '.local/m2' }
if (-not $ProviderJar) { $ProviderJar=Join-Path $repository 'identity-extensions/target/consumer-identity-1.0.0.jar' }
$fixtureExcludedFromProduction=$false
if($Phase -in @('All','Start')){
    $fixtureExcludedFromProduction=AssertProductionJar ([IO.Path]::GetFullPath($ProviderJar))
    $null=New-Item -ItemType Directory -Path $output
}
AssertNoReparseAncestors $output
$classes=Join-Path $output 'out/fixture-classes'; $client=Join-Path $output 'out/client-classes'; $temp=Join-Path $output 'tmp'
if($Phase -in @('All','Start')){$null=New-Item -ItemType Directory -Path $classes,$client,$temp}
$env:TEMP=$temp; $env:TMP=$temp
$id=[Guid]::NewGuid().ToString('N').Substring(0,12)
$prefix='account-mysql-'+$id; $network=$prefix+'-network'; $mysql=$prefix+'-db'; $identity=$prefix+'-idp'
$label='com.aimanager.account-acceptance'; $created=@(); $networkCreated=$false; $failure=$null
$stateFile=Join-Path $output 'lifecycle.json'
function SaveLifecycle{
    [ordered]@{schemaVersion=2;outputDirectory=$output;id=$id;network=$network;mysql=$mysql;identity=$identity;created=$created;networkCreated=$networkCreated;phase=$Phase} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding utf8
}
if($Phase -in @('Verify','Cleanup')){
    AssertNoReparseAncestors $stateFile
    $state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if($state.schemaVersion -notin @(1,2) -or $state.id -notmatch '^[a-f0-9]{12}$'){throw 'Invalid isolated test lifecycle.'}
    if($state.schemaVersion -eq 2){
        if(-not $state.outputDirectory -or -not [IO.Path]::GetFullPath($state.outputDirectory).Equals($output,[StringComparison]::OrdinalIgnoreCase)){throw 'Lifecycle does not match the exact original evidence directory.'}
    }elseif(-not $output.StartsWith($local,[StringComparison]::OrdinalIgnoreCase)){throw 'Legacy lifecycle is supported only in its original evidence directory below .local.'}
    $id=$state.id;$prefix='account-mysql-'+$id;$network=$prefix+'-network';$mysql=$prefix+'-db';$identity=$prefix+'-idp'
    if($state.network -ne $network -or $state.mysql -ne $mysql -or $state.identity -ne $identity){throw 'Invalid isolated test lifecycle resource names.'}
    foreach($item in $state.created){if($item -notin @($mysql,$identity)){throw 'Invalid isolated test lifecycle resource ownership.'}}
    $created=@($state.created);$networkCreated=$state.networkCreated -eq $true
}else{SaveLifecycle}
if($Phase -in @('All','Verify') -and ((Test-Path -LiteralPath (Join-Path $output 'acceptance.log')) -or (Test-Path -LiteralPath (Join-Path $output 'verification.json')))){
    throw 'This runtime already has acceptance evidence; create a new isolated runtime instead of overwriting it.'
}
$diagnosticPrefix=if($UserRowProbe){'user-row-diagnostic'}elseif($FederatedIdentityProbe){'federated-identity-diagnostic'}else{$null}
if($diagnosticPrefix -and (Test-Path -LiteralPath (Join-Path $output ($diagnosticPrefix+'.log')))){throw 'This runtime already has diagnostic evidence; do not overwrite it.'}
function Docker([string[]]$Arguments) {
    $result=& docker.exe @Arguments 2>&1
    if($LASTEXITCODE -ne 0){ throw ('Isolated Docker command failed: '+($result -join "`n")) }
    return ($result -join "`n")
}
function AssertOwned([string]$type,[string]$name){
    $value=if($type -eq 'container'){Docker @('inspect','--format',('{{ index .Config.Labels "'+$label+'" }}'),$name)}else{Docker @($type,'inspect','--format',('{{ index .Labels "'+$label+'" }}'),$name)}
    if($value.Trim() -ne $id){throw 'Cleanup refused: resource ownership label does not match this run.'}
}
try {
  if($Phase -in @('All','Start')){
    $sourceSnapshot=Join-Path $output 'src/source-snapshot';$sourceManifest=@()
    foreach($relative in @('scripts/test_family_identity_mysql.ps1','scripts/identity_acceptance/MysqlAcceptanceFactory.java','scripts/identity_acceptance/MysqlAcceptanceAuthenticatorFactory.java','scripts/identity_acceptance/MysqlIdentityAcceptance.java','scripts/tests/test_family_identity_mysql.py')){
      $source=Join-Path $repository $relative;$destination=Join-Path $sourceSnapshot $relative
      $null=New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
      Copy-Item -LiteralPath $source -Destination $destination
      $sourceManifest+=@{path=$relative;sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $sourceManifestFile=Join-Path $output 'source-manifest.json';$sourceManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $sourceManifestFile -Encoding utf8
    $frozenAcceptance=Join-Path $sourceSnapshot 'scripts/identity_acceptance'
    $images=@{}
    foreach($image in @('mysql:8.4.11','quay.io/keycloak/keycloak:26.8.0')){
        $images[$image]=Docker @('image','inspect','--format','{{.Id}}',$image)
    }
    Copy-Item -LiteralPath $ProviderJar -Destination (Join-Path $output 'production-provider.jar')
    $production=Join-Path $output 'production-provider.jar'
    $fixtureExcludedFromProduction=AssertProductionJar $production
    $jars=@(Get-ChildItem -LiteralPath (Join-Path $MavenRepository 'org/keycloak') -Recurse -Filter '*26.8.0.jar' | ForEach-Object FullName)
    foreach($relative in @('jakarta/persistence','jakarta/ws/rs','org/jboss/logging','com/fasterxml/jackson/core')){
        $jars+=@(Get-ChildItem -LiteralPath (Join-Path $MavenRepository $relative) -Recurse -Filter '*.jar' | ForEach-Object FullName)
    }
    $classpath=(@($production)+$jars) -join [IO.Path]::PathSeparator
    & (Join-Path $JavaHome 'bin/javac.exe') -encoding UTF-8 -cp $classpath -d $classes (Join-Path $frozenAcceptance 'MysqlAcceptanceFactory.java') (Join-Path $frozenAcceptance 'MysqlAcceptanceAuthenticatorFactory.java')
    if($LASTEXITCODE -ne 0){throw 'Private fixture compilation failed.'}
    & (Join-Path $JavaHome 'bin/javac.exe') -encoding UTF-8 -cp $classpath -d $client (Join-Path $frozenAcceptance 'MysqlIdentityAcceptance.java')
    if($LASTEXITCODE -ne 0){throw 'Private OIDC acceptance client compilation failed.'}
    $clientManifestFile=Join-Path $output 'client-manifest.json'
    @(Get-ChildItem -LiteralPath $client -File | Sort-Object Name | ForEach-Object {@{path=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}}) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $clientManifestFile -Encoding utf8
    $services=Join-Path $classes 'META-INF/services';$null=New-Item -ItemType Directory -Path $services -Force
    [IO.File]::WriteAllText((Join-Path $services 'org.keycloak.services.resource.RealmResourceProviderFactory'),"com.aimanager.identity.MysqlAcceptanceFactory`n")
    [IO.File]::WriteAllText((Join-Path $services 'org.keycloak.authentication.AuthenticatorFactory'),"com.aimanager.identity.MysqlAcceptanceAuthenticatorFactory`n")
    $fixture=Join-Path $output 'private-test-only-fixture.jar'
    & (Join-Path $JavaHome 'bin/jar.exe') --create --file $fixture -C $classes .
    if($LASTEXITCODE -ne 0){throw 'Private fixture packaging failed.'}
    $testKeystore=Join-Path $output 'private-test-only-tls.p12'
    $keytoolOutput=& (Join-Path $JavaHome 'bin/keytool.exe') -genkeypair -alias isolated-test -keyalg RSA -keysize 2048 -validity 2 -storetype PKCS12 -keystore $testKeystore -storepass fixture-only -keypass fixture-only -dname 'CN=localhost' -ext 'SAN=ip:127.0.0.1,dns:localhost' 2>&1
    if($LASTEXITCODE -ne 0){throw 'Isolated TLS test certificate generation failed.'}
    $management=Join-Path $output 'management-realm.json';$consumer=Join-Path $output 'consumer-realm.json'
    Copy-Item -LiteralPath (Join-Path $repository 'deploy/keycloak/realm-template.json') -Destination $management
    & (Join-Path $repository 'deploy/keycloak/merge-consumer-realm.ps1') -InputPath $management -OutputPath $consumer
    $realm=Get-Content -LiteralPath $consumer -Raw | ConvertFrom-Json -AsHashtable
    $realm.users=@()
    foreach($flow in $realm.authenticationFlows){foreach($execution in $flow.authenticationExecutions){if($execution.authenticator -eq 'consumer-cn-phone-wechat'){$execution.authenticator='mysql-acceptance-authenticator'}}}
    $parent=$realm.clients | Where-Object clientId -eq 'ai-manager-parent'
    $parent.optionalClientScopes=@('offline_access')
    $realm.clientScopes+=@(@{name='offline_access';protocol='openid-connect';attributes=@{'include.in.token.scope'='true'}})
    $realm.roles.realm+=@(@{name='offline_access'})
    $realm.scopeMappings+=@(@{clientScope='offline_access';roles=@('offline_access')})
    $realmFile=Join-Path $output 'realm-fixture-only.json'
    [IO.File]::WriteAllText($realmFile,($realm | ConvertTo-Json -Depth 60))
    $null=Docker @('network','create','--internal','--label',"$label=$id",$network);$networkCreated=$true;SaveLifecycle
    $null=Docker @('create','--name',$mysql,'--network',$network,'--network-alias','fixture-mysql','--label',"$label=$id",'--memory','768m','--tmpfs','/var/lib/mysql:rw,size=512m','--tmpfs','/var/run/mysqld:rw,size=32m','-e','MYSQL_ALLOW_EMPTY_PASSWORD=yes','-e','MYSQL_DATABASE=isolated_identity','-e','MYSQL_USER=fixture','-e','MYSQL_PASSWORD=fixture-only','mysql:8.4.11','--skip-log-bin','--innodb-buffer-pool-size=64M','--transaction-isolation=REPEATABLE-READ','--innodb-lock-wait-timeout=4');$created+=$mysql;SaveLifecycle
    $null=Docker @('start',$mysql)
    $ready=$false
    for($i=0;$i -lt 60;$i++){& docker.exe exec $mysql mysqladmin ping --silent -uroot 2>$null | Out-Null;if($LASTEXITCODE -eq 0){$ready=$true;break};Start-Sleep -Milliseconds 500}
    if(-not $ready){throw 'New ephemeral MySQL did not become ready.'}
    $theme=[IO.Path]::GetFullPath((Join-Path $repository 'deploy/keycloak/themes'))
    $containerArgs=@('create','--name',$identity,'--network',$network,'--label',"$label=$id",'--memory','1200m',
        '-e','JAVA_OPTS_KC_HEAP=-Xms128m -Xmx512m',
        '-e','KC_DB=mysql','-e','KC_DB_URL=jdbc:mysql://fixture-mysql:3306/isolated_identity','-e','KC_DB_USERNAME=fixture','-e','KC_DB_PASSWORD=fixture-only','-e',('KC_HTTP_RELATIVE_PATH='+$plan.identityRelativePath))
    if($SqlDiagnostics){$containerArgs+=@('-e','KC_LOG_LEVEL=INFO,org.hibernate.SQL:DEBUG')}
    foreach($setting in @('CONSUMER_PHONE_ENABLED=true','CONSUMER_WECHAT_ENABLED=true','CONSUMER_ACCOUNT_SECURITY_ENABLED=true',
        'CONSUMER_OTP_HMAC_KEY=isolated-fixture-hmac-key-at-least-32-bytes','ALIYUN_SMS_ACCESS_KEY_ID=fixture-only','ALIYUN_SMS_ACCESS_KEY_SECRET=fixture-only',
        'ALIYUN_SMS_SIGN_NAME=fixture-only','ALIYUN_SMS_TEMPLATE_CODE=fixture-only','WECHAT_NATIVE_APP_ID=wx-fixture','WECHAT_NATIVE_APP_SECRET=fixture-only')){$containerArgs+=@('-e',$setting)}
    $containerArgs+=@('quay.io/keycloak/keycloak:26.8.0',$plan.keycloakStartMode,'--import-realm',('--hostname='+$plan.identityHostname),'--http-enabled=false','--https-key-store-file=/fixture-test-tls.p12','--https-key-store-password=fixture-only','--cache=local')
    $null=Docker $containerArgs;$created+=$identity;SaveLifecycle
    $containerData=Join-Path $output 'container-data';$null=New-Item -ItemType Directory -Path (Join-Path $containerData 'import')
    Copy-Item -LiteralPath $realmFile -Destination (Join-Path $containerData 'import/realm-fixture-only.json')
    $null=Docker @('cp',$production,($identity+':/opt/keycloak/providers/production-provider.jar'))
    $null=Docker @('cp',$fixture,($identity+':/opt/keycloak/providers/private-test-only-fixture.jar'))
    $null=Docker @('cp',$testKeystore,($identity+':/fixture-test-tls.p12'))
    $null=Docker @('cp',($containerData+'/.'),($identity+':/opt/keycloak/data'))
    $null=Docker @('cp',($theme+'/.'),($identity+':/opt/keycloak/themes'))
    $null=Docker @('cp',$client,($identity+':/fixture-client'))
    $null=Docker @('start',$identity)
    $inspect=(@{networkInternal=$true;hostPorts=@();mysqlTmpfs=$true;database='new isolated_identity';images=$images;realSupplierAcceptance=$false;fixtureExcludedFromProduction=$fixtureExcludedFromProduction;providerSha256=(Get-FileHash -LiteralPath $production -Algorithm SHA256).Hash.ToLowerInvariant();fixtureSha256=(Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant();keycloakNodeCount=1;cacheMode='local';multiNodeInvalidationVerified=$false;tlsHostnameVerification=$true;trustAllCertificates=$false;tlsCertificate='ephemeral self-signed test certificate';realmSslRequired=$realm.sslRequired})
    $inspect.sqlStatementDiagnostics=$SqlDiagnostics.IsPresent
    $inspect.sourceManifestSha256=(Get-FileHash -LiteralPath $sourceManifestFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $inspect.clientManifestSha256=(Get-FileHash -LiteralPath $clientManifestFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $inspect | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'runtime-inspection.json') -Encoding utf8
    Write-Output "Isolated runtime started; lifecycle saved: $stateFile"
  }
  if($Phase -in @('All','Verify')){
    AssertOwned 'container' $mysql;AssertOwned 'container' $identity;AssertOwned 'network' $network
    $inspect=Get-Content -LiteralPath (Join-Path $output 'runtime-inspection.json') -Raw | ConvertFrom-Json -AsHashtable
    $clientArguments=@();if($UserRowProbe){$clientArguments+=@('--user-row-probe')};if($FederatedIdentityProbe){$clientArguments+=@('--federated-identity-probe')}
    $run=& docker.exe exec $identity java '-Djavax.net.ssl.trustStore=/fixture-test-tls.p12' '-Djavax.net.ssl.trustStorePassword=fixture-only' '-Djavax.net.ssl.trustStoreType=PKCS12' -cp '/fixture-client:/opt/keycloak/lib/lib/main/*' MysqlIdentityAcceptance @clientArguments 2>&1
    $exit=$LASTEXITCODE
    $resultLog=if($diagnosticPrefix){$diagnosticPrefix+'.log'}else{'acceptance.log'}
    $run | Set-Content -LiteralPath (Join-Path $output $resultLog) -Encoding utf8
    if($diagnosticPrefix){
      [ordered]@{scope=$diagnosticPrefix;completeAcceptance=$false;status=$(if($exit -eq 0){'PASS'}else{'FAIL'});providerSha256=$inspect.providerSha256;sourceManifestSha256=$inspect.sourceManifestSha256;clientManifestSha256=$inspect.clientManifestSha256;realSupplierAcceptance=$false;salesEnabled=$false} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output ($diagnosticPrefix+'.json')) -Encoding utf8
      if($exit -ne 0){throw 'Focused diagnostic failed; this is not full acceptance.'}
      $run | Where-Object {"$_".StartsWith('DIAGNOSTIC ')} | Write-Output
    }else{
    if($exit -ne 0){throw 'Isolated MySQL/OIDC acceptance failed; see the private acceptance and server logs.'}
    $evidence=($run | Where-Object {"$_".StartsWith('EVIDENCE ')} | Select-Object -Last 1).Substring(9) | ConvertFrom-Json -AsHashtable
    $evidence.providerSha256=$inspect.providerSha256;$evidence.images=$inspect.images;$evidence.hostPorts=@();$evidence.networkInternal=$true
    $evidence.keycloakNodeCount=1;$evidence.cacheMode='local';$evidence.multiNodeInvalidationVerified=$false;$evidence.fixtureExcludedFromProduction=$inspect.fixtureExcludedFromProduction
    $evidence.tlsHostnameVerification=$true;$evidence.trustAllCertificates=$false;$evidence.tlsCertificate=$inspect.tlsCertificate
    $evidence.realmSslRequired=$inspect.realmSslRequired
    $evidence.sqlStatementDiagnostics=$inspect.sqlStatementDiagnostics
    $evidence.fixtureSha256=$inspect.fixtureSha256;$evidence.sourceManifestSha256=$inspect.sourceManifestSha256;$evidence.clientManifestSha256=$inspect.clientManifestSha256
    $evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'verification.json') -Encoding utf8
    $run | Where-Object {"$_".StartsWith('PASS ')} | Write-Output
    }
  }
} catch { $failure=$_ } finally {
    foreach($name in $created){try{& docker.exe logs $name 2>&1 | Set-Content -LiteralPath (Join-Path $output ($name+'-server.log')) -Encoding utf8}catch{}}
  if($Phase -in @('All','Cleanup') -or ($Phase -eq 'Start' -and $failure)){
    $cleanupOrder=@($created);[array]::Reverse($cleanupOrder)
    foreach($name in $cleanupOrder){
        AssertOwned 'container' $name
        $null=Docker @('rm','--force',$name)
    }
    if($networkCreated){AssertOwned 'network' $network;$null=Docker @('network','rm',$network)}
    [ordered]@{containersRemoved=$created;networkRemoved=$networkCreated;labelVerified=$true;existingServicesTouched=$false} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'cleanup.json') -Encoding utf8
  }
}
if($failure){throw $failure}
Write-Output "Evidence saved: $output"
