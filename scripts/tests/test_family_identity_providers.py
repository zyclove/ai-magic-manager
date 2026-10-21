"""Offline tests for the provider preflight contract; never send SMS or open WeChat."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PWSH = shutil.which("pwsh")
SCRIPT = ROOT / "scripts/test_family_identity_providers.ps1"
REAL_CHECKS = {
    "REAL_SMS_DELIVERY", "REAL_WECHAT_NATIVE_AUTH", "CHANGE_PHONE_E2E",
    "RECOVER_PHONE_E2E", "BIND_WECHAT_E2E", "UNBIND_WECHAT_E2E",
    "IDENTITY_CONFLICTS", "OLD_SESSION_REVOKED", "INTERRUPTION_RECOVERY",
    "MYSQL_CONCURRENCY_ROLLBACK", "SIGNED_DEVICE_BUILD", "LOG_REDACTION",
}


class FamilyIdentityProvidersTest(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / ".cache" / "identity-provider-preflight-tests" / uuid.uuid4().hex
        self.deployment = self.root / "deployment"
        self.secrets = self.deployment / "secrets"
        self.secrets.mkdir(parents=True)
        self.provider = self.root / "identity.jar"
        self.apk = self.root / "parent.apk"
        self.output = self.root / "preflight.json"
        self.app_id = "wx0123456789abcdef"
        # Format-only dummy secrets: the script must never treat these as supplier proof.
        self.credentials = {
            "consumer_otp_hmac_key": "c" * 64,
            "consumer_sms_access_key_id": "LTAI" + "K" * 20,
            "consumer_sms_access_key_secret": "Q" * 30,
            "consumer_sms_security_token": "",
            "consumer_wechat_app_secret": "a" * 32,
        }
        for name, value in self.credentials.items():
            (self.secrets / name).write_text(value, encoding="utf-8")
        self.environment = {
            "PUBLIC_URL": "https://identity-pilot.example.invalid",
            "CONSUMER_PHONE_ENABLED": "false",
            "CONSUMER_WECHAT_ENABLED": "false",
            "FAMILY_ACCOUNT_SECURITY_ENABLED": "false",
            "FAMILY_SALES_ENABLED": "false",
            "ALIYUN_SMS_SIGN_NAME": "家庭验证码",
            "ALIYUN_SMS_TEMPLATE_CODE": "SMS_123456789",
            "WECHAT_NATIVE_APP_ID": self.app_id,
        }
        self.write_env()
        (self.deployment / "deployment.json").write_text(json.dumps({
            "schemaVersion": 1, "consumerIdentity": True,
            "publicUrl": self.environment["PUBLIC_URL"],
        }), encoding="utf-8")
        with zipfile.ZipFile(self.provider, "w") as archive:
            for name in (
                "META-INF/beans.xml",
                "META-INF/services/org.keycloak.authentication.AuthenticatorFactory",
                "META-INF/services/org.keycloak.protocol.ProtocolMapper",
                "META-INF/services/org.keycloak.services.resource.RealmResourceProviderFactory",
            ):
                archive.writestr(name, "fixture-format-only")
        with zipfile.ZipFile(self.apk, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"fixture-format-only")
            archive.writestr("classes.dex", b"fixture-format-only")

    def tearDown(self):
        if self.root.exists():
            self.assertEqual(self.root.parent.resolve(), (ROOT / ".cache" / "identity-provider-preflight-tests").resolve())
            shutil.rmtree(self.root)

    def write_env(self):
        (self.deployment / ".env").write_text("\n".join(
            f"{key}='{value}'" for key, value in self.environment.items()
        ), encoding="utf-8")

    def invoke(self, *arguments, output=None, use_default_output=False, environment_id="family-cn-pilot"):
        environment = os.environ.copy()
        environment["TEMP"] = environment["TMP"] = str(self.root)
        command = [
            PWSH, "-NoProfile", "-File", str(SCRIPT),
            "-Directory", str(self.deployment), "-EnvironmentId", environment_id,
            "-IdentityProviderJar", str(self.provider), "-ParentApk", str(self.apk),
            "-ParentWechatAppId", self.app_id,
        ]
        if not use_default_output:
            command += ["-OutputPath", str(output or self.output)]
        result = subprocess.run(command + list(arguments), cwd=ROOT, env=environment,
                                capture_output=True, text=True, encoding="utf-8", timeout=45)
        return result

    def read_report(self, output=None):
        return json.loads((output or self.output).read_text(encoding="utf-8-sig"))

    def checks(self, report):
        return {check["id"]: check for check in report["requiredChecks"]}

    def test_format_ready_report_remains_blocked_for_real_provider_acceptance(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        report = self.read_report()
        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual(report["kind"], "family-identity-provider-preflight")
        self.assertEqual(report["readinessStatus"], "PASS")
        self.assertEqual(report["acceptanceStatus"], "BLOCKED")
        self.assertIs(report["salesAllowed"], False)
        self.assertIs(report["providerRequestsPerformed"], False)
        checks = self.checks(report)
        self.assertTrue(REAL_CHECKS.issubset(checks))
        for key in REAL_CHECKS:
            self.assertEqual(checks[key]["status"], "BLOCKED", key)
            self.assertTrue(checks[key]["label"])
            self.assertEqual(checks[key]["stage"], "真实联调")
        self.assertEqual(report["artifacts"]["identityProvider"]["sha256"],
                         hashlib.sha256(self.provider.read_bytes()).hexdigest())

    def test_no_sensitive_values_or_secret_hashes_are_written_or_printed(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        emitted = self.output.read_text(encoding="utf-8-sig") + result.stdout + result.stderr
        for value in self.credentials.values():
            if value:
                self.assertNotIn(value, emitted)
                self.assertNotIn(hashlib.sha256(value.encode()).hexdigest(), emitted)
        report = self.read_report()
        for name in self.credentials:
            self.assertEqual(set(report["credentials"][name]), {"present", "validFormat"})
        self.assertNotIn(self.environment["PUBLIC_URL"], emitted)

    def test_empty_supplier_files_produce_actionable_blocked_configuration(self):
        (self.secrets / "consumer_sms_access_key_secret").write_text("")
        (self.secrets / "consumer_wechat_app_secret").write_text("")
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        report = self.read_report()
        self.assertEqual(report["readinessStatus"], "BLOCKED")
        self.assertEqual(self.checks(report)["SMS_CONFIGURATION_FORMAT"]["status"], "BLOCKED")
        self.assertEqual(self.checks(report)["WECHAT_CONFIGURATION_FORMAT"]["status"], "BLOCKED")
        self.assertFalse(report["credentials"]["consumer_sms_access_key_secret"]["present"])

    def test_one_bad_secret_closes_file_loading_as_the_identity_provider_does(self):
        for value in ("first\nsecond", "x" * 8193, "abc\x00def"):
            with self.subTest(value_type=len(value)):
                self.output.unlink(missing_ok=True)
                (self.secrets / "consumer_sms_security_token").write_text(value)
                result = self.invoke()
                self.assertEqual(result.returncode, 2, result.stderr)
                report = self.read_report()
                self.assertEqual(self.checks(report)["SECRET_FILES_FORMAT"]["status"], "BLOCKED")
                self.assertEqual(report["readinessStatus"], "BLOCKED")

    def test_missing_optional_sts_file_is_blocked_but_empty_file_is_valid(self):
        (self.secrets / "consumer_sms_security_token").unlink()
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(self.read_report()["credentials"]["consumer_sms_security_token"]["validFormat"])

    def test_unsafe_or_duplicate_environment_never_executes_or_echoes_content(self):
        marker = self.root / "must-not-exist"
        env_file = self.deployment / ".env"
        payload = "$(New-Item -ItemType File -Path '" + str(marker) + "')"
        env_file.write_text("ALIYUN_SMS_SIGN_NAME=" + payload + "\nALIYUN_SMS_SIGN_NAME='other'")
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.checks(self.read_report())["CONFIGURATION_FILE"]["status"], "BLOCKED")
        self.assertFalse(marker.exists())
        self.assertNotIn(payload, result.stdout + result.stderr + self.output.read_text(encoding="utf-8-sig"))

    def test_inline_credentials_and_sales_enabled_are_rejected(self):
        self.environment["WECHAT_NATIVE_APP_SECRET"] = self.credentials["consumer_wechat_app_secret"]
        self.environment["FAMILY_SALES_ENABLED"] = "true"
        self.write_env()
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        checks = self.checks(self.read_report())
        self.assertEqual(checks["FILE_BACKED_CREDENTIALS"]["status"], "BLOCKED")
        self.assertEqual(checks["SALES_DISABLED"]["status"], "BLOCKED")

    def test_parent_appid_mismatch_and_non_https_origin_are_blocked(self):
        self.environment["WECHAT_NATIVE_APP_ID"] = "wxabcdef0123456789"
        self.environment["PUBLIC_URL"] = "http://localhost:18090"
        self.write_env()
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        checks = self.checks(self.read_report())
        self.assertEqual(checks["APPID_CONFIGURATION_MATCH"]["status"], "BLOCKED")
        self.assertEqual(checks["HTTPS_ORIGIN"]["status"], "BLOCKED")

    def test_evidence_review_recomputes_hashes_and_never_imports_pass_status(self):
        self.assertEqual(self.invoke().returncode, 2)
        fabricated = self.read_report()
        fabricated["acceptanceStatus"] = "PASS"
        fabricated["salesAllowed"] = True
        for check in fabricated["requiredChecks"]:
            check["status"] = "PASS"
        fake_path = self.root / "fabricated.json"
        fake_path.write_text(json.dumps(fabricated, ensure_ascii=False))
        reviewed = self.root / "reviewed.json"
        result = self.invoke("-VerifyManifest", str(fake_path), output=reviewed)
        self.assertEqual(result.returncode, 2, result.stderr)
        report = self.read_report(reviewed)
        self.assertEqual(report["evidenceReview"]["status"], "BLOCKED")
        self.assertEqual(report["acceptanceStatus"], "BLOCKED")
        self.assertFalse(report["salesAllowed"])
        for key in REAL_CHECKS:
            self.assertEqual(self.checks(report)[key]["status"], "BLOCKED")

    def test_unchanged_preflight_can_be_verified_but_artifact_tampering_is_blocked(self):
        self.assertEqual(self.invoke().returncode, 2)
        reviewed = self.root / "verified.json"
        result = self.invoke("-VerifyManifest", str(self.output), output=reviewed)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.read_report(reviewed)["evidenceReview"]["status"], "PASS")
        with zipfile.ZipFile(self.apk, "a") as archive:
            archive.writestr("changed", "different build")
        reviewed2 = self.root / "tampered.json"
        result = self.invoke("-VerifyManifest", str(self.output), output=reviewed2)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.read_report(reviewed2)["evidenceReview"]["status"], "BLOCKED")

    def test_malformed_secret_utf8_is_blocked_without_its_content(self):
        (self.secrets / "consumer_sms_access_key_secret").write_bytes(b"\xff\xfe\x00")
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.checks(self.read_report())["SECRET_FILES_FORMAT"]["status"], "BLOCKED")

    def test_outputs_are_create_new_and_stay_inside_ignored_repository_directories(self):
        self.assertEqual(self.invoke().returncode, 2)
        original = self.output.read_bytes()
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.output.read_bytes(), original)
        outside = ROOT / "provider-preflight-must-not-be-created.json"
        self.assertFalse(outside.exists())
        result = self.invoke(output=outside)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(outside.exists())

    def test_default_output_uses_cache_and_never_overwrites_an_existing_report(self):
        directory = ROOT / ".cache" / "family-identity-provider-acceptance"
        legacy_directory = ROOT / ".local" / "family-p0-integration-20261016" / "provider-acceptance"
        before = set(directory.glob("preflight-*.json"))
        legacy_before = set(legacy_directory.glob("preflight-*.json"))
        environment_id = "cache-default-" + uuid.uuid4().hex
        result = self.invoke(use_default_output=True, environment_id=environment_id)
        created = set(directory.glob("preflight-*.json")) - before
        legacy_created = set(legacy_directory.glob("preflight-*.json")) - legacy_before
        owned = {path for path in created if self.read_report(path).get("environmentId") == environment_id}
        legacy_owned = {path for path in legacy_created if self.read_report(path).get("environmentId") == environment_id}
        try:
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(len(owned), 1)
            self.assertFalse(legacy_owned)
            report = self.read_report(next(iter(owned)))
            self.assertEqual(report["acceptanceStatus"], "BLOCKED")
            self.assertFalse(report["providerRequestsPerformed"])
        finally:
            for path in owned | legacy_owned:
                path.unlink()

    def test_legacy_local_output_remains_accepted(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".local", prefix="provider-legacy-output-") as temporary:
            output = Path(temporary) / "preflight.json"
            result = self.invoke(output=output)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(self.read_report(output)["acceptanceStatus"], "BLOCKED")

    def test_cache_lookalike_prefix_is_rejected_without_creating_a_directory(self):
        outside = ROOT / (".cache-lookalike-" + uuid.uuid4().hex) / "preflight.json"
        result = self.invoke(output=outside)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(outside.parent.exists())

    def test_cache_parent_traversal_is_rejected_after_normalizing_the_path(self):
        outside = ROOT / ".cache" / ".." / ("provider-outside-" + uuid.uuid4().hex + ".json")
        result = self.invoke(output=outside)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(outside.exists())

    def test_cache_reparse_ancestor_is_rejected_without_traversing_its_target(self):
        target = self.root / "target"
        target.mkdir()
        sentinel = target / "keep.txt"
        sentinel.write_bytes(b"target remains untouched")
        link = self.root / "link"
        result = subprocess.run([
            PWSH, "-NoProfile", "-Command",
            "New-Item -ItemType Junction -Path '" + str(link).replace("'", "''")
            + "' -Target '" + str(target).replace("'", "''") + "' | Out-Null",
        ], capture_output=True, text=True, timeout=20)
        if result.returncode != 0:
            self.skipTest("Junction creation is unavailable on this host")
        try:
            result = self.invoke(output=link / "preflight.json")
            self.assertEqual(result.returncode, 1)
            self.assertFalse((target / "preflight.json").exists())
            self.assertEqual(sentinel.read_bytes(), b"target remains untouched")
        finally:
            link.rmdir()


if __name__ == "__main__":
    unittest.main()
