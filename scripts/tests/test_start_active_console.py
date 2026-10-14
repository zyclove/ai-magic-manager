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
function global:Write-LauncherTestEvent($Event) {
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
        if ($env:PRIMARY_TEST_HEALTH -ceq 'healthy') {
            foreach ($service in @('backend', 'database', 'edge', 'erasure-database',
                                   'identity', 'identity-database')) {
                @{Service=$service; Project=$project; State='running'; Health='healthy'} |
                    ConvertTo-Json -Compress
            }
        }
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
try {
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
}
$environmentValue = [Environment]::GetEnvironmentVariable('COMPOSE_PROJECT_NAME', 'Process')
$edgePortValue = [Environment]::GetEnvironmentVariable('EDGE_PORT', 'Process')
$ready = @($messages | Where-Object { $_.StartsWith('Console ready:') }).Count -gt 0
@{
    ok=(-not $failed -and $callSucceeded -and $callCode -eq 0)
    failed=$failed; code=$callCode; ready=$ready; error=$errorText
    environmentPresent=($null -ne $environmentValue); environmentValue=$environmentValue
    edgePortPresent=($null -ne $edgePortValue); edgePortValue=$edgePortValue
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

    def tearDown(self):
        # Only this newly created ignored fixture directory can be removed.
        target = Path(self.temporary.name).resolve()
        self.assertEqual(target.parent, (ROOT / ".local").resolve())
        self.assertTrue(target.name.startswith("start-active-console-test-"))
        self.temporary.cleanup()

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def write_json(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")

    def invoke(self, *, host_project=HOST_PROJECT, health="unhealthy", check_only=False,
               foreign_edge="", start_mode="ok", verify_mode="ok", host_edge_port=None,
               foreign_edge_port="18101"):
        environment = os.environ.copy()
        environment.pop("COMPOSE_PROJECT_NAME", None)
        if host_project is not None:
            environment["COMPOSE_PROJECT_NAME"] = host_project
        environment.pop("EDGE_PORT", None)
        if host_edge_port is not None:
            environment["EDGE_PORT"] = host_edge_port
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

    def test_host_project_cannot_select_compose_or_frozen_scripts(self):
        payload, events = self.invoke()
        self.assertTrue(payload["ok"], "Selected startup did not complete")
        self.assertTrue(payload["ready"])
        self.assertEqual(len(self.of_kind(events, "start")), 1)
        self.assertEqual(len(self.of_kind(events, "verify")), 1)
        self.assert_selected(events)

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


if __name__ == "__main__":
    unittest.main()
