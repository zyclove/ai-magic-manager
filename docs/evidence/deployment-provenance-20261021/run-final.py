"""One fixed-input run of the six affected deployment regression modules."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import unittest

TASK = Path(__file__).resolve().parent
ROOT = TASK.parent.parent
PATHS = [
    "scripts/build-deployment.ps1", "scripts/start-deployment.ps1",
    "scripts/verify-deployment.ps1", "scripts/initialize-erasure-ledger.ps1",
    "scripts/deployment-provenance.ps1", "scripts/deployment-runtime-provenance.ps1",
    "deploy/compose/compose.yaml", "deploy/containers/backend.Dockerfile",
    "deploy/containers/edge.Dockerfile", "docs/deployment-provenance.md",
    "scripts/tests/test_deployment.py", "scripts/tests/test_deployment_build.py",
    "scripts/tests/test_consumer_deployment.py",
    "scripts/tests/deployment_provenance_fixture.py", "scripts/tests/test_deployment_provenance.py",
    "scripts/tests/test_deployment_runtime_provenance.py", "scripts/tests/test_deployment_provenance_commands.py",
]
MODULES = ["test_deployment", "test_deployment_build", "test_consumer_deployment",
           "test_deployment_provenance", "test_deployment_runtime_provenance",
           "test_deployment_provenance_commands"]


def inventory():
    return [{"path": path, "bytes": (ROOT / path).stat().st_size,
             "sha256": hashlib.sha256((ROOT / path).read_bytes()).hexdigest()} for path in PATHS]


started = time.monotonic()
receipt = TASK / "final-result.json"
assert not receipt.exists(), "A new run requires a separate reviewed result path"
pins = inventory()
state = {"startedAtUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
         "sourceFiles": pins, "modules": MODULES, "sdkBuildsRun": False,
         "servicesStartedOrChanged": False, "realDockerBoundary": "compose config only, synthetic fixture .env",
         "secretBoundary": "synthetic fixtures only; no existing credentials or runtime .env read"}
receipt.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
sys.path.insert(0, str(ROOT / "scripts/tests"))
os.environ["DOCKER_CONFIG"] = str(TASK / "docker-client")
suite = unittest.defaultTestLoader.loadTestsFromNames(MODULES)
with (TASK / "all-related-tests.log").open("x", encoding="utf-8") as stream:
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
state.update(endedAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
             elapsedSeconds=time.monotonic() - started, testsRun=result.testsRun,
             failures=len(result.failures), errors=len(result.errors),
             skipped=[{"test": str(test), "reason": reason} for test, reason in result.skipped],
             sourceUnchanged=inventory() == pins,
             logSha256=hashlib.sha256((TASK / "all-related-tests.log").read_bytes()).hexdigest())
state["passed"] = result.wasSuccessful() and state["sourceUnchanged"] and result.testsRun == 75
receipt.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
print(json.dumps({key: state[key] for key in ("passed", "testsRun", "failures", "errors", "skipped", "sourceUnchanged", "elapsedSeconds")}))
raise SystemExit(0 if state["passed"] else 1)
