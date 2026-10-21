[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
function AssertPlainExportPath([string]$Path) {
    $cursor = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path))
    while ($null -ne $cursor) {
        if (Test-Path -LiteralPath $cursor.FullName) {
            $item = Get-Item -LiteralPath $cursor.FullName -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked realm export paths are not accepted.' }
        }
        $cursor = $cursor.Parent
    }
}
$providerInputPath = [IO.Path]::GetFullPath($InputPath)
$providerOutputPath = [IO.Path]::GetFullPath($OutputPath)
AssertPlainExportPath $providerInputPath
AssertPlainExportPath $providerOutputPath
if ($providerInputPath -eq $providerOutputPath -or (Test-Path -LiteralPath $providerOutputPath)) {
    throw 'Use a new realm export output file; preserve the existing realm and export.'
}
if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($providerOutputPath)) -PathType Container)) {
    throw 'Choose an existing reviewed output directory.'
}
try {
    if ((Get-Item -LiteralPath $providerInputPath).Length -gt 8388608) { throw 'Too large' }
    $providerRealm = [IO.File]::ReadAllText($providerInputPath, [Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable
} catch { throw 'Realm export could not be read safely. Preserve and review the original file.' }
$providerScopes = @('identity-config:read', 'identity-config:manage', 'identity-config:test', 'identity-config:publish', 'identity-config:rollback')
$providerLegacyRoles = @('identity-provider-viewer', 'identity-provider-operator', 'identity-provider-tester')
$providerRoles = $providerLegacyRoles + @('identity-provider-publisher', 'identity-provider-rollback-operator')
$providerGuardian = @($providerRealm.clients | Where-Object clientId -eq 'ai-manager-guardian')
$providerParent = @($providerRealm.clients | Where-Object clientId -eq 'ai-manager-parent')
if ($providerGuardian.Count -ne 1 -or $providerParent.Count -ne 1 -or
    $providerGuardian[0].fullScopeAllowed -ne $false -or $providerParent[0].fullScopeAllowed -ne $false) {
    throw 'Expected one scope-restricted guardian and parent client. Reconcile the export first.'
}
foreach ($providerScope in @($providerParent[0].defaultClientScopes) + @($providerParent[0].optionalClientScopes)) {
    if ($providerScope -in $providerScopes) { throw 'Consumer client has a platform configuration scope. Reconcile the export first.' }
}
if (-not $providerRealm.roles) { $providerRealm.roles = @{} }
foreach ($providerRole in $providerRoles) {
    $providerExistingRole = @($providerRealm.roles.realm | Where-Object name -eq $providerRole)
    if ($providerExistingRole.Count -gt 1) { throw 'Duplicate provider platform role.' }
    if ($providerExistingRole.Count -eq 0) {
        $providerRealm.roles.realm = @($providerRealm.roles.realm) + @(@{name=$providerRole})
    }
}
foreach ($providerScope in $providerScopes) {
    $providerExistingScope = @($providerRealm.clientScopes | Where-Object name -eq $providerScope)
    if ($providerExistingScope.Count -gt 1) { throw 'Duplicate provider platform scope.' }
    if ($providerExistingScope.Count -eq 1) {
        if ($providerExistingScope[0].protocol -ne 'openid-connect' -or
            $providerExistingScope[0].attributes.'include.in.token.scope' -ne 'true') {
            throw 'Incompatible provider platform scope. Reconcile the export first.'
        }
    } else {
        $providerRealm.clientScopes = @($providerRealm.clientScopes) + @(@{
            name=$providerScope; protocol='openid-connect'; attributes=@{'include.in.token.scope'='true'}
        })
    }
    $providerExpectedRoles = switch ($providerScope) {
        'identity-config:read' { $providerRoles }
        'identity-config:manage' { @('identity-provider-operator') }
        'identity-config:test' { @('identity-provider-tester', 'identity-provider-publisher', 'identity-provider-rollback-operator') }
        'identity-config:publish' { @('identity-provider-publisher') }
        'identity-config:rollback' { @('identity-provider-rollback-operator') }
    }
    $providerMapping = @($providerRealm.scopeMappings | Where-Object clientScope -eq $providerScope)
    if ($providerMapping.Count -gt 1) { throw 'Duplicate provider platform scope mapping.' }
    if ($providerMapping.Count -eq 1) {
        $providerActualMapping = @($providerMapping[0].roles | Sort-Object) -join ','
        $providerLegacyMapping = switch ($providerScope) {
            'identity-config:read' { @($providerLegacyRoles | Sort-Object) -join ',' }
            'identity-config:test' { 'identity-provider-tester' }
            default { '' }
        }
        if ($providerActualMapping -ceq $providerLegacyMapping -and $providerLegacyMapping) {
            # Upgrade only the exact known prior contract. Never expand arbitrary assignments.
            $providerMapping[0].roles = @($providerExpectedRoles)
        } elseif ($providerActualMapping -cne (@($providerExpectedRoles | Sort-Object) -join ',')) {
            throw 'Incompatible provider platform role mapping. Reconcile the export first.'
        }
    } else {
        $providerRealm.scopeMappings = @($providerRealm.scopeMappings) + @(@{clientScope=$providerScope;roles=@($providerExpectedRoles)})
    }
    if ($providerScope -notin $providerGuardian[0].defaultClientScopes) {
        $providerGuardian[0].defaultClientScopes = @($providerGuardian[0].defaultClientScopes) + @($providerScope)
    }
}
# Offline export only: do not assign roles to users, call an Admin API or apply an identity realm.
AssertPlainExportPath $providerOutputPath
$providerBytes = [Text.UTF8Encoding]::new($false).GetBytes(($providerRealm | ConvertTo-Json -Depth 80))
$providerStream = $null
try {
    if ($IsWindows) {
        $providerIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $providerAcl = [Security.AccessControl.FileSecurity]::new()
        $providerAcl.SetOwner($providerIdentity)
        $providerAcl.SetAccessRuleProtection($true,$false)
        foreach ($providerSid in @($providerIdentity,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
            $providerAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($providerSid,'FullControl','Allow'))
        }
        # CreateNew with an explicit ACL restricts the file before any export bytes are written.
        $providerStream = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($providerOutputPath),[IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::None,$providerAcl)
    } else {
        $providerOptions = [IO.FileStreamOptions]::new()
        $providerOptions.Mode=[IO.FileMode]::CreateNew
        $providerOptions.Access=[IO.FileAccess]::Write
        $providerOptions.Share=[IO.FileShare]::None
        $providerOptions.UnixCreateMode=[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        $providerStream=[IO.FileStream]::new($providerOutputPath,$providerOptions)
    }
    $providerStream.Write($providerBytes,0,$providerBytes.Length)
    $providerStream.Flush($true)
} catch { throw 'Private realm export could not be created. No running identity realm was changed.' }
finally { if ($null -ne $providerStream) { $providerStream.Dispose() } }
Write-Output 'Provider administration permissions prepared in a new export; no running realm changed.'
