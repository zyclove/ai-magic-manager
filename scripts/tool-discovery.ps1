# Return metadata only; never invoke the discovered tool or accept a nearby path.
function Find-DeploymentToolCommand {
    [CmdletBinding()]
    param([string]$Command, [Management.Automation.CommandTypes]$CommandTypes)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    if (-not ([IO.Path]::IsPathRooted($Command) -or $Command.Contains('/') -or $Command.Contains('\'))) {
        # Mirror CommandSearcher discovery names; the framework still supplies
        # PATH candidates and decides which files are scripts or applications.
        $fileNames = [Collections.Generic.List[string]]::new()
        if ([IO.Path]::HasExtension($Command)) { $fileNames.Add($Command) }
        if ($CommandTypes.HasFlag([Management.Automation.CommandTypes]::ExternalScript)) {
            $fileNames.Add($Command + '.ps1')
        }
        if ($IsWindows -and $CommandTypes.HasFlag([Management.Automation.CommandTypes]::Application)) {
            $pathExt = [Environment]::GetEnvironmentVariable('PATHEXT')
            if ($null -ne $pathExt) {
                foreach ($extension in $pathExt.ToLower().Split([IO.Path]::PathSeparator, [StringSplitOptions]::RemoveEmptyEntries)) {
                    $fileNames.Add($Command + $extension)
                }
            }
        }
        $fileNames.Add($Command)
        $seenNames = [Collections.Generic.HashSet[string]]::new($comparer)
        $fileNames = @($fileNames | Where-Object { $seenNames.Add($_) })

        $candidate = $ExecutionContext.InvokeCommand.GetCommand($Command, $CommandTypes)
        if ($null -ne $candidate -and $seenNames.Contains($candidate.Name)) {
            return Find-DeploymentToolCommand -Command $candidate.Source -CommandTypes $CommandTypes
        }

        # A special character can prevent the exact API's PATH lookup. Use only
        # its ordinary prefix for native candidates; exact names are checked below.
        $specialIndex = $Command.IndexOfAny([char[]]'*?[]`')
        if ($specialIndex -lt 0) { return $null }
        # Retain native directory order, but use discovery's filename precedence
        # within each directory instead of accepting a nearby basename match.
        $directoryOrder = [Collections.Generic.List[string]]::new()
        $byDirectory = [Collections.Generic.Dictionary[string, object]]::new($comparer)
        $pattern = $Command.Substring(0, $specialIndex) + '*'
        foreach ($candidate in @(Microsoft.PowerShell.Core\Get-Command -Name $pattern -All -CommandType $CommandTypes -ErrorAction SilentlyContinue)) {
            if (-not $seenNames.Contains($candidate.Name) -or [string]::IsNullOrWhiteSpace($candidate.Source)) { continue }
            $directory = [IO.Path]::GetDirectoryName($candidate.Source)
            if (-not $byDirectory.ContainsKey($directory)) {
                $byDirectory.Add($directory, [Collections.Generic.Dictionary[string, object]]::new($comparer))
                $directoryOrder.Add($directory)
            }
            if (-not $byDirectory[$directory].ContainsKey($candidate.Name)) {
                $byDirectory[$directory].Add($candidate.Name, $candidate)
            }
        }
        foreach ($directory in $directoryOrder) {
            foreach ($fileName in $fileNames) {
                if (-not $byDirectory[$directory].ContainsKey($fileName)) { continue }
                $candidate = $byDirectory[$directory][$fileName]
                $resolved = Find-DeploymentToolCommand -Command $candidate.Source -CommandTypes $CommandTypes
                if ($null -ne $resolved) { return $resolved }
            }
        }
        return $null
    }

    $entry = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Command -Force -ErrorAction SilentlyContinue
    if ($null -eq $entry -or $entry -isnot [IO.FileInfo] -or
        $entry.PSProvider.Name -ne 'FileSystem' -or $entry.PSIsContainer) { return $null }
    $fullName = $entry.FullName
    # Match the entire literal path without widening it to nearby filenames.
    # Keep framework discovery and the final Source equality as separate checks.
    $encoded = [Text.StringBuilder]::new()
    foreach ($character in $fullName.ToCharArray()) {
        switch ($character) {
            '[' { [void]$encoded.Append('[[]') }
            '*' { [void]$encoded.Append('[*]') }
            '?' { [void]$encoded.Append('[?]') }
            '`' { [void]$encoded.Append('``') }
            default { [void]$encoded.Append($character) }
        }
    }
    $pattern = $encoded.ToString()
    if (-not [Management.Automation.WildcardPattern]::ContainsWildcardCharacters($pattern)) {
        $pattern = $fullName
    }
    foreach ($candidate in @(Microsoft.PowerShell.Core\Get-Command -Name $pattern -All -CommandType $CommandTypes -ErrorAction SilentlyContinue)) {
        if ($comparer.Equals($candidate.Source, $fullName)) { return $candidate }
    }
    return $null
}
