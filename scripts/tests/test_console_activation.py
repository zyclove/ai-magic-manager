"""Validate console selection metadata using local fixtures, without Docker.

Run with Python 3 and PowerShell 7 on PATH. The production helper is dot-sourced;
only isolated files under this repository's ignored .local directory are used.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PWSH = shutil.which("pwsh")
MODULE = ROOT / "scripts/console-activation.ps1"
SELECTION_FIELDS = {
    "schemaVersion", "state", "project", "publicUrl", "sourceDirectory",
    "deploymentDirectory", "releaseManifestSha256", "activationReceipt",
    "activationReceiptSha256",
}


class ConsoleActivationTest(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(PWSH, "PowerShell 7 is required")
        local = ROOT / ".local"
        local.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(
            prefix="console-activation-test-", dir=local,
        )
        self.root = Path(self.temporary.name) / "repository"
        self.local = self.root / ".local"
        self.source = self.local / "source-release"
        self.deployment = self.source / ".local/deployment"
        self.deployment.mkdir(parents=True)
        self.manifest_path = self.deployment / "release-manifest.json"
        self.settings_path = self.deployment / "deployment.json"
        self.receipt_path = self.local / "runtime/activation.json"
        self.pointer_path = self.local / "console-active.json"
        self.intent_path = self.local / "console-activation-intent.json"
        self.write_json(self.manifest_path, {
            "schemaVersion": 1,
            "publicUrl": "http://localhost:18101",
            "artifactRoot": "artifacts/release-0123456789abcdef0123456789abcdef",
        })
        self.settings = {
            "schemaVersion": 1,
            "projectName": "aimanager-v1-fixture",
            "publicUrl": "http://localhost:18101",
            "repositoryRoot": str(self.source),
        }
        self.write_json(self.settings_path, self.settings)
        self.receipt = {
            "schemaVersion": 1,
            "state": "COMMITTED",
            "project": "aimanager-v1-fixture",
            "publicUrl": "http://localhost:18101",
            "sourceDirectory": str(self.source),
            "deploymentDirectory": str(self.deployment),
            "releaseManifestSha256": self.sha(self.manifest_path),
        }
        self.write_json(self.receipt_path, self.receipt)
        self.pointer = {
            **self.receipt,
            "activationReceipt": str(self.receipt_path),
            "activationReceiptSha256": self.sha(self.receipt_path),
        }
        self.write_pointer()

    def tearDown(self):
        # tempfile owns exactly this newly-created ignored directory.
        self.assertEqual(Path(self.temporary.name).resolve().parent,
                         (ROOT / '.local').resolve())
        self.temporary.cleanup()

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def write_json(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")

    def write_pointer(self):
        self.write_json(self.pointer_path, self.pointer)

    def write_receipt(self):
        self.write_json(self.receipt_path, self.receipt)
        self.pointer["activationReceiptSha256"] = self.sha(self.receipt_path)
        self.write_pointer()

    def invoke(self, locked_path=None):
        environment = os.environ.copy()
        environment["CONSOLE_ACTIVATION_TEST_MODULE"] = str(MODULE)
        environment["CONSOLE_ACTIVATION_TEST_ROOT"] = str(self.root)
        environment.pop("CONSOLE_ACTIVATION_TEST_LOCK", None)
        if locked_path is not None:
            environment["CONSOLE_ACTIVATION_TEST_LOCK"] = str(locked_path)
        command = r"""
$ErrorActionPreference = 'Stop'
function docker { throw 'A metadata selection must not invoke Docker.' }
$locked = $null
try {
    if ($env:CONSOLE_ACTIVATION_TEST_LOCK) {
        $locked = [IO.File]::Open($env:CONSOLE_ACTIVATION_TEST_LOCK,
            [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    . $env:CONSOLE_ACTIVATION_TEST_MODULE
    $selection = Get-ActiveConsoleSelection -RepositoryRoot $env:CONSOLE_ACTIVATION_TEST_ROOT
    @{ok=$true; selection=$selection} | ConvertTo-Json -Depth 20 -Compress
} catch {
    @{ok=$false; error=$_.Exception.Message} | ConvertTo-Json -Compress
} finally {
    if ($null -ne $locked) { $locked.Dispose() }
}
"""
        result = subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-Command", command],
            cwd=ROOT, env=environment, capture_output=True, text=True,
            encoding="utf-8", timeout=20,
        )
        self.assertEqual(result.returncode, 0, "Metadata helper did not terminate normally")
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.fail("Metadata helper did not emit one JSON result")
        self.assertEqual(result.stderr, "", "Metadata helper wrote unexpected diagnostics")
        return payload

    def rejected(self):
        result = self.invoke()
        self.assertFalse(result["ok"], "Unverified metadata was accepted")
        self.assertIsInstance(result.get("error"), str)
        self.assertTrue(result["error"], "A rejected selection needs an actionable error")

    def test_missing_pointer_returns_none_for_legacy_launcher(self):
        self.pointer_path.unlink()
        result = self.invoke()
        self.assertTrue(result["ok"])
        self.assertIsNone(result["selection"])

    def test_verified_selection_returns_only_safe_fields_without_writes(self):
        self.pointer["untrustedExtra"] = "synthetic-sensitive-marker"
        self.receipt["untrustedExtra"] = "synthetic-sensitive-marker"
        self.write_receipt()
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        result = self.invoke()
        self.assertTrue(result["ok"], "A fully verified selection was rejected")
        selection = result["selection"]
        self.assertIsInstance(selection, dict, "A committed selection was not returned")
        self.assertEqual(set(selection), SELECTION_FIELDS)
        self.assertEqual(selection["project"], "aimanager-v1-fixture")
        self.assertEqual(selection["publicUrl"], "http://localhost:18101")
        self.assertEqual(Path(selection["sourceDirectory"]), self.source)
        self.assertEqual(Path(selection["deploymentDirectory"]), self.deployment)
        self.assertEqual(Path(selection["activationReceipt"]), self.receipt_path)
        self.assertNotIn("synthetic-sensitive-marker", json.dumps(result))
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()})

    def test_repository_relative_paths_are_returned_as_verified_absolute_paths(self):
        self.pointer["sourceDirectory"] = ".local/source-release"
        self.pointer["deploymentDirectory"] = ".local/source-release/.local/deployment"
        self.pointer["activationReceipt"] = ".local/runtime/activation.json"
        self.receipt["sourceDirectory"] = self.pointer["sourceDirectory"]
        self.receipt["deploymentDirectory"] = self.pointer["deploymentDirectory"]
        self.write_receipt()
        result = self.invoke()
        self.assertTrue(result["ok"])
        self.assertIsInstance(result["selection"], dict)
        self.assertEqual(Path(result["selection"]["sourceDirectory"]), self.source)
        self.assertEqual(Path(result["selection"]["deploymentDirectory"]), self.deployment)
        self.assertEqual(Path(result["selection"]["activationReceipt"]), self.receipt_path)

    def test_valid_selection_needs_no_environment_or_secret_files(self):
        self.assertFalse((self.deployment / ".env").exists())
        self.assertFalse((self.deployment / "secrets").exists())
        result = self.invoke()
        self.assertTrue(result["ok"])
        self.assertIsNotNone(result["selection"])

    def assert_protected_receipt_not_read(self, path):
        # The full receipt is valid and hash-bound. An exclusive handle denies
        # byte reads, so only rejection before IO can produce the path error.
        self.receipt["syntheticPrivateMaterial"] = "synthetic-sensitive-marker"
        self.write_json(path, self.receipt)
        self.pointer["activationReceipt"] = str(path)
        self.pointer["activationReceiptSha256"] = self.sha(path)
        self.write_pointer()
        result = self.invoke(locked_path=path)
        self.assertFalse(result["ok"], "A protected metadata path was accepted")
        self.assertIn("CONSOLE_ACTIVATION_PROTECTED_PATH", result.get("error", ""),
                      "A protected metadata path was not rejected before attempting a read")
        self.assertFalse("synthetic-sensitive-marker" in json.dumps(result),
                         "Sensitive fixture material appeared in output")

    def test_secrets_receipt_is_rejected_before_any_byte_read(self):
        self.assert_protected_receipt_not_read(self.deployment / "secrets/activation.json")

    def test_environment_and_alternate_stream_receipts_are_rejected_before_read(self):
        self.assert_protected_receipt_not_read(self.deployment / ".env")
        if os.name == "nt":
            carrier = self.deployment / "carrier.json"
            carrier.write_bytes(b"fixture carrier")
            with self.subTest(kind="alternate-data-stream"):
                self.assert_protected_receipt_not_read(Path(str(carrier) + ":activation.json"))

    def test_pointer_must_have_integer_schema_one_and_committed_state(self):
        original = copy.deepcopy(self.pointer)
        for field, values in (
            ("schemaVersion", (None, 0, 2, True, "1", 1.0)),
            ("state", (None, "PREPARED", "ROLLED_BACK", "committed", "COMMITTED\n")),
        ):
            for value in values:
                with self.subTest(field=field, value=value):
                    self.pointer = {**original, field: value}
                    self.write_pointer()
                    self.rejected()

    def test_each_selection_binding_is_required(self):
        original = copy.deepcopy(self.pointer)
        for field in SELECTION_FIELDS:
            with self.subTest(field=field):
                self.pointer = copy.deepcopy(original)
                del self.pointer[field]
                self.write_pointer()
                self.rejected()

    def test_pointer_rejects_non_object_invalid_json_and_duplicate_bindings(self):
        duplicated = json.dumps(self.pointer)[:-1] + ', "project": "aimanager-v1-fixture"}'
        for raw in ("[]", "null", "not json", duplicated):
            with self.subTest(raw=raw):
                self.pointer_path.write_text(raw, encoding="utf-8")
                self.rejected()

    def test_project_and_public_url_must_be_safe_values(self):
        original_pointer = copy.deepcopy(self.pointer)
        original_receipt = copy.deepcopy(self.receipt)
        original_settings = copy.deepcopy(self.settings)
        original_manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        for field, values in (
            ("project", ("", "Project", "../project", "project\n", 7)),
            ("publicUrl", ("", "http://u:p@localhost:18101", "http://localhost:18101/path",
                           "http://localhost:18101?x=1", "http://localhost:18101#part", 7)),
        ):
            for value in values:
                with self.subTest(field=field, value=value):
                    self.pointer = {**original_pointer, field: value}
                    self.receipt = {**original_receipt, field: value}
                    mapped = "projectName" if field == "project" else "publicUrl"
                    self.write_json(self.settings_path, {**original_settings, mapped: value})
                    manifest = copy.deepcopy(original_manifest)
                    if field == "publicUrl":
                        manifest["publicUrl"] = value
                    self.write_json(self.manifest_path, manifest)
                    manifest_hash = self.sha(self.manifest_path)
                    self.pointer["releaseManifestSha256"] = manifest_hash
                    self.receipt["releaseManifestSha256"] = manifest_hash
                    self.write_receipt()
                    self.rejected()

    def test_settings_project_origin_and_source_root_must_match(self):
        original = copy.deepcopy(self.settings)
        changes = (
            ("schemaVersion", 2), ("projectName", "another-project"),
            ("publicUrl", "http://localhost:18102"),
            ("repositoryRoot", str(self.root)),
            ("repositoryRoot", str(self.local / "another-source")),
        )
        for field, value in changes:
            with self.subTest(field=field, value=value):
                self.write_json(self.settings_path, {**original, field: value})
                self.rejected()

    def test_settings_source_root_is_required(self):
        del self.settings["repositoryRoot"]
        self.write_json(self.settings_path, self.settings)
        self.rejected()

    def test_manifest_bytes_must_match_the_committed_hash(self):
        self.manifest_path.write_bytes(self.manifest_path.read_bytes() + b"\n")
        self.rejected()

    def test_receipt_bytes_must_match_the_committed_hash(self):
        self.receipt_path.write_bytes(self.receipt_path.read_bytes() + b"\n")
        self.rejected()

    def test_hashes_require_full_lowercase_sha256(self):
        original = copy.deepcopy(self.pointer)
        for field in ("releaseManifestSha256", "activationReceiptSha256"):
            for value in ("0" * 63, "0" * 65, "G" * 64, "A" * 64, "0" * 64 + "\n", None, 5):
                with self.subTest(field=field, value=value):
                    self.pointer = {**original, field: value}
                    self.write_pointer()
                    self.rejected()

    def test_receipt_bindings_match_even_when_receipt_hash_is_updated(self):
        original = copy.deepcopy(self.receipt)
        changes = (
            ("schemaVersion", 2), ("state", "PREPARED"),
            ("project", "another-project"), ("publicUrl", "http://localhost:18102"),
            ("sourceDirectory", str(self.local / "another-source")),
            ("deploymentDirectory", str(self.local / "another-deployment")),
            ("releaseManifestSha256", "0" * 64),
        )
        for field, value in changes:
            with self.subTest(field=field, value=value):
                self.receipt = {**original, field: value}
                self.write_receipt()
                self.rejected()

    def test_missing_or_invalid_local_evidence_is_rejected(self):
        for path in (self.manifest_path, self.settings_path, self.receipt_path):
            original = path.read_bytes()
            with self.subTest(path=path.name, state="missing"):
                path.unlink()
                self.rejected()
            path.write_bytes(original)
            with self.subTest(path=path.name, state="invalid-json"):
                path.write_text("not json", encoding="utf-8")
                if path == self.receipt_path:
                    self.pointer["activationReceiptSha256"] = self.sha(path)
                    self.write_pointer()
                elif path == self.manifest_path:
                    self.pointer["releaseManifestSha256"] = self.sha(path)
                    self.receipt["releaseManifestSha256"] = self.sha(path)
                    self.write_receipt()
                self.rejected()
            path.write_bytes(original)
            self.pointer["releaseManifestSha256"] = self.sha(self.manifest_path)
            self.receipt["releaseManifestSha256"] = self.pointer["releaseManifestSha256"]
            self.write_receipt()

    def test_source_deployment_and_receipt_cannot_escape_local_boundary(self):
        original = copy.deepcopy(self.pointer)
        for field in ("sourceDirectory", "deploymentDirectory", "activationReceipt"):
            for value in (str(self.root / "outside"), str(self.root / ".local-other/escape"),
                          ".local/../../outside", ".local/../outside"):
                with self.subTest(field=field, value=value):
                    self.pointer = {**original, field: value}
                    self.write_pointer()
                    self.rejected()

    def test_outside_local_source_is_rejected_with_otherwise_matching_evidence(self):
        outside = self.root / ".local-other/source-release"
        shutil.copytree(self.source, outside)
        outside_deployment = outside / ".local/deployment"
        self.write_json(outside_deployment / "deployment.json", {
            **self.settings, "repositoryRoot": str(outside),
        })
        self.pointer["sourceDirectory"] = str(outside)
        self.pointer["deploymentDirectory"] = str(outside_deployment)
        self.receipt["sourceDirectory"] = str(outside)
        self.receipt["deploymentDirectory"] = str(outside_deployment)
        self.write_receipt()
        self.rejected()

    def test_deployment_is_exactly_the_selected_sources_local_deployment(self):
        alternative = self.source / ".local/another-deployment"
        shutil.copytree(self.deployment, alternative)
        self.pointer["deploymentDirectory"] = str(alternative)
        self.receipt["deploymentDirectory"] = str(alternative)
        self.write_receipt()
        self.rejected()

    def test_source_directory_and_evidence_files_have_the_correct_file_kind(self):
        self.pointer["sourceDirectory"] = str(self.manifest_path)
        self.write_pointer()
        self.rejected()

    def make_directory_link(self, link, target):
        if os.name != "nt":
            os.symlink(target, link, target_is_directory=True)
            return
        environment = os.environ.copy()
        environment["CONSOLE_ACTIVATION_TEST_LINK"] = str(link)
        environment["CONSOLE_ACTIVATION_TEST_TARGET"] = str(target)
        result = subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-Command",
             "$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path "
             "$env:CONSOLE_ACTIVATION_TEST_LINK -Target "
             "$env:CONSOLE_ACTIVATION_TEST_TARGET | Out-Null"],
            env=environment, capture_output=True, text=True, encoding="utf-8", timeout=20,
        )
        self.assertEqual(result.returncode, 0, "Could not create the bounded reparse fixture")

    def test_source_reparse_point_is_rejected_even_when_its_target_is_local(self):
        moved = self.local / "real-source"
        self.source.rename(moved)
        self.make_directory_link(self.source, moved)
        self.rejected()

    def test_local_root_reparse_point_is_rejected(self):
        moved = self.root / "real-local"
        self.local.rename(moved)
        self.make_directory_link(self.local, moved)
        self.rejected()

    def test_receipt_parent_reparse_point_is_rejected(self):
        moved = self.local / "real-runtime"
        self.receipt_path.parent.rename(moved)
        self.make_directory_link(self.receipt_path.parent, moved)
        self.rejected()

    def test_prepared_intent_blocks_both_pointer_and_legacy_fallback(self):
        self.write_json(self.intent_path, {**self.pointer, "state": "PREPARED"})
        self.rejected()
        self.pointer_path.unlink()
        self.rejected()

    def test_committed_intent_must_match_every_current_pointer_binding(self):
        self.write_json(self.intent_path, self.pointer)
        result = self.invoke()
        self.assertTrue(result["ok"])
        self.assertIsNotNone(result["selection"])
        changes = {
            "project": "another-project", "publicUrl": "http://localhost:18102",
            "sourceDirectory": ".local/another-source",
            "deploymentDirectory": ".local/another-deployment",
            "releaseManifestSha256": "0" * 64,
            "activationReceipt": ".local/runtime/another-receipt.json",
            "activationReceiptSha256": "0" * 64,
        }
        for field, value in changes.items():
            with self.subTest(field=field):
                self.write_json(self.intent_path, {**self.pointer, field: value})
                self.rejected()

    def test_committed_intent_cannot_fall_back_to_legacy_without_its_pointer(self):
        self.write_json(self.intent_path, self.pointer)
        self.pointer_path.unlink()
        self.rejected()

    def test_rolled_back_intent_allows_verified_old_pointer_or_legacy(self):
        self.write_json(self.intent_path, {
            **self.pointer, "state": "ROLLED_BACK", "project": "failed-candidate",
        })
        result = self.invoke()
        self.assertTrue(result["ok"])
        self.assertIsNotNone(result["selection"])
        self.pointer_path.unlink()
        result = self.invoke()
        self.assertTrue(result["ok"])
        self.assertIsNone(result["selection"])

    def test_invalid_intent_does_not_fall_back_to_pointer_or_legacy(self):
        invalid = ("not json", "[]", "null", {"schemaVersion": 2, "state": "ROLLED_BACK"},
                   {"schemaVersion": 1, "state": "UNKNOWN"},
                   {"schemaVersion": 1, "state": "rolled_back"})
        for value in invalid:
            with self.subTest(value=value):
                if isinstance(value, str):
                    self.intent_path.write_text(value, encoding="utf-8")
                else:
                    self.write_json(self.intent_path, value)
                self.rejected()
        self.pointer_path.unlink()
        self.rejected()


if __name__ == "__main__":
    unittest.main()
