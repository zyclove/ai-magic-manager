"""Exercise the primary launcher with metadata and command fakes only.

PowerShell 7 is required. Each case copies the actual primary launcher and
metadata reader into its own ignored temporary repository. Docker, browser
opening, and the selected release's start/verify scripts are local fakes.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PWSH = shutil.which("pwsh")
PROJECT = "aimanager-primary-fixture"
HOST_PROJECT = "another-host-project"
ENV_PROJECT = "another-environment-project"
PRIVATE_MARKER = "synthetic-launcher-private-material"


FAKE_START = r"""
param([string]$Directory)
Write-LauncherTestEvent @{
    kind='start'; project=$env:COMPOSE_PROJECT_NAME; edgePort=$env:EDGE_PORT; directory=$Directory
    source=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
}
switch ($env:PRIMARY_TEST_START_MODE) {
    'throw' { throw 'Synthetic start failure.' }
    'exit' { exit 17 }
    'write-log' {
        $source = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
        $deployment = [IO.Path]::GetFullPath((Join-Path $source $Directory))
        # Deliberately do not create the parent: the actual primary launcher
        # must prepare it before the selected release writes its start log.
        [IO.File]::WriteAllText((Join-Path $deployment 'logs/compose-start.log'),
            "Synthetic selected release started.`n", [Text.UTF8Encoding]::new($false))
    }
}
"""

FAKE_VERIFY = r"""
param([string]$Directory)
Write-LauncherTestEvent @{
    kind='verify'; project=$env:COMPOSE_PROJECT_NAME; edgePort=$env:EDGE_PORT; directory=$Directory
    source=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
}
switch ($env:PRIMARY_TEST_VERIFY_MODE) {
    'throw' { throw 'Synthetic verification failure.' }
    'exit' { exit 23 }
}
"""

WRAPPER = r"""
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0
$global:PRIMARY_TEST_COMPOSE_COUNT = 0
function global:Write-LauncherTestEvent($Event) {
    if ($env:PRIMARY_TEST_LEASE_PROBE -ceq 'true') {
        $probeStream = $null
        try {
            $probeStream = [IO.File]::Open($env:PRIMARY_TEST_RUNTIME_LEASE,
                [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $Event.leaseHeld = $false
        } catch [IO.IOException] {
            # The fixture owns the directory; an exclusive OS file handle
            # held by the real launcher is the only expected IO conflict.
            $Event.leaseHeld = $true
        } finally {
            if ($null -ne $probeStream) { $probeStream.Dispose() }
        }
    }
    $line = ConvertTo-Json -InputObject $Event -Depth 10 -Compress
    [IO.File]::AppendAllText($env:PRIMARY_TEST_EVENTS, $line + "`n",
        [Text.UTF8Encoding]::new($false))
}
function global:docker {
    $arguments = @($args | ForEach-Object { [string]$_ })
    $global:LASTEXITCODE = 0
    if ($arguments.Count -eq 0) { throw 'Unexpected empty Docker fake command.' }
    if ($arguments[0] -ceq 'compose') {
        $project = $env:COMPOSE_PROJECT_NAME
        if (-not $project) { $project = $env:PRIMARY_TEST_ENV_PROJECT }
        $explicitProject = $false
        for ($index = 1; $index -lt $arguments.Count; $index++) {
            if ($arguments[$index] -cin @('-p', '--project-name')) {
                if ($index + 1 -ge $arguments.Count) { throw 'Missing fake project argument.' }
                $project = $arguments[$index + 1]
                $explicitProject = $true
            } elseif ($arguments[$index].StartsWith('--project-name=')) {
                $project = $arguments[$index].Substring('--project-name='.Length)
                $explicitProject = $true
            }
        }
        Write-LauncherTestEvent @{
            kind='compose'; argv=$arguments; project=$project
            explicitProject=$explicitProject
        }
        if ($arguments -cnotcontains 'ps') { throw 'Unexpected Compose fake command.' }
        $global:PRIMARY_TEST_COMPOSE_COUNT += 1
        if ($env:PRIMARY_TEST_ENGINE_OFF -ceq 'true' -and $global:PRIMARY_TEST_COMPOSE_COUNT -eq 1) {
            $global:LASTEXITCODE = 1
            Write-Output 'Synthetic Docker engine is unavailable.'
            return
        }
        if ($env:PRIMARY_TEST_RETRY_COMPOSE_MODE -ceq 'fail' -and $global:PRIMARY_TEST_COMPOSE_COUNT -gt 1) {
            $global:LASTEXITCODE = 37
            Write-Output 'Synthetic Docker engine remains unavailable.'
            return
        }
        if ($env:PRIMARY_TEST_COMPOSE_JSON_MODE -ceq 'invalid') {
            Write-Output 'Synthetic successful Compose command with malformed JSON.'
            return
        }
        if ($env:PRIMARY_TEST_HEALTH -ceq 'healthy') {
            foreach ($service in @('backend', 'database', 'edge', 'erasure-database',
                                   'identity', 'identity-database')) {
                @{Service=$service; Project=$project; State='running'; Health='healthy'} |
                    ConvertTo-Json -Compress
            }
        }
        return
    }
    if ($arguments[0] -ceq 'context') {
        if ($arguments.Count -ne 2 -or $arguments[1] -cne 'show') {
            throw 'The launcher fixture permits context inspection only.'
        }
        Write-LauncherTestEvent @{kind='context'; argv=$arguments}
        Write-Output $env:PRIMARY_TEST_DOCKER_CONTEXT
        return
    }
    if ($arguments[0] -ceq 'desktop') {
        Write-LauncherTestEvent @{kind='desktop'; argv=$arguments}
        if ($arguments.Count -ne 4 -or $arguments[1] -cne 'start' -or
            $arguments[2] -cne '--timeout' -or $arguments[3] -cne '120') {
            throw 'The launcher fixture only permits bounded Docker Desktop start.'
        }
        if ($env:PRIMARY_TEST_DESKTOP_START_MODE -ceq 'fail') {
            $global:LASTEXITCODE = 31
            Write-Output 'Synthetic Docker Desktop start failure.'
            return
        }
        Write-Output 'Synthetic Docker Desktop start completed.'
        return
    }
    if ($arguments[0] -ceq 'ps') {
        Write-LauncherTestEvent @{kind='edges'; argv=$arguments}
        if ($env:PRIMARY_TEST_FOREIGN_EDGE) { Write-Output 'foreign-edge-fixture-id' }
        return
    }
    if ($arguments[0] -ceq 'inspect') {
        if ($arguments.Count -ne 2 -or $arguments[1] -cne 'foreign-edge-fixture-id') {throw 'Unexpected inspection target.'}
        Write-LauncherTestEvent @{kind='inspect'; argv=$arguments}
        @(@{Id='foreign-edge-fixture-id';Config=@{Labels=@{'com.docker.compose.project'=$env:PRIMARY_TEST_FOREIGN_EDGE;'com.docker.compose.service'='edge'}};NetworkSettings=@{Ports=@{'8080/tcp'=@(@{HostIp='127.0.0.1';HostPort=$env:PRIMARY_TEST_FOREIGN_EDGE_PORT})}}}) | ConvertTo-Json -Depth 10 -Compress
        return
    }
    throw 'Unexpected Docker fake command; real Docker is never a fallback.'
}
function global:Start-Process { throw 'A launcher fixture must not open a browser.' }
$messages = [Collections.Generic.List[string]]::new()
$failed = $false
$callSucceeded = $false
$callCode = 0
$errorText = $null
$externalLeaseStream = $null
try {
    if ($env:PRIMARY_TEST_EXTERNAL_LEASE -ceq 'true') {
        $externalLeaseStream = [IO.File]::Open($env:PRIMARY_TEST_RUNTIME_LEASE,
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    $switches = @{NoBrowser=$true}
    if ($env:PRIMARY_TEST_CHECK_ONLY -ceq 'true') { $switches.CheckOnly = $true }
    & $env:PRIMARY_TEST_LAUNCHER @switches |
        ForEach-Object { $messages.Add([string]$_) }
    $callSucceeded = $?
    $callCode = $global:LASTEXITCODE
} catch {
    $failed = $true
    $callCode = $global:LASTEXITCODE
    $errorText = $_.Exception.Message
} finally {
    if ($null -ne $externalLeaseStream) { $externalLeaseStream.Dispose() }
}
$runtimeLeaseReleased = $null
if ($env:PRIMARY_TEST_LEASE_PROBE -ceq 'true') {
    $probeStream = $null
    try {
        # Release the wrapper's external lease before checking whether the
        # primary launcher leaked any of its own handles on return/failure.
        $probeStream = [IO.File]::Open($env:PRIMARY_TEST_RUNTIME_LEASE,
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $runtimeLeaseReleased = $true
    } catch [IO.IOException] {
        $runtimeLeaseReleased = $false
    } finally {
        if ($null -ne $probeStream) { $probeStream.Dispose() }
    }
}
$environmentValue = [Environment]::GetEnvironmentVariable('COMPOSE_PROJECT_NAME', 'Process')
$edgePortValue = [Environment]::GetEnvironmentVariable('EDGE_PORT', 'Process')
$ready = @($messages | Where-Object { $_.StartsWith('Console ready:') }).Count -gt 0
@{
    ok=(-not $failed -and $callSucceeded -and $callCode -eq 0)
    failed=$failed; code=$callCode; ready=$ready; error=$errorText
    environmentPresent=($null -ne $environmentValue); environmentValue=$environmentValue
    edgePortPresent=($null -ne $edgePortValue); edgePortValue=$edgePortValue
    runtimeLeaseReleased=$runtimeLeaseReleased
} | ConvertTo-Json -Compress
"""


class StartActiveConsoleTest(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(PWSH, "PowerShell 7 is required")
        local = ROOT / ".local"
        local.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(
            prefix="start-active-console-test-", dir=local,
        )
        self.root = Path(self.temporary.name) / "repository"
        self.scripts = self.root / "scripts"
        self.scripts.mkdir(parents=True)
        for name in ("console-activation.ps1", "start-active-console.ps1"):
            shutil.copyfile(ROOT / "scripts" / name, self.scripts / name)
        self.local = self.root / ".local"
        self.source = self.local / "selected-release"
        self.deployment = self.source / ".local/deployment"
        self.deployment.mkdir(parents=True)
        self.logs = self.deployment / "logs"
        self.directory_links = []
        selected_scripts = self.source / "scripts"
        selected_scripts.mkdir()
        (selected_scripts / "start-deployment.ps1").write_text(FAKE_START, encoding="utf-8")
        (selected_scripts / "verify-deployment.ps1").write_text(FAKE_VERIFY, encoding="utf-8")
        compose = self.source / "deploy/compose/compose.yaml"
        compose.parent.mkdir(parents=True)
        compose.write_text("name: ${COMPOSE_PROJECT_NAME}\nservices: {}\n", encoding="utf-8")
        (self.deployment / ".env").write_text(
            f"COMPOSE_PROJECT_NAME={ENV_PROJECT}\nFIXTURE_PRIVATE={PRIVATE_MARKER}\n",
            encoding="utf-8",
        )
        self.manifest = self.deployment / "release-manifest.json"
        self.write_json(self.manifest, {
            "schemaVersion": 1, "publicUrl": "http://localhost:18101",
            "artifactRoot": "artifacts/release-0123456789abcdef0123456789abcdef",
        })
        self.write_json(self.deployment / "deployment.json", {
            "schemaVersion": 1, "projectName": PROJECT,
            "publicUrl": "http://localhost:18101", "repositoryRoot": str(self.source),
        })
        receipt_path = self.local / "runtime/activation.json"
        receipt = {
            "schemaVersion": 1, "state": "COMMITTED", "project": PROJECT,
            "publicUrl": "http://localhost:18101", "sourceDirectory": str(self.source),
            "deploymentDirectory": str(self.deployment),
            "releaseManifestSha256": self.sha(self.manifest),
        }
        self.write_json(receipt_path, receipt)
        pointer = {
            **receipt, "activationReceipt": str(receipt_path),
            "activationReceiptSha256": self.sha(receipt_path),
        }
        self.write_json(self.local / "console-active.json", pointer)
        self.write_json(self.local / "console-activation-intent.json", pointer)
        self.events_path = Path(self.temporary.name) / "events.jsonl"
        self.runtime_lease_path = self.local / "runtime/console-runtime.lock"

    def tearDown(self):
        # Only this newly created ignored fixture directory can be removed.
        target = Path(self.temporary.name).resolve()
        self.assertEqual(target.parent, (ROOT / ".local").resolve())
        self.assertTrue(target.name.startswith("start-active-console-test-"))
        # Remove only the link itself before recursive fixture cleanup. Both
        # the link's lexical location and its real parent stay in this fixture.
        for link in reversed(self.directory_links):
            self.assertTrue(Path(os.path.abspath(link)).is_relative_to(target))
            self.assertTrue(link.parent.resolve().is_relative_to(target))
            if os.path.lexists(link):
                self.assert_directory_link(link)
                if os.name == "nt":
                    os.rmdir(link)
                else:
                    link.unlink()
        self.temporary.cleanup()

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def write_json(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")

    def assert_directory_link(self, path):
        if os.name == "nt":
            self.assertTrue(path.lstat().st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT,
                            "The Windows fixture must be a real reparse point")
        else:
            self.assertTrue(path.is_symlink(), "The fixture must be a real directory link")

    def make_directory_link(self, link, target):
        # Reuse the activation tests' native Junction fixture pattern, with
        # stricter ownership checks for creation and explicit link cleanup.
        fixture = Path(self.temporary.name).resolve()
        self.assertTrue(Path(os.path.abspath(link)).is_relative_to(fixture))
        self.assertTrue(link.parent.resolve().is_relative_to(fixture))
        self.assertTrue(target.resolve().is_relative_to(fixture))
        self.assertTrue(target.is_dir())
        self.assertFalse(os.path.lexists(link))
        self.directory_links.append(link)
        if os.name != "nt":
            os.symlink(target, link, target_is_directory=True)
        else:
            environment = os.environ.copy()
            environment["PRIMARY_TEST_LINK"] = str(link)
            environment["PRIMARY_TEST_LINK_TARGET"] = str(target)
            environment["PATH"] = ""
            result = subprocess.run(
                [PWSH, "-NoProfile", "-NonInteractive", "-Command",
                 "$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path "
                 "$env:PRIMARY_TEST_LINK -Target $env:PRIMARY_TEST_LINK_TARGET | Out-Null"],
                cwd=self.root, env=environment, capture_output=True, text=True,
                encoding="utf-8", timeout=20,
            )
            self.assertEqual(result.returncode, 0, "Could not create the bounded Junction fixture")
            self.assertEqual(result.stderr, "", "Junction fixture creation emitted diagnostics")
        self.assert_directory_link(link)

    def invoke(self, *, host_project=HOST_PROJECT, health="unhealthy", check_only=False,
               foreign_edge="", start_mode="ok", verify_mode="ok", host_edge_port=None,
               foreign_edge_port="18101", engine_off=False, docker_context="desktop-linux",
               docker_host=None, desktop_start_mode="ok", retry_compose_mode="ok",
               compose_json_mode="valid", lease_probe=False, external_lease=False):
        environment = os.environ.copy()
        environment.pop("COMPOSE_PROJECT_NAME", None)
        if host_project is not None:
            environment["COMPOSE_PROJECT_NAME"] = host_project
        environment.pop("EDGE_PORT", None)
        if host_edge_port is not None:
            environment["EDGE_PORT"] = host_edge_port
        environment.pop("DOCKER_HOST", None)
        environment.pop("DOCKER_CONTEXT", None)
        if docker_host is not None:
            environment["DOCKER_HOST"] = docker_host
        environment.update({
            "PRIMARY_TEST_LAUNCHER": str(self.scripts / "start-active-console.ps1"),
            "PRIMARY_TEST_EVENTS": str(self.events_path),
            "PRIMARY_TEST_ENV_PROJECT": ENV_PROJECT,
            "PRIMARY_TEST_HEALTH": health,
            "PRIMARY_TEST_CHECK_ONLY": "true" if check_only else "false",
            "PRIMARY_TEST_FOREIGN_EDGE": foreign_edge,
            "PRIMARY_TEST_FOREIGN_EDGE_PORT": foreign_edge_port,
            "PRIMARY_TEST_START_MODE": start_mode,
            "PRIMARY_TEST_VERIFY_MODE": verify_mode,
            "PRIMARY_TEST_ENGINE_OFF": "true" if engine_off else "false",
            "PRIMARY_TEST_DOCKER_CONTEXT": docker_context,
            "PRIMARY_TEST_DESKTOP_START_MODE": desktop_start_mode,
            "PRIMARY_TEST_RETRY_COMPOSE_MODE": retry_compose_mode,
            "PRIMARY_TEST_COMPOSE_JSON_MODE": compose_json_mode,
            "PRIMARY_TEST_RUNTIME_LEASE": str(self.runtime_lease_path),
            "PRIMARY_TEST_LEASE_PROBE": "true" if lease_probe else "false",
            "PRIMARY_TEST_EXTERNAL_LEASE": "true" if external_lease else "false",
        })
        # The executable is absolute. No executable named Docker can be found
        # if the production code accidentally stops using the command fake.
        environment["PATH"] = ""
        self.events_path.write_text("", encoding="utf-8")
        result = subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-Command", WRAPPER],
            cwd=self.root, env=environment, capture_output=True, text=True,
            encoding="utf-8", timeout=20,
        )
        self.assertEqual(result.returncode, 0, "Launcher fixture wrapper did not terminate normally")
        self.assertEqual(result.stderr, "", "Launcher fixture emitted unexpected diagnostics")
        self.assertFalse(PRIVATE_MARKER in result.stdout or PRIVATE_MARKER in result.stderr,
                         "Launcher exposed private fixture material")
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.fail("Launcher fixture did not emit one safe JSON result")
        events = [json.loads(line) for line in self.events_path.read_text(encoding="utf-8").splitlines()
                  if line]
        return payload, events

    @staticmethod
    def of_kind(events, kind):
        return [event for event in events if event["kind"] == kind]

    def assert_selected(self, events):
        compose = self.of_kind(events, "compose")
        self.assertTrue(compose, "The primary launcher did not inspect its selected project")
        for event in compose:
            self.assertEqual(event["project"], PROJECT, "Compose used a project outside its selection")
            self.assertTrue(event["explicitProject"], "Compose project was not bound explicitly")
            arguments = event["argv"]
            self.assertEqual(arguments[arguments.index("--env-file") + 1],
                             str(self.deployment / ".env"))
            self.assertEqual(Path(arguments[arguments.index("-f") + 1]),
                             self.source / "deploy/compose/compose.yaml")
            self.assertFalse(set(arguments) & {"stop", "down", "rm", "prune"},
                             "Primary startup must not stop or remove another runtime")
        for kind in ("start", "verify"):
            for event in self.of_kind(events, kind):
                self.assertEqual(event["project"], PROJECT,
                                 "A frozen release script inherited the wrong project")
                self.assertEqual(event["directory"], ".local/deployment")
                self.assertEqual(Path(event["source"]), self.source,
                                 "A script outside the selected freeze was invoked")

    def assert_restored(self, payload, original):
        self.assertEqual(payload["environmentPresent"], original is not None,
                         "The launcher changed whether the host project variable exists")
        self.assertEqual(payload["environmentValue"], original,
                         "The launcher did not restore the host project variable")

    def assert_rejected(self, payload):
        self.assertFalse(payload["ok"], "Launcher failure did not reach its caller")
        self.assertFalse(payload["ready"], "A failed launcher still announced readiness")

    def assert_edge_port_restored(self, payload, original):
        self.assertEqual(payload["edgePortPresent"], original is not None)
        self.assertEqual(payload["edgePortValue"], original)

    def assert_no_release_start_or_verification(self, events):
        self.assertEqual(self.of_kind(events, "start"), [])
        self.assertEqual(self.of_kind(events, "verify"), [])

    def assert_runtime_lease_held(self, events):
        self.assertTrue(events, "Runtime lease inspection needs an actual launcher operation")
        for event in events:
            self.assertIs(event.get("leaseHeld"), True,
                          f"The launcher did not hold its runtime lease during {event['kind']}")

    def assert_runtime_lease_released(self, payload):
        self.assertIs(payload["runtimeLeaseReleased"], True,
                      "The launcher retained its runtime lease after returning")

    def test_host_project_cannot_select_compose_or_frozen_scripts(self):
        payload, events = self.invoke()
        self.assertTrue(payload["ok"], "Selected startup did not complete")
        self.assertTrue(payload["ready"])
        self.assertEqual(len(self.of_kind(events, "start")), 1)
        self.assertEqual(len(self.of_kind(events, "verify")), 1)
        self.assert_selected(events)

    def test_missing_logs_directory_is_created_before_selected_release_writes_start_log(self):
        self.assertFalse(self.logs.exists())
        payload, events = self.invoke(start_mode="write-log", lease_probe=True,
                                      host_edge_port="18112")
        self.assertTrue(payload["ok"], "The selected release could not write its log with a missing parent")
        self.assertTrue(payload["ready"])
        self.assertTrue(self.logs.is_dir())
        self.assertEqual((self.logs / "compose-start.log").read_bytes(),
                         b"Synthetic selected release started.\n")
        self.assertEqual([event["kind"] for event in events], ["compose", "edges", "start", "verify"])
        self.assert_runtime_lease_held(events)
        self.assert_runtime_lease_released(payload)
        self.assert_selected(events)
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_existing_logs_directory_contents_survive_selected_release_start(self):
        self.logs.mkdir()
        old_log = self.logs / "earlier-start.log"
        old_log.write_bytes(b"Keep the earlier runtime evidence.\n")
        archived_log = self.logs / "archive/earlier-verification.log"
        archived_log.parent.mkdir()
        archived_log.write_bytes(b"Keep the nested verification evidence.\n")
        payload, events = self.invoke(start_mode="write-log", lease_probe=True,
                                      host_edge_port="18112")
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["ready"])
        self.assertEqual(old_log.read_bytes(), b"Keep the earlier runtime evidence.\n")
        self.assertEqual(archived_log.read_bytes(), b"Keep the nested verification evidence.\n")
        self.assertEqual((self.logs / "compose-start.log").read_bytes(),
                         b"Synthetic selected release started.\n")
        self.assertEqual([event["kind"] for event in events], ["compose", "edges", "start", "verify"])
        self.assert_runtime_lease_held(events)
        self.assert_runtime_lease_released(payload)
        self.assert_selected(events)
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_check_only_never_creates_missing_logs_for_healthy_or_unhealthy_selection(self):
        for health in ("healthy", "unhealthy"):
            with self.subTest(health=health):
                self.assertFalse(self.logs.exists())
                payload, events = self.invoke(
                    health=health, check_only=True, start_mode="write-log",
                    lease_probe=True, host_edge_port="18112",
                )
                if health == "healthy":
                    self.assertTrue(payload["ok"])
                    self.assertTrue(payload["ready"])
                    self.assertEqual([event["kind"] for event in events], ["compose", "verify"])
                else:
                    self.assert_rejected(payload)
                    self.assertEqual([event["kind"] for event in events], ["compose"])
                self.assertEqual(self.of_kind(events, "start"), [])
                self.assertFalse(os.path.lexists(self.logs), "CheckOnly created a log directory")
                self.assert_runtime_lease_held(events)
                self.assert_runtime_lease_released(payload)
                self.assert_selected(events)
                self.assert_restored(payload, HOST_PROJECT)
                self.assert_edge_port_restored(payload, "18112")

    def test_healthy_normal_start_does_not_create_logs_without_starting_release(self):
        payload, events = self.invoke(health="healthy", start_mode="write-log",
                                      lease_probe=True, host_edge_port="18112")
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["ready"])
        self.assertEqual([event["kind"] for event in events], ["compose", "verify"])
        self.assertFalse(os.path.lexists(self.logs), "An already healthy release created unused logs")
        self.assert_runtime_lease_held(events)
        self.assert_runtime_lease_released(payload)
        self.assert_selected(events)
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_foreign_port_conflict_is_rejected_before_creating_missing_logs(self):
        payload, events = self.invoke(
            foreign_edge="another-running-project", foreign_edge_port="18101",
            start_mode="write-log", lease_probe=True, host_edge_port="18112",
        )
        self.assert_rejected(payload)
        self.assertEqual([event["kind"] for event in events], ["compose", "edges", "inspect"])
        self.assert_no_release_start_or_verification(events)
        self.assertFalse(os.path.lexists(self.logs), "A foreign listener conflict still created logs")
        self.assert_runtime_lease_held(events)
        self.assert_runtime_lease_released(payload)
        self.assert_selected(events)
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_logs_leaf_file_is_rejected_before_start_or_verification(self):
        marker = b"This existing file must never be replaced with a directory.\n"
        self.logs.write_bytes(marker)
        payload, events = self.invoke(start_mode="write-log", lease_probe=True,
                                      host_edge_port="18112")
        self.assert_rejected(payload)
        self.assert_no_release_start_or_verification(events)
        self.assertEqual(self.logs.read_bytes(), marker)
        self.assertTrue(self.logs.is_file())
        self.assert_runtime_lease_held(events)
        self.assert_runtime_lease_released(payload)
        self.assert_selected(events)
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_logs_junction_is_rejected_without_changing_its_unselected_target(self):
        target = self.root / "unselected-log-target"
        target.mkdir()
        old_log = target / "compose-start.log"
        old_log.write_bytes(b"Do not overwrite the unselected start log.\n")
        marker = target / "untouched.txt"
        marker.write_bytes(b"Do not change this unselected directory.\n")
        self.make_directory_link(self.logs, target)
        payload, events = self.invoke(start_mode="write-log", lease_probe=True,
                                      host_edge_port="18112")
        self.assert_rejected(payload)
        self.assert_no_release_start_or_verification(events)
        self.assert_directory_link(self.logs)
        self.assertEqual(old_log.read_bytes(), b"Do not overwrite the unselected start log.\n")
        self.assertEqual(marker.read_bytes(), b"Do not change this unselected directory.\n")
        self.assertEqual({path.name for path in target.iterdir()}, {"compose-start.log", "untouched.txt"})
        self.assert_runtime_lease_held(events)
        self.assert_runtime_lease_released(payload)
        self.assert_selected(events)
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_dangling_logs_junction_is_rejected_without_recreating_its_target(self):
        target = self.root / "missing-log-target"
        target.mkdir()
        self.make_directory_link(self.logs, target)
        # This is one known empty fixture directory, not a recursive removal.
        self.assertTrue(target.resolve().is_relative_to(Path(self.temporary.name).resolve()))
        target.rmdir()
        self.assertFalse(target.exists())
        payload, events = self.invoke(start_mode="write-log", lease_probe=True,
                                      host_edge_port="18112")
        self.assert_rejected(payload)
        self.assert_no_release_start_or_verification(events)
        self.assert_directory_link(self.logs)
        self.assertFalse(target.exists(), "Startup followed the dangling link and recreated its target")
        self.assert_runtime_lease_held(events)
        self.assert_runtime_lease_released(payload)
        self.assert_selected(events)
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_host_edge_port_cannot_override_selected_release_on_success(self):
        for original in (None, "18112"):
            for health in ("unhealthy", "healthy"):
                with self.subTest(original=original, health=health):
                    payload, events = self.invoke(host_edge_port=original, health=health)
                    self.assertTrue(payload["ok"])
                    for kind in ("start", "verify"):
                        for event in self.of_kind(events, kind):
                            self.assertIsNone(event["edgePort"], "A temporary listener leaked into normal launch")
                    self.assertEqual(payload["edgePortPresent"], original is not None)
                    self.assertEqual(payload["edgePortValue"], original)

    def test_host_edge_port_is_restored_after_child_failures(self):
        for original in (None, "18112"):
            for stage in ("start", "verify"):
                for mode in ("throw", "exit"):
                    with self.subTest(original=original, stage=stage, mode=mode):
                        payload, events = self.invoke(host_edge_port=original, **{f"{stage}_mode": mode})
                        self.assert_rejected(payload)
                        for kind in ("start", "verify"):
                            for event in self.of_kind(events, kind):
                                self.assertIsNone(event["edgePort"], "Failed launch inherited a temporary listener")
                        self.assertEqual(payload["edgePortPresent"], original is not None)
                        self.assertEqual(payload["edgePortValue"], original)

    def test_absent_host_project_is_restored_after_success(self):
        payload, events = self.invoke(host_project=None)
        self.assertTrue(payload["ok"])
        self.assert_restored(payload, None)
        self.assert_selected(events)

    def test_existing_host_project_is_restored_after_success(self):
        payload, events = self.invoke(host_project=HOST_PROJECT)
        self.assertTrue(payload["ok"])
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_selected(events)

    def test_host_project_presence_and_value_are_restored_after_failures(self):
        for original in (None, HOST_PROJECT):
            for stage in ("start", "verify"):
                for mode in ("throw", "exit"):
                    with self.subTest(original_present=original is not None, stage=stage, mode=mode):
                        options = {f"{stage}_mode": mode}
                        payload, events = self.invoke(host_project=original, **options)
                        self.assert_rejected(payload)
                        self.assert_restored(payload, original)
                        self.assert_selected(events)

    def test_check_only_unhealthy_never_starts_or_verifies(self):
        payload, events = self.invoke(check_only=True)
        self.assert_rejected(payload)
        self.assertEqual([event["kind"] for event in events], ["compose"])
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_selected(events)

    def test_foreign_running_edge_blocks_start_without_stopping_it(self):
        payload, events = self.invoke(foreign_edge="another-running-project")
        self.assert_rejected(payload)
        self.assertEqual([event["kind"] for event in events], ["compose", "edges", "inspect"])
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_selected(events)

    def test_foreign_edge_on_another_port_allows_selected_start_without_stopping_it(self):
        payload, events = self.invoke(foreign_edge="another-running-project", foreign_edge_port="18102")
        self.assertTrue(payload["ok"], "An independent console listener blocked normal startup")
        self.assertEqual(len(self.of_kind(events, "start")), 1)
        self.assertEqual(len(self.of_kind(events, "verify")), 1)
        self.assert_selected(events)
        for event in events:
            self.assertFalse(set(event.get("argv", [])) & {"stop", "down", "rm", "prune"})

    def test_start_throw_propagates_without_verification_or_ready(self):
        payload, events = self.invoke(start_mode="throw")
        self.assert_rejected(payload)
        self.assertEqual(len(self.of_kind(events, "start")), 1)
        self.assertEqual(self.of_kind(events, "verify"), [])
        self.assert_restored(payload, HOST_PROJECT)

    def test_start_nonzero_exit_propagates_without_verification_or_ready(self):
        payload, events = self.invoke(start_mode="exit")
        self.assert_rejected(payload)
        self.assertEqual(len(self.of_kind(events, "start")), 1)
        self.assertEqual(self.of_kind(events, "verify"), [])
        self.assert_restored(payload, HOST_PROJECT)

    def test_verify_throw_propagates_without_ready(self):
        payload, events = self.invoke(verify_mode="throw")
        self.assert_rejected(payload)
        self.assertEqual(len(self.of_kind(events, "verify")), 1)
        self.assert_restored(payload, HOST_PROJECT)

    def test_verify_nonzero_exit_propagates_without_ready(self):
        payload, events = self.invoke(verify_mode="exit")
        self.assert_rejected(payload)
        self.assertEqual(len(self.of_kind(events, "verify")), 1)
        self.assert_restored(payload, HOST_PROJECT)

    def test_healthy_check_only_verifies_only_selected_freeze(self):
        payload, events = self.invoke(health="healthy", check_only=True)
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["ready"])
        self.assertEqual([event["kind"] for event in events], ["compose", "verify"])
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_selected(events)

    def test_invalid_activation_fails_before_any_docker_or_release_script(self):
        (self.local / "console-active.json").write_text("not json", encoding="utf-8")
        payload, events = self.invoke()
        self.assert_rejected(payload)
        self.assertEqual(events, [])
        self.assert_restored(payload, HOST_PROJECT)

    def test_engine_off_starts_local_desktop_once_then_rechecks_same_selection(self):
        for original_project in (None, HOST_PROJECT):
            for original_port in (None, "18112"):
                for health in ("unhealthy", "healthy"):
                    with self.subTest(project=original_project, port=original_port, health=health):
                        payload, events = self.invoke(
                            engine_off=True, health=health, host_project=original_project,
                            host_edge_port=original_port,
                        )
                        self.assertTrue(payload["ok"], "Local engine recovery did not complete startup")
                        self.assertTrue(payload["ready"])
                        self.assertEqual(len(self.of_kind(events, "desktop")), 1)
                        self.assertEqual(self.of_kind(events, "desktop")[0]["argv"],
                                         ["desktop", "start", "--timeout", "120"])
                        compose = self.of_kind(events, "compose")
                        self.assertEqual(len(compose), 2, "Engine recovery must recheck the selected runtime once")
                        self.assertEqual(compose[0]["argv"], compose[1]["argv"])
                        self.assertEqual(len(self.of_kind(events, "start")), 1 if health == "unhealthy" else 0)
                        self.assertEqual(len(self.of_kind(events, "verify")), 1)
                        kinds = [event["kind"] for event in events]
                        self.assertEqual(kinds[:4], ["compose", "context", "desktop", "compose"])
                        self.assert_selected(events)
                        self.assert_restored(payload, original_project)
                        self.assert_edge_port_restored(payload, original_port)

    def test_check_only_engine_off_never_starts_desktop_or_release(self):
        payload, events = self.invoke(engine_off=True, check_only=True, host_edge_port="18112")
        self.assert_rejected(payload)
        self.assertEqual([event["kind"] for event in events], ["compose"])
        self.assert_no_release_start_or_verification(events)
        self.assert_selected(events)
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_remote_context_or_explicit_docker_host_never_starts_local_desktop(self):
        for context, host in (("remote-production", None),
                              ("desktop-linux", "tcp://remote.example.test:2376"),
                              ("desktop-linux", "npipe:////./pipe/docker_engine")):
            with self.subTest(context=context, docker_host=host):
                payload, events = self.invoke(
                    engine_off=True, docker_context=context, docker_host=host,
                    host_edge_port="18112",
                )
                self.assert_rejected(payload)
                self.assertEqual(self.of_kind(events, "desktop"), [])
                self.assertEqual(len(self.of_kind(events, "compose")), 1)
                self.assert_no_release_start_or_verification(events)
                for event in self.of_kind(events, "context"):
                    self.assertEqual(event["argv"], ["context", "show"])
                self.assert_selected(events)
                self.assert_restored(payload, HOST_PROJECT)
                self.assert_edge_port_restored(payload, "18112")

    def test_desktop_start_failure_never_starts_or_verifies_release(self):
        for original_project in (None, HOST_PROJECT):
            for original_port in (None, "18112"):
                with self.subTest(project=original_project, port=original_port):
                    payload, events = self.invoke(
                        engine_off=True, desktop_start_mode="fail", host_project=original_project,
                        host_edge_port=original_port,
                    )
                    self.assert_rejected(payload)
                    self.assertEqual(len(self.of_kind(events, "desktop")), 1)
                    self.assertEqual(len(self.of_kind(events, "compose")), 1)
                    self.assert_no_release_start_or_verification(events)
                    self.assertEqual(self.of_kind(events, "edges"), [])
                    self.assert_selected(events)
                    self.assert_restored(payload, original_project)
                    self.assert_edge_port_restored(payload, original_port)

    def test_failed_engine_recheck_never_starts_or_verifies_release(self):
        for original_project in (None, HOST_PROJECT):
            for original_port in (None, "18112"):
                with self.subTest(project=original_project, port=original_port):
                    payload, events = self.invoke(
                        engine_off=True, retry_compose_mode="fail", host_project=original_project,
                        host_edge_port=original_port,
                    )
                    self.assert_rejected(payload)
                    self.assertEqual(len(self.of_kind(events, "desktop")), 1)
                    compose = self.of_kind(events, "compose")
                    self.assertEqual(len(compose), 2)
                    self.assertEqual(compose[0]["argv"], compose[1]["argv"])
                    self.assert_no_release_start_or_verification(events)
                    self.assertEqual(self.of_kind(events, "edges"), [])
                    self.assert_selected(events)
                    self.assert_restored(payload, original_project)
                    self.assert_edge_port_restored(payload, original_port)

    def test_successful_compose_with_malformed_json_is_not_engine_recovery(self):
        payload, events = self.invoke(compose_json_mode="invalid", host_edge_port="18112")
        self.assert_rejected(payload)
        self.assertEqual([event["kind"] for event in events], ["compose"])
        self.assert_no_release_start_or_verification(events)
        self.assert_selected(events)
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_prepared_activation_is_rejected_before_any_engine_recovery(self):
        intent_path = self.local / "console-activation-intent.json"
        intent = json.loads(intent_path.read_text(encoding="utf-8"))
        self.write_json(intent_path, {**intent, "state": "PREPARED"})
        payload, events = self.invoke(engine_off=True, host_edge_port="18112")
        self.assert_rejected(payload)
        self.assertEqual(events, [])
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_external_runtime_lease_blocks_launcher_without_docker_or_file_replacement(self):
        marker = b"another runtime operation owns this existing lease file\n"
        self.runtime_lease_path.write_bytes(marker)
        for check_only in (False, True):
            for engine_off in (False, True):
                with self.subTest(check_only=check_only, engine_off=engine_off):
                    payload, events = self.invoke(
                        lease_probe=True, external_lease=True, check_only=check_only,
                        engine_off=engine_off, host_edge_port="18112",
                    )
                    self.assert_rejected(payload)
                    self.assertEqual(events, [], "A runtime lease conflict must precede every Docker operation")
                    self.assert_no_release_start_or_verification(events)
                    self.assertTrue(self.runtime_lease_path.is_file(), "The launcher removed another operation's lease file")
                    self.assertEqual(self.runtime_lease_path.read_bytes(), marker,
                                     "The launcher replaced another operation's existing lease file")
                    self.assert_runtime_lease_released(payload)
                    self.assert_restored(payload, HOST_PROJECT)
                    self.assert_edge_port_restored(payload, "18112")

    def test_healthy_normal_start_holds_runtime_lease_through_verification(self):
        payload, events = self.invoke(lease_probe=True, health="healthy")
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["ready"])
        self.assertEqual([event["kind"] for event in events], ["compose", "verify"])
        self.assert_runtime_lease_held(events)
        self.assert_runtime_lease_released(payload)
        self.assert_selected(events)

    def test_healthy_check_only_holds_runtime_lease_through_verification(self):
        payload, events = self.invoke(lease_probe=True, health="healthy", check_only=True)
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["ready"])
        self.assertEqual([event["kind"] for event in events], ["compose", "verify"])
        self.assert_runtime_lease_held(events)
        self.assert_runtime_lease_released(payload)
        self.assert_selected(events)

    def test_unhealthy_normal_start_holds_runtime_lease_through_selected_scripts(self):
        payload, events = self.invoke(lease_probe=True, host_edge_port="18112")
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["ready"])
        self.assertEqual([event["kind"] for event in events], ["compose", "edges", "start", "verify"])
        self.assert_runtime_lease_held(events)
        self.assert_runtime_lease_released(payload)
        self.assert_selected(events)
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_engine_recovery_holds_runtime_lease_through_desktop_and_release_start(self):
        payload, events = self.invoke(lease_probe=True, engine_off=True, host_edge_port="18112")
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["ready"])
        self.assertEqual([event["kind"] for event in events],
                         ["compose", "context", "desktop", "compose", "edges", "start", "verify"])
        self.assert_runtime_lease_held(events)
        self.assert_runtime_lease_released(payload)
        self.assert_selected(events)
        self.assert_restored(payload, HOST_PROJECT)
        self.assert_edge_port_restored(payload, "18112")

    def test_child_start_and_verification_failures_release_runtime_lease(self):
        for stage in ("start", "verify"):
            for mode in ("throw", "exit"):
                with self.subTest(stage=stage, mode=mode):
                    payload, events = self.invoke(
                        lease_probe=True, host_edge_port="18112", **{f"{stage}_mode": mode},
                    )
                    self.assert_rejected(payload)
                    self.assert_runtime_lease_held(events)
                    self.assert_runtime_lease_released(payload)
                    self.assert_selected(events)
                    self.assert_restored(payload, HOST_PROJECT)
                    self.assert_edge_port_restored(payload, "18112")

    def test_engine_and_inspection_failures_release_runtime_lease(self):
        for options in (
            {"engine_off": True, "desktop_start_mode": "fail"},
            {"engine_off": True, "retry_compose_mode": "fail"},
            {"engine_off": True, "docker_context": "remote-production"},
            {"engine_off": True, "check_only": True},
            {"compose_json_mode": "invalid"},
        ):
            with self.subTest(options=options):
                payload, events = self.invoke(lease_probe=True, host_edge_port="18112", **options)
                self.assert_rejected(payload)
                self.assert_no_release_start_or_verification(events)
                self.assert_runtime_lease_held(events)
                self.assert_runtime_lease_released(payload)
                self.assert_selected(events)
                self.assert_restored(payload, HOST_PROJECT)
                self.assert_edge_port_restored(payload, "18112")

    def test_invalid_or_prepared_activation_releases_runtime_lease_without_docker(self):
        pointer_path = self.local / "console-active.json"
        intent_path = self.local / "console-activation-intent.json"
        original_pointer = pointer_path.read_bytes()
        original_intent = intent_path.read_bytes()
        for state in ("invalid-pointer", "prepared-intent"):
            with self.subTest(state=state):
                pointer_path.write_bytes(original_pointer)
                intent_path.write_bytes(original_intent)
                if state == "invalid-pointer":
                    pointer_path.write_text("not json", encoding="utf-8")
                else:
                    intent = json.loads(original_intent)
                    self.write_json(intent_path, {**intent, "state": "PREPARED"})
                payload, events = self.invoke(lease_probe=True, host_edge_port="18112")
                self.assert_rejected(payload)
                self.assertEqual(events, [])
                self.assert_runtime_lease_released(payload)
                self.assert_restored(payload, HOST_PROJECT)
                self.assert_edge_port_restored(payload, "18112")


if __name__ == "__main__":
    unittest.main()
