"""Exercise release orchestration with local Git/Flutter/signing fixtures.

No Android build, key generation, provider request, or device operation occurs.
The production script must pass the intended client configuration, reject
source drift and wrong certificates, and leave sales acceptance pending.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/build-parent-android.ps1"
PWSH = shutil.which("pwsh")
CERT = "ab" * 32


@unittest.skipUnless(os.name == "nt" and PWSH, "Windows PowerShell fixture")
class ParentAndroidBuildTest(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / ".cache/family-p0-20261021/build-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "apps/parent").mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.repo / "scripts/build-parent-android.ps1")
        self.bin = self.base / "bin"
        self.bin.mkdir()
        # External tooling is replaced at the process boundary; the actual
        # orchestration, argument validation, manifest and checks run unchanged.
        (self.bin / "git.cmd").write_text(
            '@echo off\n'
            'if "%~3"=="rev-parse" (\n'
            ' if exist "%BUILD_TEST_HEAD_MARKER%" (echo ' + "2" * 40 + ') else (echo ' + "1" * 40 + ')\n'
            ')\n'
            'if "%~3"=="status" if exist "%BUILD_TEST_DIRTY_MARKER%" echo  M lib/main.dart\n'
            'exit /b 0\n', encoding="utf-8")
        self.flutter = self.bin / "flutter.ps1"
        self.flutter.write_text(
            '$args | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:BUILD_TEST_ARGUMENTS\n'
            'if ($args[0] -eq "build") {\n'
            '  New-Item -ItemType Directory -Force "build/app/outputs/flutter-apk" | Out-Null\n'
            '  [IO.File]::WriteAllBytes((Join-Path (Get-Location) "build/app/outputs/flutter-apk/app-release.apk"), [byte[]](1,2,3))\n'
            '  if ($env:BUILD_TEST_MUTATE -eq "true") { New-Item -ItemType File $env:BUILD_TEST_DIRTY_MARKER | Out-Null }\n'
            '  if ($env:BUILD_TEST_ADVANCE_HEAD -eq "true") { New-Item -ItemType File $env:BUILD_TEST_HEAD_MARKER | Out-Null }\n'
            '}\n$global:LASTEXITCODE = 0\n', encoding="utf-8")
        self.signer = self.bin / "apksigner.ps1"
        self.signer.write_text(
            'Write-Output "Verifies"\n'
            'Write-Output "Signer #1 certificate DN: $env:BUILD_TEST_CERT_DN"\n'
            'Write-Output "Signer #1 certificate SHA-256 digest: $env:BUILD_TEST_CERT"\n'
            '$global:LASTEXITCODE = 0\n', encoding="utf-8")
        key = self.base / "fixture.keystore"
        key.write_bytes(b"test fixture; not a signing key")
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(self.bin) + os.pathsep + self.env["PATH"],
            "PARENT_ANDROID_KEYSTORE": str(key),
            "PARENT_ANDROID_STORE_PASSWORD": "fixture-store-secret",
            "PARENT_ANDROID_KEY_ALIAS": "fixture-alias",
            "PARENT_ANDROID_KEY_PASSWORD": "fixture-key-secret",
            "PARENT_WECHAT_APP_ID": "wx0123456789abcdef",
            "BUILD_TEST_ARGUMENTS": str(self.base / "arguments.jsonl"),
            "BUILD_TEST_DIRTY_MARKER": str(self.base / "dirty.marker"),
            "BUILD_TEST_HEAD_MARKER": str(self.base / "head.marker"),
            "BUILD_TEST_CERT": CERT,
            "BUILD_TEST_CERT_DN": "CN=Family Acceptance Fixture",
        })

    def run_build(self, *extra):
        return subprocess.run([
            PWSH, "-NoProfile", "-File", str(self.repo / "scripts/build-parent-android.ps1"),
            "-Issuer", "https://identity.example.test/realms/family",
            "-ApiUrl", "https://api.example.test/api/v1",
            "-ConsoleUrl", "https://console.example.test/",
            "-BuildName", "1.0.0", "-BuildNumber", "12",
            "-FlutterCommand", str(self.flutter), "-ApkSignerPath", str(self.signer),
            *extra], cwd=self.repo, env=self.env, capture_output=True,
            text=True, encoding="utf-8", timeout=30)

    def manifest(self):
        return json.loads((self.repo / "apps/parent/build/parent-release-manifest.json").read_text(encoding="utf-8-sig"))

    def test_institution_default_does_not_enable_family_login(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = self.manifest()
        self.assertEqual(manifest["releaseProfile"], "Institution")
        self.assertFalse(manifest["familyIdentity"]["phoneLoginEnabled"])
        self.assertFalse(manifest["familyIdentity"]["wechatLoginEnabled"])
        self.assertFalse(manifest["familyIdentity"]["accountSecurityEnabled"])

    def test_family_profile_binds_flags_appid_certificate_and_pending_gate(self):
        result = self.run_build("-ReleaseProfile", "FamilyAcceptance", "-ExpectedCertificateSha256", CERT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.base / "arguments.jsonl").read_text(encoding="utf-8-sig").splitlines()]
        build = next(call for call in calls if call[0] == "build")
        for flag in ("PHONE_LOGIN_ENABLED", "WECHAT_LOGIN_ENABLED", "FAMILY_ACCOUNT_SECURITY_ENABLED"):
            self.assertIn("--dart-define=" + flag + "=true", build)
        manifest = self.manifest()
        self.assertEqual(manifest["sourceRevision"], "1" * 40)
        self.assertEqual(manifest["signingCertificateSha256"], CERT)
        self.assertEqual(manifest["familyIdentity"]["wechatAppId"], "wx0123456789abcdef")
        self.assertEqual(manifest["acceptanceStatus"], "PENDING")
        self.assertFalse(manifest["salesAllowed"])
        self.assertNotIn("fixture-store-secret", json.dumps(manifest) + result.stdout + result.stderr)
        self.assertNotIn("fixture-key-secret", json.dumps(manifest) + result.stdout + result.stderr)

    def test_family_profile_refuses_missing_appid_before_build(self):
        self.env.pop("PARENT_WECHAT_APP_ID")
        result = self.run_build("-ReleaseProfile", "FamilyAcceptance", "-ExpectedCertificateSha256", CERT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PARENT_WECHAT_APP_ID", result.stderr)
        self.assertFalse((self.base / "arguments.jsonl").exists())

    def test_wrong_certificate_does_not_produce_manifest(self):
        result = self.run_build("-ReleaseProfile", "FamilyAcceptance", "-ExpectedCertificateSha256", "cd" * 32)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("matching ExpectedCertificateSha256", result.stderr)
        self.assertFalse((self.repo / "apps/parent/build/parent-release-manifest.json").exists())

    def test_debug_certificate_is_rejected_even_when_digest_matches(self):
        self.env["BUILD_TEST_CERT_DN"] = "CN=Android Debug, O=Android, C=US"
        result = self.run_build("-ReleaseProfile", "FamilyAcceptance", "-ExpectedCertificateSha256", CERT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Android Debug certificates", result.stderr)
        self.assertFalse((self.repo / "apps/parent/build/parent-release-manifest.json").exists())

    def test_source_change_during_build_does_not_produce_manifest(self):
        self.env["BUILD_TEST_MUTATE"] = "true"
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed the committed source tree", result.stderr)
        self.assertFalse((self.repo / "apps/parent/build/parent-release-manifest.json").exists())

    def test_clean_revision_change_during_build_does_not_produce_manifest(self):
        self.env["BUILD_TEST_ADVANCE_HEAD"] = "true"
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Source revision changed", result.stderr)
        self.assertFalse((self.repo / "apps/parent/build/parent-release-manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
