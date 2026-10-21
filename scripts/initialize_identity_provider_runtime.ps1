#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Directory,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{2,63}$')][string]$EnvironmentId = 'family-cn-pilot',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{2,63}$')][string]$InstanceId = 'identity-1',
    [string]$ObservationUrl = 'http://identity:8080/identity/realms/ai-manager/consumer-account/runtime-observation'
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$destination = [IO.Path]::GetFullPath($Directory, $repository)
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$allowed = $false
foreach ($relative in @('.cache', '.local')) {
    $boundary = [IO.Path]::GetFullPath((Join-Path $repository $relative))
    if ($destination.StartsWith($boundary + [IO.Path]::DirectorySeparatorChar, $comparison)) { $allowed = $true }
}
if (-not $allowed -or $destination -match "[`r`n']") { throw 'Use a new runtime directory inside repository ignored configuration roots.' }
$uri = $null
if (-not [Uri]::TryCreate($ObservationUrl, [UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
    $uri.AbsolutePath -cne '/identity/realms/ai-manager/consumer-account/runtime-observation' -or
    $ObservationUrl -match '[\s\\]' -or
    ($uri.Scheme -eq 'http' -and -not $uri.IsLoopback -and $uri.Host -cne 'identity')) {
    throw 'Use the fixed runtime observation resource on an internal identity host, loopback or reviewed HTTPS origin.'
}
function AssertPlainRuntimePath([string]$Path) {
    $cursor = [IO.DirectoryInfo]::new($Path)
    while ($null -ne $cursor) {
        if (Test-Path -LiteralPath $cursor.FullName) {
            $item = Get-Item -LiteralPath $cursor.FullName -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked runtime configuration paths are not accepted.' }
        }
        $cursor = $cursor.Parent
    }
}
AssertPlainRuntimePath $destination
if (Test-Path -LiteralPath $destination) { throw 'Runtime configuration already exists; preserve its keys and use a new directory.' }
$null = New-Item -ItemType Directory -Path $destination
if ($IsWindows) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($identity)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($identity, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $destination -AclObject $acl
} else {
    [IO.File]::SetUnixFileMode($destination, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
}
$encoding = [Text.UTF8Encoding]::new($false)
function WritePrivateRuntimeFile([string]$Name, [string]$Content) {
    AssertPlainRuntimePath $destination
    $file = Join-Path $destination $Name
    $stream = [IO.File]::Open($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes = $encoding.GetBytes($Content); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($file, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
}
foreach ($name in @('executor-key', 'observation-key')) {
    $keyBytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    try {
        $encoded = [Convert]::ToBase64String($keyBytes).TrimEnd('=').Replace('+','-').Replace('/','_')
        WritePrivateRuntimeFile $name $encoded
    } finally { [Array]::Clear($keyBytes, 0, $keyBytes.Length); $encoded = $null }
}
WritePrivateRuntimeFile 'runtime-inventory.json' ([ordered]@{
    schemaVersion=1;environmentId=$EnvironmentId;
    instances=@([ordered]@{instanceId=$InstanceId;url=$ObservationUrl;keyFile='/run/identity-provider-runtime/observation-key'})
} | ConvertTo-Json -Depth 5)
WritePrivateRuntimeFile 'identity-runtime.env' ((@(
    "IDENTITY_PROVIDER_RUNTIME_ROOT='$($destination.Replace('\','/'))'",
    "IDENTITY_PROVIDER_ENVIRONMENT_ID='$EnvironmentId'"
) -join "`n") + "`n")
WritePrivateRuntimeFile 'runtime-setup.json' ([ordered]@{
    schemaVersion=1;environmentId=$EnvironmentId;instanceId=$InstanceId;configuredInstances=1;
    runtimeStatus='APPLY_REQUIRED';servicesStarted=$false;existingDeploymentChanged=$false;salesAllowed=$false;
    keyMaterialIncluded=$false;keyDigestIncluded=$false
} | ConvertTo-Json -Depth 4)
WritePrivateRuntimeFile 'NEXT_STEPS.md' @'
# Runtime infrastructure prepared

This fresh private directory does not replace the existing provider vault or deployment. The executor key and observation key are independent of one another, the vault, OTP HMAC and supplier credentials.

Review identity-runtime.env with deploy/compose/compose.identity-runtime-control.yaml and the existing identity administration overlay. The backend receives only three readonly file mounts. Check the inventory environment and fixed instance URL before use. There is no Docker socket or service start in this setup tool.

The observation key must also be provided through the reviewed identity release target; never expose it in the browser, command arguments, ordinary logs or chat. Set ownership for the actual backend/identity UID in Linux without granting world or group access. Keep an independent restricted backup.

Provision the fixed host executor target against a verified ConsumerIdentity deployment and pinned actual identity image. Run only the approved operation through the release runner. One current host executor supports one instance; do not partially deploy a larger inventory. An unknown execution result must be reconciled by querying the original claim and observing the actual instance, not by repeating the restart.

All consumer and sales switches stay closed. A configuration confirmation is not real SMS/WeChat acceptance. Use docs/family-identity-provider-release.md for the controlled release and rollback procedure.
'@
Write-Output 'Runtime verification infrastructure prepared in a new private directory. Existing keys, services and data are unchanged.'
