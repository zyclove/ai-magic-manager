"""Exercise the real provenance helper against isolated, hand-built inventories.

Removing inventory membership checks, canonical-path validation, raw-manifest
binding, or recipe checks must make these tests fail. SDKs and real Docker are
not part of this boundary. This file does not run tests when imported.
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
HELPER = ROOT / "scripts/deployment-provenance.ps1"
RECIPES = (
    "deploy/containers/backend.Dockerfile",
    "deploy/containers/edge.Dockerfile",
    "deploy/containers/keycloak.Dockerfile",
    "deploy/compose/compose.yaml",
    "deploy/compose/compose.family.yaml",
    "deploy/compose/compose.identity-admin.yaml",
    "deploy/compose/compose.identity-runtime-control.yaml",
    "deploy/compose/compose.identity-runtime-image.yaml",
    "deploy/compose/compose.tls.yaml",
    "deploy/compose/compose.external-tls.yaml",
    "deploy/edge/nginx.conf",
    "deploy/edge/http.conf",
    "deploy/edge/routes.conf",
    "deploy/edge/tls.conf",
    "deploy/edge/routes.external-tls.conf",
    "scripts/build-deployment.ps1",
    "scripts/tool-discovery.ps1",
    "scripts/start-deployment.ps1",
    "scripts/verify-deployment.ps1",
    "scripts/deployment-common.ps1",
    "scripts/family-identity-release-common.ps1",
    "scripts/initialize-erasure-ledger.ps1",
    "scripts/deployment-provenance.ps1",
    "scripts/deployment-runtime-provenance.ps1",
)
SOURCE_CONTENTS = {
    "backend/pom.xml": b"<project/>\n",
    "apps/guardian/lib/main.dart": b"void main() {}\n",
}
ARTIFACT_CONTENTS = {
    "backend/manager-backend.jar": b"fixture jar\x00\xff",
    "guardian/index.html": b"<html>fixture</html>\n",
    "guardian/main.dart.js": b"fixture javascript\n",
    "guardian/assets/icons/check.svg": b"<svg/>\n",
}


def inventory(contents):
    """Independent Python oracle; never obtain expected entries from PowerShell."""
    return [dict(path=path, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            for path, data in sorted(contents.items())]


def tree_sha(files):
    encoded = "".join(
        f"{item['path']}\0{item['bytes']}\0{item['sha256']}\n"
        for item in sorted(files, key=lambda item: item["path"])
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


class DeploymentProvenanceTest(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(PWSH, "PowerShell 7 is required")
        self.assertTrue(HELPER.is_file(), "The production provenance helper is required")
        cache = ROOT / ".cache"
        cache.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="deployment-provenance-test-", dir=cache)
        self.work = Path(self.temporary.name)
        self.repository = self.work / "repository"
        self.deployment = self.repository / ".local/deployment"
        self.release = self.deployment / "artifacts/release-0123456789abcdef0123456789abcdef"
        self.files_root = self.work / "inventory"
        self.files_root.mkdir()
        self.calls = self.work / "docker-calls.jsonl"
        self.fake_bin = self.work / "fake-bin"
        self.fake_bin.mkdir()
        if os.name == "nt":
            self.write(self.fake_bin / "docker.cmd",
                       b'@echo off\r\n>>"%PROVENANCE_TEST_DOCKER_CALLS%" echo invoked\r\nexit /b 91\r\n')
        else:
            executable = self.fake_bin / "docker"
            self.write(executable,
                       b'#!/bin/sh\nprintf "invoked\\n" >> "$PROVENANCE_TEST_DOCKER_CALLS"\nexit 91\n')
            executable.chmod(0o755)
        self.links = []
        self.recipe_contents = {path: ("# public fixture: " + path + "\n").encode() for path in RECIPES}
        for path, data in self.recipe_contents.items():
            self.write(self.repository / path, data)
        for path, data in ARTIFACT_CONTENTS.items():
            self.write(self.release / path, data)
        self.context = {
            "Root": str(self.deployment), "Repository": str(self.repository),
            "Settings": {"publicUrl": "http://localhost:18997", "consumerIdentity": False},
        }
        source_files = inventory(SOURCE_CONTENTS)
        artifact_files = inventory(ARTIFACT_CONTENTS)
        recipe_files = inventory(self.recipe_contents)
        self.manifest = {
            "schemaVersion": 1, "provenanceVersion": 1, "applicationVersion": "1.0.0",
            "publicUrl": self.context["Settings"]["publicUrl"], "consumerIdentity": False,
            "artifactRoot": self.release.relative_to(self.deployment).as_posix(),
            "source": {"kind": "content-snapshot", "revision": "sha256:" + tree_sha(source_files)},
            "sourceFiles": source_files, "sourceTreeSha256": tree_sha(source_files),
            "artifactFiles": artifact_files, "artifactTreeSha256": tree_sha(artifact_files),
            "recipeFiles": recipe_files, "recipeTreeSha256": tree_sha(recipe_files),
            "backendSha256": hashlib.sha256(ARTIFACT_CONTENTS["backend/manager-backend.jar"]).hexdigest(),
            "guardianSha256": hashlib.sha256(ARTIFACT_CONTENTS["guardian/main.dart.js"]).hexdigest(),
            "identityProviderSha256": None,
        }
        self.publish()

    def tearDown(self):
        # Every fixture and link target belongs to this one cache child.
        for link in reversed(self.links):
            if os.path.lexists(link):
                if os.name == "nt" and link.is_dir():
                    link.rmdir()
                else:
                    link.unlink()
        self.assertEqual(self.work.resolve().parent, (ROOT / ".cache").resolve())
        self.temporary.cleanup()

    @staticmethod
    def write(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def publish(self, manifest=None):
        value = self.manifest if manifest is None else manifest
        data = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")
        self.write(self.deployment / "release-manifest.json", data)
        self.write(self.release / "release-manifest.json", data)

    def invoke(self, body, files=None):
        context_file = self.work / "context.json"
        files_file = self.work / "files.json"
        context_file.write_text(json.dumps(self.context), encoding="utf-8")
        files_file.write_text(json.dumps(files if files is not None else []), encoding="utf-8")
        env = os.environ.copy()
        env.update(PROVENANCE_TEST_HELPER=str(HELPER), PROVENANCE_TEST_CONTEXT=str(context_file),
                   PROVENANCE_TEST_FILES=str(files_file), PROVENANCE_TEST_ROOT=str(self.files_root),
                   PROVENANCE_TEST_DOCKER_CALLS=str(self.calls))
        env["PATH"] = str(self.fake_bin) + os.pathsep + env.get("PATH", "")
        script = r"""
$ErrorActionPreference = 'Stop'
function docker {
    $row = @{arguments=@($args)} | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($env:PROVENANCE_TEST_DOCKER_CALLS, $row + "`n")
    throw 'Inventory and manifest reads must not invoke Docker.'
}
. $env:PROVENANCE_TEST_HELPER
foreach ($name in @('Get-DeploymentFileInventory','Get-DeploymentTreeSha256',
                    'Assert-DeploymentInventory','Read-DeploymentProvenance')) {
    [void](Get-Command $name -CommandType Function -ErrorAction Stop)
}
$context = Get-Content -LiteralPath $env:PROVENANCE_TEST_CONTEXT -Raw | ConvertFrom-Json
$files = @(Get-Content -LiteralPath $env:PROVENANCE_TEST_FILES -Raw | ConvertFrom-Json)
try {
    $value = & {
""" + body + r"""
    }
    @{ok=$true; value=$value} | ConvertTo-Json -Depth 64 -Compress
} catch {
    @{ok=$false; error=$_.Exception.Message} | ConvertTo-Json -Compress
}
"""
        result = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-Command", script],
                                cwd=ROOT, env=env, capture_output=True, text=True,
                                encoding="utf-8", timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls.exists(), "A metadata operation crossed the Docker boundary")
        return json.loads(result.stdout)

    def read(self):
        return self.invoke("$p = Read-DeploymentProvenance -Context $context; "
                           "@{Manifest=$p.Manifest; ManifestSha256=$p.ManifestSha256; "
                           "ArtifactRoot=$p.ArtifactRoot; Labels=$p.Labels}")

    def assert_rejected(self, result):
        self.assertFalse(result["ok"], result)
        self.assertTrue(result.get("error"), "Rejection must explain the invalid input")

    def assert_inventory(self, files, extra=""):
        return self.invoke("Assert-DeploymentInventory -Root $env:PROVENANCE_TEST_ROOT "
                           "-Files $files " + extra + "; @{validated=$true}", files)

    def test_inventory_records_all_files_bytes_and_hashes_in_ordinal_path_order(self):
        contents = {"z.txt": b"z", "A.txt": b"", "a dir/b.bin": b"\x00\xff", "é.txt": "é".encode()}
        for path, data in contents.items():
            self.write(self.files_root / path, data)
        result = self.invoke("@{files=@(Get-DeploymentFileInventory -Root $env:PROVENANCE_TEST_ROOT)}")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["value"]["files"], inventory(contents))

    def test_tree_digest_uses_canonical_bytes_and_does_not_depend_on_input_order(self):
        files = inventory({"b.txt": b"b", "a.txt": b"a"})
        expected = tree_sha(files)
        for entries in (files, list(reversed(files))):
            result = self.invoke("@{tree=(Get-DeploymentTreeSha256 -Files $files)}", entries)
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["value"]["tree"], expected)

    def test_generated_exclusion_keeps_real_source_and_ignores_generated_members(self):
        kept = {"backend/pom.xml": b"source", "backend/target-name.txt": b"source"}
        generated = {"backend/target/out.jar": b"generated", "app/build/out": b"generated",
                     "app/.dart_tool/config.json": b"generated", ".git/HEAD": b"generated",
                     ".local/state": b"generated", "__pycache__/cache.pyc": b"generated",
                     "app/.flutter-plugins-dependencies": b"generated",
                     "deploy/keycloak/providers/stale.jar": b"generated"}
        for path, data in {**kept, **generated}.items():
            self.write(self.files_root / path, data)
        result = self.invoke("@{files=@(Get-DeploymentFileInventory -Root $env:PROVENANCE_TEST_ROOT -ExcludeGenerated)}")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["value"]["files"], inventory(kept))
        self.assertTrue(self.assert_inventory(inventory(kept), "-ExcludeGenerated")["ok"])

    def test_relative_exclusion_removes_only_the_named_root_manifest(self):
        contents = {"release-manifest.json": b"root", "nested/release-manifest.json": b"nested"}
        for path, data in contents.items():
            self.write(self.files_root / path, data)
        result = self.invoke("@{files=@(Get-DeploymentFileInventory -Root $env:PROVENANCE_TEST_ROOT "
                             "-ExcludeRelativePaths @('release-manifest.json'))}")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["value"]["files"], inventory({"nested/release-manifest.json": b"nested"}))

    def test_assert_inventory_accepts_untouched_members_and_rejects_add_delete_or_edit(self):
        path = self.files_root / "source.txt"
        files = inventory({"source.txt": b"original"})
        self.write(path, b"original")
        self.assertTrue(self.assert_inventory(files)["ok"])
        self.write(self.files_root / "extra.txt", b"extra")
        self.assert_rejected(self.assert_inventory(files))
        (self.files_root / "extra.txt").unlink()
        path.unlink()
        self.assert_rejected(self.assert_inventory(files))
        self.write(path, b"modified")
        self.assert_rejected(self.assert_inventory(files))

    def test_tree_rejects_duplicate_and_case_colliding_inventory_paths(self):
        entry = inventory({"backend/pom.xml": b"source"})[0]
        for path in (entry["path"], "Backend/pom.xml"):
            with self.subTest(path=path):
                duplicate = dict(entry, path=path)
                self.assert_rejected(self.invoke("@{tree=(Get-DeploymentTreeSha256 -Files $files)}",
                                                 [entry, duplicate]))

    def test_tree_rejects_noncanonical_paths(self):
        paths = ("", "../outside.txt", "backend/../pom.xml", "/absolute.txt", "C:/absolute.txt",
                 "backend\\pom.xml", "backend//pom.xml", "./pom.xml", "backend/ pom.xml",
                 "backend/pom.xml ", "backend/\x01pom.xml")
        for path in paths:
            with self.subTest(path=repr(path)):
                entry = dict(path=path, bytes=1, sha256=hashlib.sha256(b"x").hexdigest())
                self.assert_rejected(self.invoke("@{tree=(Get-DeploymentTreeSha256 -Files $files)}", [entry]))

    def test_tree_rejects_missing_or_invalid_inventory_fields(self):
        original = inventory({"source.txt": b"x"})[0]
        mutations = [dict(original, bytes=value) for value in (-1, "1", 1.0, True)]
        mutations += [dict(original, sha256="0" * 63), dict(original, sha256="A" * 64)]
        mutations += [{k: v for k, v in original.items() if k != field}
                      for field in ("path", "bytes", "sha256")]
        for entry in mutations:
            with self.subTest(entry=entry):
                self.assert_rejected(self.invoke("@{tree=(Get-DeploymentTreeSha256 -Files $files)}", [entry]))

    def test_complete_manifest_reads_without_a_retained_source_copy_or_docker(self):
        result = self.read()
        self.assertTrue(result["ok"], result)
        value = result["value"]
        expected_manifest_sha = hashlib.sha256((self.deployment / "release-manifest.json").read_bytes()).hexdigest()
        self.assertEqual(value["ManifestSha256"], expected_manifest_sha)
        self.assertEqual(Path(value["ArtifactRoot"]).resolve(), self.release.resolve())
        self.assertEqual(value["Labels"], {
            "org.opencontainers.image.revision": self.manifest["source"]["revision"],
            "org.opencontainers.image.version": "1.0.0",
            "com.aimanager.release.manifest-sha256": expected_manifest_sha,
            "com.aimanager.release.source-tree-sha256": self.manifest["sourceTreeSha256"],
            "com.aimanager.release.artifact-tree-sha256": self.manifest["artifactTreeSha256"],
        })

    def test_legacy_settings_without_consumer_mode_still_mean_management_mode(self):
        del self.context["Settings"]["consumerIdentity"]
        self.assertTrue(self.read()["ok"])

    def test_artifact_additions_deletions_and_edits_reject_index_asset_and_jar(self):
        for path in ("guardian/index.html", "guardian/assets/icons/check.svg", "backend/manager-backend.jar"):
            original = ARTIFACT_CONTENTS[path]
            for operation in ("add", "delete", "modify"):
                with self.subTest(path=path, operation=operation):
                    target = self.release / path
                    extra = target.with_name("unexpected-" + target.name)
                    if operation == "add":
                        self.write(extra, b"unreviewed")
                    elif operation == "delete":
                        target.unlink()
                    else:
                        self.write(target, b"tampered")
                    self.assert_rejected(self.read())
                    if extra.exists():
                        extra.unlink()
                    self.write(target, original)

    def test_nested_release_manifest_is_an_artifact_member_not_an_excluded_root_file(self):
        self.write(self.release / "guardian/release-manifest.json", b"nested")
        self.assert_rejected(self.read())

    def test_recipe_edit_and_deletion_are_rejected(self):
        for path in ("deploy/containers/backend.Dockerfile", "deploy/edge/routes.conf",
                     "scripts/start-deployment.ps1", "scripts/tool-discovery.ps1"):
            for operation in ("delete", "modify"):
                with self.subTest(path=path, operation=operation):
                    target = self.repository / path
                    if operation == "delete":
                        target.unlink()
                    else:
                        self.write(target, b"tampered recipe")
                    self.assert_rejected(self.read())
                    self.write(target, self.recipe_contents[path])

    def test_unapproved_recipe_cannot_be_added_even_with_a_matching_tree_digest(self):
        path = "deploy/edge/unreviewed.conf"
        self.write(self.repository / path, b"unreviewed")
        manifest = copy.deepcopy(self.manifest)
        manifest["recipeFiles"] += inventory({path: b"unreviewed"})
        manifest["recipeTreeSha256"] = tree_sha(manifest["recipeFiles"])
        self.publish(manifest)
        self.assert_rejected(self.read())

    def test_missing_provenance_fields_never_fall_back_to_the_old_manifest(self):
        for field in self.manifest:
            with self.subTest(field=field):
                manifest = copy.deepcopy(self.manifest)
                del manifest[field]
                self.publish(manifest)
                self.assert_rejected(self.read())

    def test_real_start_rejects_missing_provenance_version_before_any_docker_event(self):
        # Copy only public entry-point dependencies so its real .local boundary
        # is exercised inside this cache fixture, never a live deployment.
        dependencies = ("start-deployment.ps1", "deployment-common.ps1",
                        "family-identity-release-common.ps1", "deployment-provenance.ps1",
                        "deployment-runtime-provenance.ps1")
        for name in dependencies:
            path = "scripts/" + name
            data = (ROOT / path).read_bytes()
            self.write(self.repository / path, data)
            if path in self.recipe_contents:
                self.recipe_contents[path] = data
        settings = dict(self.context["Settings"], schemaVersion=1,
                        projectName="provenance-fixture-" + self.work.name.rsplit("-", 1)[-1])
        self.write(self.deployment / "deployment.json", json.dumps(settings).encode())
        environment = b"# synthetic test environment; no credentials\n"
        self.write(self.deployment / ".env", environment)
        (self.deployment / "secrets").mkdir()
        manifest = copy.deepcopy(self.manifest)
        manifest["recipeFiles"] = inventory(self.recipe_contents)
        manifest["recipeTreeSha256"] = tree_sha(manifest["recipeFiles"])
        del manifest["provenanceVersion"]
        self.publish(manifest)
        result = self.invoke("& (Join-Path $context.Repository 'scripts/start-deployment.ps1') "
                             "-Directory $context.Root; @{started=$true}")
        self.assert_rejected(result)
        self.assertIn("provenance field is missing", result["error"].lower())
        self.assertEqual((self.deployment / ".env").read_bytes(), environment)
        self.assertFalse((self.deployment / "release-runtime.json").exists())

    def test_source_digest_and_revision_cannot_be_forged_independently(self):
        for mutation in ("file", "tree", "revision", "kind"):
            with self.subTest(mutation=mutation):
                manifest = copy.deepcopy(self.manifest)
                if mutation == "file":
                    manifest["sourceFiles"][0]["sha256"] = "0" * 64
                elif mutation == "tree":
                    manifest["sourceTreeSha256"] = "0" * 64
                elif mutation == "revision":
                    manifest["source"]["revision"] = "sha256:" + "0" * 64
                else:
                    manifest["source"]["kind"] = "git-working-tree"
                self.publish(manifest)
                self.assert_rejected(self.read())

    def test_source_inventory_duplicate_and_traversal_are_rejected_after_rehashing(self):
        for path in ("backend/pom.xml", "Backend/pom.xml", "../outside.txt"):
            with self.subTest(path=path):
                manifest = copy.deepcopy(self.manifest)
                manifest["sourceFiles"].append(dict(manifest["sourceFiles"][0], path=path))
                manifest["sourceTreeSha256"] = tree_sha(manifest["sourceFiles"])
                manifest["source"]["revision"] = "sha256:" + manifest["sourceTreeSha256"]
                self.publish(manifest)
                self.assert_rejected(self.read())

    def test_artifact_and_recipe_tree_digests_must_match_their_inventories(self):
        for field in ("artifactTreeSha256", "recipeTreeSha256", "backendSha256", "guardianSha256"):
            with self.subTest(field=field):
                manifest = copy.deepcopy(self.manifest)
                manifest[field] = "0" * 64
                self.publish(manifest)
                self.assert_rejected(self.read())

    def test_manifest_origin_versions_mode_and_artifact_root_are_bound(self):
        cases = (("schemaVersion", 2), ("provenanceVersion", 0), ("applicationVersion", "2.0.0"),
                 ("publicUrl", "http://localhost:18998"), ("consumerIdentity", "false"),
                 ("consumerIdentity", True), ("artifactRoot", "../outside"),
                 ("artifactRoot", str(self.release)), ("identityProviderSha256", "0" * 64))
        for field, value in cases:
            with self.subTest(field=field, value=value):
                manifest = copy.deepcopy(self.manifest)
                manifest[field] = value
                self.publish(manifest)
                self.assert_rejected(self.read())

    def test_root_and_release_manifest_must_have_identical_raw_bytes(self):
        equivalent_json = json.dumps(self.manifest, sort_keys=True, indent=4).encode()
        self.write(self.release / "release-manifest.json", equivalent_json)
        self.assert_rejected(self.read())

    def make_link(self, link, target):
        try:
            link.symlink_to(target, target_is_directory=target.is_dir())
        except (OSError, NotImplementedError) as error:
            self.skipTest("This host cannot create the reparse fixture: " + type(error).__name__)
        self.links.append(link)

    def test_inventory_rejects_file_reparse_points(self):
        target = self.work / "link-target.txt"
        self.write(target, b"outside inventory")
        self.make_link(self.files_root / "linked.txt", target)
        self.assert_rejected(self.invoke("@{files=@(Get-DeploymentFileInventory -Root $env:PROVENANCE_TEST_ROOT)}"))

    def test_generated_directory_reparse_point_is_rejected_before_exclusion(self):
        target = self.work / "link-target-directory"
        target.mkdir()
        self.make_link(self.files_root / "build", target)
        self.assert_rejected(self.invoke("@{files=@(Get-DeploymentFileInventory -Root $env:PROVENANCE_TEST_ROOT -ExcludeGenerated)}"))

    def test_release_artifact_reparse_is_rejected_even_when_bytes_match(self):
        target = self.work / "matching-index.html"
        self.write(target, ARTIFACT_CONTENTS["guardian/index.html"])
        index = self.release / "guardian/index.html"
        index.unlink()
        self.make_link(index, target)
        self.assert_rejected(self.read())


if __name__ == "__main__":
    unittest.main()
