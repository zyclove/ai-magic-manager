#Requires -Version 7.0
<# Uses an already verified executable backend JAR and the actual backend signer.
   Only a temporary test key is generated; no production credentials are read. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$BackendJar,
      [string]$JavaCommand='java', [string]$DartCommand='dart')
$ErrorActionPreference='Stop'
$repository=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$jarPath=[IO.Path]::GetFullPath($BackendJar,$repository)
if(-not (Test-Path -LiteralPath $jarPath -PathType Leaf)) { throw 'Provide a verified backend JAR.' }
foreach($command in @($JavaCommand,$DartCommand)) {
  if(-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw 'Configure Java and Dart executable paths.' }
}
$work=Join-Path $repository ('.local/device-access-interop-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $work
if($IsWindows) {
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  & icacls.exe $work /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' *> $null
  if($LASTEXITCODE -ne 0) { throw 'Failed to protect test workspace.' }
} else {
  & chmod 700 -- $work
  if($LASTEXITCODE -ne 0) { throw 'Failed to protect test workspace.' }
}
$zip=[IO.Compression.ZipFile]::OpenRead($jarPath)
$totalLength=0L
try {
  foreach($entry in $zip.Entries) {
    if($entry.Name -eq '' -or ($entry.FullName -notlike 'BOOT-INF/classes/*' -and $entry.FullName -notlike 'BOOT-INF/lib/*.jar')) { continue }
    $totalLength += $entry.Length
    if($entry.Length -gt 100MB -or $totalLength -gt 512MB) { throw 'Backend JAR exceeds fixture extraction limits.' }
    $target=[IO.Path]::GetFullPath((Join-Path $work $entry.FullName))
    if(-not $target.StartsWith($work+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe JAR entry path.' }
    $null=New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)
  }
} finally { $zip.Dispose() }
$classpath=(Join-Path $work 'BOOT-INF/classes')+[IO.Path]::PathSeparator+(Join-Path $work 'BOOT-INF/lib/*')
$fixture=Join-Path $work 'fixture'
& $JavaCommand '-Dfile.encoding=UTF-8' '--class-path' $classpath (Join-Path $PSScriptRoot 'NimbusAccessFixture.java') $fixture
if($LASTEXITCODE -ne 0) { throw 'Nimbus fixture generation failed.' }
if(Test-Path -LiteralPath (Join-Path $fixture 'temporary-signing-key.jwk')) { throw 'Temporary private fixture key was retained.' }
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
  & $DartCommand 'run' 'tool/verify_nimbus_fixture.dart' (Join-Path $fixture 'nimbus-fixture.json')
  if($LASTEXITCODE -ne 0) { throw 'Dart verification of the access-window Nimbus fixture failed.' }
} finally { Pop-Location }
Write-Output "Interoperability verification completed; public evidence: $fixture"
