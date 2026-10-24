#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repository = 'D:\codes\mobile\ai-manager'
. (Join-Path $repository 'scripts/console-activation.ps1')
$selection = Get-ActiveConsoleSelection -RepositoryRoot $repository
if ($selection.project -cne 'ai-manager-v1-refresh-20261016-r1' -or
    $selection.publicUrl -cne 'http://localhost:18101' -or
    $selection.releaseManifestSha256 -cne 'b6db21c77cb4ed5815931895f92158ec3473b0174e0cf5385b78157bdb773793') {
    throw 'The active release changed; recovery evidence must be reviewed again.'
}
$format = '{"id":{{json .Id}},"imageId":{{json .Image}},"running":{{json .State.Running}},"health":{{if .State.Health}}{{json .State.Health.Status}}{{else}}null{{end}},"project":{{json (index .Config.Labels "com.docker.compose.project")}},"service":{{json (index .Config.Labels "com.docker.compose.service")}}}'
$ids = @(& docker ps -a --no-trunc --filter ('label=com.docker.compose.project=' + $selection.project) --format '{{.ID}}')
if ($LASTEXITCODE -ne 0 -or $ids.Count -ne 6) { throw 'Expected exactly six existing selected-release containers.' }
$rows = @()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$expected = @('backend','database','edge','erasure-database','identity','identity-database')
foreach ($id in $ids) {
    if ($id -cnotmatch '\A[0-9a-f]{64}\z') { throw 'Invalid container identity.' }
    $raw = @(& docker container inspect --format $format $id)
    if ($LASTEXITCODE -ne 0 -or $raw.Count -ne 1) { throw 'Selected container inspection failed.' }
    $row = $raw[0] | ConvertFrom-Json
    if ($row.id -cne $id -or $row.project -cne $selection.project -or
        $expected -cnotcontains $row.service -or -not $seen.Add($row.service) -or
        $row.running -ne $true -or $row.health -cne 'healthy') {
        throw 'Selected service ownership or health check failed.'
    }
    $rows += $row
}
$smokeText = @(& (Join-Path $selection.sourceDirectory 'scripts/verify-deployment.ps1') -Directory '.local/deployment')
if ($LASTEXITCODE -ne 0) { throw 'Read-only service smoke check failed.' }
$smoke = ($smokeText -join "`n") | ConvertFrom-Json
$again = Get-ActiveConsoleSelection -RepositoryRoot $repository
if ($again.releaseManifestSha256 -cne $selection.releaseManifestSha256 -or
    $again.project -cne $selection.project) { throw 'Selected release changed during verification.' }
$receipt = [ordered]@{
    schemaVersion = 1
    observedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    action = 'DOCKER_DESKTOP_STARTED_EXISTING_RESTART_POLICY_CONTAINERS'
    startupActual = '3a995d exit0'
    selection = $selection
    containers = @($rows | Sort-Object service)
    smoke = $smoke
    newSourceDeployed = $false
    newImageBuiltOrPulled = $false
    databaseMigrationInvoked = $false
    credentialsFileRead = $false
    imageProvenance = 'OBSERVED_IMAGE_IDS_ONLY_LEGACY_SELECTED_MANIFEST_HAS_NO_RUNTIME_IMAGE_BINDING'
}
$destination = Join-Path $repository '.cache/guardian-services-recovery-20261024-r1.json'
$bytes = [Text.UTF8Encoding]::new($false).GetBytes(($receipt | ConvertTo-Json -Depth 12) + "`n")
$stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
[ordered]@{receipt=$destination; bytes=$bytes.Length; sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant(); selectedServicesHealthy=$rows.Count; smoke=$smoke} | ConvertTo-Json -Depth 5
