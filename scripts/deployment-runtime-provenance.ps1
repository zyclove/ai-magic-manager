# Runtime evidence is separate from the immutable build manifest. Loading this
# file performs no Docker calls, reads no credentials, and creates no files.

function Invoke-DeploymentProvenanceDocker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments, [ValidateRange(1, 60)][int]$TimeoutSeconds = 15)
    Set-StrictMode -Version 3.0
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command docker -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Only the read-only Docker client and its descendants belong to us.
            try { $process.Kill($true) } catch { }
            throw 'Deployment image inspection timed out; runtime provenance is unknown.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Deployment image inspection failed; runtime provenance is unknown.' }
        if ($output.Length -gt 1048576) { throw 'Deployment image inspection output is oversized.' }
        return $output.Trim()
    } finally { $process.Dispose() }
}

function Assert-DeploymentRuntimeProperties {
    param($Object, [string[]]$Properties)
    Set-StrictMode -Version 3.0
    if ($null -eq $Object) { throw 'Invalid deployment runtime evidence.' }
    if ($Object -is [Collections.IDictionary]) { $names = @($Object.Keys) }
    elseif ($Object -is [pscustomobject]) { $names = @($Object.PSObject.Properties.Name) }
    else { throw 'Invalid deployment runtime evidence.' }
    if ($names.Count -ne $Properties.Count) { throw 'Invalid deployment runtime evidence properties.' }
    foreach ($name in $names) {
        if ($Properties -cnotcontains $name) { throw 'Invalid deployment runtime evidence properties.' }
    }
}

function Assert-DeploymentRuntimeJsonNames {
    param([Text.Json.JsonElement]$Element)
    Set-StrictMode -Version 3.0
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw 'Duplicate deployment runtime evidence property.' }
            Assert-DeploymentRuntimeJsonNames $property.Value
        }
    } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-DeploymentRuntimeJsonNames $item }
    }
}

function ConvertFrom-DeploymentRuntimeJson {
    param([string]$Text)
    Set-StrictMode -Version 3.0
    try {
        $document = [Text.Json.JsonDocument]::Parse($Text)
        try {
            Assert-DeploymentRuntimeJsonNames $document.RootElement
            $result = ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 16
            # PowerShell versions differ in automatic ISO timestamp conversion.
            # Preserve JSON string types for strict receipt validation on PS 7.0+.
            if ($result -is [Collections.IDictionary]) {
                foreach ($property in $document.RootElement.EnumerateObject()) {
                    if ($property.Value.ValueKind -eq [Text.Json.JsonValueKind]::String) {
                        $result[$property.Name] = $property.Value.GetString()
                    }
                }
            }
            return $result
        } finally { $document.Dispose() }
    } catch { throw 'Invalid deployment runtime evidence JSON.' }
}

function Get-DeploymentRuntimeBindingMap {
    param([Parameter(Mandatory)][object[]]$Bindings)
    Set-StrictMode -Version 3.0
    if ($Bindings.Count -ne 2) { throw 'Runtime provenance requires backend and edge image bindings.' }
    $result = @{}
    $containerIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($binding in $Bindings) {
        Assert-DeploymentRuntimeProperties $binding @('service', 'imageId', 'containerIds')
        if ($binding.service -isnot [string] -or @('backend', 'edge') -cnotcontains $binding.service -or
            $result.ContainsKey($binding.service) -or $binding.imageId -isnot [string] -or
            $binding.imageId -cnotmatch '^sha256:[0-9a-f]{64}$' -or $binding.containerIds -isnot [array] -or
            $binding.containerIds.Count -eq 0) { throw 'Invalid deployment runtime image binding.' }
        foreach ($id in $binding.containerIds) {
            if ($id -isnot [string] -or $id -cnotmatch '^[0-9a-f]{64}$' -or -not $containerIds.Add($id)) {
                throw 'Invalid deployment runtime container binding.'
            }
        }
        $result[$binding.service] = $binding
    }
    return $result
}

function Resolve-DeploymentRuntimeHostMountSource {
    param([Parameter(Mandatory)][string]$Source)
    Set-StrictMode -Version 3.0
    if ($Source -cmatch '[\x00-\x1f\x7f]') { throw 'Invalid deployment public configuration mount source.' }
    if ($IsWindows -and $Source -cmatch '\A/run/desktop/mnt/host/([a-zA-Z])(/.*)?\z') {
        # Docker Desktop exposes Windows drives using this explicit host mapping.
        # Do not infer arbitrary /mnt, WSL, network-share or legacy aliases.
        $suffix = if ($Matches.ContainsKey(2)) { $Matches[2] } else { '/' }
        $Source = $Matches[1] + ':' + $suffix
    }
    if (-not [IO.Path]::IsPathFullyQualified($Source)) { throw 'Deployment public configuration mount source must be absolute.' }
    return [IO.Path]::GetFullPath($Source)
}

function Get-DeploymentRuntimeExpectedEdgeMounts {
    param([Parameter(Mandatory)]$Context)
    Set-StrictMode -Version 3.0
    if ($Context.Repository -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($Context.Repository)) {
        throw 'Deployment runtime inspection requires an absolute repository path.'
    }
    $uri = $null
    if ($Context.Settings.publicUrl -isnot [string] -or
        -not [Uri]::TryCreate($Context.Settings.publicUrl, [UriKind]::Absolute, [ref]$uri) -or
        @('http', 'https') -cnotcontains $uri.Scheme) { throw 'Invalid deployment runtime origin.' }
    $external = $false
    if ($Context.Settings -is [Collections.IDictionary]) {
        if (@($Context.Settings.Keys) -ccontains 'externalTlsProxy') {
            if ($Context.Settings.externalTlsProxy -isnot [bool]) { throw 'Invalid deployment runtime TLS mode.' }
            $external = $Context.Settings.externalTlsProxy
        }
    } else {
        $property = $Context.Settings.PSObject.Properties['externalTlsProxy']
        if ($null -ne $property) {
            if ($property.Value -isnot [bool]) { throw 'Invalid deployment runtime TLS mode.' }
            $external = $property.Value
        }
    }
    $paths = [ordered]@{
        '/etc/nginx/nginx.conf' = 'nginx.conf'
        '/etc/nginx/conf.d/default.conf' = $(if ($uri.Scheme -ceq 'https' -and -not $external) { 'tls.conf' } else { 'http.conf' })
        '/etc/nginx/includes/routes.conf' = $(if ($external) { 'routes.external-tls.conf' } else { 'routes.conf' })
    }
    $result = @{}
    foreach ($target in $paths.Keys) {
        $result[$target] = [IO.Path]::GetFullPath((Join-Path $Context.Repository ('deploy/edge/' + $paths[$target])))
    }
    return $result
}

function Test-DeploymentRuntimeMountOverlap {
    param([string]$Destination, [string]$ProtectedPath)
    return $Destination -ceq '/' -or $Destination -ceq $ProtectedPath -or
        $Destination.StartsWith($ProtectedPath + '/', [StringComparison]::Ordinal) -or
        $ProtectedPath.StartsWith($Destination + '/', [StringComparison]::Ordinal)
}

function Assert-DeploymentRuntimeMounts {
    param([Parameter(Mandatory)]$Container, [Parameter(Mandatory)][Collections.IDictionary]$ExpectedEdgeMounts)
    Set-StrictMode -Version 3.0
    if ($Container.mounts -isnot [array]) { throw 'Deployment runtime mount metadata is missing.' }
    $seen = @{}
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($mount in $Container.mounts) {
        Assert-DeploymentRuntimeProperties $mount @('type', 'source', 'destination', 'rw')
        if ($mount.type -isnot [string] -or [string]::IsNullOrEmpty($mount.type) -or $mount.source -isnot [string] -or
            $mount.destination -isnot [string] -or $mount.destination -cnotmatch '\A/(?:[^/\\\x00-\x1f\x7f]+(?:/[^/\\\x00-\x1f\x7f]+)*)?\z' -or
            @($mount.destination -split '/') -ccontains '.' -or @($mount.destination -split '/') -ccontains '..' -or
            $mount.rw -isnot [bool]) { throw 'Invalid deployment runtime mount metadata.' }
        if ($Container.service -ceq 'backend') {
            if (Test-DeploymentRuntimeMountOverlap $mount.destination '/app') {
                throw 'A runtime mount shadows the verified backend artifact.'
            }
        } else {
            if (@($ExpectedEdgeMounts.Keys) -ccontains $mount.destination) {
                if ($seen.ContainsKey($mount.destination) -or $mount.type -cne 'bind' -or $mount.rw -or
                    -not (Resolve-DeploymentRuntimeHostMountSource $mount.source).Equals($ExpectedEdgeMounts[$mount.destination], $comparison)) {
                    throw 'Runtime edge configuration mount differs from the verified deployment.'
                }
                $seen[$mount.destination] = $true
            } elseif ((Test-DeploymentRuntimeMountOverlap $mount.destination '/etc/nginx') -or
                (Test-DeploymentRuntimeMountOverlap $mount.destination '/usr/share/nginx/html')) {
                throw 'A runtime mount shadows the verified frontend artifact or configuration.'
            }
        }
    }
    if ($Container.service -ceq 'edge' -and $seen.Count -ne $ExpectedEdgeMounts.Count) {
        throw 'Runtime edge configuration mounts are missing.'
    }
}

function Get-DeploymentImageBindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string[]]$ComposeArguments,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][Collections.IDictionary]$Labels
    )
    Set-StrictMode -Version 3.0
    if ($ComposeArguments.Count -eq 0 -or $ComposeArguments[0] -cne 'compose' -or
        $Project -cnotmatch '^[a-z][a-z0-9-]{2,40}$') { throw 'Invalid deployment runtime inspection scope.' }
    $labelNames = @('org.opencontainers.image.revision', 'org.opencontainers.image.version',
        'com.aimanager.release.manifest-sha256', 'com.aimanager.release.source-tree-sha256',
        'com.aimanager.release.artifact-tree-sha256')
    Assert-DeploymentRuntimeProperties $Labels $labelNames
    foreach ($name in $labelNames) {
        if ($Labels[$name] -isnot [string] -or [string]::IsNullOrEmpty($Labels[$name]) -or
            $Labels[$name] -cmatch '[\x00-\x1f\x7f]') { throw 'Invalid expected deployment image label.' }
        if ($name -like '*sha256' -and $Labels[$name] -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Invalid expected deployment image digest.'
        }
    }
    if ($Labels['org.opencontainers.image.version'] -cne '1.0.0') { throw 'Invalid deployment image version.' }
    $expectedEdgeMounts = Get-DeploymentRuntimeExpectedEdgeMounts -Context $Context

    # Bound the entire inspection, including every replica and immutable image.
    $clock = [Diagnostics.Stopwatch]::StartNew()
    function Invoke-ScopedInspection([string[]]$Arguments) {
        $remaining = 60 - [int][Math]::Ceiling($clock.Elapsed.TotalSeconds)
        if ($remaining -lt 1) { throw 'Deployment runtime inspection exceeded its time budget.' }
        return Invoke-DeploymentProvenanceDocker -Arguments $Arguments -TimeoutSeconds ([Math]::Min(15, $remaining))
    }
    $output = Invoke-ScopedInspection ($ComposeArguments + @('ps', '--all', '--quiet', 'backend', 'edge'))
    $ids = @($output -split '[\r\n]+' | Where-Object { $_ })
    if ($ids.Count -lt 2) { throw 'Backend and edge containers are required for runtime provenance.' }
    $requested = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $actual = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $images = @{}
    $services = @{ backend = [Collections.Generic.List[string]]::new(); edge = [Collections.Generic.List[string]]::new() }
    $serviceImages = @{}
    # Never request the complete container Config: it contains private environment.
    $format = '{"id":{{json .Id}},"imageId":{{json .Image}},"running":{{json .State.Running}},"health":{{if .State.Health}}{{json .State.Health.Status}}{{else}}null{{end}},"project":{{json (index .Config.Labels "com.docker.compose.project")}},"service":{{json (index .Config.Labels "com.docker.compose.service")}},"oneoff":{{json (index .Config.Labels "com.docker.compose.oneoff")}},"mounts":[{{range $i,$m := .Mounts}}{{if $i}},{{end}}{"type":{{json $m.Type}},"destination":{{json $m.Destination}},"rw":{{json $m.RW}},"source":{{if or (eq $m.Destination "/etc/nginx/nginx.conf") (eq $m.Destination "/etc/nginx/conf.d/default.conf") (eq $m.Destination "/etc/nginx/includes/routes.conf")}}{{json $m.Source}}{{else}}""{{end}}}{{end}}]}'
    foreach ($id in $ids) {
        if ($id -cnotmatch '^[0-9a-f]{12,64}$' -or -not $requested.Add($id)) {
            throw 'Invalid or duplicate deployment container reference.'
        }
        $container = ConvertFrom-DeploymentRuntimeJson (Invoke-ScopedInspection @('container', 'inspect', '--format', $format, $id))
        Assert-DeploymentRuntimeProperties $container @('id', 'imageId', 'running', 'health', 'project', 'service', 'oneoff', 'mounts')
        if ($container.id -isnot [string] -or $container.id -cnotmatch '^[0-9a-f]{64}$' -or
            -not $container.id.StartsWith($id, [StringComparison]::Ordinal) -or -not $actual.Add($container.id) -or
            $container.imageId -isnot [string] -or $container.imageId -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            $container.project -cne $Project -or @('backend', 'edge') -cnotcontains $container.service -or
            $container.oneoff -isnot [string] -or $container.oneoff -ine 'False' -or
            $container.running -isnot [bool] -or -not $container.running -or $container.health -cne 'healthy') {
            throw 'Deployment container ownership, identity or health does not match the selected release.'
        }
        Assert-DeploymentRuntimeMounts -Container $container -ExpectedEdgeMounts $expectedEdgeMounts
        $service = $container.service
        if ($serviceImages.ContainsKey($service) -and $serviceImages[$service] -cne $container.imageId) {
            throw 'A deployment service has multiple running image identities.'
        }
        $serviceImages[$service] = $container.imageId
        $services[$service].Add($container.id)
        if (-not $images.ContainsKey($container.imageId)) {
            # Inspect the actual image ID, never its mutable tag or container labels.
            $imageLabels = ConvertFrom-DeploymentRuntimeJson (Invoke-ScopedInspection @('image', 'inspect', '--format', '{{json .Config.Labels}}', $container.imageId))
            if ($imageLabels -isnot [Collections.IDictionary]) { throw 'Deployment image provenance labels are missing.' }
            $actualLabelNames = @($imageLabels.Keys)
            foreach ($name in $labelNames) {
                if ($actualLabelNames -cnotcontains $name -or $imageLabels[$name] -cne $Labels[$name]) {
                    throw 'Deployment image provenance differs from the verified build manifest.'
                }
            }
            $images[$container.imageId] = $true
        }
    }
    $result = @(
        foreach ($service in @('backend', 'edge')) {
            if ($services[$service].Count -eq 0) { throw 'Backend and edge containers are required for runtime provenance.' }
            $sortedIds = $services[$service].ToArray()
            [Array]::Sort($sortedIds, [StringComparer]::Ordinal)
            [ordered]@{ service = $service; imageId = $serviceImages[$service]; containerIds = $sortedIds }
        }
    )
    return $result
}

function Get-DeploymentRuntimeReceiptPath {
    param([Parameter(Mandatory)]$Context)
    Set-StrictMode -Version 3.0
    $root = [IO.Path]::GetFullPath($Context.Root)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Deployment runtime receipt directory is missing.' }
    $path = Join-Path $root 'release-runtime.json'
    for ($cursor = $path; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
        if ((Test-Path -LiteralPath $cursor) -and
            ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Linked deployment runtime receipt paths are refused.'
        }
        if ($cursor -eq [IO.Path]::GetPathRoot($cursor)) { break }
    }
    if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Deployment runtime receipt must be a regular file.'
    }
    return $path
}

function Get-DeploymentRuntimeReceiptMetadata {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Provenance, [Parameter(Mandatory)][string]$Project)
    Set-StrictMode -Version 3.0
    if ($Project -cnotmatch '^[a-z][a-z0-9-]{2,40}$' -or $Context.Settings.publicUrl -isnot [string] -or
        [string]::IsNullOrEmpty($Context.Settings.publicUrl) -or $Provenance.Manifest.applicationVersion -cne '1.0.0') {
        throw 'Invalid deployment runtime receipt scope.'
    }
    foreach ($digest in @($Provenance.ManifestSha256, $Provenance.Manifest.sourceTreeSha256, $Provenance.Manifest.artifactTreeSha256)) {
        if ($digest -isnot [string] -or $digest -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid deployment runtime receipt digest.' }
    }
    return [ordered]@{ schemaVersion = 1; manifestSha256 = $Provenance.ManifestSha256; applicationVersion = '1.0.0';
        publicUrl = $Context.Settings.publicUrl; project = $Project;
        sourceTreeSha256 = $Provenance.Manifest.sourceTreeSha256; artifactTreeSha256 = $Provenance.Manifest.artifactTreeSha256 }
}

function Write-DeploymentRuntimeReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Provenance,
        [Parameter(Mandatory)][object[]]$Bindings, [Parameter(Mandatory)][string]$Project)
    Set-StrictMode -Version 3.0
    $path = Get-DeploymentRuntimeReceiptPath $Context
    $receipt = Get-DeploymentRuntimeReceiptMetadata $Context $Provenance $Project
    $map = Get-DeploymentRuntimeBindingMap $Bindings
    $receipt['createdAt'] = [DateTimeOffset]::UtcNow.ToString('O', [Globalization.CultureInfo]::InvariantCulture)
    $receipt['services'] = [ordered]@{}
    foreach ($service in @('backend', 'edge')) {
        $receipt.services[$service] = [ordered]@{ imageId = $map[$service].imageId; containerIds = $map[$service].containerIds }
    }
    $text = $receipt | ConvertTo-Json -Depth 8
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($path)) ('.release-runtime-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    try {
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [void](Get-DeploymentRuntimeReceiptPath $Context)
        [IO.File]::Move($temporary, $path, $true)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Assert-DeploymentRuntimeReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Provenance,
        [Parameter(Mandatory)][object[]]$Bindings, [Parameter(Mandatory)][string]$Project)
    Set-StrictMode -Version 3.0
    $path = Get-DeploymentRuntimeReceiptPath $Context
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Deployment runtime receipt is missing; start the verified release first.' }
    $stream = [IO.File]::OpenRead($path)
    try {
        if ($stream.Length -gt 65536) { throw 'Deployment runtime receipt is oversized.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($count -eq 0) { throw 'Deployment runtime receipt is incomplete.' }
            $offset += $count
        }
    } finally { $stream.Dispose() }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { throw 'Deployment runtime receipt encoding is invalid.' }
    $receipt = ConvertFrom-DeploymentRuntimeJson $text
    Assert-DeploymentRuntimeProperties $receipt @('schemaVersion', 'manifestSha256', 'applicationVersion', 'publicUrl', 'project',
        'sourceTreeSha256', 'artifactTreeSha256', 'createdAt', 'services')
    $expected = Get-DeploymentRuntimeReceiptMetadata $Context $Provenance $Project
    if (($receipt.schemaVersion -isnot [long] -and $receipt.schemaVersion -isnot [int]) -or $receipt.schemaVersion -ne 1) {
        throw 'Unsupported deployment runtime receipt version.'
    }
    foreach ($name in @('manifestSha256', 'applicationVersion', 'publicUrl', 'project', 'sourceTreeSha256', 'artifactTreeSha256')) {
        if ($receipt[$name] -isnot [string] -or $receipt[$name] -cne $expected[$name]) {
            throw 'Deployment runtime receipt does not bind the selected build and project.'
        }
    }
    $createdAt = [DateTimeOffset]::MinValue
    if ($receipt.createdAt -isnot [string] -or -not [DateTimeOffset]::TryParseExact($receipt.createdAt, 'O',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$createdAt)) {
        throw 'Invalid deployment runtime receipt timestamp.'
    }
    Assert-DeploymentRuntimeProperties $receipt.services @('backend', 'edge')
    $map = Get-DeploymentRuntimeBindingMap $Bindings
    $recorded = @(
        foreach ($service in @('backend', 'edge')) {
            Assert-DeploymentRuntimeProperties $receipt.services[$service] @('imageId', 'containerIds')
            [ordered]@{ service = $service; imageId = $receipt.services[$service].imageId; containerIds = $receipt.services[$service].containerIds }
        }
    )
    [void](Get-DeploymentRuntimeBindingMap $recorded)
    foreach ($service in @('backend', 'edge')) {
        if ($receipt.services[$service].imageId -cne $map[$service].imageId) {
            throw 'Running deployment image differs from the activation receipt.'
        }
    }
    # Container IDs document activation; a legitimate recreation using the same
    # immutable image is allowed. Verification never creates or repairs receipts.
}
