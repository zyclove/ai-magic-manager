"""Android readiness safety tests. SDK output is a fixture, never real acceptance."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/test_family_android_acceptance.ps1"
TASK = ROOT / ".cache/family-provider-acceptance-20261017-r3/runtime"
PWSH = shutil.which("pwsh")
JDK = Path("C:/Program Files/Java/jdk-17/bin")
CSC = Path("C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe")
CERTIFICATE = "a" * 64


@unittest.skipUnless(PWSH and JDK.exists() and CSC.exists(), "Windows SDK fixture compilers unavailable")
class FamilyAndroidAcceptanceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = TASK / "tmp" / ("fixture-tools-" + uuid.uuid4().hex)
        cls.shared.mkdir(parents=True)
        signer = cls.shared / "FixtureSigner.java"
        signer.write_text('''public final class FixtureSigner {
 public static void main(String[] args) {
  String mode=System.getenv("FAMILY_ANDROID_FIXTURE_SIGNER_MODE");
  System.err.println("PRIVATE-TOOL-OUTPUT-MUST-NOT-LEAK");
  if("large".equals(mode)) {System.out.print("x".repeat(100000));return;}
  if("timeout".equals(mode)) {try{Thread.sleep(30000);}catch(Exception e){}return;}
  System.out.println("Signer #1 certificate DN: CN="+("debug".equals(mode)?"Android Debug":"Fixture Release"));
  System.out.println("Signer #1 certificate SHA-256 digest: ''' + CERTIFICATE + '''");
  if("multiple".equals(mode))System.out.println("Signer #2 certificate SHA-256 digest: ''' + "b" * 64 + '''");
  if("failure".equals(mode))System.exit(1);
  if("mutate".equals(mode)) {
   try {java.nio.file.Files.writeString(java.nio.file.Path.of(args[2]),"unexpected mutation");}
   catch(Exception denied) {System.err.println("READ_LOCK_PREVENTED_WRITE");}
  }
 }
}''', encoding="utf-8")
        subprocess.run([str(JDK / "javac.exe"), "-d", str(cls.shared), str(signer)], check=True, capture_output=True)
        cls.signer = cls.shared / "apksigner.jar"
        with zipfile.ZipFile(cls.signer, "w") as archive:
            archive.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\nMain-Class: FixtureSigner\n\n")
            archive.write(cls.shared / "FixtureSigner.class", "FixtureSigner.class")
        aapt = cls.shared / "FixtureAapt.cs"
        aapt.write_text('''using System;class FixtureAapt {
 static int Main(string[] args) {
  string mode=Environment.GetEnvironmentVariable("FAMILY_ANDROID_FIXTURE_AAPT_MODE");
  Console.Error.WriteLine("PRIVATE-TOOL-OUTPUT-MUST-NOT-LEAK");
  if(mode=="failure")return 1;
  if(mode=="malformed"){Console.WriteLine("not a manifest");return 0;}
  string package=mode=="wrong-package"?"com.example.other":"com.aimanager.parent";
  Console.WriteLine("package: name='"+package+"' versionCode='1' versionName='1.0.0'");
  if(mode=="debuggable")Console.WriteLine("application-debuggable");
  return 0;
 }
}''', encoding="utf-8")
        cls.aapt = cls.shared / "aapt.exe"
        subprocess.run([str(CSC), "/nologo", "/target:exe", "/out:" + str(cls.aapt), str(aapt)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.clean_owned(cls.shared)

    @classmethod
    def clean_owned(cls, path):
        temporary = (TASK / "tmp").resolve()
        if path.exists():
            if not path.resolve().is_relative_to(temporary):
                raise AssertionError("Cleanup escaped exact task temporary root")
            entries = []
            for file in path.rglob("*"):
                if file.is_symlink() or file.is_junction():
                    raise AssertionError("Test link must be explicitly removed before cleanup")
                if file.is_file():
                    entries.append({"path": str(file.relative_to(path)), "bytes": file.stat().st_size,
                                    "sha256": hashlib.sha256(file.read_bytes()).hexdigest()})
            receipt = TASK / "out" / ("android-test-cleanup-" + uuid.uuid4().hex + ".json")
            receipt.parent.mkdir(parents=True, exist_ok=True)
            receipt.write_text(json.dumps({"ownedTemporaryDirectory": str(path.relative_to(TASK)), "files": entries}), encoding="utf-8")
            shutil.rmtree(path)

    def setUp(self):
        self.directory = TASK / "tmp" / ("android-test-" + uuid.uuid4().hex)
        self.directory.mkdir(parents=True)
        self.sdk = self.directory / "sdk with spaces"
        tools = self.sdk / "build-tools" / "35.0.0"
        (tools / "lib").mkdir(parents=True)
        shutil.copy2(self.signer, tools / "lib/apksigner.jar")
        shutil.copy2(self.aapt, tools / "aapt.exe")
        (self.sdk / "platform-tools").mkdir()
        # The production tool must use the fixed loopback read-only protocol, not run adb.
        (self.sdk / "platform-tools/adb.exe").write_bytes(b"fixture presence only; must never execute")
        self.apk = self.directory / "parent release.apk"
        with zipfile.ZipFile(self.apk, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"fixture")
            archive.writestr("classes.dex", b"fixture")
        self.output = self.directory / "report.json"
        self.extra_environment = {}

    def tearDown(self):
        self.clean_owned(self.directory)

    def invoke(self, *extra, output=None, apk=None, default_output=False):
        environment = os.environ.copy()
        for key in list(environment):
            if key.startswith("FAMILY_ANDROID_FIXTURE_"):
                del environment[key]
        environment.update(self.extra_environment)
        environment["TEMP"] = environment["TMP"] = str(self.directory)
        command = [PWSH, "-NoProfile", "-File", str(SCRIPT), "-EnvironmentId", "android-fixture",
                   "-AndroidSdkDirectory", str(self.sdk), "-ParentApk", str(apk or self.apk),
                   "-ExpectedCertificateSha256", CERTIFICATE]
        if not default_output:
            command += ["-OutputPath", str(output or self.output)]
        for name in extra[::2]:
            if name in command:
                index = command.index(name)
                del command[index:index + 2]
        return subprocess.run(command + list(extra), cwd=ROOT, env=environment,
                              capture_output=True, text=True, encoding="utf-8", timeout=65)

    def report(self, path=None):
        return json.loads((path or self.output).read_text(encoding="utf-8-sig"))

    def checks(self):
        return {item["id"]: item for item in self.report()["requiredChecks"]}

    def test_format_ready_artifact_never_becomes_real_acceptance_or_sales(self):
        result = self.invoke("-ParentWechatAppId", "wx0123456789abcdef")
        self.assertEqual(result.returncode, 2, result.stderr)
        report = self.report()
        self.assertEqual(report["kind"], "family-android-acceptance-preflight")
        self.assertEqual(report["acceptanceStatus"], "BLOCKED")
        self.assertFalse(report["salesAllowed"])
        self.assertFalse(report["providerRequestsPerformed"])
        self.assertFalse(report["deviceStateChanged"])
        self.assertEqual(report["artifact"]["sha256"], hashlib.sha256(self.apk.read_bytes()).hexdigest())
        self.assertEqual(report["artifact"]["certificateSha256"], CERTIFICATE)
        self.assertEqual(self.checks()["CERTIFICATE_MATCH"]["status"], "PASS")
        self.assertEqual(report["wechatAppId"]["status"], "NOT_VERIFIED")
        self.assertFalse(report["wechatAppId"]["apkValueVerified"])
        for case in ("REAL_SMS_DELIVERY", "REAL_WECHAT_NATIVE_AUTH", "SIGNED_DEVICE_ACCEPTANCE"):
            self.assertEqual(self.checks()[case]["status"], "BLOCKED")
        combined = result.stdout + result.stderr + self.output.read_text(encoding="utf-8-sig")
        self.assertNotIn("PRIVATE-TOOL-OUTPUT-MUST-NOT-LEAK", combined)
        self.assertNotIn(str(self.apk), combined)

    def test_debug_certificate_and_debuggable_apk_are_rejected_separately(self):
        self.extra_environment["FAMILY_ANDROID_FIXTURE_SIGNER_MODE"] = "debug"
        self.extra_environment["FAMILY_ANDROID_FIXTURE_AAPT_MODE"] = "debuggable"
        self.assertEqual(self.invoke().returncode, 2)
        self.assertEqual(self.checks()["NON_DEBUG_CERTIFICATE"]["status"], "BLOCKED")
        self.assertEqual(self.checks()["NON_DEBUGGABLE_APK"]["status"], "BLOCKED")

    def test_certificate_mismatch_does_not_accept_a_valid_signature(self):
        result = self.invoke("-ExpectedCertificateSha256", "b" * 64)
        self.assertEqual(result.returncode, 2)
        self.assertTrue(self.report()["artifact"]["signatureVerified"])
        self.assertEqual(self.checks()["CERTIFICATE_MATCH"]["status"], "BLOCKED")

    def test_wrong_package_and_malformed_manifest_are_blocked(self):
        self.extra_environment["FAMILY_ANDROID_FIXTURE_AAPT_MODE"] = "wrong-package"
        self.assertEqual(self.invoke().returncode, 2)
        self.assertEqual(self.checks()["PARENT_PACKAGE"]["status"], "BLOCKED")
        self.output.unlink()
        self.extra_environment["FAMILY_ANDROID_FIXTURE_AAPT_MODE"] = "malformed"
        self.assertEqual(self.invoke().returncode, 2)
        self.assertEqual(self.checks()["APK_MANIFEST"]["status"], "BLOCKED")

    def test_signer_failure_multiple_signers_and_excessive_output_fail_closed(self):
        for mode in ("failure", "multiple", "large"):
            with self.subTest(mode=mode):
                self.extra_environment["FAMILY_ANDROID_FIXTURE_SIGNER_MODE"] = mode
                self.assertEqual(self.invoke().returncode, 2)
                self.assertEqual(self.checks()["APK_SIGNATURE"]["status"], "BLOCKED")
                self.output.unlink()

    def test_missing_apk_and_missing_sdk_each_produce_a_blocked_report(self):
        self.assertEqual(self.invoke(apk=self.directory / "absent.apk").returncode, 2)
        self.assertEqual(self.checks()["APK_ARTIFACT"]["status"], "BLOCKED")
        self.output.unlink()
        shutil.rmtree(self.sdk)
        self.assertEqual(self.invoke().returncode, 2)
        self.assertEqual(self.checks()["ANDROID_SDK_TOOLS"]["status"], "BLOCKED")

    def test_missing_certificate_and_invalid_configuration_do_not_echo_input(self):
        result = self.invoke("-ExpectedCertificateSha256", "")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.checks()["EXPECTED_CERTIFICATE"]["status"], "BLOCKED")
        self.output.unlink()
        sentinel = "private-path-or-value-which-must-not-appear"
        result = self.invoke("-ExpectedCertificateSha256", sentinel)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(sentinel, result.stdout + result.stderr + self.output.read_text(encoding="utf-8-sig"))

    def test_sdk_tool_deadline_fails_closed_without_hanging(self):
        self.extra_environment["FAMILY_ANDROID_FIXTURE_SIGNER_MODE"] = "timeout"
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.checks()["APK_SIGNATURE"]["status"], "BLOCKED")
        self.assertFalse(self.report()["salesAllowed"])

    def test_apk_read_lock_prevents_tool_time_artifact_mutation(self):
        self.extra_environment["FAMILY_ANDROID_FIXTURE_SIGNER_MODE"] = "mutate"
        original = self.apk.read_bytes()
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.apk.read_bytes(), original)
        self.assertEqual(self.report()["artifact"]["sha256"], hashlib.sha256(original).hexdigest())

    def test_apk_filename_is_passed_without_shell_expansion(self):
        unusual = self.directory / "parent & echo PRIVATE-MARKER %.apk"
        shutil.copy2(self.apk, unusual)
        result = self.invoke(apk=unusual)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue(self.report()["artifact"]["signatureVerified"])
        self.assertNotIn("PRIVATE-MARKER", result.stdout + result.stderr)

    def test_default_cache_and_existing_local_output_remain_supported(self):
        directory = ROOT / ".cache/family-provider-acceptance-20261017-r3/android"
        before = set(directory.glob("preflight-*.json"))
        result = self.invoke(default_output=True)
        created = set(directory.glob("preflight-*.json")) - before
        local = ROOT / ".local" / ("android-preflight-fixture-" + uuid.uuid4().hex + ".json")
        try:
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(len(created), 1)
            self.assertEqual(self.report(next(iter(created)))["acceptanceStatus"], "BLOCKED")
            self.assertEqual(self.invoke(output=local).returncode, 2)
            self.assertFalse(self.report(local)["salesAllowed"])
        finally:
            owned = created | ({local} if local.exists() else set())
            receipt = TASK / "out" / ("android-output-cleanup-" + uuid.uuid4().hex + ".json")
            receipt.write_text(json.dumps([{"path": str(path.relative_to(ROOT)),
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in owned]), encoding="utf-8")
            for path in owned:
                path.unlink()

    def test_overwrite_traversal_lookalike_and_nonignored_output_are_rejected(self):
        self.assertEqual(self.invoke().returncode, 2)
        original = self.output.read_bytes()
        self.assertEqual(self.invoke().returncode, 1)
        self.assertEqual(self.output.read_bytes(), original)
        for output in (ROOT / "android-report-must-not-exist.json",
                       ROOT / (".cache-lookalike-" + uuid.uuid4().hex) / "report.json",
                       ROOT / ".cache" / ".." / ("outside-" + uuid.uuid4().hex + ".json")):
            self.assertEqual(self.invoke(output=output).returncode, 1)
            self.assertFalse(output.exists())

    def test_junction_input_and_output_are_rejected_without_traversing_target(self):
        target = self.directory / "target"
        target.mkdir()
        sentinel = target / "keep.txt"
        sentinel.write_bytes(b"keep original")
        link = self.directory / "linked"
        created = subprocess.run([PWSH, "-NoProfile", "-Command",
            "New-Item -ItemType Junction -Path '" + str(link).replace("'", "''") + "' -Target '"
            + str(target).replace("'", "''") + "' | Out-Null"], capture_output=True, timeout=20)
        if created.returncode:
            self.skipTest("Junction creation unavailable")
        try:
            self.assertEqual(self.invoke(output=link / "report.json").returncode, 1)
            shutil.copy2(self.apk, target / "parent.apk")
            self.assertEqual(self.invoke(apk=link / "parent.apk").returncode, 1)
            self.assertFalse((target / "report.json").exists())
            self.assertEqual(sentinel.read_bytes(), b"keep original")
        finally:
            link.rmdir()

    def test_device_parser_uses_fresh_random_aliases_and_never_persists_serials(self):
        helper = self.directory / "device-parser.ps1"
        helper.write_text('''$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$tokens,[ref]$errors)
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Convert-AdbInventory'},$true)
if($null -eq $function){throw 'Device parser unavailable'}
Invoke-Expression $function.Extent.Text
$body="PRIVATE-USB-SERIAL device usb:1-1 product:fixture model:fixture device:fixture`nemulator-5554 device product:fixture`nPRIVATE-NETWORK:5555 unauthorized"
@{first=(Convert-AdbInventory $body);second=(Convert-AdbInventory $body)}|ConvertTo-Json -Depth 8
''', encoding="utf-8")
        result = subprocess.run([PWSH, "-NoProfile", "-File", str(helper), str(SCRIPT)], capture_output=True,
                                text=True, encoding="utf-8", timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(len(value["first"]), 3)
        self.assertEqual(value["first"][0]["state"], "device")
        self.assertNotEqual(value["first"][0]["deviceAlias"], value["second"][0]["deviceAlias"])
        self.assertEqual(value["first"][1]["transport"], "emulator")
        self.assertNotIn("PRIVATE-USB-SERIAL", result.stdout)
        self.assertNotIn("PRIVATE-NETWORK", result.stdout)
        self.assertNotIn("emulator-5554", result.stdout)

    def test_local_adb_reader_returns_one_typed_inventory_without_task_result(self):
        helper = self.directory / "adb-result.ps1"
        helper.write_text('''$utf8=[Text.UTF8Encoding]::new($false,$true)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$tokens,[ref]$errors)
foreach($name in @('Convert-AdbInventory','Read-ExactAdbBytes','Read-LocalAdbInventory')) {
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
 Invoke-Expression $function.Extent.Text
}
$inventory=Read-LocalAdbInventory
@{isHashtable=($inventory -is [hashtable]);resultCount=@($inventory).Count;
 deviceCount=@($inventory.devices).Count;nonNullDeviceCount=@($inventory.devices|Where-Object{$null -ne $_}).Count}|ConvertTo-Json
''', encoding="utf-8")
        result = subprocess.run([PWSH, "-NoProfile", "-File", str(helper), str(SCRIPT)], capture_output=True,
                                text=True, encoding="utf-8", timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertTrue(value["isHashtable"])
        self.assertEqual(value["resultCount"], 1)
        self.assertEqual(value["deviceCount"], value["nonNullDeviceCount"])


if __name__ == "__main__":
    unittest.main()
