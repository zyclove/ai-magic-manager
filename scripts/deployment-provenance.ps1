# Shared release provenance. This module performs file I/O only; it never reads
# environment files, credentials, Git metadata, or running containers.
# Inventory commands emit path/bytes/sha256 records; callers capture with @(...).

$script:DeploymentRecipeRelativePaths = @(
    'deploy/containers/backend.Dockerfile',
    'deploy/containers/edge.Dockerfile',
    'deploy/containers/keycloak.Dockerfile',
    'deploy/compose/compose.yaml',
    'deploy/compose/compose.family.yaml',
    'deploy/compose/compose.identity-admin.yaml',
    'deploy/compose/compose.identity-runtime-control.yaml',
    'deploy/compose/compose.identity-runtime-image.yaml',
    'deploy/compose/compose.tls.yaml',
    'deploy/compose/compose.external-tls.yaml',
    'deploy/edge/nginx.conf',
    'deploy/edge/http.conf',
    'deploy/edge/routes.conf',
    'deploy/edge/tls.conf',
    'deploy/edge/routes.external-tls.conf',
    'scripts/build-deployment.ps1',
    'scripts/start-deployment.ps1',
    'scripts/verify-deployment.ps1',
    'scripts/deployment-common.ps1',
    'scripts/family-identity-release-common.ps1',
    'scripts/initialize-erasure-ledger.ps1',
    'scripts/deployment-provenance.ps1',
    'scripts/deployment-runtime-provenance.ps1'
)

function Get-DeploymentProvenanceMember {
    param([object]$Value, [string]$Name, [switch]$AllowMissing)
    if ($null -ne $Value) {
        if ($Value -is [Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                if ($key -is [string] -and $key -ceq $Name) { return ,$Value[$key] }
            }
        } else {
            foreach ($property in $Value.PSObject.Properties) {
                if ($property.Name -ceq $Name) { return ,$property.Value }
            }
        }
    }
    if ($AllowMissing) { return $null }
    throw "Required deployment provenance field is missing: $Name."
}

function Assert-DeploymentRelativePath {
    param([object]$Path)
    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path) -or
        $Path.StartsWith('/') -or $Path.Contains('\') -or
        $Path -cmatch '[\p{Cc}:*?<>|\"]') {
        throw 'Deployment inventory contains an invalid relative path.'
    }
    foreach ($character in $Path.ToCharArray()) {
        if ([char]::IsWhiteSpace($character) -and $character -ne ' ') {
            throw 'Deployment inventory contains an invalid relative path.'
        }
    }
    foreach ($part in $Path.Split('/')) {
        if (-not $part -or $part -eq '.' -or $part -eq '..' -or
            $part.Trim() -cne $part -or $part.EndsWith('.') -or
            $part -match '\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)') {
            throw 'Deployment inventory contains an invalid relative path.'
        }
    }
}

function Resolve-DeploymentProvenanceRoot {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { throw 'Deployment inventory root is invalid.' }
    try { $item = Get-Item -LiteralPath ([IO.Path]::GetFullPath($Root)) -Force -ErrorAction Stop }
    catch { throw 'Deployment inventory root is unavailable.' }
    if (-not $item.PSIsContainer) { throw 'Deployment inventory root must be a directory.' }
    $ancestor = $item
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Deployment provenance paths must not contain links.'
        }
        $ancestor = $ancestor.Parent
    }
    return [IO.Path]::GetFullPath($item.FullName)
}

function Get-DeploymentProvenanceFile {
    param([string]$Root, [string]$RelativePath)
    Assert-DeploymentRelativePath $RelativePath
    $currentPath = $Root
    $parts = $RelativePath.Split('/')
    for ($index = 0; $index -lt $parts.Length; $index++) {
        $currentPath = Join-Path $currentPath $parts[$index]
        try { $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop }
        catch { throw 'Deployment provenance file is unavailable.' }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Deployment provenance paths must not contain links.'
        }
        if ($item.Name -cne $parts[$index] -or
            ($index -lt $parts.Length - 1 -and -not $item.PSIsContainer) -or
            ($index -eq $parts.Length - 1 -and $item.PSIsContainer)) {
            throw 'Deployment provenance file path is ambiguous or invalid.'
        }
    }
    return $item
}

function Get-DeploymentProvenanceBytesSha256 {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-DeploymentProvenanceFileRecord {
    param([string]$Root, [string]$RelativePath)
    $item = Get-DeploymentProvenanceFile $Root $RelativePath
    $stream = $null
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $length = $stream.Length
        $digest = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    } catch { throw 'Deployment provenance file cannot be read.' }
    finally { if ($null -ne $stream) { $stream.Dispose() }; $algorithm.Dispose() }
    return [pscustomobject][ordered]@{path=$RelativePath; bytes=[long]$length; sha256=$digest}
}

function ConvertTo-DeploymentProvenanceInventory {
    param([AllowEmptyCollection()][object[]]$Files)
    $records = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $spellings = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Files) {
        $path = Get-DeploymentProvenanceMember $entry 'path'
        $bytes = Get-DeploymentProvenanceMember $entry 'bytes'
        $hash = Get-DeploymentProvenanceMember $entry 'sha256'
        Assert-DeploymentRelativePath $path
        $integer = $bytes -is [byte] -or $bytes -is [sbyte] -or
            $bytes -is [int16] -or $bytes -is [uint16] -or
            $bytes -is [int32] -or $bytes -is [uint32] -or
            $bytes -is [int64] -or $bytes -is [uint64] -or $bytes -is [bigint]
        if (-not $integer -or [bigint]$bytes -lt 0 -or [bigint]$bytes -gt [long]::MaxValue -or
            $hash -isnot [string] -or $hash -cnotmatch '\A[0-9a-f]{64}\z') {
            throw 'Deployment inventory bytes or SHA256 is invalid.'
        }
        $prefix = ''
        foreach ($part in $path.Split('/')) {
            $prefix = if ($prefix) { $prefix + '/' + $part } else { $part }
            if ($spellings.ContainsKey($prefix)) {
                if ($spellings[$prefix] -cne $prefix) { throw 'Deployment inventory contains ambiguous path casing.' }
            } else { $spellings.Add($prefix, $prefix) }
        }
        if ($records.ContainsKey($path)) { throw 'Deployment inventory contains duplicate paths.' }
        $records.Add($path, [pscustomobject][ordered]@{path=$path; bytes=[long]$bytes; sha256=$hash})
    }
    $paths = [string[]]@($records.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    foreach ($path in $paths) { $records[$path] }
}

function Assert-DeploymentProvenanceInventoryEqual {
    param([AllowEmptyCollection()][object[]]$Expected, [AllowEmptyCollection()][object[]]$Actual)
    $wanted = @(ConvertTo-DeploymentProvenanceInventory -Files $Expected)
    $observed = @(ConvertTo-DeploymentProvenanceInventory -Files $Actual)
    if ($wanted.Count -ne $observed.Count) { throw 'Deployment inventory members differ.' }
    for ($index = 0; $index -lt $wanted.Count; $index++) {
        if ($wanted[$index].path -cne $observed[$index].path -or
            $wanted[$index].bytes -ne $observed[$index].bytes -or
            $wanted[$index].sha256 -cne $observed[$index].sha256) {
            throw 'Deployment inventory members, bytes or hashes differ.'
        }
    }
}

function Get-DeploymentFileInventory {
    <#
    .SYNOPSIS
    Emits an Ordinal-sorted, exact file inventory without following links.
    .DESCRIPTION
    ExcludeGenerated matches CopySourceTree: .git, .local, target, build,
    .dart_tool, __pycache__, .flutter-plugins*, and providers below keycloak.
    Excluded directories are not traversed; encountered reparse points always fail.
    ExcludeRelativePaths excludes exact, case-sensitive root-relative files only.
    For example release-manifest.json does not exclude sub/release-manifest.json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [switch]$ExcludeGenerated,
        [string[]]$ExcludeRelativePaths = @())
    $resolvedRoot = Resolve-DeploymentProvenanceRoot $Root
    $excludedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($excluded in $ExcludeRelativePaths) {
        Assert-DeploymentRelativePath $excluded
        if (-not $excludedPaths.Add($excluded)) { throw 'Duplicate inventory exclusion.' }
    }
    $records = [Collections.Generic.List[object]]::new()
    function Visit-DeploymentProvenanceDirectory([string]$Directory) {
        try { $entries = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop) }
        catch { throw 'Deployment inventory directory cannot be enumerated.' }
        foreach ($entry in $entries) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Deployment provenance paths must not contain links.'
            }
            $relative = [IO.Path]::GetRelativePath($resolvedRoot, $entry.FullName).Replace('\', '/')
            Assert-DeploymentRelativePath $relative
            if ($ExcludeGenerated -and
                ($entry.Name -in @('.git', '.local', 'target', 'build', '.dart_tool', '__pycache__') -or
                 $entry.Name -like '.flutter-plugins*' -or
                 ($entry.Name -eq 'providers' -and (Split-Path $Directory -Leaf) -eq 'keycloak'))) { continue }
            if ($entry.PSIsContainer) { Visit-DeploymentProvenanceDirectory $entry.FullName }
            elseif (-not $excludedPaths.Contains($relative)) {
                $records.Add((Get-DeploymentProvenanceFileRecord $resolvedRoot $relative))
            }
        }
    }
    Visit-DeploymentProvenanceDirectory $resolvedRoot
    ConvertTo-DeploymentProvenanceInventory -Files @($records.ToArray())
}

function Get-DeploymentTreeSha256 {
    <#
    .SYNOPSIS
    Hashes validated path/bytes/sha256 records, independently of enumeration order.
    .DESCRIPTION
    Canonical bytes are UTF-8 without BOM. Each Ordinal-sorted record contributes:
    path + NUL + invariant decimal bytes + NUL + lowercase SHA256 + LF.
    Empty inventories hash the empty byte sequence. Relative paths are unique,
    portable and case-unambiguous; ordinary internal spaces are allowed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files)
    $records = @(ConvertTo-DeploymentProvenanceInventory -Files $Files)
    $canonical = [Text.StringBuilder]::new()
    foreach ($entry in $records) {
        [void]$canonical.Append($entry.path)
        [void]$canonical.Append([char]0)
        [void]$canonical.Append($entry.bytes.ToString([Globalization.CultureInfo]::InvariantCulture))
        [void]$canonical.Append([char]0)
        [void]$canonical.Append($entry.sha256)
        [void]$canonical.Append([char]10)
    }
    Get-DeploymentProvenanceBytesSha256 ([Text.UTF8Encoding]::new($false).GetBytes($canonical.ToString()))
}

function Assert-DeploymentInventory {
    <# .SYNOPSIS
    Compares exact file membership, byte lengths and hashes; writes nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [switch]$ExcludeGenerated)
    $actual = @(Get-DeploymentFileInventory -Root $Root -ExcludeGenerated:$ExcludeGenerated)
    Assert-DeploymentProvenanceInventoryEqual -Expected $Files -Actual $actual
}

function Get-DeploymentRecipeInventory {
    <# .SYNOPSIS
    Inventories exactly 23 public recipes; never scans .env or secret directories.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repository)
    $root = Resolve-DeploymentProvenanceRoot $Repository
    $files = @(
        foreach ($relative in $script:DeploymentRecipeRelativePaths) {
            Get-DeploymentProvenanceFileRecord $root $relative
        }
    )
    ConvertTo-DeploymentProvenanceInventory -Files $files
}

function Read-DeploymentProvenance {
    <#
    .SYNOPSIS
    Validates a release and returns Manifest/ManifestSha256/ArtifactRoot/Labels.
    .DESCRIPTION
    Context requires Root, Repository and Settings.publicUrl. Missing context
    consumerIdentity is false, matching Get-DeploymentContext callers. The manifest
    itself requires a Boolean consumerIdentity and all provenanceVersion=1 fields.
    sourceFiles binds content only; the original source snapshot need not remain.
    artifactFiles covers the complete release directory except its root manifest.
    The deployment and artifact manifests must contain identical original bytes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context)
    $root = Resolve-DeploymentProvenanceRoot (Get-DeploymentProvenanceMember $Context 'Root')
    $repository = Resolve-DeploymentProvenanceRoot (Get-DeploymentProvenanceMember $Context 'Repository')
    $settings = Get-DeploymentProvenanceMember $Context 'Settings'
    $origin = Get-DeploymentProvenanceMember $settings 'publicUrl'
    $consumerIdentity = (Get-DeploymentProvenanceMember $settings 'consumerIdentity' -AllowMissing) -eq $true
    try { $rootManifest = Get-DeploymentProvenanceFile $root 'release-manifest.json' }
    catch { throw 'Verified build contexts are missing; run build-deployment.ps1 first.' }
    try {
        $manifestBytes = [IO.File]::ReadAllBytes($rootManifest.FullName)
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($manifestBytes)
        if ($json.Length -gt 0 -and $json[0] -eq [char]0xFEFF) { $json = $json.Substring(1) }
        $manifest = ConvertFrom-Json -InputObject $json -Depth 100 -ErrorAction Stop
    } catch { throw 'Release manifest is not valid UTF-8 JSON.' }
    $schema = Get-DeploymentProvenanceMember $manifest 'schemaVersion'
    $provenance = Get-DeploymentProvenanceMember $manifest 'provenanceVersion'
    $version = Get-DeploymentProvenanceMember $manifest 'applicationVersion'
    $publicUrl = Get-DeploymentProvenanceMember $manifest 'publicUrl'
    $identity = Get-DeploymentProvenanceMember $manifest 'consumerIdentity'
    $artifactRelative = Get-DeploymentProvenanceMember $manifest 'artifactRoot'
    $uri = $null
    if (($schema -isnot [int] -and $schema -isnot [long]) -or $schema -ne 1 -or
        ($provenance -isnot [int] -and $provenance -isnot [long]) -or $provenance -ne 1 -or
        $version -cne '1.0.0' -or $publicUrl -isnot [string] -or $publicUrl -cne $origin -or
        -not [Uri]::TryCreate($publicUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cnotin @('http', 'https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.AbsolutePath -cne '/' -or $uri.GetLeftPart([UriPartial]::Authority) -cne $publicUrl -or
        $identity -isnot [bool] -or $identity -ne $consumerIdentity -or
        $artifactRelative -isnot [string] -or $artifactRelative -cnotmatch '\Aartifacts/release-[0-9a-f]{32}\z') {
        throw 'Invalid release provenance manifest.'
    }
    $artifactRoot = Resolve-DeploymentProvenanceRoot (Join-Path $root $artifactRelative)
    try {
        $releaseManifest = Get-DeploymentProvenanceFile $artifactRoot 'release-manifest.json'
        $releaseBytes = [IO.File]::ReadAllBytes($releaseManifest.FullName)
        if ($manifestBytes.Length -ne $releaseBytes.Length) { throw 'Manifest differs.' }
        for ($index = 0; $index -lt $manifestBytes.Length; $index++) {
            if ($manifestBytes[$index] -ne $releaseBytes[$index]) { throw 'Manifest differs.' }
        }
    } catch { throw 'Deployment and release manifests must be byte-identical.' }
    $sourceFiles = Get-DeploymentProvenanceMember $manifest 'sourceFiles'
    $sourceTree = Get-DeploymentProvenanceMember $manifest 'sourceTreeSha256'
    $source = Get-DeploymentProvenanceMember $manifest 'source'
    if ($sourceFiles -isnot [array] -or $sourceFiles.Count -eq 0 -or
        $sourceTree -isnot [string] -or $sourceTree -cnotmatch '\A[0-9a-f]{64}\z' -or
        (Get-DeploymentTreeSha256 -Files $sourceFiles) -cne $sourceTree -or
        (Get-DeploymentProvenanceMember $source 'kind') -cne 'content-snapshot' -or
        (Get-DeploymentProvenanceMember $source 'revision') -cne ('sha256:' + $sourceTree)) {
        throw 'Release source snapshot provenance is invalid.'
    }
    $backendHash = Get-DeploymentProvenanceMember $manifest 'backendSha256'
    $guardianHash = Get-DeploymentProvenanceMember $manifest 'guardianSha256'
    $providerHash = Get-DeploymentProvenanceMember $manifest 'identityProviderSha256'
    if ($identity) {
        try {
            $provider = Get-DeploymentProvenanceFileRecord $artifactRoot 'keycloak/keycloak/providers/consumer-identity-1.0.0.jar'
            if ($providerHash -isnot [string] -or $providerHash -cnotmatch '\A[0-9a-f]{64}\z' -or $provider.sha256 -cne $providerHash) { throw 'Provider differs.' }
        } catch { throw 'Identity provider changed since verification.' }
    } elseif ($null -ne $providerHash) { throw 'Invalid identity provider provenance.' }
    try {
        $artifactFiles = Get-DeploymentProvenanceMember $manifest 'artifactFiles'
        $artifactTree = Get-DeploymentProvenanceMember $manifest 'artifactTreeSha256'
        if ($artifactFiles -isnot [array] -or $artifactTree -isnot [string] -or
            $artifactTree -cnotmatch '\A[0-9a-f]{64}\z' -or
            (Get-DeploymentTreeSha256 -Files $artifactFiles) -cne $artifactTree) { throw 'Artifact inventory invalid.' }
        $actualArtifacts = @(Get-DeploymentFileInventory -Root $artifactRoot -ExcludeRelativePaths @('release-manifest.json'))
        Assert-DeploymentProvenanceInventoryEqual -Expected $artifactFiles -Actual $actualArtifacts
        $backend = Get-DeploymentProvenanceFileRecord $artifactRoot 'backend/manager-backend.jar'
        $guardian = Get-DeploymentProvenanceFileRecord $artifactRoot 'guardian/main.dart.js'
        [void](Get-DeploymentProvenanceFile $artifactRoot 'guardian/index.html')
        if ($backendHash -isnot [string] -or $backendHash -cnotmatch '\A[0-9a-f]{64}\z' -or
            $guardianHash -isnot [string] -or $guardianHash -cnotmatch '\A[0-9a-f]{64}\z' -or
            $backend.sha256 -cne $backendHash -or $guardian.sha256 -cne $guardianHash) { throw 'Artifact hash differs.' }
    } catch { throw 'Build artifact changed since verification.' }
    $recipeFiles = Get-DeploymentProvenanceMember $manifest 'recipeFiles'
    $recipeTree = Get-DeploymentProvenanceMember $manifest 'recipeTreeSha256'
    try {
        if ($recipeFiles -isnot [array] -or $recipeTree -isnot [string] -or
            $recipeTree -cnotmatch '\A[0-9a-f]{64}\z' -or
            (Get-DeploymentTreeSha256 -Files $recipeFiles) -cne $recipeTree) { throw 'Recipe inventory invalid.' }
        Assert-DeploymentProvenanceInventoryEqual -Expected $recipeFiles -Actual @(Get-DeploymentRecipeInventory -Repository $repository)
    } catch { throw 'Deployment recipe changed since verification.' }
    $manifestHash = Get-DeploymentProvenanceBytesSha256 $manifestBytes
    $labels = [ordered]@{
        'org.opencontainers.image.revision'=('sha256:' + $sourceTree)
        'org.opencontainers.image.version'='1.0.0'
        'com.aimanager.release.manifest-sha256'=$manifestHash
        'com.aimanager.release.source-tree-sha256'=$sourceTree
        'com.aimanager.release.artifact-tree-sha256'=$artifactTree
    }
    return [pscustomobject]@{Manifest=$manifest; ManifestSha256=$manifestHash; ArtifactRoot=$artifactRoot; Labels=$labels}
}
