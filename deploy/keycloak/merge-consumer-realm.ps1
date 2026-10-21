[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference='Stop'
if ([IO.Path]::GetFullPath($InputPath) -eq [IO.Path]::GetFullPath($OutputPath) -or (Test-Path -LiteralPath $OutputPath)) {
    throw 'Consumer realm conversion requires a new output file; preserve the original export.'
}
# Offline export transformation only. No credentials, Admin API, or running realm mutation.
$consumerRealm=Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json -AsHashtable
$consumerFlowId='3a8a2a8d-653f-4a2a-a2af-8ea44fa15d01'
$consumerFlow=@{
    id=$consumerFlowId;alias='consumer-phone-browser';providerId='basic-flow';topLevel=$true;builtIn=$false
    authenticationExecutions=@(@{authenticator='consumer-cn-phone-wechat';requirement='REQUIRED';priority=10;authenticatorFlow=$false})
}
$consumerRealm.authenticationFlows=@($consumerRealm.authenticationFlows | Where-Object alias -ne 'consumer-phone-browser')+@($consumerFlow)
$consumerClient=@($consumerRealm.clients | Where-Object clientId -eq 'ai-manager-parent')
if($consumerClient.Count -ne 1){throw 'Expected exactly one ai-manager-parent client'}
$consumerClient=$consumerClient[0]
if(-not $consumerClient.authenticationFlowBindingOverrides){$consumerClient.authenticationFlowBindingOverrides=@{}}
$consumerClient.authenticationFlowBindingOverrides.browser=$consumerFlowId
$consumerClient.protocolMappers=@($consumerClient.protocolMappers | Where-Object {$_.protocolMapper -notin @('oidc-amr-mapper','consumer-trusted-claims')})+@(@{
    name='Verified consumer claims';protocol='openid-connect';protocolMapper='consumer-trusted-claims'
    config=@{'access.token.claim'='true';'id.token.claim'='true';'userinfo.token.claim'='true'}
})
if(-not $consumerRealm.components){$consumerRealm.components=@{}}
$consumerProfileType='org.keycloak.userprofile.UserProfileProvider'
$consumerProfiles=@($consumerRealm.components[$consumerProfileType] | Where-Object providerId -eq 'declarative-user-profile')
if($consumerProfiles.Count -gt 1){throw 'Multiple declarative user profiles require manual reconciliation'}
if($consumerProfiles.Count -eq 1){
    $consumerProfileComponent=$consumerProfiles[0]
    $consumerProfile=$consumerProfileComponent.config.'kc.user.profile.config'[0] | ConvertFrom-Json -AsHashtable
}else{
    $consumerProfileComponent=@{providerId='declarative-user-profile';name='declarative-user-profile';config=@{}}
    $consumerProfile=@{attributes=@(
        @{name='username';permissions=@{view=@('admin','user');edit=@('admin','user')};validations=@{length=@{min=3;max=255}}},
        @{name='email';permissions=@{view=@('admin','user');edit=@('admin','user')};validations=@{email=@{}}},
        @{name='firstName';permissions=@{view=@('admin','user');edit=@('admin','user')}},
        @{name='lastName';permissions=@{view=@('admin','user');edit=@('admin','user')}}
    );groups=@()}
}
$consumerProfile.unmanagedAttributePolicy='ADMIN_EDIT'
$consumerProfile.attributes=@($consumerProfile.attributes | Where-Object name -notin @('consumer_phone_number','consumer_phone_verified','consumer_identity_revision','consumer_last_operation_id','consumer_last_operation_action','consumer_last_operation_at'))+@(
    @{name='consumer_phone_number';permissions=@{view=@('admin');edit=@('admin')};validations=@{pattern=@{pattern='\+861[3-9][0-9]{9}'}}},
    @{name='consumer_phone_verified';permissions=@{view=@('admin');edit=@('admin')};validations=@{pattern=@{pattern='true|false'}}},
    @{name='consumer_identity_revision';permissions=@{view=@('admin');edit=@('admin')};validations=@{pattern=@{pattern='[1-9][0-9]{0,9}'}}},
    @{name='consumer_last_operation_id';permissions=@{view=@('admin');edit=@('admin')};validations=@{pattern=@{pattern='[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}'}}},
    @{name='consumer_last_operation_action';permissions=@{view=@('admin');edit=@('admin')};validations=@{pattern=@{pattern='CHANGE_PHONE|RECOVER_PHONE|BIND_WECHAT|UNBIND_WECHAT'}}},
    @{name='consumer_last_operation_at';permissions=@{view=@('admin');edit=@('admin')};validations=@{pattern=@{pattern='[0-9]{1,16}'}}}
)
$consumerProfileComponent.config.'kc.user.profile.config'=@(($consumerProfile | ConvertTo-Json -Depth 50 -Compress))
$consumerRealm.components[$consumerProfileType]=@($consumerRealm.components[$consumerProfileType] | Where-Object { $null -ne $_ -and $_.providerId -ne 'declarative-user-profile' })+@($consumerProfileComponent)
$consumerRealm.editUsernameAllowed=$false
$consumerRealm | ConvertTo-Json -Depth 70 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Output "Consumer realm export written: $OutputPath"
