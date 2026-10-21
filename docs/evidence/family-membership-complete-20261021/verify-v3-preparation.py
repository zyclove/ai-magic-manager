import hashlib
import json
from pathlib import Path

TASK = Path(__file__).resolve().parent
ROOT = TASK.parent.parent
before = (TASK / "run-complete-parent.py").read_bytes()
after = (TASK / "run-complete-parent-v3.py").read_bytes()
assert hashlib.sha256(after).hexdigest() == "5d3e5000295cf7b74a15b0fc08aac695583f0abfcb8d73536ec214f9b309a0d1"
replacements = [
    (b"post-fix-v3", b"post-fix-v2"),
    (b"81e08370194a5fe927f764932ef4357ea1878fde7f9cde953b871369ca4f43d1", b"285b46962dc0ffdd7892148f761e44c08021faf7c0026b7987cfe93c03853e06"),
    (b"dd31bc969bfcdf4c8afa4b88fabf7de61ae39243ab7e9684c22a15e56c23bfee", b"b56119f4c8f2a27f8e4f3117395f120506b719fc9c7e6a2b578c2fdc8b1cedb6"),
    (b"complete-parent-v3-main-pins.json", b"complete-parent-main-pins.json"),
    (b"complete-parent-v3-result.json", b"complete-parent-result.json"),
    (b"complete-parent-v3-worker-state.json", b"complete-parent-worker-state.json"),
]
for new, old in replacements:
    after = after.replace(new, old)
assert before == after, "Runner change exceeds frozen input/path substitutions"
manifest_bytes = (TASK / "post-fix-v3/input-manifest.json").read_bytes()
assert hashlib.sha256(manifest_bytes).hexdigest() == "81e08370194a5fe927f764932ef4357ea1878fde7f9cde953b871369ca4f43d1"
manifest = json.loads(manifest_bytes)
meta_bytes = (TASK / "complete-parent-v3-main-pins.json").read_bytes()
assert hashlib.sha256(meta_bytes).hexdigest() == "dd31bc969bfcdf4c8afa4b88fabf7de61ae39243ab7e9684c22a15e56c23bfee"
metadata = json.loads(meta_bytes)
changed = []
for row in manifest["sourceFiles"]:
    data = (TASK / "post-fix-v3/src" / row["path"]).read_bytes()
    assert len(data) == row["bytes"] and hashlib.sha256(data).hexdigest() == row["sha256"]
    if data != (TASK / "post-fix-v2/src" / row["path"]).read_bytes():
        changed.append(row["path"])
path = "apps/parent/test/family_membership_test.dart"
assert changed == [path]
assert (TASK / "post-fix-v2/src" / path).read_bytes().replace(
    b"import 'package:flutter/foundation.dart';\n", b"", 1) == (ROOT / path).read_bytes() == (TASK / "post-fix-v3/src" / path).read_bytes()
for row in metadata["mainProtectedFiles"] + manifest["explicitOverlays"]:
    data = (ROOT / row["path"]).read_bytes()
    assert len(data) == row["bytes"] and hashlib.sha256(data).hexdigest() == row["sha256"]
print(json.dumps({"templateChangesLimitedToFixedInputs": True, "sourceFiles": len(manifest["sourceFiles"]),
                  "mainProtectedFiles": len(metadata["mainProtectedFiles"]), "onlySourceChange": changed,
                  "allSourceAndMainPinsMatched": True}))
