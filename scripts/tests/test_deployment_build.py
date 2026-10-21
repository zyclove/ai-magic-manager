"""Run the real release orchestrator with controlled compiler boundaries.

The doubles replace costly SDK builds, not snapshot, manifest or publication
logic. Full SDK verification remains a separate release gate.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
PWSH = shutil.which("pwsh")
PROJECTS = {
    "apps/guardian": "flutter", "apps/child": "flutter", "apps/parent": "flutter",
    "packages/device_operations": "flutter", "packages/usage_report_ui": "flutter",
    "packages/device_operations/example": "flutter",
    "packages/device_policy": "dart", "packages/device_identity": "dart",
    "packages/device_access": "dart", "packages/device_observation": "dart",
    "packages/device_reports": "dart", "packages/usage_reporting": "dart",
    "packages/device_cleanup": "dart",
}
PROPERTIES = {
    "device.policy.package": "packages/device_policy",
    "device.identity.package": "packages/device_identity",
    "device.access.package": "packages/device_access",
    "device.child.package": "apps/child",
    "observation.device.package": "packages/device_observation",
    "observation.guardian.package": "apps/guardian",
    "usage.report.device.package": "packages/device_reports",
    "usage.report.guardian.package": "apps/guardian",
    "diagnostic.guardian.package": "apps/guardian",
    "parent.package": "apps/parent",
    "guardian.package": "apps/guardian",
}


class DeploymentBuildTest(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / ".local" / ("build-test-" + uuid.uuid4().hex)
        self.source = self.directory / "input source"
        self.deployment = self.directory / "deployment"
        self.deployment.mkdir(parents=True)
        (self.deployment / "secrets").mkdir()
        (self.deployment / "deployment.json").write_text(json.dumps({
            "schemaVersion": 1, "publicUrl": "http://localhost:18091"}), encoding="utf-8")
        self.old_env = "COMPOSE_PROJECT_NAME=build-test\nBACKEND_BUILD_CONTEXT='old'\n"
        (self.deployment / ".env").write_text(self.old_env, encoding="utf-8")
        (self.source / "backend").mkdir(parents=True)
        (self.source / "backend/pom.xml").write_text("<project/>", encoding="utf-8")
        # Existing script only activates two interop branches with these markers.
        for name in ("DeviceConfigurationHttpInteropTest", "DeviceIdentityHttpInteropTest"):
            marker = self.source / f"backend/src/test/java/com/aimanager/{name}.java"
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text("// fixture", encoding="utf-8")
        for project, toolkit in PROJECTS.items():
            path = self.source / project
            path.mkdir(parents=True)
            pubspec = f"name: {path.name}\nenvironment:\n  sdk: '>=3.4.0 <4.0.0'\n"
            if toolkit == "flutter":
                pubspec += "dependencies:\n  flutter:\n    sdk: flutter\n"
            (path / "pubspec.yaml").write_text(pubspec, encoding="utf-8")
            if project != "packages/device_cleanup":
                (path / "test").mkdir()
                (path / "test/example_test.dart").write_text("// fixture", encoding="utf-8")
        for excluded in ("build", ".dart_tool", ".local"):
            path = self.source / "apps/guardian" / excluded
            path.mkdir()
            (path / "stale.marker").write_text("stale", encoding="utf-8")
        self.calls = self.directory / "calls.jsonl"
        self.tool = self.directory / "sdk.ps1"
        self.tool.write_text(r'''
$toolArgs = @($args)
$toolName = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
$cwd = (Get-Location).Path
$injectFailure = $env:BUILD_TEST_FAIL -and $cwd.Replace('\','/').EndsWith($env:BUILD_TEST_FAIL) -and $toolArgs[0] -eq $env:BUILD_TEST_FAIL_ACTION
@{tool=$toolName; cwd=$cwd; arguments=$toolArgs; failureInjected=[bool]$injectFailure} | ConvertTo-Json -Compress -Depth 5 | Add-Content -LiteralPath $env:BUILD_TEST_CALLS
if ($injectFailure) { exit 23 }
if ($toolName -eq 'maven') {
    $index = [Array]::IndexOf($toolArgs, '-f')
    $target = Join-Path (Split-Path $toolArgs[$index + 1] -Parent) 'target'
    $null = New-Item -ItemType Directory -Path $target -Force
    [IO.File]::WriteAllText((Join-Path $target 'manager-backend.jar'), 'fixture artifact')
}
if ($toolArgs[0] -eq 'build') {
    $null = New-Item -ItemType Directory -Path 'build/web' -Force
    [IO.File]::WriteAllText((Join-Path $cwd 'build/web/index.html'), '<html>fixture</html>')
    [IO.File]::WriteAllText((Join-Path $cwd 'build/web/main.dart.js'), 'fixture artifact')
    $null = New-Item -ItemType Directory -Path 'build/web/assets' -Force
    [IO.File]::WriteAllText((Join-Path $cwd 'build/web/assets/app.json'), '{"fixture":true}')
    if ($env:BUILD_TEST_MUTATE_SOURCE -eq 'true') {
        [IO.File]::AppendAllText((Join-Path $cwd 'pubspec.yaml'), "`n# changed during build")
    }
}
exit 0
''', encoding="utf-8")
        for name in ("maven", "dart"):
            shutil.copyfile(self.tool, self.directory / f"{name}.ps1")
        # The orchestrator derives the SDK root from bin/flutter. Keep its
        # tools-snapshot check inside this fixture instead of an installed SDK.
        self.flutter_command = self.directory / "fake-sdk/bin/flutter.ps1"
        self.flutter_tools = self.directory / "fake-sdk/bin/cache/flutter_tools.snapshot"
        self.flutter_tools.parent.mkdir(parents=True)
        shutil.copyfile(self.tool, self.flutter_command)
        # Fake Maven records the interop properties; it never executes this file.
        self.flutter_tools.write_bytes(b"fixture snapshot: not executable SDK code")

    def tearDown(self):
        self.assertEqual(self.directory.resolve().parent, (ROOT / ".local").resolve())
        shutil.rmtree(self.directory)

    def build(self, fail="", extra=(), fail_action="analyze", mutate_source=False):
        env = os.environ.copy()
        env.update(BUILD_TEST_CALLS=str(self.calls), BUILD_TEST_FAIL=fail,
                   BUILD_TEST_FAIL_ACTION=fail_action,
                   BUILD_TEST_MUTATE_SOURCE=str(mutate_source).lower())
        return subprocess.run([
            PWSH, "-NoProfile", "-File", str(ROOT / "scripts/build-deployment.ps1"),
            "-Directory", str(self.deployment), "-SourceDirectory", str(self.source),
            "-MavenCommand", str(self.directory / "maven.ps1"),
            "-FlutterCommand", str(self.flutter_command),
            "-DartCommand", str(self.directory / "dart.ps1"), *extra,
        ], cwd=ROOT, env=env, capture_output=True, text=True, encoding="utf-8", timeout=60)

    def read_calls(self):
        return [json.loads(line) for line in self.calls.read_text(encoding="utf-8-sig").splitlines()]

    def assert_failed_action_was_reached(self, calls, project, sdk, action):
        failures = [call for call in calls if call["failureInjected"]]
        self.assertEqual(len(failures), 1, "Requested compiler failure was never reached")
        failed = failures[0]
        self.assertEqual(failed["tool"], sdk)
        parts = tuple(project.split("/"))
        self.assertEqual(Path(failed["cwd"]).parts[-len(parts):], parts)
        self.assertEqual(failed["arguments"][0], action)
        self.assertEqual(calls[-1], failed, "Verification continued after a compiler failure")
        self.assertTrue(any(call["tool"] == "maven" for call in calls),
                        "Failure occurred before backend and SDK preflight completed")
        self.assertFalse(any(call["arguments"][0] == "build" for call in calls))

    def test_every_project_is_prepared_before_backend_and_verified_with_its_sdk(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.read_calls()
        backend_index = next(i for i, call in enumerate(calls) if call["tool"] == "maven")
        maven = calls[backend_index]["arguments"]
        snapshot = Path(maven[maven.index("-f") + 1]).parent.parent
        for project, sdk in PROJECTS.items():
            path = snapshot / project
            selected = [(i, call) for i, call in enumerate(calls) if Path(call["cwd"]) == path]
            self.assertTrue(selected, f"Project omitted: {project}")
            self.assertTrue(all(call["tool"] == sdk for _, call in selected), project)
            prepared = [i for i, call in selected if call["arguments"][:2] == ["pub", "get"]]
            self.assertTrue(prepared and max(prepared) < backend_index, f"Dependencies not ready for interop: {project}")
            self.assertTrue(any(call["arguments"][0] == "analyze" for _, call in selected), project)
            tested = any(call["arguments"][0] == "test" for _, call in selected)
            self.assertEqual(tested, project != "packages/device_cleanup", project)
        for prop, project in PROPERTIES.items():
            value = next((arg.split("=", 1)[1] for arg in maven if arg.startswith(f"-D{prop}=")), None)
            self.assertIsNotNone(value, f"Missing interoperability property: {prop}")
            self.assertEqual(Path(value), snapshot / project)
        self.assertIn(f"-Ddevice.flutter.command={self.flutter_command}", maven)
        self.assertIn(f"-Ddevice.dart.command={self.directory / 'dart.ps1'}", maven)
        for client in ("parent", "guardian"):
            self.assertIn(f"-D{client}.dart.command={self.directory / 'dart.ps1'}", maven)
            self.assertIn(f"-D{client}.flutter.tool={self.flutter_tools}", maven)
        manifest = json.loads((self.deployment / "release-manifest.json").read_text(encoding="utf-8-sig"))
        coverage = {project["path"]: project for project in manifest["verifiedProjects"]}
        self.assertEqual(set(coverage), set(PROJECTS))
        self.assertEqual(coverage["packages/device_cleanup"]["tests"], "not-present")
        self.assertEqual(coverage["apps/child"]["tests"], "passed")
        self.assertEqual(coverage["apps/parent"]["tests"], "passed")
        self.assertTrue(any(entry["path"] == "apps/parent/pubspec.yaml"
                            for entry in manifest["sourceFiles"]))
        release_calls = [call for call in calls if call["arguments"][0] == "build"]
        self.assertEqual(len(release_calls), 1, "Native app must not be built as Web")
        self.assertEqual(Path(release_calls[0]["cwd"]), snapshot / "apps/guardian")
        self.assertEqual(release_calls[0]["arguments"][:2], ["build", "web"])
        self.assertEqual(manifest["applicationVersion"], "1.0.0")
        self.assertEqual(manifest["provenanceVersion"], 1)
        self.assertEqual(manifest["source"], {
            "kind": "content-snapshot",
            "revision": "sha256:" + manifest["sourceTreeSha256"],
        }, "A frozen non-Git input must not inherit the enclosing repository HEAD")
        def tree_hash(rows):
            return hashlib.sha256("".join(
                f"{row['path']}\0{row['bytes']}\0{row['sha256']}\n"
                for row in sorted(rows, key=lambda row: row["path"])
            ).encode("utf-8")).hexdigest()
        for prefix in ("source", "artifact", "recipe"):
            self.assertEqual(tree_hash(manifest[prefix + "Files"]), manifest[prefix + "TreeSha256"])
        release = self.deployment / manifest["artifactRoot"]
        actual_artifacts = {
            path.relative_to(release).as_posix(): {
                "bytes": path.stat().st_size,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
            for path in release.rglob("*") if path.is_file() and path.name != "release-manifest.json"
        }
        self.assertEqual({row["path"]: {"bytes": row["bytes"], "sha256": row["sha256"]}
                          for row in manifest["artifactFiles"]}, actual_artifacts)
        self.assertIn("guardian/assets/app.json", actual_artifacts)
        self.assertEqual((release / "release-manifest.json").read_bytes(),
                         (self.deployment / "release-manifest.json").read_bytes())
        self.assertFalse(any("stale.marker" in entry["path"] for entry in manifest["sourceFiles"]))
        self.assertFalse((self.source / "backend/target").exists(), "Build polluted input source")

    def test_source_changed_during_build_cannot_replace_verified_release(self):
        previous = b'{"previous":"verified release"}'
        manifest = self.deployment / "release-manifest.json"
        manifest.write_bytes(previous)
        result = self.build(mutate_source=True)
        self.assertNotEqual(result.returncode, 0, "Mutated verification inputs were published")
        self.assertIn("changed", result.stderr.lower())
        self.assertEqual(manifest.read_bytes(), previous)
        self.assertEqual((self.deployment / ".env").read_text(), self.old_env)

    def test_missing_child_fails_before_any_compiler_runs(self):
        (self.source / "apps/child/pubspec.yaml").unlink()
        result = self.build()
        self.assertNotEqual(result.returncode, 0, "Incomplete release source was accepted")
        self.assertFalse(self.calls.exists(), "Incomplete source invoked compilers")

    def test_missing_parent_fails_before_any_compiler_runs(self):
        (self.source / "apps/parent/pubspec.yaml").unlink()
        result = self.build()
        self.assertNotEqual(result.returncode, 0, "Parent source silently omitted")
        self.assertFalse(self.calls.exists(), "Incomplete source invoked compilers")
        self.assertEqual((self.deployment / ".env").read_text(), self.old_env)

    def test_parent_manifest_directory_fails_before_any_compiler_runs(self):
        pubspec = self.source / "apps/parent/pubspec.yaml"
        pubspec.unlink()
        pubspec.mkdir()
        manifest = self.deployment / "release-manifest.json"
        manifest.write_text('{"previous":"release"}', encoding="utf-8")
        result = self.build()
        self.assertNotEqual(result.returncode, 0, "Directory accepted as required manifest")
        self.assertFalse(self.calls.exists(), "Invalid source invoked compilers")
        self.assertEqual(manifest.read_text(), '{"previous":"release"}')
        self.assertEqual((self.deployment / ".env").read_text(), self.old_env)

    def test_missing_flutter_tools_snapshot_rejects_backend_and_preserves_release(self):
        manifest = self.deployment / "release-manifest.json"
        manifest.write_text('{"previous":"release"}', encoding="utf-8")
        previous_manifest = manifest.read_bytes()
        previous_environment = (self.deployment / ".env").read_bytes()
        self.flutter_tools.unlink()
        result = self.build()
        self.assertNotEqual(result.returncode, 0, "Missing Flutter tools snapshot was accepted")
        self.assertIn("Parent and guardian HTTP interoperability require the installed Flutter tools snapshot.",
                      result.stderr)
        calls = self.read_calls()
        self.assertEqual(len(calls), len(PROJECTS), "SDK check did not follow dependency preparation")
        self.assertTrue(all(call["arguments"][:2] == ["pub", "get"] for call in calls))
        self.assertFalse(any(call["tool"] == "maven" for call in calls),
                         "Missing tools snapshot invoked backend compilation")
        self.assertFalse(any(call["arguments"][0] in ("analyze", "test", "build") for call in calls))
        self.assertFalse(list(self.deployment.glob("source-*/backend/target/manager-backend.jar")))
        self.assertFalse((self.deployment / "artifacts").exists(), "Unverified release artifacts were published")
        self.assertEqual(manifest.read_bytes(), previous_manifest)
        self.assertEqual((self.deployment / ".env").read_bytes(), previous_environment)

    def test_parent_analysis_failure_keeps_previous_release_selected(self):
        self.assert_parent_failure_preserves_release("analyze")

    def test_parent_test_failure_keeps_previous_release_selected(self):
        self.assert_parent_failure_preserves_release("test")

    def assert_parent_failure_preserves_release(self, action):
        manifest = self.deployment / "release-manifest.json"
        manifest.write_text('{"previous":"release"}', encoding="utf-8")
        result = self.build(fail="apps/parent", fail_action=action)
        self.assertNotEqual(result.returncode, 0, f"Parent {action} failure was ignored")
        self.assertEqual(manifest.read_text(), '{"previous":"release"}')
        self.assertEqual((self.deployment / ".env").read_text(), self.old_env)
        calls = self.read_calls()
        self.assert_failed_action_was_reached(calls, "apps/parent", "flutter", action)
        self.assertFalse(any(call["arguments"][0] == "build" for call in calls))

    def test_parent_without_tests_is_recorded_without_native_release_claim(self):
        (self.source / "apps/parent/test/example_test.dart").unlink()
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.deployment / "release-manifest.json").read_text(encoding="utf-8-sig"))
        coverage = {project["path"]: project for project in manifest["verifiedProjects"]}
        self.assertIn("apps/parent", coverage)
        self.assertEqual(coverage["apps/parent"]["tests"], "not-present")
        self.assertNotIn("parentSha256", manifest)

    def test_client_analysis_failure_keeps_previous_release_selected(self):
        manifest = self.deployment / "release-manifest.json"
        manifest.write_text('{"previous":"release"}', encoding="utf-8")
        result = self.build(fail="packages/device_access")
        self.assertNotEqual(result.returncode, 0, "Failed client analysis was ignored")
        self.assertEqual(manifest.read_text(), '{"previous":"release"}')
        self.assertEqual((self.deployment / ".env").read_text(), self.old_env)
        calls = self.read_calls()
        self.assert_failed_action_was_reached(calls, "packages/device_access", "dart", "analyze")
        self.assertFalse(any(call["arguments"][0] == "build" for call in calls))

    def test_offline_applies_to_dependency_resolution_and_maven(self):
        result = self.build(extra=("-Offline",))
        self.assertEqual(result.returncode, 0, result.stderr)
        for call in self.read_calls():
            if call["tool"] == "maven":
                self.assertIn("-o", call["arguments"])
            elif call["arguments"][:2] == ["pub", "get"]:
                self.assertIn("--offline", call["arguments"])
            elif call["tool"] == "flutter" and call["arguments"][0] in ("analyze", "test", "build"):
                self.assertIn("--no-pub", call["arguments"], "Flutter must not implicitly resolve dependencies online")


if __name__ == "__main__":
    unittest.main()
