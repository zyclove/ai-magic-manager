"""Exercise only the new entry's plans and input guards; no SDK or deployment."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / "scripts/manager.ps1"
PWSH = os.environ.get("PWSH") or shutil.which("pwsh")


@unittest.skipUnless(PWSH, "Set PWSH to PowerShell 7 or put pwsh on PATH")
class ManagerEntryTest(unittest.TestCase):
    def invoke(self, *arguments, cwd=ROOT):
        environment = os.environ.copy()
        environment["NO_COLOR"] = "1"
        return subprocess.run(
            [PWSH, "-NoLogo", "-NoProfile", "-File", str(ENTRY), *arguments],
            cwd=cwd, env=environment, capture_output=True, text=True,
            encoding="utf-8", timeout=20,
        )

    def plan(self, action, *arguments, cwd=ROOT, flag="-Plan"):
        result = self.invoke(action, *arguments, flag, cwd=cwd)
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(result.stdout)
        self.assertEqual(document["mode"], "PLAN_ONLY")
        self.assertEqual(document["action"], action)
        return document

    def test_each_action_has_the_expected_entry_and_forwarded_parameters(self):
        source = str(ROOT / "input source")
        rows = [
            ("doctor", "manager.ps1", [], {}),
            ("init", "initialize-deployment.ps1", [], {
                "PublicUrl": "http://localhost:18090", "EdgePort": 18090,
                "ProjectName": "ai-manager-repro",
            }),
            ("init", "initialize-deployment.ps1", [
                "-PublicUrl", "https://manager.example.com", "-EdgePort", "18120",
                "-ProjectName", "manager-demo", "-ExternalTlsProxy", "-ConsumerIdentity",
            ], {"PublicUrl": "https://manager.example.com", "EdgePort": 18120,
                "ProjectName": "manager-demo", "ExternalTlsProxy": True, "ConsumerIdentity": True}),
            ("build", "build-deployment.ps1", [
                "-SourceDirectory", source, "-MavenCommand", "custom-mvn",
                "-FlutterCommand", "custom-flutter", "-DartCommand", "custom-dart",
                "-MavenRepository", "repository cache", "-ConsumerIdentity", "-Offline",
            ], {"SourceDirectory": source, "MavenCommand": "custom-mvn",
                "FlutterCommand": "custom-flutter", "DartCommand": "custom-dart",
                "MavenRepository": str(ROOT / "repository cache"), "ConsumerIdentity": True, "Offline": True}),
            ("init-ledger", "initialize-erasure-ledger.ps1", [], {}),
            ("start", "start-deployment.ps1", [
                "-Tls", "-IdentityAdminDirectory", ".local/identity admin",
                "-IdentityRuntimeDirectory", ".local/identity runtime",
            ], {"Tls": True, "IdentityAdminDirectory": str(ROOT / ".local/identity admin"),
                "IdentityRuntimeDirectory": str(ROOT / ".local/identity runtime")}),
            ("start", "start-deployment.ps1", ["-ExternalTlsProxy"], {"ExternalTlsProxy": True}),
            ("status", "manager.ps1", [], {}),
            ("verify", "verify-deployment.ps1", [], {}),
        ]
        for action, script, arguments, expected in rows:
            with self.subTest(action=action, arguments=arguments):
                document = self.plan(action, *arguments)
                self.assertEqual(document["entry"], "scripts/" + script)
                for name, value in expected.items():
                    self.assertEqual(document["parameters"][name], value)
                if action != "doctor":
                    self.assertEqual(Path(document["parameters"]["Directory"]), ROOT / ".local/deployment")

    def test_relative_workspace_does_not_change_with_callers_working_directory(self):
        document = self.plan("status", "-Directory", ".local/manager plan", cwd=ROOT / "scripts/tests")
        self.assertEqual(Path(document["parameters"]["Directory"]), ROOT / ".local/manager plan")

    def test_explicit_file_options_use_the_repository_base_from_every_working_directory(self):
        cases = [
            ("build", {
                "SourceDirectory": "input source/../source snapshot",
                "MavenRepository": ".cache/maven plan",
                "MavenCommand": "tools/maven bin/mvn",
                "FlutterCommand": "tools/flutter bin/flutter",
                "DartCommand": "tools/dart bin/dart",
            }),
            ("start", {
                "IdentityAdminDirectory": ".local/identity admin",
                "IdentityRuntimeDirectory": ".local/identity runtime",
            }),
        ]
        for cwd in [ROOT, ROOT / "scripts/tests"]:
            for action, options in cases:
                with self.subTest(cwd=cwd, action=action):
                    arguments = [part for key, value in options.items()
                                 for part in ("-" + key, value)]
                    result = self.plan(action, *arguments, cwd=cwd)
                    for key, value in options.items():
                        self.assertEqual(Path(result["parameters"][key]),
                                         Path(os.path.abspath(ROOT / value)))

    def test_initialization_resolves_one_public_entry_without_repeating_its_port(self):
        rows = [
            ([], "http://localhost:18090", 18090),
            (["-EdgePort", "18120"], "http://localhost:18120", 18120),
            (["-PublicUrl", "http://127.0.0.1:18121"], "http://127.0.0.1:18121", 18121),
            (["-PublicUrl", "https://manager.example.com:8443"], "https://manager.example.com:8443", 8443),
            (["-PublicUrl", "https://manager.example.com"], "https://manager.example.com", 443),
            (["-PublicUrl", "http://localhost:18123", "-EdgePort", "18123"], "http://localhost:18123", 18123),
            (["-PublicUrl", "http://localhost:18123", "-EdgePort", "18124"], "http://localhost:18123", 18124),
            (["-PublicUrl", "https://manager.example.com:8443", "-ExternalTlsProxy:$false"], "https://manager.example.com:8443", 8443),
            (["-PublicUrl", "https://manager.example.com", "-ExternalTlsProxy"], "https://manager.example.com", 18090),
            (["-PublicUrl", "https://manager.example.com", "-ExternalTlsProxy", "-EdgePort", "18124"], "https://manager.example.com", 18124),
        ]
        for arguments, public_url, edge_port in rows:
            with self.subTest(arguments=arguments):
                document = self.plan("init", *arguments)
                self.assertEqual(document["parameters"]["PublicUrl"], public_url)
                self.assertEqual(document["parameters"]["EdgePort"], edge_port)
        result = self.invoke("init", "-PublicUrl", "http://localhost:0", "-Plan")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("port must be between 1 and 65535", result.stdout + result.stderr)

    def test_active_status_plans_without_resolving_and_rejects_ambiguous_targets(self):
        document = self.plan("status", "-Active")
        self.assertEqual(document["selection"], "ACTIVE_CONSOLE")
        self.assertTrue(document["parameters"]["Active"])
        self.assertNotIn("Directory", document["parameters"])
        for arguments, message in [
            (["status", "-Active", "-Directory", ".local/not-selected"],
             "cannot be combined"),
            (["start", "-Active"], "does not apply"),
        ]:
            with self.subTest(arguments=arguments):
                result = self.invoke(*arguments, "-Plan")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout + result.stderr)

    def test_invalid_options_fail_before_any_action(self):
        rows = [
            (["build", "-Tls"], "does not apply"),
            (["init-ledger", "-Offline"], "does not apply"),
            (["status", "-Directory", "../outside-manager"], "Deployment directory"),
            (["init", "-PublicUrl", "https://operator:synthetic-private@manager.example.com"], "without credentials"),
            (["init", "-PublicUrl", "https://manager.example.com/private?token=synthetic-private"], "without credentials"),
        ]
        for arguments, message in rows:
            with self.subTest(arguments=arguments):
                result = self.invoke(*arguments, "-Plan")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout + result.stderr)
                self.assertNotIn("synthetic-private", result.stdout + result.stderr)

    def test_dry_run_never_creates_a_workspace_or_requires_native_tools(self):
        relative = ".local/manager-plan-" + uuid.uuid4().hex
        workspace = ROOT / relative
        self.assertFalse(workspace.exists())
        self.plan("init", "-Directory", relative, flag="-DryRun")
        self.plan("build", "-Directory", relative, "-SourceDirectory", "missing-source",
                  "-MavenCommand", "nonexistent-manager-mvn", "-FlutterCommand", "nonexistent-manager-flutter",
                  "-DartCommand", "nonexistent-manager-dart", flag="-DryRun")
        self.plan("init-ledger", "-Directory", relative, flag="-DryRun")
        self.assertFalse(workspace.exists(), "A plan must not initialize or change a deployment")

    def test_posix_launcher_has_unix_line_endings(self):
        self.assertNotIn(b"\r", (ROOT / "scripts/manager.sh").read_bytes())


if __name__ == "__main__":
    unittest.main()
