"""Resolve SDK entry links and exercise the real build with existing fake tools.

Only public recipe files and generated fixtures enter this task's .cache tree.
No installed SDK, Docker, credentials, package installation or network is used.
"""
import errno
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PWSH = os.environ.get("PWSH") or shutil.which("pwsh")
FUNCTION = "Resolve-DeploymentFlutterInstallation"
WRAPPER = r'''
param([string]$Script, [string]$Command)
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Build script contains syntax errors.' }
$functions = @($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Resolve-DeploymentFlutterInstallation'
}, $false))
if ($functions.Count -ne 1) { throw 'Expected one production Flutter resolver.' }
. ([ScriptBlock]::Create($functions[0].Extent.Text))
Resolve-DeploymentFlutterInstallation -Command $Command | ConvertTo-Json -Compress
'''


@unittest.skipUnless(PWSH, "Set PWSH to PowerShell 7 or put pwsh on PATH")
class FlutterResolutionTest(unittest.TestCase):
    def setUp(self):
        (ROOT / ".cache").mkdir(exist_ok=True)
        self.scratch = Path(tempfile.mkdtemp(prefix="build-flutter-resolution-", dir=ROOT / ".cache"))
        self.links = []
        self.addCleanup(self.cleanup)
        self.wrapper = self.scratch / "resolve.ps1"
        self.wrapper.write_text(WRAPPER, encoding="utf-8")
        self.flutter = self.scratch / "real sdk/bin/flutter.ps1"
        self.flutter.parent.mkdir(parents=True)
        self.flutter.write_text("throw 'A resolver must not execute the tool.'\n", encoding="utf-8")
        self.snapshot = self.flutter.parent / "cache/flutter_tools.snapshot"
        self.snapshot.parent.mkdir()
        self.snapshot.write_bytes(b"fixture, never executable")

    def cleanup(self):
        root = self.scratch.resolve()
        self.assertEqual(root, self.scratch.absolute())
        self.assertEqual(root.parent, (ROOT / ".cache").resolve())
        # Every link is a file link created by this test. Unlink without resolving
        # its target; cycles and missing targets are intentional test inputs.
        for link in reversed(self.links):
            self.assertTrue(link.absolute().is_relative_to(root))
            if link.is_symlink():
                link.unlink()
        shutil.rmtree(root)

    def link(self, path, target):
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            path.symlink_to(target, target_is_directory=False)
        except OSError as error:
            if os.name == "nt" and (getattr(error, "winerror", None) == 1314 or
                                     error.errno in (errno.EACCES, errno.EPERM)):
                self.skipTest("Windows did not grant file-symlink creation; real link case not verified")
            raise
        self.links.append(path)
        return path

    def resolve(self, command):
        return subprocess.run([PWSH, "-NoLogo", "-NoProfile", "-File", str(self.wrapper),
                               "-Script", str(ROOT / "scripts/build-deployment.ps1"),
                               "-Command", str(command)], cwd=ROOT,
                              capture_output=True, text=True, encoding="utf-8", timeout=15)

    def assert_location(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        location = json.loads(result.stdout)
        self.assertEqual(Path(location["FlutterPath"]), self.flutter)
        self.assertEqual(Path(location["FlutterTool"]), self.snapshot)
        self.assertEqual(Path(location["DefaultDartCommand"]),
                         self.flutter.parent / ("dart.bat" if os.name == "nt" else "dart"))

    def test_regular_sdk_path_preserves_its_bin_and_default_dart(self):
        self.assert_location(self.resolve(self.flutter))

    def test_relative_multi_hop_links_resolve_the_same_sdk(self):
        second = self.link(self.scratch / "second/flutter.ps1",
                           os.path.relpath(self.flutter, self.scratch / "second"))
        first = self.link(self.scratch / "first/flutter.ps1",
                          os.path.relpath(second, self.scratch / "first"))
        self.assert_location(self.resolve(first))

    def test_cyclic_links_are_rejected_within_the_bound(self):
        first = self.scratch / "cycle/first.ps1"
        second = self.scratch / "cycle/second.ps1"
        self.link(first, "second.ps1")
        self.link(second, "first.ps1")
        result = self.resolve(first)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cycle", result.stderr.lower())

    def test_dangling_links_are_rejected(self):
        link = self.link(self.scratch / "missing/flutter.ps1", "missing-target.ps1")
        result = self.resolve(link)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("existing file", result.stderr.lower())

    def test_overlong_link_chain_is_rejected(self):
        target = self.flutter
        for index in range(17):
            target = self.link(self.scratch / f"chain-{index}/flutter.ps1", target)
            if index == 15:
                self.assert_location(self.resolve(target))
        result = self.resolve(target)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("16", result.stderr)

    def _build_fixture(self):
        # Reuse the existing minimal build fixture without inheriting/rerunning
        # its other tests, and relocate all its generated .local data into .cache.
        repository = self.scratch / "repository"
        recipe_source = (ROOT / "scripts/deployment-provenance.ps1").read_text(encoding="utf-8-sig")
        declaration = re.search(r"\$script:DeploymentRecipeRelativePaths\s*=\s*@\((.*?)\)",
                                recipe_source, re.DOTALL)
        self.assertIsNotNone(declaration)
        recipes = re.findall(r"'([^']+)'", declaration.group(1))
        self.assertTrue(recipes)
        for relative in recipes:
            self.assertFalse(Path(relative).is_absolute())
            self.assertNotIn("..", Path(relative).parts)
            destination = repository / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        spec = importlib.util.spec_from_file_location("_flutter_build_fixture",
                                                     ROOT / "scripts/tests/test_deployment_build.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.ROOT = repository
        module.PWSH = PWSH
        fixture = module.DeploymentBuildTest(methodName="runTest")
        fixture.setUp()
        return fixture

    def test_linked_build_uses_resolved_flutter_for_sdk_and_all_calls(self):
        fixture = self._build_fixture()
        actual = fixture.flutter_command
        source = actual.read_text(encoding="utf-8")
        actual.write_text(source.replace("@{tool=$toolName;", "@{commandPath=$MyInvocation.MyCommand.Path; tool=$toolName;"),
                          encoding="utf-8")
        alias = self.link(fixture.directory / "alias/bin/flutter.ps1", actual)
        fixture.flutter_command = alias
        result = fixture.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = fixture.read_calls()
        arguments = next(call["arguments"] for call in calls if call["tool"] == "maven")
        self.assertIn(f"-Ddevice.flutter.command={actual}", arguments)
        for client in ("parent", "guardian"):
            self.assertIn(f"-D{client}.flutter.tool={fixture.flutter_tools}", arguments)
        flutter_calls = [call for call in calls if call["tool"] == "flutter"]
        self.assertTrue(flutter_calls)
        self.assertTrue(all(Path(call["commandPath"]) == actual for call in flutter_calls),
                        "Build must invoke the same resolved Flutter used to derive SDK paths")

    def test_missing_snapshot_keeps_preparation_order_and_preserves_old_release(self):
        fixture = self._build_fixture()
        fixture.test_missing_flutter_tools_snapshot_rejects_backend_and_preserves_release()


if __name__ == "__main__":
    unittest.main()
