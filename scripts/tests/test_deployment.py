"""Exercise deployment initialization and Compose output, without starting services.

Run with Python 3 and PowerShell 7 on PATH. All generated credentials stay in
an isolated, ignored workspace; assertions never print their values.
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


def assert_no_secret(case, secret, output):
    # unittest.assertNotIn includes both operands in failure output, even with a custom msg.
    case.assertFalse(secret in output, "Sensitive material appeared in captured output")


class DeploymentInitializationTest(unittest.TestCase):
    def test_runtime_ledger_permissions_preserve_immutable_acceptance_records(self):
        import re
        script = (ROOT / "scripts/initialize-erasure-ledger.ps1").read_text(encoding="utf-8-sig")
        grants = dict((table, set(privileges.split(","))) for privileges, table in
                      re.findall(r"GRANT ([A-Z,]+) ON erasure_ledger\.([a-z_]+) TO", script))
        self.assertEqual({
            "erasure_ledger_head": {"SELECT", "UPDATE"},
            "erasure_ledger_entries": {"SELECT", "INSERT"},
            "erasure_work_admissions": {"SELECT", "INSERT", "DELETE"},
            "erasure_admission_pause": {"SELECT", "INSERT", "DELETE"},
        }, grants)

    def test_secret_assertion_failure_does_not_print_material(self):
        material = "synthetic-sensitive-value"
        with self.assertRaises(AssertionError) as failure:
            assert_no_secret(self, material, "captured: " + material)
        self.assertFalse(material in str(failure.exception), "Secret assertion leaks its input")

    def setUp(self):
        self.directory = ROOT / ".local" / ("deployment-test-" + uuid.uuid4().hex)

    def tearDown(self):
        # Only this explicitly bounded test directory belongs to the test.
        if self.directory.exists():
            self.assertEqual(self.directory.parent.resolve(), (ROOT / ".local").resolve())
            shutil.rmtree(self.directory)

    def initialize(self, *arguments):
        self.assertIsNotNone(PWSH, "PowerShell 7 is required")
        return subprocess.run(
            [PWSH, "-NoProfile", "-File", str(ROOT / "scripts/initialize-deployment.ps1"),
             "-Directory", str(self.directory), *arguments],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=60,
        )

    def test_new_environment_separates_credentials_and_emits_valid_compose(self):
        result = self.initialize()
        self.assertEqual(result.returncode, 0, "Deployment initialization failed")
        env = (self.directory / ".env").read_text(encoding="utf-8")
        self.assertTrue((self.directory / "secrets/erasure_root").is_file(), "Independent ledger root credential is missing")
        self.assertTrue((self.directory / "secrets/erasure_app").is_file(), "Independent ledger application credential is missing")
        passwords = [(self.directory / "secrets" / name).read_text(encoding="utf-8")
                     for name in ("mysql_root", "mysql_app", "identity_root",
                                  "identity_app", "bootstrap_admin", "erasure_root", "erasure_app")]
        self.assertEqual(len(set(passwords)), 7, "Credentials must be independent")
        for password in passwords:
            self.assertGreaterEqual(len(password), 48)
            assert_no_secret(self, password, env)
            assert_no_secret(self, password, result.stdout + result.stderr)
        private = json.loads((self.directory / "secrets/signing.jwk").read_text())
        public = json.loads((self.directory / "verification.jwks").read_text())["keys"][0]
        self.assertEqual(private["crv"], "P-256")
        self.assertIn("d", private)
        self.assertNotIn("d", public)
        self.assertEqual(public["x"], private["x"])
        self.assertEqual(public["key_ops"], ["verify"])
        command = ["docker", "compose", "--env-file", str(self.directory / ".env"),
                   "-f", str(ROOT / "deploy/compose/compose.yaml"), "config", "--format", "json"]
        configured = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=60)
        self.assertEqual(configured.returncode, 0, "Compose did not accept the generated environment")
        services = json.loads(configured.stdout)["services"]
        self.assertEqual(set(services), {"database", "identity-database", "erasure-database", "identity", "backend", "edge"})
        for name in ("database", "identity-database", "erasure-database", "identity", "backend"):
            self.assertFalse(services[name].get("ports"), "Internal services must not publish ports")
        self.assertEqual(services["edge"]["ports"][0]["host_ip"], "127.0.0.1")
        self.assertEqual(services["backend"]["environment"]["OIDC_ISSUER_URI"],
                         "http://localhost:18090/identity/realms/ai-manager")
        self.assertEqual(services["backend"]["environment"]["OIDC_JWK_SET_URI"],
                         "http://identity:8080/identity/realms/ai-manager/protocol/openid-connect/certs")
        backend = services["backend"]["environment"]
        self.assertEqual(str(backend["ERASURE_RECOVERY_REQUIRED"]).lower(), "true")
        self.assertIn("erasure-database:3306/erasure_ledger", backend["ERASURE_LEDGER_URL"])
        self.assertEqual(backend["ERASURE_LEDGER_USERNAME"], "erasure_app")
        self.assertEqual(str(uuid.UUID(backend["ERASURE_LEDGER_ID"])), backend["ERASURE_LEDGER_ID"])
        self.assertNotEqual(services["database"]["volumes"][0]["source"],
                            services["erasure-database"]["volumes"][0]["source"])
        self.assertIn({"source": "erasure_app", "target": "manager.erasure-ledger.password"},
                      services["backend"]["secrets"])
        for password in passwords:
            assert_no_secret(self, password, configured.stdout)

    def test_second_initialization_preserves_existing_credentials(self):
        self.assertEqual(self.initialize().returncode, 0)
        before = {str(p.relative_to(self.directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in self.directory.rglob("*") if p.is_file()}
        result = self.initialize()
        self.assertNotEqual(result.returncode, 0, "Reinitialization must not silently rotate credentials")
        after = {str(p.relative_to(self.directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in self.directory.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_export_and_diagnostic_keys_are_independent_and_mounted_read_only(self):
        result = self.initialize()
        self.assertEqual(result.returncode, 0)
        materials = []
        for name in ("audit-export.jwks", "diagnostic-package.jwks"):
            path = self.directory / "secrets" / name
            self.assertTrue(path.is_file(), f"Missing runtime encryption key: {name}")
            key = json.loads(path.read_text(encoding="utf-8"))["keys"][0]
            self.assertEqual((key["kty"], key["use"], key["alg"]), ("oct", "enc", "dir"))
            import base64
            self.assertEqual(len(base64.urlsafe_b64decode(key["k"] + "=")), 32)
            assert_no_secret(self, key["k"], result.stdout + result.stderr)
            materials.append(key["k"])
        self.assertEqual(len(set(materials)), 2)
        configured = subprocess.run(
            ["docker", "compose", "--env-file", str(self.directory / ".env"),
             "-f", str(ROOT / "deploy/compose/compose.yaml"), "config", "--format", "json"],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=60)
        self.assertEqual(configured.returncode, 0)
        services = json.loads(configured.stdout)["services"]
        backend = services["backend"]
        for variable, source, filename in (
            ("AUDIT_EXPORT_KEY_FILE", "audit_export_key", "audit-export.jwks"),
            ("DIAGNOSTIC_PACKAGE_KEY_FILE", "diagnostic_package_key", "diagnostic-package.jwks"),
        ):
            target = f"/run/keys/{filename}"
            self.assertEqual(backend["environment"][variable], target)
            self.assertIn({"source": source, "target": target}, backend["secrets"])
            for service in ("edge", "identity", "database", "erasure-database", "identity-database"):
                self.assertNotIn(source, str(services[service].get("secrets", [])))
        for material in materials:
            assert_no_secret(self, material, configured.stdout)

    def test_public_http_origin_is_rejected_before_writing_secrets(self):
        result = self.initialize("-PublicUrl", "http://public.example.com:18090")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.directory.exists())

    def test_port_origin_mismatch_is_rejected(self):
        result = self.initialize("-PublicUrl", "http://localhost:18091")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.directory.exists())

    def test_invalid_origin_has_no_filesystem_side_effect(self):
        for value in ("https://example.com/subpath", "https://user@example.com", "https://example.com?token=x"):
            with self.subTest(origin=value):
                result = self.initialize("-PublicUrl", value)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.directory.exists())

    def test_start_without_verified_build_is_rejected(self):
        self.assertEqual(self.initialize().returncode, 0)
        result = subprocess.run([PWSH, "-NoProfile", "-File", str(ROOT / "scripts/start-deployment.ps1"),
                                 "-Directory", str(self.directory)], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Verified build contexts are missing", result.stderr)

    def test_ledger_initialization_without_verified_build_is_rejected(self):
        self.assertEqual(self.initialize().returncode, 0)
        result = subprocess.run([PWSH, "-NoProfile", "-File", str(ROOT / "scripts/initialize-erasure-ledger.ps1"),
                                 "-Directory", str(self.directory)], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Verified build contexts are missing", result.stderr)

    def test_changed_build_artifact_is_rejected_before_start(self):
        self.assertEqual(self.initialize().returncode, 0)
        release = self.directory / "artifacts" / ("release-" + uuid.uuid4().hex)
        (release / "backend").mkdir(parents=True)
        (release / "guardian").mkdir()
        jar = release / "backend/manager-backend.jar"
        bundle = release / "guardian/main.dart.js"
        jar.write_bytes(b"build fixture")
        bundle.write_bytes(b"original bundle fixture")
        (release / "guardian/index.html").write_text("fixture")
        (self.directory / "release-manifest.json").write_text(json.dumps({
            "schemaVersion": 1, "publicUrl": "http://localhost:18090",
            "artifactRoot": release.relative_to(self.directory).as_posix(),
            "backendSha256": hashlib.sha256(jar.read_bytes()).hexdigest(),
            "guardianSha256": hashlib.sha256(bundle.read_bytes()).hexdigest(),
        }))
        bundle.write_bytes(b"modified fixture")
        result = subprocess.run([PWSH, "-NoProfile", "-File", str(ROOT / "scripts/start-deployment.ps1"),
                                 "-Directory", str(self.directory)], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Build artifact changed since verification", result.stderr)


if __name__ == "__main__":
    unittest.main()
