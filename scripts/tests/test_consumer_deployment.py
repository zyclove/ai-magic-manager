"""Consumer deployment orchestration checks; never start services or contact providers."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
PWSH = shutil.which("pwsh")


class ConsumerDeploymentTest(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / ".local" / ("consumer-deployment-test-" + uuid.uuid4().hex)
        self.source = self.directory / "fixture-source"

    def tearDown(self):
        if self.directory.exists():
            self.assertEqual(self.directory.parent.resolve(), (ROOT / ".local").resolve())
            shutil.rmtree(self.directory)

    def command(self, script, *arguments):
        return subprocess.run([PWSH, "-NoProfile", "-File", str(ROOT / "scripts" / script),
                               "-Directory", str(self.directory), *arguments], cwd=ROOT,
                              capture_output=True, text=True, encoding="utf-8", timeout=90)

    def initialize(self, consumer=False):
        result = self.command("initialize-deployment.ps1", *( ["-ConsumerIdentity"] if consumer else []))
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((self.directory / "deployment.json").read_text(encoding="utf-8-sig"))

    def tools(self, fail_identity=False):
        # Compiler doubles exercise path/atomic publication behavior; the SPI itself is compiled separately.
        paths = ["backend", "apps/guardian", "apps/parent", "apps/child"]
        paths += ["packages/" + name for name in ("device_policy", "device_identity", "device_access",
                  "device_observation", "device_reports", "device_operations")]
        for path in paths:
            project = self.source / path
            project.mkdir(parents=True)
            if path == "backend":
                (project / "pom.xml").write_text("<project/>")
            else:
                (project / "pubspec.yaml").write_text("name: fixture\nenvironment:\n  sdk: '>=3.4.0 <4.0.0'\n")
        shutil.copytree(ROOT / "deploy/keycloak", self.source / "deploy/keycloak")
        shutil.copytree(ROOT / "deploy/containers", self.source / "deploy/containers")
        shutil.copytree(ROOT / "identity-extensions", self.source / "identity-extensions", ignore=shutil.ignore_patterns("target", ".local"))
        sdk = self.directory / "fixture-sdk"
        binary = sdk / "bin"
        (binary / "cache").mkdir(parents=True)
        (binary / "cache/flutter_tools.snapshot").write_bytes(b"test tool marker")
        maven = binary / "maven.ps1"
        failure = "if($identity){exit 7}" if fail_identity else ""
        maven.write_text("""$pom=$args[[Array]::IndexOf($args,'-f')+1]
$project=Split-Path $pom -Parent
$identity=(Split-Path $project -Leaf) -eq 'identity-extensions'
""" + failure + """
$null=New-Item -ItemType Directory -Path (Join-Path $project 'target') -Force
$name=if($identity){'consumer-identity-1.0.0.jar'}else{'manager-backend.jar'}
[IO.File]::WriteAllBytes((Join-Path $project "target/$name"),[Text.Encoding]::UTF8.GetBytes('verified compiler fixture'))
exit 0
""", encoding="utf-8")
        flutter = binary / "flutter.ps1"
        flutter.write_text("""if($args[0] -eq 'build'){
$null=New-Item -ItemType Directory -Path 'build/web' -Force
[IO.File]::WriteAllText((Join-Path (Get-Location) 'build/web/index.html'),'fixture')
[IO.File]::WriteAllText((Join-Path (Get-Location) 'build/web/main.dart.js'),'fixture')
}
exit 0
""", encoding="utf-8")
        dart = binary / "dart.ps1"
        dart.write_text("exit 0\n", encoding="utf-8")
        return ["-SourceDirectory", str(self.source), "-MavenCommand", str(maven),
                "-FlutterCommand", str(flutter), "-DartCommand", str(dart), "-Offline"]

    def build(self, consumer=False, fail_identity=False):
        arguments = self.tools(fail_identity)
        if consumer:
            arguments.append("-ConsumerIdentity")
        return self.command("build-deployment.ps1", *arguments)

    def test_consumer_initialization_creates_offline_realm_and_disabled_file_backed_services(self):
        settings = self.initialize(True)
        self.assertIs(settings["consumerIdentity"], True)
        realm = json.loads((self.directory / "realm.json").read_text(encoding="utf-8-sig"))
        original = json.loads((ROOT / "deploy/keycloak/realm-template.json").read_text(encoding="utf-8-sig"))
        clients = {x["clientId"]: x for x in realm["clients"]}
        management = next(x for x in original["clients"] if x["clientId"] == "ai-manager-guardian")
        self.assertEqual(clients["ai-manager-guardian"].get("authenticationFlowBindingOverrides"),
                         management.get("authenticationFlowBindingOverrides"))
        self.assertEqual(realm["browserFlow"], original["browserFlow"])
        flow = next(x for x in realm["authenticationFlows"] if x["alias"] == "consumer-phone-browser")
        self.assertEqual(clients["ai-manager-parent"]["authenticationFlowBindingOverrides"]["browser"], flow["id"])
        profile_component = realm["components"]["org.keycloak.userprofile.UserProfileProvider"][0]
        profile = json.loads(profile_component["config"]["kc.user.profile.config"][0])
        attributes = {item["name"]: item for item in profile["attributes"]}
        for name in ("consumer_phone_number", "consumer_phone_verified", "consumer_identity_revision",
                     "consumer_last_operation_id", "consumer_last_operation_action", "consumer_last_operation_at"):
            self.assertEqual(attributes[name]["permissions"]["edit"], ["admin"])
        env = (self.directory / ".env").read_text(encoding="utf-8-sig")
        for flag in ("CONSUMER_PHONE_ENABLED", "CONSUMER_WECHAT_ENABLED", "FAMILY_ACCOUNT_SECURITY_ENABLED", "FAMILY_AI_ENABLED",
                     "FAMILY_PUSH_ENABLED", "FAMILY_WECHAT_ENABLED", "FAMILY_SALES_ENABLED", "FAMILY_ACCEPTANCE_ENABLED",
                     "FAMILY_COMMERCE_WORKER_ENABLED", "FAMILY_BILLS_WORKER_ENABLED"):
            self.assertIn(flag + "='false'", env)
        hmac = (self.directory / "secrets/consumer_otp_hmac_key").read_text()
        self.assertGreaterEqual(len(hmac), 64)
        self.assertFalse(hmac in env)
        configured = subprocess.run(["docker", "compose", "--env-file", str(self.directory / ".env"),
            "-f", str(ROOT / "deploy/compose/compose.yaml"), "-f", str(ROOT / "deploy/compose/compose.family.yaml"),
            "config", "--format", "json"], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=60)
        self.assertEqual(configured.returncode, 0, configured.stderr)
        services = json.loads(configured.stdout)["services"]
        self.assertEqual(services["identity"]["environment"]["CONSUMER_OTP_HMAC_KEY_FILE"], "/run/secrets/consumer_otp_hmac_key")
        self.assertEqual(services["backend"]["environment"]["MANAGER_FAMILY_SALES_ENABLED"], "false")
        self.assertEqual(services["backend"]["environment"]["MANAGER_FAMILY_AI_ENABLED"], "false")
        self.assertEqual(services["backend"]["environment"]["MANAGER_FAMILY_COMMERCE_WORKER_ENABLED"], "false")
        self.assertEqual(services["backend"]["environment"]["MANAGER_FAMILY_BILLS_WORKER_ENABLED"], "false")
        self.assertEqual(services["identity"]["environment"]["CONSUMER_ACCOUNT_SECURITY_ENABLED"], "false")
        self.assertEqual(services["backend"]["environment"]["MANAGER_CONSUMER_IDENTITY_ENABLED"], "false")
        self.assertEqual(services["backend"]["environment"]["MANAGER_CONSUMER_IDENTITY_STATUS_URL"],
                         "http://identity:8080/identity/realms/ai-manager/consumer-account/status")
        self.assertFalse(hmac in configured.stdout)
        for service in ("identity", "backend"):
            self.assertFalse(services[service].get("ports"))
            self.assertIn("family-egress", services[service]["networks"])

    def test_management_initialization_and_build_do_not_require_consumer_spi(self):
        self.assertIs(self.initialize()["consumerIdentity"], False)
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.directory / "release-manifest.json").read_text(encoding="utf-8-sig"))
        self.assertIs(manifest["consumerIdentity"], False)
        self.assertIsNone(manifest.get("identityProviderSha256"))
        self.assertFalse(any(x["path"] == "identity-extensions" for x in manifest["verifiedProjects"]))

    def test_consumer_build_stages_verified_provider_and_start_rejects_tampering(self):
        self.initialize(True)
        result = self.build(True)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.directory / "release-manifest.json").read_text(encoding="utf-8-sig"))
        context = self.directory / manifest["artifactRoot"] / "keycloak"
        provider = context / "keycloak/providers/consumer-identity-1.0.0.jar"
        self.assertEqual(hashlib.sha256(provider.read_bytes()).hexdigest(), manifest["identityProviderSha256"])
        self.assertFalse((self.source / "identity-extensions/target").exists())
        self.assertTrue(any(x["path"] == "identity-extensions" and x["tests"] == "passed" for x in manifest["verifiedProjects"]))
        provider.write_bytes(b"modified provider fixture")
        started = self.command("start-deployment.ps1")
        self.assertNotEqual(started.returncode, 0)
        self.assertIn("Identity provider changed since verification", started.stderr)

    def test_consumer_spi_verification_failure_does_not_publish_release(self):
        self.initialize(True)
        result = self.build(True, True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / "release-manifest.json").exists())

    def test_consumer_build_requires_consistent_initialization_mode(self):
        self.initialize(False)
        result = self.build(True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ConsumerIdentity must match the initialized deployment", result.stderr)
        self.assertFalse((self.directory / "release-manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
