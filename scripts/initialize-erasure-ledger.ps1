#Requires -Version 7.0
<# Explicit first-time ledger provisioning. Never called by normal startup or recovery. #>
[CmdletBinding()]
param([string]$Directory = '.local/deployment')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deployment-common.ps1')
. (Join-Path $PSScriptRoot 'deployment-provenance.ps1')
$context = Get-DeploymentContext $Directory
$provenance = Read-DeploymentProvenance -Context $context
$artifactRoot = $provenance.ArtifactRoot
$arguments = @('compose', '--env-file', $context.Environment, '-f', $context.Compose)
$configurationJson = & docker @arguments config --format json
if ($LASTEXITCODE -ne 0) { throw 'Compose configuration validation failed.' }
$configuration = ($configurationJson -join "`n") | ConvertFrom-Json
$expected = [IO.Path]::GetFullPath((Join-Path $artifactRoot 'backend')).Replace('\','/')
if ($configuration.services.backend.build.context.Replace('\','/') -ne $expected) { throw 'Compose build context does not match the verified release.' }
$ledgerId = $configuration.services.backend.environment.ERASURE_LEDGER_ID
if ($ledgerId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'A fixed ledger identity is required.' }
$receipt = Join-Path $context.Root 'erasure-ledger-initialized.json'
if (Test-Path -LiteralPath $receipt) { throw 'Ledger initialization is already recorded; normal startup must preserve it.' }
$logs = Join-Path $context.Root 'logs'
Invoke-DeploymentNative 'docker' ($arguments + @('up', '-d', '--wait', '--wait-timeout', '180', 'erasure-database')) (Join-Path $logs 'erasure-database-start.log')
Invoke-DeploymentNative 'docker' ($arguments + @('build', 'backend')) (Join-Path $logs 'erasure-initializer-build.log')
# Literal shell text: secrets stay inside the container and never enter host command arguments.
$initialize = 'export ERASURE_LEDGER_PASSWORD="$(cat /run/secrets/manager.erasure-ledger.password)"; exec java -Dloader.main=com.aimanager.retention.internal.ErasureLedgerBootstrap -cp /app/manager-backend.jar org.springframework.boot.loader.launch.PropertiesLauncher initialize-new-ledger'
Invoke-DeploymentNative 'docker' ($arguments + @('run', '--rm', '--no-deps', '--entrypoint', '/bin/sh', 'backend', '-c', $initialize)) (Join-Path $logs 'erasure-initialize.log')
# After explicit schema creation, remove runtime DDL and accepted-record mutation privileges.
# The app never mounts root. Only work permits and unaccepted pause intentions can be removed.
# The image escapes underscores in database-level grants. Revoke the dedicated account's grants
# without matching that wildcard spelling, then grant only the required table permissions.
$restrict = 'export MYSQL_PWD="$(cat /run/secrets/erasure_root)"; exec mysql -uroot -e "REVOKE ALL PRIVILEGES, GRANT OPTION FROM ''erasure_app''@''%''; GRANT SELECT,UPDATE ON erasure_ledger.erasure_ledger_head TO ''erasure_app''@''%''; GRANT SELECT,INSERT ON erasure_ledger.erasure_ledger_entries TO ''erasure_app''@''%''; GRANT SELECT,INSERT,DELETE ON erasure_ledger.erasure_work_admissions TO ''erasure_app''@''%''; GRANT SELECT,INSERT,DELETE ON erasure_ledger.erasure_admission_pause TO ''erasure_app''@''%'';"'
Invoke-DeploymentNative 'docker' ($arguments + @('exec', '-T', 'erasure-database', '/bin/sh', '-c', $restrict)) (Join-Path $logs 'erasure-restrict-runtime.log')
[ordered]@{schemaVersion=1; ledgerId=$ledgerId; initializedAt=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding utf8NoBOM
Write-Output 'Independent erasure ledger initialized; runtime permissions restricted. Preserve its identity, credentials and backups separately.'
