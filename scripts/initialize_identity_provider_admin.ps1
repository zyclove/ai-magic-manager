#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Directory,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{2,63}$')][string]$EnvironmentId = 'family-cn-pilot'
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
if (-not $allowed -or $destination -match "[`r`n']") { throw 'Use a new directory inside the repository ignored configuration roots.' }
function AssertPlainPath([string]$Path) {
    $cursor = [IO.DirectoryInfo]::new($Path)
    while ($null -ne $cursor) {
        if (Test-Path -LiteralPath $cursor.FullName) {
            $item = Get-Item -LiteralPath $cursor.FullName -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked configuration paths are not accepted.' }
        }
        $cursor = $cursor.Parent
    }
}
AssertPlainPath $destination
if (Test-Path -LiteralPath $destination) { throw 'Configuration directory already exists; preserve its files and choose a new directory.' }
$null = New-Item -ItemType Directory -Path $destination
if ($IsWindows) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($identity)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($identity, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $destination -AclObject $acl
} else {
    [IO.File]::SetUnixFileMode($destination, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
}
$encoding = [Text.UTF8Encoding]::new($false)
function WritePrivateNew([string]$Name, [string]$Content) {
    AssertPlainPath $destination
    $file = Join-Path $destination $Name
    $stream = [IO.File]::Open($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes = $encoding.GetBytes($Content); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($file, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
}
$keyId = 'identity-provider-' + [Guid]::NewGuid().ToString('N')
$keyBytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
try {
    $key = [ordered]@{kty='oct';use='enc';alg='dir';kid=$keyId;k=([Convert]::ToBase64String($keyBytes).TrimEnd('=').Replace('+','-').Replace('/','_'))}
    WritePrivateNew 'provider-keyring.json' (@{keys=@($key)} | ConvertTo-Json -Depth 5)
} finally { [Array]::Clear($keyBytes, 0, $keyBytes.Length); $key = $null }
$null = New-Item -ItemType Directory -Path (Join-Path $destination 'release-preparations')
$fragment = @(
    "IDENTITY_PROVIDER_ADMIN_ROOT='$($destination.Replace('\','/'))'",
    "IDENTITY_PROVIDER_ACTIVE_KEY_ID='$keyId'",
    "IDENTITY_PROVIDER_ENVIRONMENT_ID='$EnvironmentId'"
) -join "`n"
WritePrivateNew 'identity-admin.env' ($fragment + "`n")
WritePrivateNew 'admin-setup.json' ([ordered]@{
    schemaVersion=1;environmentId=$EnvironmentId;keyId=$keyId;
    runtimeStatus='APPLY_REQUIRED';servicesStarted=$false;salesAllowed=$false;
    keyMaterialIncluded=$false;keyDigestIncluded=$false
} | ConvertTo-Json -Depth 4)
WritePrivateNew 'NEXT_STEPS.md' @'
# Administrator configuration infrastructure prepared

This is a new, private configuration directory. No existing deployment or identity realm was changed.

Review identity-admin.env together with deploy/compose/compose.identity-admin.yaml. Apply the overlay only to a separately verified deployment and check the backend process can read the keyring and write release-preparations. On Linux use the existing deployment APP_UID/APP_GID for ownership; do not make the key world-readable.

The keyring is purpose-specific. Back it up through your restricted secret-management process, keep old keys during rotation, and never paste it into the browser, logs or a chat. The browser only writes SMS/WeChat replacements; it cannot read this master key or existing credentials.

Add dedicated platform roles using an offline reviewed realm export. Assign roles only to authorized administrators with MFA. Existing realms are never replaced by this setup tool.

Saving provider configuration produces a draft. Preparing a release produces encrypted files only. The identity service remains unchanged until a controlled deployment and instance verification. SMS/WeChat, account-security and sales gates are not enabled by this tool.
'@
Write-Output 'Provider administration infrastructure prepared in a new private directory. No service or provider request was started.'
