"""Exercise plans, guards and controlled command inventories; no SDK or deployment."""
import base64
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

DOCTOR_WRAPPER = r'''
$ErrorActionPreference = 'Stop'
$fixture = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
$global:doctorLookups = [Collections.Generic.List[object]]::new()
function global:docker { throw 'Diagnostic discovery must not invoke Docker.' }
function global:git { throw 'Diagnostic discovery must not invoke Git.' }
function global:java { throw 'Diagnostic discovery must not invoke Java.' }
function global:mvn { throw 'Diagnostic discovery must not invoke Maven.' }
function global:flutter { throw 'Diagnostic discovery must not invoke Flutter.' }
function global:dart { throw 'Diagnostic discovery must not invoke Dart.' }
function global:configured-flutter { throw 'Diagnostic discovery must not invoke configured tools.' }
function global:Get-Command {
    param([string]$Name, [object]$CommandType, [string]$ErrorAction)
    $global:doctorLookups.Add(@{name=$Name; externalScriptAllowed=
        (([Management.Automation.CommandTypes]$CommandType -band [Management.Automation.CommandTypes]::ExternalScript) -ne 0)})
    $pattern = [Management.Automation.WildcardPattern]::new($Name,
        [Management.Automation.WildcardOptions]::IgnoreCase)
    foreach ($availableCommand in $fixture.available) {
        if ($pattern.IsMatch([string]$availableCommand)) {
            [pscustomobject]@{Source=[string]$availableCommand}
        }
    }
}
$parameters = @{}
foreach ($property in $fixture.parameters.PSObject.Properties) { $parameters[$property.Name]=$property.Value }
$raw = @(& $fixture.entry doctor @parameters)
[ordered]@{inventory=(($raw -join "`n") | ConvertFrom-Json); lookups=@($global:doctorLookups.ToArray())} |
    ConvertTo-Json -Depth 10 -Compress
'''


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

    def doctor_with_command_inventory(self, parameters, available):
        payload = base64.b64encode(json.dumps({
            "entry": str(ENTRY), "parameters": parameters, "available": available,
        }).encode("utf-8")).decode("ascii")
        script = DOCTOR_WRAPPER.replace("__PAYLOAD__", payload)
        encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        result = subprocess.run([PWSH, "-NoLogo", "-NoProfile", "-EncodedCommand", encoded],
                                cwd=ROOT, capture_output=True, text=True,
                                encoding="utf-8", timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_doctor_runtime_does_not_require_source_build_commands(self):
        runtime = self.doctor_with_command_inventory({"Toolset": "Runtime"}, ["docker"])
        self.assertEqual(runtime["inventory"]["toolset"], "Runtime")
        self.assertEqual(runtime["inventory"]["missingTools"], [])
        self.assertEqual([item["name"] for item in runtime["lookups"]], ["docker"])
        self.assertIn("status -Active -Plan", runtime["inventory"]["next"])
        self.assertNotIn("Resolve missing commands", runtime["inventory"]["next"])
        runtime_missing = self.doctor_with_command_inventory({"Toolset": "Runtime"}, [])
        self.assertEqual(runtime_missing["inventory"]["missingTools"], ["docker"])
        self.assertEqual([item["name"] for item in runtime_missing["lookups"]], ["docker"])
        runtime_next = runtime_missing["inventory"]["next"]
        self.assertIn("Resolve missing commands", runtime_next)
        self.assertIn("docker", runtime_next)
        self.assertIn("doctor", runtime_next)
        self.assertNotIn("init -Plan", runtime_next)
        self.assertNotIn("-MavenCommand", runtime_next)
        build = self.doctor_with_command_inventory({}, ["docker"])
        self.assertEqual(build["inventory"]["toolset"], "Build")
        self.assertEqual(build["inventory"]["missingTools"], ["git", "java", "mvn", "flutter"])
        self.assertEqual([item["name"] for item in build["lookups"]],
                         ["docker", "git", "java", "mvn", "flutter"])
        build_next = build["inventory"]["next"]
        self.assertIn("Resolve missing commands", build_next)
        for name in ["git", "java", "mvn", "flutter", "-MavenCommand", "-FlutterCommand", "doctor"]:
            self.assertIn(name, build_next)
        self.assertNotIn("-DartCommand", build_next)
        self.assertNotIn("init -Plan", build_next)
        self.assertIn("not verified", runtime["inventory"]["scope"])

    def test_doctor_checks_explicit_build_tools_as_file_commands_without_invocation(self):
        absent = Path(".cache") / ("doctor absent tools-" + uuid.uuid4().hex)
        self.assertFalse((ROOT / absent).exists())
        maven = str(ROOT / absent / "mvn.ps1")
        dart = str(ROOT / absent / "dart.ps1")
        result = self.doctor_with_command_inventory({
            "Toolset": "Build", "MavenCommand": str(absent / "mvn.ps1"),
            "FlutterCommand": "configured-flutter", "DartCommand": str(absent / "dart.ps1"),
        }, ["docker", "git", "java", maven, "configured-flutter", dart])
        inventory = result["inventory"]
        self.assertEqual(inventory["missingTools"], [])
        self.assertEqual({item["tool"]: item["command"] for item in inventory["tools"]}, {
            "docker": "docker", "git": "git", "java": "java", "mvn": maven,
            "flutter": "configured-flutter", "dart": dart,
        })
        self.assertEqual([item["name"] for item in result["lookups"]
                          if item["externalScriptAllowed"]], [maven, "configured-flutter", dart])
        self.assertIn("init -Plan", inventory["next"])
        missing = self.doctor_with_command_inventory({
            "Toolset": "Build", "MavenCommand": str(absent / "mvn.ps1"),
            "FlutterCommand": "configured-flutter", "DartCommand": str(absent / "dart.ps1"),
        }, ["docker", "git", "java"])
        self.assertEqual(missing["inventory"]["missingTools"], ["mvn", "flutter", "dart"])
        next_step = missing["inventory"]["next"]
        self.assertIn("Resolve missing commands", next_step)
        for name in ["mvn", "flutter", "dart", "-MavenCommand", "-FlutterCommand", "-DartCommand", "doctor"]:
            self.assertIn(name, next_step)
        for private_command in [maven, dart, str(absent), "configured-flutter"]:
            self.assertNotIn(private_command, next_step)
        self.assertNotIn("init -Plan", next_step)

    def test_doctor_treats_special_paths_and_wildcard_command_names_literally(self):
        absent = Path(".cache") / ("doctor private [stable] tools-" + uuid.uuid4().hex)
        self.assertFalse((ROOT / absent).exists())
        commands = {
            "mvn": str(ROOT / absent / "maven bin" / "mvn.ps1"),
            "flutter": str(ROOT / absent / "flutter bin" / "flutter.ps1"),
            "dart": str(ROOT / absent / "dart bin" / "dart.ps1"),
        }
        parameters = {
            "MavenCommand": commands["mvn"],
            "FlutterCommand": commands["flutter"],
            "DartCommand": commands["dart"],
        }
        defaults = ["docker", "git", "java"]
        for available, expected_missing in [
            (list(commands.values()), []),
            ([], ["mvn", "flutter", "dart"]),
        ]:
            with self.subTest(explicit_paths_available=bool(available)):
                result = self.doctor_with_command_inventory(
                    parameters, defaults + available,
                )
                inventory = result["inventory"]
                self.assertEqual(inventory["missingTools"], expected_missing)
                tools = {item["tool"]: item for item in inventory["tools"]}
                for tool, command in commands.items():
                    self.assertEqual(tools[tool]["command"], command)
                    self.assertEqual(
                        tools[tool]["available"], tool not in expected_missing,
                    )
                    self.assertNotIn(command, inventory["next"])
                self.assertNotIn("doctor private", inventory["next"])
                if expected_missing:
                    self.assertIn("Resolve missing commands", inventory["next"])
                    self.assertNotIn("init -Plan", inventory["next"])
        for available_command, expected_missing in [
            ("configured-flutter", ["flutter"]),
            ("configured-*", []),
        ]:
            with self.subTest(available_command=available_command):
                result = self.doctor_with_command_inventory(
                    {"FlutterCommand": "configured-*"},
                    [*defaults, "mvn", available_command],
                )
                inventory = result["inventory"]
                self.assertEqual(inventory["missingTools"], expected_missing)
                flutter = next(
                    item for item in inventory["tools"] if item["tool"] == "flutter"
                )
                self.assertEqual(flutter["command"], "configured-*")
                self.assertEqual(flutter["available"], not expected_missing)
                self.assertNotIn("configured-", inventory["next"])
                if expected_missing:
                    self.assertIn("Resolve missing commands", inventory["next"])

    def test_each_action_has_the_expected_entry_and_forwarded_parameters(self):
        source = str(ROOT / "input source")
        rows = [
            ("doctor", "manager.ps1", [], {"Toolset": "Build"}),
            ("doctor", "manager.ps1", ["-Toolset", "Runtime"], {"Toolset": "Runtime"}),
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
            ("resume", "start-deployment.ps1", [], {"ResumeExisting": True}),
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
            (["-PublicUrl", "https://localhost:18443"], "https://localhost:18443", 18443),
            (["-PublicUrl", "https://manager.example.com:8443"], "https://manager.example.com:8443", 8443),
            (["-PublicUrl", "https://manager.example.com"], "https://manager.example.com", 443),
            (["-PublicUrl", "http://localhost:18123", "-EdgePort", "18123"], "http://localhost:18123", 18123),
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
            (["build", "-Toolset", "Runtime"], "does not apply"),
            (["build", "-PublicUrl", "https://operator:synthetic-private@manager.example.com"], "does not apply"),
            (["doctor", "-Toolset", "Runtime", "-MavenCommand", "synthetic-private-mvn"], "requires doctor -Toolset Build"),
            (["resume", "-Offline"], "does not apply"),
            (["init-ledger", "-Offline"], "does not apply"),
            (["status", "-Directory", "../outside-manager"], "Deployment directory"),
            (["init", "-PublicUrl", "http://localhost:18123", "-EdgePort", "18124"], "loopback origin"),
            (["init", "-PublicUrl", "https://manager.example.com:8443", "-EdgePort", "18124"], "port must match EdgePort"),
            (["init", "-PublicUrl", "http://manager.example.com:18090"], "HTTP is limited"),
            (["init", "-PublicUrl", "http://localhost:18090", "-ExternalTlsProxy"], "requires a standard HTTPS public origin"),
            (["init", "-PublicUrl", "https://manager.example.com:8443", "-ExternalTlsProxy"], "requires a standard HTTPS public origin"),
            (["init", "-PublicUrl", "https://operator:synthetic-private@manager.example.com"], "without credentials"),
            (["init", "-PublicUrl", "https://operator:synthetic-private@manager.example.com:invalid"], "without credentials"),
            (["init", "-PublicUrl", "https://manager.example.com/private?token=synthetic-private"], "without credentials"),
            (["init", "-PublicUrl", "https://manager.example.com/#synthetic-private"], "without credentials"),
            (["init", "-PublicUrl", "https://bad_host.synthetic-private"], "without credentials"),
        ]
        for arguments, message in rows:
            with self.subTest(arguments=arguments):
                result = self.invoke(*arguments, "-Plan")
                self.assertNotEqual(result.returncode, 0)
                output = result.stdout + result.stderr
                self.assertIn(message, output)
                self.assertNotIn("synthetic-private", output)
                if message == "does not apply":
                    self.assertIn("Allowed parameters for '" + arguments[0] + "'", output)
                    self.assertIn("-Help", output)
                    expected_options = {
                        "build": ["-SourceDirectory", "-MavenCommand", "-Offline"],
                        "resume": ["-Directory", "-Tls"],
                        "init-ledger": ["-Directory"],
                    }
                    for option in expected_options[arguments[0]]:
                        self.assertIn(option, output)

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
