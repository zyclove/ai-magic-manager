#Requires -Version 7.0
<#
Read-only console activation selection. Only committed, mutually consistent
metadata can select a release. This module never reads runtime credentials or
invokes deployment commands; absence of a pointer permits the legacy launcher.
#>
function Get-ActiveConsoleSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $localRoot = Join-Path $repository '.local'
    $localPrefix = $localRoot + [IO.Path]::DirectorySeparatorChar

    function Test-ActivationPath {
        param([string]$Path, [ValidateSet('File', 'Directory')][string]$Kind, [switch]$AllowMissing)
        $current = $Path
        $leaf = $true
        $missing = $false
        while ($current) {
            try {
                $attributes = [IO.File]::GetAttributes($current)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Console activation paths must not contain reparse points.'
                }
                $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
                if (($leaf -and (($Kind -eq 'Directory') -ne $isDirectory)) -or (-not $leaf -and -not $isDirectory)) {
                    throw 'Console activation metadata has an invalid file or directory kind.'
                }
            } catch [IO.FileNotFoundException] {
                $missing = $true
            } catch [IO.DirectoryNotFoundException] {
                $missing = $true
            }
            $parent = [IO.Path]::GetDirectoryName($current)
            if ($parent -eq $current) { break }
            $current = $parent
            $leaf = $false
        }
        if ($missing -and -not $AllowMissing) { throw 'Required console activation evidence is missing.' }
        return -not $missing
    }

    function Get-ActivationHash([byte[]]$Bytes) {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
    }

    function Read-ActivationObject([string]$Path) {
        Assert-ActivationReadablePath $Path
        $null = Test-ActivationPath -Path $Path -Kind File
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -eq 0 -or $bytes.Length -gt 1048576) {
            throw 'Console activation metadata has an invalid size.'
        }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xfeff) { $text = $text.Substring(1) }
        $document = $null
        try {
            $document = [Text.Json.JsonDocument]::Parse($text)
            if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
                throw 'Console activation metadata must be a JSON object.'
            }
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $fields = [Collections.Generic.Dictionary[string, Text.Json.JsonElement]]::new([StringComparer]::Ordinal)
            foreach ($property in $document.RootElement.EnumerateObject()) {
                if (-not $seen.Add($property.Name)) { throw 'Console activation metadata has duplicate fields.' }
                $fields.Add($property.Name, $property.Value.Clone())
            }
            return @{ Fields=$fields; Hash=(Get-ActivationHash $bytes) }
        } finally {
            if ($null -ne $document) { $document.Dispose() }
        }
    }

    function Assert-ActivationReadablePath([string]$Path) {
        $full = [IO.Path]::GetFullPath($Path)
        $withoutRoot = $full.Substring([IO.Path]::GetPathRoot($full).Length)
        if ($withoutRoot.Contains(':') -or
            @($full -split '[\\/]' | Where-Object { $_ -ieq '.env' -or $_ -ieq 'secrets' }).Count -gt 0) {
            throw 'CONSOLE_ACTIVATION_PROTECTED_PATH: Activation metadata cannot refer to credentials or alternate streams.'
        }
    }

    function Assert-ActivationSchema($Object) {
        if (-not $Object.Fields.ContainsKey('schemaVersion') -or
            $Object.Fields['schemaVersion'].ValueKind -ne [Text.Json.JsonValueKind]::Number -or
            $Object.Fields['schemaVersion'].GetRawText() -cne '1') {
            throw 'Unsupported console activation metadata schema.'
        }
    }

    function Get-ActivationString($Object, [string]$Name) {
        if (-not $Object.Fields.ContainsKey($Name) -or
            $Object.Fields[$Name].ValueKind -ne [Text.Json.JsonValueKind]::String) {
            throw 'Required console activation metadata field is missing or invalid.'
        }
        $value = $Object.Fields[$Name].GetString()
        if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 4096 -or $value.Trim() -cne $value -or
            $value -match '[\x00-\x1f\x7f-\x9f]') {
            throw 'Console activation metadata contains an invalid value.'
        }
        return $value
    }

    function Resolve-ActivationLocalPath([string]$Value, [string]$Kind) {
        $full = [IO.Path]::GetFullPath($Value, $repository)
        Assert-ActivationReadablePath $full
        if (-not $full.StartsWith($localPrefix, $comparison)) {
            throw 'Console activation evidence must remain inside this repository .local directory.'
        }
        $null = Test-ActivationPath -Path $full -Kind $Kind
        return $full
    }

    function Assert-ActivationHashValue([string]$Value) {
        if ($Value -cnotmatch '\A[0-9a-f]{64}\z') { throw 'Console activation evidence needs a canonical SHA-256 hash.' }
    }

    function Assert-ActivationUnchanged([string]$Path, $Snapshot) {
        Assert-ActivationReadablePath $Path
        $exists = Test-ActivationPath -Path $Path -Kind File -AllowMissing
        if (($null -eq $Snapshot) -ne (-not $exists)) { throw 'Console activation changed while it was being verified.' }
        if ($exists -and (Get-ActivationHash ([IO.File]::ReadAllBytes($Path))) -cne $Snapshot.Hash) {
            throw 'Console activation changed while it was being verified.'
        }
    }

    $null = Test-ActivationPath -Path $repository -Kind Directory
    if (-not (Test-ActivationPath -Path $localRoot -Kind Directory -AllowMissing)) { return $null }
    $pointerPath = Join-Path $localRoot 'console-active.json'
    $intentPath = Join-Path $localRoot 'console-activation-intent.json'
    $intent = $null
    $intentState = $null
    if (Test-ActivationPath -Path $intentPath -Kind File -AllowMissing) {
        $intent = Read-ActivationObject $intentPath
        Assert-ActivationSchema $intent
        $intentState = Get-ActivationString $intent 'state'
        if ($intentState -ceq 'PREPARED') { throw 'A console activation is incomplete; finish or roll back that activation before starting.' }
        if ($intentState -cnotin @('COMMITTED', 'ROLLED_BACK')) { throw 'Console activation intent has an invalid state.' }
    }
    if (-not (Test-ActivationPath -Path $pointerPath -Kind File -AllowMissing)) {
        if ($intentState -ceq 'COMMITTED') { throw 'A committed console activation is missing its current selection.' }
        Assert-ActivationUnchanged $pointerPath $null
        Assert-ActivationUnchanged $intentPath $intent
        return $null
    }

    $pointer = Read-ActivationObject $pointerPath
    Assert-ActivationSchema $pointer
    if ((Get-ActivationString $pointer 'state') -cne 'COMMITTED') { throw 'Console selection is not committed.' }
    $bindings = @{}
    foreach ($name in @('project', 'publicUrl', 'sourceDirectory', 'deploymentDirectory',
                        'releaseManifestSha256', 'activationReceipt', 'activationReceiptSha256')) {
        $bindings[$name] = Get-ActivationString $pointer $name
    }
    if ($bindings.project -cnotmatch '\A[a-z0-9][a-z0-9_-]{0,62}\z') { throw 'Console selection has an invalid project name.' }
    $origin = $null
    if (-not [Uri]::TryCreate($bindings.publicUrl, [UriKind]::Absolute, [ref]$origin) -or
        $origin.Scheme -cnotin @('http', 'https') -or $origin.UserInfo -or $origin.Query -or $origin.Fragment -or
        $origin.AbsolutePath -cne '/' -or $origin.GetLeftPart([UriPartial]::Authority) -cne $bindings.publicUrl) {
        throw 'Console selection must use an absolute HTTP or HTTPS origin.'
    }
    Assert-ActivationHashValue $bindings.releaseManifestSha256
    Assert-ActivationHashValue $bindings.activationReceiptSha256

    if ($intentState -ceq 'COMMITTED') {
        foreach ($name in $bindings.Keys) {
            if ((Get-ActivationString $intent $name) -cne $bindings[$name]) {
                throw 'Committed console activation intent differs from its current selection.'
            }
        }
    }

    $source = Resolve-ActivationLocalPath $bindings.sourceDirectory 'Directory'
    $deployment = Resolve-ActivationLocalPath $bindings.deploymentDirectory 'Directory'
    $expectedDeployment = [IO.Path]::GetFullPath((Join-Path $source '.local/deployment'))
    if (-not $deployment.Equals($expectedDeployment, $comparison)) {
        throw 'Console deployment must be the selected source .local/deployment directory.'
    }
    $receiptPath = Resolve-ActivationLocalPath $bindings.activationReceipt 'File'
    if ([IO.Path]::GetExtension($receiptPath) -ine '.json') { throw 'Console activation receipt must be a JSON metadata file.' }
    $manifestPath = Join-Path $deployment 'release-manifest.json'
    $settingsPath = Join-Path $deployment 'deployment.json'
    $manifest = Read-ActivationObject $manifestPath
    $settings = Read-ActivationObject $settingsPath
    $receipt = Read-ActivationObject $receiptPath
    if ($manifest.Hash -cne $bindings.releaseManifestSha256 -or $receipt.Hash -cne $bindings.activationReceiptSha256) {
        throw 'Console activation evidence differs from its committed hash.'
    }
    Assert-ActivationSchema $manifest
    Assert-ActivationSchema $settings
    Assert-ActivationSchema $receipt
    if ((Get-ActivationString $manifest 'publicUrl') -cne $bindings.publicUrl -or
        (Get-ActivationString $settings 'projectName') -cne $bindings.project -or
        (Get-ActivationString $settings 'publicUrl') -cne $bindings.publicUrl) {
        throw 'Console deployment project or public origin differs from its committed selection.'
    }
    $settingsSource = Resolve-ActivationLocalPath (Get-ActivationString $settings 'repositoryRoot') 'Directory'
    if (-not $settingsSource.Equals($source, $comparison)) { throw 'Console deployment repository root differs from its selected source.' }
    if ((Get-ActivationString $receipt 'state') -cne 'COMMITTED') { throw 'Console activation receipt is not committed.' }
    foreach ($name in @('project', 'publicUrl', 'releaseManifestSha256')) {
        if ((Get-ActivationString $receipt $name) -cne $bindings[$name]) {
            throw 'Console activation receipt differs from its committed selection.'
        }
    }
    $receiptSource = Resolve-ActivationLocalPath (Get-ActivationString $receipt 'sourceDirectory') 'Directory'
    $receiptDeployment = Resolve-ActivationLocalPath (Get-ActivationString $receipt 'deploymentDirectory') 'Directory'
    if (-not $receiptSource.Equals($source, $comparison) -or -not $receiptDeployment.Equals($deployment, $comparison)) {
        throw 'Console activation receipt refers to a different deployment.'
    }

    Assert-ActivationUnchanged $manifestPath $manifest
    Assert-ActivationUnchanged $settingsPath $settings
    Assert-ActivationUnchanged $receiptPath $receipt
    Assert-ActivationUnchanged $pointerPath $pointer
    Assert-ActivationUnchanged $intentPath $intent
    return [pscustomobject]@{
        schemaVersion=1; state='COMMITTED'; project=$bindings.project; publicUrl=$bindings.publicUrl
        sourceDirectory=$source; deploymentDirectory=$deployment
        releaseManifestSha256=$bindings.releaseManifestSha256
        activationReceipt=$receiptPath; activationReceiptSha256=$bindings.activationReceiptSha256
    }
}
