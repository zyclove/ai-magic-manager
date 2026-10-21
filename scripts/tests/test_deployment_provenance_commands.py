"""Run real start/verify scripts with controlled Docker and HTTP transports.

Public scripts and recipes are copied into one disposable .cache repository.
No daemon, SDK, network request, private configuration or real service is used.
"""
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

try:
    from .test_deployment_provenance import ARTIFACT_CONTENTS, RECIPES, SOURCE_CONTENTS, inventory, tree_sha
except ImportError:
    from test_deployment_provenance import ARTIFACT_CONTENTS, RECIPES, SOURCE_CONTENTS, inventory, tree_sha


ROOT = Path(__file__).resolve().parents[2]
PWSH = shutil.which("pwsh")
PROJECT = "runtime-commands-fixture"
ORIGIN = "http://localhost:18997"
BACKEND = "a" * 64
EDGE = "b" * 64
BACKEND_IMAGE = "sha256:" + "1" * 64
EDGE_IMAGE = "sha256:" + "2" * 64
REPLACEMENT_IMAGE = "sha256:" + "6" * 64
RELEASE_ENV = {
    "RELEASE_REVISION": "prior-revision", "RELEASE_VERSION": None,
    "RELEASE_MANIFEST_SHA256": "prior-manifest", "RELEASE_SOURCE_TREE_SHA256": None,
    "RELEASE_ARTIFACT_TREE_SHA256": "",
}

# Only this I/O boundary is replaced in the copied runtime helper. All production
# validation and receipt code above it remains byte-for-byte the current source.
DOCKER_TRANSPORT = r'''
function Invoke-DeploymentProvenanceDocker {
    param([string[]]$Arguments, [int]$TimeoutSeconds)
    return Invoke-CommandFixtureInspection -Arguments $Arguments
}
'''

WRAPPER = r'''
param([string]$Fixture, [string]$Entry, [string]$Deployment, [string]$Action, [string]$Mode)
$ErrorActionPreference = 'Stop'
$global:commandFixture = Get-Content -LiteralPath $Fixture -Raw | ConvertFrom-Json -AsHashtable -Depth 32
$global:commandCalls = [Collections.Generic.List[object]]::new()
$global:commandMode = $Mode
$global:httpSwitched = $false
function global:Invoke-CommandFixtureInspection {
    param([string[]]$Arguments)
    $global:commandCalls.Add(@{boundary='inspect'; arguments=@($Arguments)})
    if ($Arguments[0] -ceq 'compose' -and ($Arguments[-5..-1] -join '|') -ceq 'ps|--all|--quiet|backend|edge') {
        return $global:commandFixture.ids -join "`n"
    }
    if ($Arguments[0] -ceq 'container' -and $Arguments[1] -ceq 'inspect') {
        return $global:commandFixture.containers[$Arguments[-1]] | ConvertTo-Json -Depth 16 -Compress
    }
    if ($Arguments[0] -ceq 'image' -and $Arguments[1] -ceq 'inspect') {
        return $global:commandFixture.labels | ConvertTo-Json -Depth 8 -Compress
    }
    throw 'Unexpected inspection command; real Docker is forbidden.'
}
function global:docker {
    $arguments = @($args)
    $global:commandCalls.Add(@{boundary='docker'; arguments=$arguments})
    $global:LASTEXITCODE = 0
    if ($arguments -contains 'config') {
        if ($global:commandMode -ceq 'config-fail') { $global:LASTEXITCODE=71; return }
        $configuration = $global:commandFixture.configuration
        foreach ($service in @('backend','edge')) {
            foreach ($name in $global:commandFixture.environmentBefore.Keys) {
                $configuration.services[$service].build.args[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
            }
        }
        return $configuration | ConvertTo-Json -Depth 24 -Compress
    }
    if ($arguments -contains 'up') {
        if ($global:commandMode -ceq 'up-fail') { $global:LASTEXITCODE=72; return 'controlled up failure' }
        return
    }
    if ($arguments -contains 'exec') { return '{"status":"UP"}' }
    throw 'Unexpected Docker command; real Docker is forbidden.'
}
function global:Invoke-WebRequest {
    param([string]$Uri, [int]$TimeoutSec, [switch]$SkipHttpErrorCheck)
    $global:commandCalls.Add(@{boundary='http'; uri=$Uri})
    $origin = $global:commandFixture.origin
    if (-not $global:httpSwitched) {
        $global:httpSwitched=$true
        if ($global:commandMode -ceq 'manifest-switch') {
            # Both manifests remain valid and identical, but their identity changes.
            foreach ($path in $global:commandFixture.manifests) { [IO.File]::AppendAllText($path,"`n") }
        } elseif ($global:commandMode -ceq 'image-switch') {
            $global:commandFixture.containers[$global:commandFixture.ids[0]].imageId = $global:commandFixture.replacementImage
        }
    }
    $body = '<html><title>智能管家</title></html>'
    if ($Uri -ceq "$origin/" -or $Uri -like "$origin/auth/callback?*") {
        return [pscustomobject]@{StatusCode=200;Content=$body;Headers=@{'X-Content-Type-Options'=@('nosniff')}}
    }
    if ($Uri -ceq "$origin/identity/realms/ai-manager/.well-known/openid-configuration") {
        $issuer="$origin/identity/realms/ai-manager"
        return [pscustomobject]@{StatusCode=200;Content=(@{issuer=$issuer;token_endpoint="$issuer/protocol/openid-connect/token"}|ConvertTo-Json -Compress)}
    }
    if ($Uri -ceq "$origin/api/v1/me") {
        return [pscustomobject]@{StatusCode=401;Content='{"errorCode":"UNAUTHENTICATED","correlationId":"controlled-correlation"}'}
    }
    throw 'Unexpected HTTP request; real network access is forbidden.'
}
foreach ($name in $global:commandFixture.environmentBefore.Keys) {
    if ($null -eq $global:commandFixture.environmentBefore[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($name,$global:commandFixture.environmentBefore[$name],'Process') }
}
$ok=$false; $failure=$null; $output=@()
try { $output=@(& $Entry -Directory $Deployment); $ok=$true }
catch { $failure=$_.Exception.Message }
$after=@{}
foreach ($name in $global:commandFixture.environmentBefore.Keys) { $after[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
[ordered]@{ok=$ok;error=$failure;output=($output -join "`n");environmentAfter=$after;calls=@($global:commandCalls.ToArray())} |
    ConvertTo-Json -Depth 32 -Compress
if (-not $ok) { exit 1 }
'''


class DeploymentProvenanceCommandsTest(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(PWSH, "PowerShell 7 is required")
        cache = ROOT / ".cache"
        cache.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="deployment-commands-test-", dir=cache)
        self.work = Path(self.temporary.name)
        self.repository = self.work / "repository"
        self.deployment = self.repository / ".local/deployment"
        self.release = self.deployment / "artifacts/release-0123456789abcdef0123456789abcdef"
        self.deployment.mkdir(parents=True)
        (self.deployment / "secrets").mkdir()
        (self.deployment / "logs").mkdir()
        self.write_json(self.deployment / "deployment.json", {
            "schemaVersion": 1, "applicationVersion": "1.0.0", "publicUrl": ORIGIN,
            "projectName": PROJECT, "edgePort": 18997, "consumerIdentity": False,
            "externalTlsProxy": False,
        })
        self.write(self.deployment / ".env", b"# controlled fixture; never passed to real Docker\n")
        self.write_json(self.deployment / "erasure-ledger-initialized.json", {"schemaVersion": 1, "ledgerId": "fixture-ledger"})
        for name in set(RECIPES) | {"scripts/family-identity-release-common.ps1"}:
            self.write(self.repository / name, (ROOT / name).read_bytes())
        runtime_helper = self.repository / "scripts/deployment-runtime-provenance.ps1"
        with runtime_helper.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write("\n" + DOCKER_TRANSPORT)
        for name, data in ARTIFACT_CONTENTS.items():
            self.write(self.release / name, data)
        source_files = inventory(SOURCE_CONTENTS)
        artifact_files = inventory(ARTIFACT_CONTENTS)
        recipe_files = inventory({name: (self.repository / name).read_bytes() for name in RECIPES})
        self.manifest = {
            "schemaVersion": 1, "provenanceVersion": 1, "applicationVersion": "1.0.0",
            "publicUrl": ORIGIN, "consumerIdentity": False,
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
        self.manifest_bytes = (self.deployment / "release-manifest.json").read_bytes()
        self.labels = {
            "org.opencontainers.image.revision": self.manifest["source"]["revision"],
            "org.opencontainers.image.version": "1.0.0",
            "com.aimanager.release.manifest-sha256": hashlib.sha256(self.manifest_bytes).hexdigest(),
            "com.aimanager.release.source-tree-sha256": self.manifest["sourceTreeSha256"],
            "com.aimanager.release.artifact-tree-sha256": self.manifest["artifactTreeSha256"],
        }
        mounts = [
            {"type": "bind", "source": str(self.repository / "deploy/edge" / filename), "destination": target, "rw": False}
            for target, filename in (("/etc/nginx/nginx.conf", "nginx.conf"),
                                     ("/etc/nginx/conf.d/default.conf", "http.conf"),
                                     ("/etc/nginx/includes/routes.conf", "routes.conf"))
        ]
        configuration = {
            "name": PROJECT,
            "services": {
                "backend": {"build": {"context": str(self.release / "backend"),
                                       "dockerfile": str(self.repository / "deploy/containers/backend.Dockerfile"), "args": {}},
                            "environment": {"OIDC_ISSUER_URI": ORIGIN + "/identity/realms/ai-manager",
                                            "ERASURE_LEDGER_ID": "fixture-ledger", "ERASURE_RECOVERY_REQUIRED": "true"}},
                "edge": {"build": {"context": str(self.release / "guardian"),
                                    "dockerfile": str(self.repository / "deploy/containers/edge.Dockerfile"), "args": {}},
                         "volumes": [{"type": "bind", "source": mount["source"], "target": mount["destination"], "read_only": True}
                                     for mount in mounts]},
            },
        }
        self.fixture = {
            "origin": ORIGIN, "ids": [BACKEND, EDGE], "labels": self.labels,
            "replacementImage": REPLACEMENT_IMAGE,
            "configuration": configuration, "environmentBefore": RELEASE_ENV,
            "manifests": [str(self.deployment / "release-manifest.json"), str(self.release / "release-manifest.json")],
            "containers": {
                BACKEND: {"id": BACKEND, "imageId": BACKEND_IMAGE, "running": True, "health": "healthy",
                          "project": PROJECT, "service": "backend", "oneoff": "False", "mounts": []},
                EDGE: {"id": EDGE, "imageId": EDGE_IMAGE, "running": True, "health": "healthy",
                       "project": PROJECT, "service": "edge", "oneoff": "False", "mounts": mounts},
            },
        }
        self.fixture_path = self.work / "fixture.json"
        self.wrapper = self.work / "invoke.ps1"
        self.wrapper.write_text(WRAPPER, encoding="utf-8")
        self.receipt = self.deployment / "release-runtime.json"

    def tearDown(self):
        self.assertFalse(self.work.is_symlink())
        self.assertEqual(self.work.resolve().parent, (ROOT / ".cache").resolve())
        self.temporary.cleanup()

    @staticmethod
    def write(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def write_json(self, path, value):
        self.write(path, (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8"))

    def publish(self):
        self.write_json(self.deployment / "release-manifest.json", self.manifest)
        self.write_json(self.release / "release-manifest.json", self.manifest)

    def initial_receipt(self):
        return {
            "schemaVersion": 1, "manifestSha256": self.labels["com.aimanager.release.manifest-sha256"],
            "applicationVersion": "1.0.0", "publicUrl": ORIGIN, "project": PROJECT,
            "sourceTreeSha256": self.manifest["sourceTreeSha256"], "artifactTreeSha256": self.manifest["artifactTreeSha256"],
            "createdAt": "2026-10-21T04:30:00.0000000+00:00",
            "services": {"backend": {"imageId": BACKEND_IMAGE, "containerIds": [BACKEND]},
                         "edge": {"imageId": EDGE_IMAGE, "containerIds": [EDGE]}},
        }

    def invoke(self, action, mode="success", success=True):
        self.write_json(self.fixture_path, self.fixture)
        completed = subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-File", str(self.wrapper),
             "-Fixture", str(self.fixture_path), "-Entry", str(self.repository / f"scripts/{action}-deployment.ps1"),
             "-Deployment", str(self.deployment), "-Action", action, "-Mode", mode],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(completed.returncode == 0, success, completed.stdout + completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["ok"], success, payload)
        self.assertEqual(payload["environmentAfter"], RELEASE_ENV)
        return payload

    def test_start_writes_separate_actual_image_receipt_without_changing_manifest(self):
        payload = self.invoke("start")
        self.assertEqual((self.deployment / "release-manifest.json").read_bytes(), self.manifest_bytes)
        self.assertEqual((self.release / "release-manifest.json").read_bytes(), self.manifest_bytes)
        actual = json.loads(self.receipt.read_text(encoding="utf-8"))
        expected = self.initial_receipt()
        expected["createdAt"] = actual["createdAt"]
        self.assertEqual(actual, expected)
        self.assertTrue(any("up" in call.get("arguments", []) for call in payload["calls"]))

    def test_failed_config_or_start_restores_existing_and_absent_environment(self):
        for mode in ("config-fail", "up-fail"):
            with self.subTest(mode=mode):
                payload = self.invoke("start", mode=mode, success=False)
                self.assertFalse(self.receipt.exists())
                self.assertEqual((self.deployment / "release-manifest.json").read_bytes(), self.manifest_bytes)
                self.assertFalse(any(call["boundary"] == "inspect" for call in payload["calls"]))
                if mode == "config-fail":
                    self.assertFalse(any("up" in call.get("arguments", []) for call in payload["calls"]))

    def test_verify_rejects_manifest_or_image_replacement_during_http_checks(self):
        for mode in ("manifest-switch", "image-switch"):
            with self.subTest(mode=mode):
                self.publish()
                self.write_json(self.receipt, self.initial_receipt())
                before = self.receipt.read_bytes()
                payload = self.invoke("verify", mode=mode, success=False)
                self.assertTrue(any(call["boundary"] == "http" for call in payload["calls"]))
                self.assertEqual(self.receipt.read_bytes(), before)
                if mode == "manifest-switch":
                    self.assertIn("Release changed during verification", payload["error"])
                else:
                    self.assertIn("differs from the activation receipt", payload["error"])

    def test_invalid_manifest_rejects_before_any_docker_or_http_boundary(self):
        self.manifest["provenanceVersion"] = 2
        self.publish()
        for action in ("start", "verify"):
            with self.subTest(action=action):
                payload = self.invoke(action, success=False)
                self.assertEqual(payload["calls"], [])
                self.assertFalse(self.receipt.exists())


if __name__ == "__main__":
    unittest.main()
