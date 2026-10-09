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


class DeploymentInitializationTest(unittest.TestCase):
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
        passwords = [(self.directory / "secrets" / name).read_text(encoding="utf-8")
                     for name in ("mysql_root", "mysql_app", "identity_root",
                                  "identity_app", "bootstrap_admin")]
        self.assertEqual(len(set(passwords)), 5, "Credentials must be independent")
        for password in passwords:
            self.assertGreaterEqual(len(password), 48)
            self.assertNotIn(password, env, "Compose environment must not contain passwords")
            self.assertNotIn(password, result.stdout + result.stderr, "Secrets must not be printed")
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
        self.assertEqual(set(services), {"database", "identity-database", "identity", "backend", "edge"})
        for name in ("database", "identity-database", "identity", "backend"):
            self.assertFalse(services[name].get("ports"), "Internal services must not publish ports")
        self.assertEqual(services["edge"]["ports"][0]["host_ip"], "127.0.0.1")
        self.assertEqual(services["backend"]["environment"]["OIDC_ISSUER_URI"],
                         "http://localhost:18090/identity/realms/ai-manager")
        self.assertEqual(services["backend"]["environment"]["OIDC_JWK_SET_URI"],
                         "http://identity:8080/identity/realms/ai-manager/protocol/openid-connect/certs")
        for password in passwords:
            self.assertNotIn(password, configured.stdout, "Compose must expose only secret file references")

    def test_second_initialization_preserves_existing_credentials(self):
        self.assertEqual(self.initialize().returncode, 0)
        before = {str(p.relative_to(self.directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in self.directory.rglob("*") if p.is_file()}
        result = self.initialize()
        self.assertNotEqual(result.returncode, 0, "Reinitialization must not silently rotate credentials")
        after = {str(p.relative_to(self.directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in self.directory.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

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
