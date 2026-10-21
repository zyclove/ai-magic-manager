"""Public, synthetic release metadata for deployment command tests."""
import hashlib
import json


RECIPE_PATHS = (
    "deploy/containers/backend.Dockerfile", "deploy/containers/edge.Dockerfile",
    "deploy/containers/keycloak.Dockerfile",
    "deploy/compose/compose.yaml", "deploy/compose/compose.tls.yaml",
    "deploy/compose/compose.external-tls.yaml", "deploy/compose/compose.family.yaml",
    "deploy/compose/compose.identity-runtime-image.yaml",
    "deploy/compose/compose.identity-runtime-control.yaml",
    "deploy/compose/compose.identity-admin.yaml",
    "deploy/edge/nginx.conf", "deploy/edge/http.conf", "deploy/edge/tls.conf",
    "deploy/edge/routes.conf", "deploy/edge/routes.external-tls.conf",
    "scripts/build-deployment.ps1", "scripts/start-deployment.ps1",
    "scripts/verify-deployment.ps1", "scripts/deployment-common.ps1",
    "scripts/family-identity-release-common.ps1", "scripts/initialize-erasure-ledger.ps1",
    "scripts/deployment-provenance.ps1", "scripts/deployment-runtime-provenance.ps1",
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def row(path, data):
    return {"path": path, "bytes": len(data), "sha256": digest(data)}


def tree(rows):
    return digest("".join(f"{item['path']}\0{item['bytes']}\0{item['sha256']}\n"
                          for item in sorted(rows, key=lambda item: item["path"])).encode("utf-8"))


def write_release_manifest(directory, release, repository, origin):
    """No credentials, Docker calls, builds or production workspace reads."""
    source = [row("backend/pom.xml", b"synthetic source")]
    artifacts = [row(path.relative_to(release).as_posix(), path.read_bytes())
                 for path in release.rglob("*") if path.is_file()
                 and path.relative_to(release).as_posix() != "release-manifest.json"]
    recipes = [row(path, (repository / path).read_bytes()) for path in RECIPE_PATHS]
    manifest = {
        "schemaVersion": 1, "provenanceVersion": 1, "applicationVersion": "1.0.0",
        "publicUrl": origin, "consumerIdentity": False, "identityProviderSha256": None,
        "artifactRoot": release.relative_to(directory).as_posix(),
        "source": {"kind": "content-snapshot", "revision": "sha256:" + tree(source)},
        "sourceFiles": source, "sourceTreeSha256": tree(source),
        "artifactFiles": artifacts, "artifactTreeSha256": tree(artifacts),
        "recipeFiles": recipes, "recipeTreeSha256": tree(recipes),
        "backendSha256": digest((release / "backend/manager-backend.jar").read_bytes()),
        "guardianSha256": digest((release / "guardian/main.dart.js").read_bytes()),
    }
    content = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    (directory / "release-manifest.json").write_bytes(content)
    (release / "release-manifest.json").write_bytes(content)
    return manifest
