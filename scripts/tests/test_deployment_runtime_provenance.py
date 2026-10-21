"""Exercise runtime provenance with controlled Docker metadata, never a daemon.

Only the Docker transport is replaced. The real image binding and receipt
functions run against isolated fixtures under the repository's ignored .cache.
Full application/SDK and deployment verification remain separate release gates.
"""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PWSH = shutil.which("pwsh")
HELPER = ROOT / "scripts/deployment-runtime-provenance.ps1"
PROJECT = "runtime-fixture"
ORIGIN = "http://localhost:18101"
BACKEND = "a" * 64
EDGE = "b" * 64
BACKEND_IMAGE = "sha256:" + "1" * 64
EDGE_IMAGE = "sha256:" + "2" * 64
MANIFEST_SHA = "3" * 64
SOURCE_SHA = "4" * 64
ARTIFACT_SHA = "5" * 64
LABELS = {
    "org.opencontainers.image.revision": "sha256:" + SOURCE_SHA,
    "org.opencontainers.image.version": "1.0.0",
    "com.aimanager.release.manifest-sha256": MANIFEST_SHA,
    "com.aimanager.release.source-tree-sha256": SOURCE_SHA,
    "com.aimanager.release.artifact-tree-sha256": ARTIFACT_SHA,
}

WRAPPER = r'''
param([string]$Helper, [string]$Fixture, [string]$Deployment, [string]$Action)
$ErrorActionPreference = 'Stop'
. $Helper
$script:fixtureData = Get-Content -LiteralPath $Fixture -Raw | ConvertFrom-Json -AsHashtable -Depth 16
$script:dockerCalls = [Collections.Generic.List[object]]::new()
function Invoke-DeploymentProvenanceDocker {
    param([string[]]$Arguments, [int]$TimeoutSeconds)
    $script:dockerCalls.Add(@($Arguments))
    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 15) { throw 'Unexpected inspection timeout.' }
    if ($Arguments[0] -ceq 'compose') {
        if (($Arguments[-5..-1] -join '|') -cne 'ps|--all|--quiet|backend|edge') { throw 'Unexpected Compose inspection.' }
        return $script:fixtureData.ids -join "`n"
    }
    if ($Arguments[0] -ceq 'container' -and $Arguments[1] -ceq 'inspect' -and $Arguments[2] -ceq '--format') {
        if (-not $script:fixtureData.containers.Contains($Arguments[-1])) { throw 'Unknown fixture container.' }
        return $script:fixtureData.containers[$Arguments[-1]] | ConvertTo-Json -Depth 8 -Compress
    }
    if ($Arguments[0] -ceq 'image' -and $Arguments[1] -ceq 'inspect' -and
        $Arguments[2] -ceq '--format' -and $Arguments[3] -ceq '{{json .Config.Labels}}') {
        if (-not $script:fixtureData.images.Contains($Arguments[-1])) { throw 'Unknown fixture image.' }
        return $script:fixtureData.images[$Arguments[-1]] | ConvertTo-Json -Depth 8 -Compress
    }
    throw 'Unexpected Docker command; real Docker is forbidden.'
}
$context = @{ Root=$Deployment; Repository=$script:fixtureData.repository; Settings=@{
    publicUrl=$script:fixtureData.origin; externalTlsProxy=$script:fixtureData.externalTlsProxy} }
$provenance = @{ ManifestSha256=$script:fixtureData.manifestSha256; Manifest=@{
    applicationVersion='1.0.0'; sourceTreeSha256=$script:fixtureData.sourceTreeSha256;
    artifactTreeSha256=$script:fixtureData.artifactTreeSha256 }; Labels=$script:fixtureData.labels }
try {
    $bindings = @(Get-DeploymentImageBindings -Context $context -ComposeArguments @('compose','--project-name',$script:fixtureData.project) `
        -Project $script:fixtureData.project -Labels $script:fixtureData.labels)
    switch ($Action) {
        'bindings' { }
        'write' { Write-DeploymentRuntimeReceipt -Context $context -Provenance $provenance -Bindings $bindings -Project $script:fixtureData.project }
        'assert' { Assert-DeploymentRuntimeReceipt -Context $context -Provenance $provenance -Bindings $bindings -Project $script:fixtureData.project }
        default { throw 'Unknown fixture action.' }
    }
    [ordered]@{ok=$true; bindings=$bindings; calls=@($script:dockerCalls.ToArray())} | ConvertTo-Json -Depth 12 -Compress
} catch {
    [ordered]@{ok=$false; error=$_.Exception.Message; calls=@($script:dockerCalls.ToArray())} | ConvertTo-Json -Depth 12 -Compress
    exit 1
}
'''


class DeploymentRuntimeProvenanceTest(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(PWSH, "PowerShell 7 is required")
        self.cache = ROOT / ".cache"
        self.cache.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="deployment-runtime-test-", dir=self.cache)
        self.directory = Path(self.temporary.name)
        self.deployment = self.directory / "deployment"
        self.deployment.mkdir()
        self.receipt_path = self.deployment / "release-runtime.json"
        self.wrapper = self.directory / "invoke.ps1"
        self.wrapper.write_text(WRAPPER, encoding="utf-8")
        self.fixture_path = self.directory / "fixture.json"
        self.fixture = {
            "project": PROJECT, "origin": ORIGIN, "labels": copy.deepcopy(LABELS),
            "repository": str(ROOT), "externalTlsProxy": False,
            "manifestSha256": MANIFEST_SHA, "sourceTreeSha256": SOURCE_SHA,
            "artifactTreeSha256": ARTIFACT_SHA, "ids": [BACKEND, EDGE],
            "containers": {
                BACKEND: self.container(BACKEND, "backend", BACKEND_IMAGE),
                EDGE: self.container(EDGE, "edge", EDGE_IMAGE),
            },
            "images": {BACKEND_IMAGE: copy.deepcopy(LABELS), EDGE_IMAGE: copy.deepcopy(LABELS)},
        }

    def tearDown(self):
        # This is the exact disposable fixture created by this test; no user
        # sources, links, service directories or delivery evidence are stored here.
        self.assertFalse(self.directory.is_symlink())
        self.assertEqual(self.directory.resolve().parent, self.cache.resolve())
        self.temporary.cleanup()

    @staticmethod
    def container(container_id, service, image_id):
        return {"id": container_id, "imageId": image_id, "running": True,
                "health": "healthy", "project": PROJECT, "service": service, "oneoff": "False",
                "mounts": DeploymentRuntimeProvenanceTest.edge_mounts() if service == "edge" else [
                    {"type": "tmpfs", "source": "", "destination": "/tmp", "rw": True}]}

    @staticmethod
    def edge_mounts(https=False, external=False):
        public = {
            "/etc/nginx/nginx.conf": "nginx.conf",
            "/etc/nginx/conf.d/default.conf": "tls.conf" if https and not external else "http.conf",
            "/etc/nginx/includes/routes.conf": "routes.external-tls.conf" if external else "routes.conf",
        }
        return [{"type": "bind", "source": str(ROOT / "deploy/edge" / name),
                 "destination": target, "rw": False} for target, name in public.items()] + [
            {"type": "tmpfs", "source": "", "destination": "/tmp", "rw": True},
            {"type": "tmpfs", "source": "", "destination": "/var/cache/nginx", "rw": True},
        ]

    @staticmethod
    def receipt():
        # This expected receipt is constructed independently of the production
        # writer so a shared writer/reader mistake cannot bless negative cases.
        return {
            "schemaVersion": 1, "manifestSha256": MANIFEST_SHA,
            "applicationVersion": "1.0.0", "publicUrl": ORIGIN, "project": PROJECT,
            "sourceTreeSha256": SOURCE_SHA, "artifactTreeSha256": ARTIFACT_SHA,
            "createdAt": "2026-10-21T04:30:00.0000000+00:00",
            "services": {"backend": {"imageId": BACKEND_IMAGE, "containerIds": [BACKEND]},
                         "edge": {"imageId": EDGE_IMAGE, "containerIds": [EDGE]}},
        }

    def write_receipt(self, receipt=None):
        self.receipt_path.write_text(json.dumps(self.receipt() if receipt is None else receipt), encoding="utf-8")

    def invoke(self, action="bindings", success=True):
        self.fixture_path.write_text(json.dumps(self.fixture), encoding="utf-8")
        completed = subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-File", str(self.wrapper),
             "-Helper", str(HELPER), "-Fixture", str(self.fixture_path),
             "-Deployment", str(self.deployment), "-Action", action],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=20)
        self.assertEqual(completed.returncode == 0, success, completed.stdout + completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result["ok"], success, result)
        return result

    def test_binds_actual_image_ids_and_reads_image_labels(self):
        result = self.invoke()
        self.assertEqual(result["bindings"], [
            {"service": "backend", "imageId": BACKEND_IMAGE, "containerIds": [BACKEND]},
            {"service": "edge", "imageId": EDGE_IMAGE, "containerIds": [EDGE]},
        ])
        calls = result["calls"]
        self.assertEqual(calls[0], ["compose", "--project-name", PROJECT, "ps", "--all", "--quiet", "backend", "edge"])
        image_calls = [call for call in calls if call[0] == "image"]
        self.assertEqual(image_calls, [
            ["image", "inspect", "--format", "{{json .Config.Labels}}", BACKEND_IMAGE],
            ["image", "inspect", "--format", "{{json .Config.Labels}}", EDGE_IMAGE],
        ])
        for call in (call for call in calls if call[0] == "container"):
            self.assertNotIn("{{json .Config}}", call[3])
            self.assertNotIn("{{json .}}", call[3])
        self.assertFalse(self.receipt_path.exists())

    def test_all_replicas_with_same_service_image_are_allowed(self):
        replica = "c" * 64
        self.fixture["ids"].insert(0, replica)
        self.fixture["containers"][replica] = self.container(replica, "backend", BACKEND_IMAGE)
        result = self.invoke()
        self.assertEqual(result["bindings"][0]["containerIds"], [BACKEND, replica])
        self.assertEqual(len([call for call in result["calls"] if call[0] == "image"]), 2)

    def test_image_labels_are_mandatory_even_when_containers_are_healthy(self):
        original = copy.deepcopy(self.fixture["images"][BACKEND_IMAGE])
        for change in ("wrong", "missing", "wrong_case"):
            with self.subTest(change=change):
                labels = copy.deepcopy(original)
                key = "com.aimanager.release.manifest-sha256"
                if change == "wrong":
                    labels[key] = "f" * 64
                elif change == "missing":
                    del labels[key]
                else:
                    labels[key.upper()] = labels.pop(key)
                self.fixture["images"][BACKEND_IMAGE] = labels
                result = self.invoke(success=False)
                self.assertIn("image provenance", result["error"])
                self.assertTrue(any(call[0] == "image" for call in result["calls"]))
                self.assertFalse(self.receipt_path.exists())

    def test_image_change_is_rejected_even_with_same_valid_release_labels(self):
        self.write_receipt()
        before = self.receipt_path.read_bytes()
        replacement = "sha256:" + "6" * 64
        self.fixture["containers"][BACKEND]["imageId"] = replacement
        self.fixture["images"][replacement] = copy.deepcopy(LABELS)
        result = self.invoke("assert", success=False)
        self.assertIn("differs from the activation receipt", result["error"])
        self.assertEqual(self.receipt_path.read_bytes(), before)

    def test_missing_service_is_rejected(self):
        for ids in ([BACKEND], [BACKEND, "c" * 64]):
            with self.subTest(ids=ids):
                self.fixture["ids"] = ids
                self.fixture["containers"]["c" * 64] = self.container("c" * 64, "backend", BACKEND_IMAGE)
                self.invoke(success=False)
                self.assertFalse(self.receipt_path.exists())

    def test_stopped_or_unhealthy_containers_are_rejected(self):
        for changes in ({"running": False}, {"health": "starting"}, {"health": "unhealthy"}, {"health": None}):
            with self.subTest(changes=changes):
                self.fixture["containers"][BACKEND] = {**self.container(BACKEND, "backend", BACKEND_IMAGE), **changes}
                self.invoke(success=False)
                self.assertFalse(self.receipt_path.exists())

    def test_wrong_project_service_or_oneoff_is_rejected(self):
        for changes in ({"project": "another-project"}, {"service": "database"}, {"oneoff": "True"}, {"oneoff": None}):
            with self.subTest(changes=changes):
                self.fixture["containers"][BACKEND] = {**self.container(BACKEND, "backend", BACKEND_IMAGE), **changes}
                self.invoke(success=False)
                self.assertFalse(self.receipt_path.exists())

    def test_duplicate_container_ids_and_aliases_are_rejected(self):
        for alias in (BACKEND, BACKEND[:12]):
            with self.subTest(alias=alias):
                self.fixture["ids"] = [BACKEND, EDGE, alias]
                self.fixture["containers"][alias] = self.container(BACKEND, "backend", BACKEND_IMAGE)
                self.invoke(success=False)
                self.assertFalse(self.receipt_path.exists())

    def test_replicas_cannot_mix_different_images(self):
        replica = "c" * 64
        replacement = "sha256:" + "6" * 64
        self.fixture["ids"].append(replica)
        self.fixture["containers"][replica] = self.container(replica, "backend", replacement)
        self.fixture["images"][replacement] = copy.deepcopy(LABELS)
        result = self.invoke(success=False)
        self.assertIn("multiple running image identities", result["error"])

    def test_public_mounts_follow_http_local_tls_and_external_tls_modes(self):
        for https, external in ((False, False), (True, False), (True, True)):
            with self.subTest(https=https, external=external):
                self.fixture["origin"] = "https://fixture.example.com" if https else ORIGIN
                self.fixture["externalTlsProxy"] = external
                mounts = self.edge_mounts(https=https, external=external)
                if https and not external:
                    mounts.extend({"type": "bind", "source": "", "destination": "/run/secrets/" + name, "rw": False}
                                  for name in ("tls_certificate", "tls_private_key"))
                self.fixture["containers"][EDGE]["mounts"] = mounts
                self.invoke()
        if os.name == "nt":
            # Independent Docker Desktop spelling of the same canonical host path.
            self.fixture["origin"] = ORIGIN
            self.fixture["externalTlsProxy"] = False
            mounts = self.edge_mounts()
            for mount in mounts[:3]:
                path = Path(mount["source"])
                self.assertTrue(path.drive.endswith(":"), "Fixture expects a Windows drive")
                mount["source"] = "/run/desktop/mnt/host/" + path.drive[0].lower() + "/" + "/".join(path.parts[1:])
            self.fixture["containers"][EDGE]["mounts"] = mounts
            self.invoke()

    def test_same_image_with_changed_public_configuration_mount_is_rejected(self):
        self.write_receipt()
        before = self.receipt_path.read_bytes()
        for change in ("source", "writable", "missing", "duplicate", "type"):
            with self.subTest(change=change):
                mounts = self.edge_mounts()
                if change == "source":
                    mounts[0]["source"] = str(self.directory / "other-nginx.conf")
                elif change == "writable":
                    mounts[0]["rw"] = True
                elif change == "missing":
                    mounts.pop(0)
                elif change == "duplicate":
                    mounts.append(copy.deepcopy(mounts[0]))
                else:
                    mounts[0]["type"] = "volume"
                self.fixture["containers"][EDGE]["mounts"] = mounts
                self.invoke("assert", success=False)
                self.assertEqual(self.receipt_path.read_bytes(), before)

    def test_mounts_cannot_shadow_frontend_backend_or_nginx_roots(self):
        for service, target in (("edge", "/usr/share/nginx/html"), ("edge", "/usr/share/nginx/html/main.dart.js"),
                                ("edge", "/usr"), ("edge", "/etc/nginx"), ("edge", "/etc"),
                                ("backend", "/app"), ("backend", "/app/manager-backend.jar"), ("backend", "/")):
            with self.subTest(service=service, target=target):
                self.fixture["containers"][EDGE] = self.container(EDGE, "edge", EDGE_IMAGE)
                self.fixture["containers"][BACKEND] = self.container(BACKEND, "backend", BACKEND_IMAGE)
                container = self.fixture["containers"][EDGE if service == "edge" else BACKEND]
                container["mounts"].append({"type": "bind", "source": "", "destination": target, "rw": False})
                self.invoke(success=False)
                self.assertFalse(self.receipt_path.exists())

    def test_successful_activation_writes_separate_receipt_atomically(self):
        self.invoke("write")
        actual = json.loads(self.receipt_path.read_text(encoding="utf-8"))
        expected = self.receipt()
        self.assertIsInstance(actual["createdAt"], str)
        self.assertRegex(actual["createdAt"], r"^\d{4}-\d{2}-\d{2}T.*\+00:00$")
        expected["createdAt"] = actual["createdAt"]
        self.assertEqual(actual, expected)
        self.assertEqual(sorted(path.name for path in self.deployment.iterdir()), ["release-runtime.json"])

    def test_recreated_containers_using_same_images_preserve_receipt(self):
        self.write_receipt()
        before = self.receipt_path.read_bytes()
        backend, edge = "c" * 64, "d" * 64
        self.fixture["ids"] = [backend, edge]
        self.fixture["containers"] = {backend: self.container(backend, "backend", BACKEND_IMAGE),
                                      edge: self.container(edge, "edge", EDGE_IMAGE)}
        self.invoke("assert")
        self.assertEqual(self.receipt_path.read_bytes(), before)

    def test_missing_receipt_is_not_created_by_verification(self):
        result = self.invoke("assert", success=False)
        self.assertIn("receipt is missing", result["error"])
        self.assertEqual(list(self.deployment.iterdir()), [])

    def test_receipt_scope_mismatch_is_not_repaired(self):
        for field, value in (("manifestSha256", "f" * 64), ("sourceTreeSha256", "f" * 64),
                             ("artifactTreeSha256", "f" * 64), ("publicUrl", "http://localhost:18102"),
                             ("project", "another-project"), ("applicationVersion", "2.0.0")):
            with self.subTest(field=field):
                receipt = self.receipt()
                receipt[field] = value
                self.write_receipt(receipt)
                before = self.receipt_path.read_bytes()
                self.invoke("assert", success=False)
                self.assertEqual(self.receipt_path.read_bytes(), before)

    def test_invalid_receipt_types_duplicates_and_shape_are_rejected(self):
        version = self.receipt()
        version["schemaVersion"] = "1"
        bad_service = self.receipt()
        bad_service["services"]["database"] = {"imageId": BACKEND_IMAGE, "containerIds": [BACKEND]}
        bad_time = self.receipt()
        bad_time["createdAt"] = "yesterday"
        raw_cases = [json.dumps(value) for value in (version, bad_service, bad_time)]
        raw_cases.append(json.dumps(self.receipt())[:-1] + ', "project": "runtime-fixture"}')
        for raw in raw_cases:
            with self.subTest(raw=raw):
                self.receipt_path.write_text(raw, encoding="utf-8")
                before = self.receipt_path.read_bytes()
                self.invoke("assert", success=False)
                self.assertEqual(self.receipt_path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
