"""Safety checks for the isolated real-MySQL identity acceptance runner."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]


class FamilyIdentityMysqlPlanTest(unittest.TestCase):
    def run_script(self, *arguments):
        return subprocess.run(
            [shutil.which("pwsh"), "-NoProfile", "-File",
             str(ROOT / "scripts/test_family_identity_mysql.ps1"), *arguments],
            capture_output=True, text=True, encoding="utf-8", timeout=20)

    def test_plan_is_isolated_and_does_not_claim_real_suppliers(self):
        result = subprocess.run(
            [shutil.which("pwsh"), "-NoProfile", "-File",
             str(ROOT / "scripts/test_family_identity_mysql.ps1"), "-PlanOnly"],
            capture_output=True, text=True, encoding="utf-8", timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertTrue(plan["networkInternal"])
        self.assertEqual(plan["hostPorts"], [])
        self.assertEqual(plan["persistentVolumes"], [])
        self.assertTrue(plan["mysqlTmpfs"])
        self.assertFalse(plan["realSupplierAcceptance"])
        self.assertFalse(plan["salesEnabled"])
        self.assertTrue(plan["fixtureExcludedFromProduction"])
        self.assertIn("account-mysql-", plan["resourcePrefix"])
        self.assertEqual(urlparse(plan["identityHostname"]).path, plan["identityRelativePath"])
        self.assertEqual(plan["identityRelativePath"], "/identity")
        self.assertEqual(urlparse(plan["identityHostname"]).scheme, "https")
        self.assertTrue(plan["tlsHostnameVerification"])
        self.assertFalse(plan["trustAllCertificates"])
        self.assertEqual(plan["keycloakStartMode"], "start")
        self.assertFalse(plan["httpListenerEnabled"])
        self.assertTrue(plan["defaultEvidenceDirectory"].startswith(".cache/"))

    def test_cache_child_is_accepted_before_provider_validation(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".cache", prefix="mysql-cache-safety-") as temporary:
            base = Path(temporary)
            run = self.run_script("-OutputDirectory", str(base / "evidence"),
                                  "-ProviderJar", str(base / "missing-provider.jar"))
            self.assertNotEqual(run.returncode, 0)
            self.assertIn("production provider jar is missing", run.stderr.lower())
            self.assertFalse((base / "evidence").exists())

    def test_cache_root_is_not_a_task_directory(self):
        run = self.run_script("-OutputDirectory", str(ROOT / ".cache"))
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("isolated evidence directory", run.stderr.lower())

    def test_resume_is_bound_to_the_exact_original_task_directory(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".cache", prefix="mysql-lifecycle-safety-") as temporary:
            base = Path(temporary)
            (base / "lifecycle.json").write_text(json.dumps({
                "schemaVersion": 2, "id": "0123456789ab", "outputDirectory": str(base / "different-task"),
                "network": "account-mysql-0123456789ab-network",
                "mysql": "account-mysql-0123456789ab-db",
                "identity": "account-mysql-0123456789ab-idp", "created": [],
                "networkCreated": False}), encoding="utf-8")
            run = self.run_script("-Phase", "Cleanup", "-OutputDirectory", str(base))
            self.assertNotEqual(run.returncode, 0)
            self.assertIn("original evidence directory", run.stderr.lower())
            self.assertFalse((base / "cleanup.json").exists())

    def test_fixture_is_not_in_production_service_registration(self):
        services = ROOT / "identity-extensions/src/main/resources/META-INF/services"
        for path in services.iterdir():
            self.assertNotIn("MysqlAcceptance", path.read_text(encoding="utf-8"))
        self.assertFalse((ROOT / "identity-extensions/src/main/java/com/aimanager/identity/MysqlAcceptanceFactory.java").exists())

    def test_reparse_output_ancestor_is_rejected_before_creating_evidence(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".cache", prefix="mysql-path-safety-") as temporary:
            base = Path(temporary)
            target = base / "target"
            target.mkdir()
            link = base / "link"
            result = subprocess.run(
                [shutil.which("pwsh"), "-NoProfile", "-Command",
                 "New-Item -ItemType Junction -Path '" + str(link).replace("'", "''")
                 + "' -Target '" + str(target).replace("'", "''") + "' | Out-Null"],
                capture_output=True, text=True, timeout=20)
            if result.returncode != 0:
                self.skipTest("Junction creation is unavailable on this host")
            try:
                run = self.run_script("-OutputDirectory", str(link / "evidence"))
                self.assertNotEqual(run.returncode, 0)
                self.assertIn("reparse", run.stderr.lower())
                self.assertFalse((target / "evidence").exists())
            finally:
                link.rmdir()

    def test_custom_provider_fixture_is_rejected_before_creating_evidence(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".cache", prefix="mysql-jar-safety-") as temporary:
            base = Path(temporary)
            jar = base / "fixture-disguised-as-production.jar"
            with zipfile.ZipFile(jar, "w") as archive:
                archive.writestr("com/aimanager/identity/MysqlAcceptanceFactory.class", b"fixture")
                archive.writestr("META-INF/services/org.keycloak.services.resource.RealmResourceProviderFactory",
                                 "com.aimanager.identity.MysqlAcceptanceFactory\n")
            run = self.run_script("-OutputDirectory", str(base / "evidence"), "-ProviderJar", str(jar))
            self.assertNotEqual(run.returncode, 0)
            self.assertIn("fixture", run.stderr.lower())
            self.assertFalse((base / "evidence").exists())

    def test_resume_does_not_overwrite_previous_acceptance_evidence(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".cache", prefix="mysql-immutable-evidence-") as temporary:
            base = Path(temporary)
            (base / "lifecycle.json").write_text(json.dumps({
                "schemaVersion": 2, "outputDirectory": str(base), "id": "0123456789ab",
                "network": "account-mysql-0123456789ab-network",
                "mysql": "account-mysql-0123456789ab-db",
                "identity": "account-mysql-0123456789ab-idp", "created": [],
                "networkCreated": False}), encoding="utf-8")
            log = base / "acceptance.log"
            log.write_text("original evidence", encoding="utf-8")
            run = self.run_script("-Phase", "Verify", "-OutputDirectory", str(base))
            self.assertNotEqual(run.returncode, 0)
            self.assertIn("already", run.stderr.lower())
            self.assertEqual(log.read_text(encoding="utf-8"), "original evidence")


if __name__ == "__main__":
    unittest.main()
