"""Authenticated, offline release preparation; fixtures never call identity suppliers."""
import base64
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
SCRIPT = ROOT / "scripts/prepare_family_identity_release.ps1"
TASK_ROOT = ROOT / ".cache/family-provider-admin-20261017/deploy"
SEAL = r"""
param([string]$InputFile,[string]$OutputFile)
$ErrorActionPreference='Stop'
function Url64([byte[]]$Value){[Convert]::ToBase64String($Value).TrimEnd('=').Replace('+','-').Replace('/','_')}
$fixture=Get-Content -LiteralPath $InputFile -Raw|ConvertFrom-Json -AsHashtable
$utf8=[Text.UTF8Encoding]::new($false,$true)
$encoded=Url64 $utf8.GetBytes($fixture.headerRaw)
$plain=$utf8.GetBytes($fixture.payloadRaw)
$iv=[Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
$cipher=[byte[]]::new($plain.Length);$tag=[byte[]]::new(16)
$aes=[Security.Cryptography.AesGcm]::new([Convert]::FromBase64String($fixture.key),16)
try{$aes.Encrypt($iv,$plain,$cipher,$tag,$utf8.GetBytes($encoded))}finally{$aes.Dispose()}
$fixture.outer.protectedPayload=$encoded+'..'+(Url64 $iv)+'.'+(Url64 $cipher)+'.'+(Url64 $tag)
[IO.File]::WriteAllText($OutputFile,($fixture.outer|ConvertTo-Json -Depth 20 -Compress),$utf8)
if($IsWindows -and -not (Get-Acl -LiteralPath (Join-Path (Split-Path $InputFile -Parent) 'release-key.jwks')).AreAccessRulesProtected){
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false)
  foreach($allowed in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($allowed,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
  }
  Set-Acl -LiteralPath (Join-Path (Split-Path $InputFile -Parent) 'release-key.jwks') -AclObject $acl
}
"""


@unittest.skipUnless(PWSH, "PowerShell 7 is required for the deployment tool")
class PrepareFamilyIdentityReleaseTest(unittest.TestCase):
    def setUp(self):
        self.root = TASK_ROOT / "tests" / uuid.uuid4().hex
        self.root.mkdir(parents=True)
        self.temp = self.root / "tmp"
        self.temp.mkdir()
        self.bundle = self.root / "release.json"
        self.key_file = self.root / "release-key.jwks"
        self.output = self.root / "prepared"
        self.environment = "family-cn-isolated"
        self.version = str(uuid.uuid4())
        self.key = bytes(range(32))
        self.credentials = {
            "CONSUMER_OTP_HMAC_KEY": "fixture-only-otp-hmac-key-" + "q" * 40,
            "ALIYUN_SMS_ACCESS_KEY_ID": "LTAI" + "K" * 20,
            "ALIYUN_SMS_ACCESS_KEY_SECRET": "Q" * 30,
            "ALIYUN_SMS_SECURITY_TOKEN": "",
            "WECHAT_NATIVE_APP_SECRET": "a" * 32,
        }
        self.settings = {
            "smsSignName": "家庭验证码",
            "smsTemplateCode": "SMS_123456789",
            "wechatAppId": "wx0123456789abcdef",
            "parentPackageName": "com.aimanager.parent",
            "parentCertificateSha256": "b" * 64,
        }
        self.header = {
            "alg": "dir", "enc": "A256GCM", "kid": "identity-release-test-1",
            "typ": "family-identity-provider-release+jwe", "cty": "application/json",
            "purpose": "family-identity-provider-release-v1",
            "environmentId": self.environment, "versionId": self.version,
        }
        self.payload = {"schemaVersion": 1, "versionId": self.version,
                        "settings": self.settings, "credentials": self.credentials}
        self.outer = {"schemaVersion": 1, "environmentId": self.environment,
                      "versionId": self.version}
        self.key_ring = {"keys": [{"kty": "oct", "use": "enc", "alg": "dir",
                                   "kid": self.header["kid"],
                                   "k": self.url64(self.key)}]}
        self.write_key()
        self.seal()

    def tearDown(self):
        # Only generated fixtures are disposable. Preserve a secret-free inventory outside them.
        self.assertEqual(self.root.parent.resolve(), (TASK_ROOT / "tests").resolve())
        files = []
        for current, directories, names in os.walk(self.root, followlinks=False):
            for name in list(directories):
                path = Path(current) / name
                if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
                    files.append({"path": str(path.relative_to(self.root)), "kind": "link"})
                    directories.remove(name)
                    if path.is_symlink():
                        path.unlink()
                    else:
                        os.rmdir(path)
            for name in names:
                path = Path(current) / name
                files.append({"path": str(path.relative_to(self.root)), "kind": "fixture"})
        receipt_root = TASK_ROOT / "test-receipts"
        receipt_root.mkdir(parents=True, exist_ok=True)
        (receipt_root / (self.root.name + ".json")).write_text(json.dumps({
            "task": self.root.name, "disposableFixtureInventory": files,
            "testSourceSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "providerRequestsPerformed": False,
        }), encoding="utf-8")
        shutil.rmtree(self.root)

    @staticmethod
    def url64(value):
        return base64.urlsafe_b64encode(value).decode().rstrip("=")

    def process_environment(self):
        environment = os.environ.copy()
        environment["TEMP"] = environment["TMP"] = str(self.temp)
        return environment

    def write_key(self):
        self.key_file.write_text(json.dumps(self.key_ring), encoding="utf-8")
        if os.name != "nt":
            self.key_file.chmod(0o600)

    def seal(self, payload_raw=None, header_raw=None):
        helper = self.root / "seal.ps1"
        helper.write_text(SEAL, encoding="utf-8")
        fixture = self.root / "seal-input.json"
        fixture.write_text(json.dumps({
            "headerRaw": header_raw or json.dumps(self.header),
            "payloadRaw": payload_raw or json.dumps(self.payload),
            "key": base64.b64encode(self.key).decode(), "outer": self.outer,
        }), encoding="utf-8")
        result = subprocess.run([PWSH, "-NoProfile", "-File", str(helper),
                                 "-InputFile", str(fixture), "-OutputFile", str(self.bundle)],
                                cwd=ROOT, env=self.process_environment(), capture_output=True,
                                text=True, encoding="utf-8", timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    def invoke(self, bundle=None, key_file=None, output=None, environment=None, version=None):
        return subprocess.run([
            PWSH, "-NoProfile", "-File", str(SCRIPT),
            "-BundleFile", str(bundle or self.bundle), "-KeyFile", str(key_file or self.key_file),
            "-OutputDirectory", str(output or self.output),
            "-EnvironmentId", environment or self.environment,
            "-VersionId", version or self.version,
        ], cwd=ROOT, env=self.process_environment(), capture_output=True,
            text=True, encoding="utf-8", timeout=45)

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse(self.output.exists())
        for secret in self.credentials.values():
            if secret:
                self.assertNotIn(secret, result.stdout + result.stderr)

    def test_authenticated_bundle_prepares_disabled_complete_version_and_restricts_permissions(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads((self.output / "prepared-release.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(report["state"], "APPLY_REQUIRED")
        self.assertFalse(report["applied"])
        self.assertFalse(report["runtimeVerified"])
        self.assertFalse(report["salesAllowed"])
        self.assertFalse(report["providerRequestsPerformed"])
        self.assertEqual(report["acceptanceStatus"], "BLOCKED")
        self.assertEqual(report["versionId"], self.version)
        self.assertTrue(report["permissionsRestricted"])
        environment = (self.output / "family-identity.env").read_text(encoding="utf-8")
        for key in ("CONSUMER_PHONE_ENABLED", "CONSUMER_WECHAT_ENABLED",
                    "FAMILY_ACCOUNT_SECURITY_ENABLED", "FAMILY_SALES_ENABLED"):
            self.assertIn(f"{key}=false", environment)
        mapping = {
            "CONSUMER_OTP_HMAC_KEY": "consumer_otp_hmac_key",
            "ALIYUN_SMS_ACCESS_KEY_ID": "consumer_sms_access_key_id",
            "ALIYUN_SMS_ACCESS_KEY_SECRET": "consumer_sms_access_key_secret",
            "ALIYUN_SMS_SECURITY_TOKEN": "consumer_sms_security_token",
            "WECHAT_NATIVE_APP_SECRET": "consumer_wechat_app_secret",
        }
        for key, filename in mapping.items():
            self.assertEqual((self.output / "secrets" / filename).read_text(), self.credentials[key])
        emitted = (result.stdout + result.stderr + json.dumps(report) + environment
                   + (self.output / "NEXT_STEPS.md").read_text(encoding="utf-8"))
        for value in self.credentials.values():
            if value:
                self.assertNotIn(value, emitted)
                self.assertNotIn(hashlib.sha256(value.encode()).hexdigest(), emitted)
        if os.name == "nt":
            command = "$a=Get-Acl -LiteralPath $env:FAMILY_RELEASE_TEST_PATH;if(-not $a.AreAccessRulesProtected){exit 1};$a.Access|%{if($_.IdentityReference.Value -match 'Everyone|Authenticated Users|BUILTIN\\\\Users'){exit 2}}"
            environment = self.process_environment()
            environment["FAMILY_RELEASE_TEST_PATH"] = str(self.output)
            permissions = subprocess.run([PWSH, "-NoProfile", "-Command", command],
                                         env=environment, capture_output=True, timeout=30)
            self.assertEqual(permissions.returncode, 0, permissions.stderr)
        else:
            self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
            self.assertEqual((self.output / "secrets/consumer_otp_hmac_key").stat().st_mode & 0o777, 0o600)

    def test_expected_environment_and_version_are_authenticated_in_every_layer(self):
        self.assert_rejected(self.invoke(environment="other-environment"))
        self.assert_rejected(self.invoke(version=str(uuid.uuid4())))
        for container, key in ((self.header, "environmentId"), (self.header, "versionId"),
                               (self.payload, "versionId")):
            previous = container[key]
            container[key] = str(uuid.uuid4()) if key == "versionId" else "other-environment"
            self.seal()
            self.assert_rejected(self.invoke())
            container[key] = previous

    def test_bad_tag_or_unmatched_decryption_key_never_creates_plaintext_output(self):
        outer = json.loads(self.bundle.read_text())
        parts = outer["protectedPayload"].split(".")
        parts[4] = self.url64(bytes(16))
        outer["protectedPayload"] = ".".join(parts)
        self.bundle.write_text(json.dumps(outer))
        self.assert_rejected(self.invoke())
        self.seal()
        self.key_ring["keys"][0]["k"] = self.url64(bytes(reversed(range(32))))
        self.write_key()
        self.assert_rejected(self.invoke())

    def test_jwe_purpose_algorithms_and_unsupported_header_extensions_are_rejected(self):
        for field, value in (("purpose", "audit-export-v1"), ("typ", "other+jwe"),
                             ("alg", "RSA-OAEP"), ("enc", "A128GCM"),
                             ("zip", "DEF"), ("crit", ["purpose"]), ("jku", "https://example.invalid/key"),
                             ("purpose", ["family-identity-provider-release-v1"])):
            with self.subTest(field=field):
                saved = dict(self.header)
                self.header[field] = value
                self.seal()
                self.assert_rejected(self.invoke())
                self.header.clear(); self.header.update(saved)

    def test_duplicate_or_unknown_json_fields_cannot_override_the_binding(self):
        payload = json.dumps(self.payload)
        self.seal(payload_raw=payload[:-1] + ',"versionId":"' + self.version + '"}')
        self.assert_rejected(self.invoke())
        self.seal(header_raw=json.dumps(self.header)[:-1] + ',"kid":"identity-release-test-1"}')
        self.assert_rejected(self.invoke())
        self.seal()
        text = self.bundle.read_text()
        self.bundle.write_text(text[:-1] + ',"schemaVersion":1}')
        self.assert_rejected(self.invoke())
        self.payload["credentials"]["UNKNOWN_SECRET"] = "must-not-be-exported"
        self.seal()
        self.assert_rejected(self.invoke())

    def test_bad_secret_files_and_placeholder_values_are_refused_before_writing(self):
        for name, value in (("CONSUMER_OTP_HMAC_KEY", "short"),
                            ("ALIYUN_SMS_ACCESS_KEY_SECRET", "Q" * 8193),
                            ("ALIYUN_SMS_SECURITY_TOKEN", "first\nsecond"),
                            ("ALIYUN_SMS_SECURITY_TOKEN", "\ufeff" + "Q" * 30),
                            ("WECHAT_NATIVE_APP_SECRET", "not-real-secret"),
                            ("ALIYUN_SMS_ACCESS_KEY_ID", "")):
            with self.subTest(name=name):
                saved = self.credentials[name]
                self.credentials[name] = value
                self.seal()
                self.assert_rejected(self.invoke())
                self.credentials[name] = saved

    def test_setting_injection_is_not_written_or_executed(self):
        marker = self.root / "must-not-exist"
        self.settings["smsSignName"] = "$(New-Item '" + str(marker) + "')"
        self.seal()
        self.assert_rejected(self.invoke())
        self.assertFalse(marker.exists())
        for name, value in (("wechatAppId", "wrong-app"),
                            ("parentPackageName", "other.package"),
                            ("parentCertificateSha256", "not-a-digest")):
            self.settings["smsSignName"] = "家庭验证码"
            previous = self.settings[name]
            self.settings[name] = value
            self.seal()
            self.assert_rejected(self.invoke())
            self.settings[name] = previous

    def test_existing_output_is_never_overwritten(self):
        self.output.mkdir()
        marker = self.output / "unique-user-file.txt"
        marker.write_text("keep-existing-content")
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(marker.read_text(), "keep-existing-content")
        self.assertEqual(list(self.output.iterdir()), [marker])

    def test_drive_root_and_paths_outside_repository_scratch_are_rejected(self):
        self.assert_rejected(self.invoke(bundle=ROOT / "README.md"))
        self.assert_rejected(self.invoke(key_file=ROOT / "identity-extensions/pom.xml"))
        result = self.invoke(output=ROOT / "unexpected-release-output")
        self.assertEqual(result.returncode, 1)
        self.assertFalse((ROOT / "unexpected-release-output").exists())
        drive_root = Path(ROOT.anchor) / ("identity-release-" + uuid.uuid4().hex)
        result = self.invoke(output=drive_root)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(drive_root.exists())

    def test_linked_output_ancestors_and_input_files_are_refused(self):
        target = self.root / "link-target"
        target.mkdir()
        link = self.root / "linked"
        if os.name == "nt":
            environment = self.process_environment()
            environment["FAMILY_RELEASE_TEST_LINK"] = str(link)
            environment["FAMILY_RELEASE_TEST_TARGET"] = str(target)
            result = subprocess.run([PWSH, "-NoProfile", "-Command",
                                     "New-Item -ItemType Junction -Path $env:FAMILY_RELEASE_TEST_LINK -Target $env:FAMILY_RELEASE_TEST_TARGET | Out-Null"],
                                    env=environment, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            link.symlink_to(target, target_is_directory=True)
        result = self.invoke(output=link / "new-version")
        self.assertEqual(result.returncode, 1)
        self.assertFalse((target / "new-version").exists())
        self.assertEqual(list(target.iterdir()), [])

    def test_oversized_and_invalid_utf8_inputs_are_rejected_without_echo(self):
        self.bundle.write_bytes(b"x" * 131073)
        self.assert_rejected(self.invoke())
        self.bundle.write_bytes(b"\xff\xfeinvalid-utf8")
        self.assert_rejected(self.invoke())

    def test_jwk_duplicates_wrong_lengths_and_unknown_keys_are_rejected(self):
        saved = json.loads(json.dumps(self.key_ring))
        self.key_ring["keys"].append(dict(self.key_ring["keys"][0]))
        self.write_key()
        self.assert_rejected(self.invoke())
        self.key_ring = saved
        self.key_ring["keys"][0]["k"] = self.url64(bytes(16))
        self.write_key()
        self.assert_rejected(self.invoke())
        self.key_ring["keys"][0]["k"] = self.url64(self.key)
        self.key_ring["keys"][0]["kid"] = "different-key"
        self.write_key()
        self.assert_rejected(self.invoke())

    def test_unrestricted_key_file_is_refused_without_creating_output(self):
        public_key = self.root / "unrestricted-key.jwks"
        public_key.write_text(json.dumps(self.key_ring), encoding="utf-8")
        if os.name != "nt":
            public_key.chmod(0o644)
        self.assert_rejected(self.invoke(key_file=public_key))

    def test_prepared_files_match_existing_offline_provider_preflight(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        deployment = self.root / "deployment-fixture"
        deployment.mkdir()
        shutil.copytree(self.output / "secrets", deployment / "secrets")
        environment = (self.output / "family-identity.env").read_text(encoding="utf-8")
        (deployment / ".env").write_text(
            "PUBLIC_URL=https://identity-isolated.example.invalid\n" + environment, encoding="utf-8")
        (deployment / "deployment.json").write_text(json.dumps({
            "schemaVersion": 1, "consumerIdentity": True,
            "publicUrl": "https://identity-isolated.example.invalid",
        }), encoding="utf-8")
        report = self.root / "preflight.json"
        result = subprocess.run([
            PWSH, "-NoProfile", "-File", str(ROOT / "scripts/test_family_identity_providers.ps1"),
            "-Directory", str(deployment), "-EnvironmentId", self.environment,
            "-ParentWechatAppId", self.settings["wechatAppId"], "-OutputPath", str(report),
        ], cwd=ROOT, env=self.process_environment(), capture_output=True,
            text=True, encoding="utf-8", timeout=45)
        self.assertEqual(result.returncode, 2, result.stderr)
        evidence = json.loads(report.read_text(encoding="utf-8-sig"))
        checks = {check["id"]: check for check in evidence["requiredChecks"]}
        self.assertEqual(checks["SMS_CONFIGURATION_FORMAT"]["status"], "PASS")
        self.assertEqual(checks["WECHAT_CONFIGURATION_FORMAT"]["status"], "PASS")
        self.assertEqual(evidence["acceptanceStatus"], "BLOCKED")
        self.assertFalse(evidence["providerRequestsPerformed"])
        self.assertFalse(evidence["salesAllowed"])


if __name__ == "__main__":
    unittest.main()
