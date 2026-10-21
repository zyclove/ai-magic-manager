"""Single-use Parent full-suite/analyzer grant; preparing this file runs nothing.

The supervisor owns a Windows job containing its worker and every child. Its
watchdog includes hashes, directory reads, SDK commands and release checks.
Six seconds of the 330-second envelope are reserved for forced termination.
"""
import ast
import ctypes
from ctypes import wintypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import threading
import time
from urllib.parse import unquote, urlparse

TASK = Path(__file__).resolve().parent
REPO = TASK.parent.parent
VARIANT = TASK / "post-fix-v3"
SOURCE = VARIANT / "src"
SDK = Path(r"D:\softwares\flutter")
MANIFEST_SHA = "81e08370194a5fe927f764932ef4357ea1878fde7f9cde953b871369ca4f43d1"
MAIN_METADATA_SHA = "dd31bc969bfcdf4c8afa4b88fabf7de61ae39243ab7e9684c22a15e56c23bfee"
SAMPLER_SHA = "c2345679d9ad4a7b9c2036ce7e6bb6179d73a8597d8aa4c3d6d61ab05f46eb84"
SDK_REVISION = "761747bfc538b5af34aa0d3fac380f1bc331ec49"
RESULT = TASK / "complete-parent-v3-result.json"
STATE = TASK / "complete-parent-v3-worker-state.json"
OPTIONAL_MISSING_LIBS = {"flutter_secure_storage_darwin", "flutter_secure_storage_linux"}
SDK_NAMES = {"dart.exe", "dartaotruntime.exe", "flutter.exe", "flutter_tester.exe",
             "gen_snapshot.exe", "java.exe", "javaw.exe", "go.exe", "gofmt.exe",
             "compile.exe", "link.exe", "asm.exe", "cgo.exe"}
GENERATED = {".git", ".local", "target", "build", ".dart_tool", "__pycache__"}


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write_json(path, value):
    temporary = path.with_name(path.name + ".part")
    with temporary.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def protected(relative):
    parts = Path(relative).parts
    return "lib" in parts or "test" in parts or parts[-1] in {"pubspec.yaml", "pubspec.lock"}


def protected_members(base):
    found = set()
    for scope in ("apps/parent", "packages"):
        for directory, directories, files in os.walk(base / scope, followlinks=False):
            relative_directory = Path(directory).relative_to(base)
            inside_protected = "lib" in relative_directory.parts or "test" in relative_directory.parts
            no_link(Path(directory))
            kept = []
            for name in directories:
                if not inside_protected and (name in GENERATED or name.startswith(".flutter-plugins")):
                    continue
                no_link(Path(directory) / name)
                kept.append(name)
            directories[:] = kept
            for name in files:
                path = Path(directory) / name
                relative = path.relative_to(base).as_posix()
                if protected(relative):
                    no_link(path)
                    found.add(relative)
    return found


def load_audited_functions():
    path = TASK / "runtime-sample.py"
    check(sha(path) == SAMPLER_SHA, "Audited sampler changed")
    tree = ast.parse(path.read_text(encoding="utf-8"))
    names = {"no_link", "hash_file", "source_observation"}
    selected = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
    check({node.name for node in selected} == names, "Audited helper definitions missing")
    # No old batch or sampler module top-level code is executed.
    exec(compile(ast.Module(body=selected, type_ignores=[]), "<audited-source-functions>", "exec"), globals())


def sdk_processes():
    import psutil  # Already installed; never install or resolve a dependency.
    found, unknown = [], []
    for process in psutil.process_iter(["pid", "name", "create_time"], ad_value=None):
        info = process.info
        if info["name"] is None:
            if info["pid"] not in (0, 4):
                unknown.append(info["pid"])
        elif info["name"].lower() in SDK_NAMES:
            found.append(info)
    check(not unknown, "Process names could not be read: " + str(unknown))
    return found


def packages_observation(config):
    rows = []
    for package in config["packages"]:
        row = {"name": package["name"], "rootUri": package["rootUri"], "packageUri": package["packageUri"]}
        try:
            uri = urlparse(package["rootUri"])
            check(uri.scheme == "file" and not uri.netloc, "Unexpected package root URI")
            root = Path(unquote(uri.path).lstrip("/"))
            library = root / package["packageUri"]
            for label, path in (("root", root), ("lib", library)):
                try:
                    path.lstat()
                except FileNotFoundError:
                    if label == "lib" and package["name"] in OPTIONAL_MISSING_LIBS:
                        row[label] = {"path": str(path), "state": "KNOWN_OPTIONAL_LIB_MISSING"}
                        continue
                    raise
                no_link(path)
                info = path.stat()
                check(path.is_dir(), "Package directory is missing")
                with os.scandir(path) as entries:
                    next(entries, None)  # Directory readability; no source content is emitted.
                row[label] = {"path": str(path), "state": "READABLE", "mtimeNs": info.st_mtime_ns,
                              "attributes": getattr(info, "st_file_attributes", None)}
        except Exception as error:
            row["error"] = type(error).__name__ + ": " + str(error)
        rows.append(row)
    return rows


def sample_gate(label, manifest, main_metadata, work, cutoff):
    record = {"label": label, "startedAtUtc": utc(), "errors": []}
    observation_path = VARIANT / "out" / (work["runTag"] + "-" + label + ".json")
    try:
        check(time.monotonic() < cutoff, "No batch time remains")
        check(sha(VARIANT / "input-manifest.json") == MANIFEST_SHA, "Snapshot manifest changed")
        check(sha(TASK / "complete-parent-v3-main-pins.json") == MAIN_METADATA_SHA, "Main metadata pin changed")
        check(sha(TASK / "runtime-sample.py") == SAMPLER_SHA, "Sampler pin changed")
        record["sourceObservation"] = source_observation(SOURCE, manifest["sourceFiles"], manifest["sourceTreeSha256"], "post")
        check(record["sourceObservation"]["matched"], "Snapshot's 400 raw file pins differ")
        record["sourceFiles"] = [{"path": item["path"], "bytes": (SOURCE / item["path"]).stat().st_size,
                                  "sha256": hash_file(SOURCE / item["path"])} for item in manifest["sourceFiles"]]
        expected_records = {item["path"]: item for item in manifest["sourceFiles"]}
        check(all(row["bytes"] == expected_records[row["path"]]["bytes"] and
                  row["sha256"] == expected_records[row["path"]]["sha256"]
                  for row in record["sourceFiles"]), "Snapshot drifted during raw metadata capture")
        expected = {item["path"] for item in main_metadata["mainProtectedFiles"]}
        snapshot_members = protected_members(SOURCE)
        main_members = protected_members(REPO)
        record["protectedMembership"] = {"expectedCount": len(expected),
            "snapshotAdded": sorted(snapshot_members - expected), "snapshotMissing": sorted(expected - snapshot_members),
            "mainAdded": sorted(main_members - expected), "mainMissing": sorted(expected - main_members)}
        check(snapshot_members == expected == main_members, "Protected source/test/pubspec membership changed")
        record["mainProtectedFiles"] = []
        for item in main_metadata["mainProtectedFiles"]:
            path = REPO / item["path"]
            no_link(path)
            current = {"path": item["path"], "bytes": path.stat().st_size, "sha256": hash_file(path)}
            record["mainProtectedFiles"].append(current)
            check(current["bytes"] == item["bytes"] and current["sha256"] == item["sha256"], "Raw Main pin changed: " + item["path"])
        record["sixMainOverlays"] = []
        for item in manifest["explicitOverlays"]:
            current = {"path": item["path"], "bytes": (REPO / item["path"]).stat().st_size,
                       "sha256": hash_file(REPO / item["path"])}
            record["sixMainOverlays"].append(current)
            check(current["bytes"] == item["bytes"] and current["sha256"] == item["sha256"], "Main overlay changed")
        config_path = SOURCE / "apps/parent/.dart_tool/package_config.json"
        record["packageConfigSha256"] = hash_file(config_path)
        check(record["packageConfigSha256"] == manifest["packageConfig"]["sha256"], "Package map changed")
        config = json.loads(config_path.read_bytes())
        check(len(config["packages"]) == 97, "Expected 97 package mappings")
        internal = {item["name"]: item for item in manifest["packageConfig"]["remappedRepositoryPackages"]}
        check(len(internal) == 9, "Expected 9 internal package mappings")
        for package in config["packages"]:
            if package["name"] in internal:
                check(package["rootUri"] == Path(internal[package["name"]]["root"]).as_uri(), "Internal package root changed")
                check(Path(internal[package["name"]]["root"]).is_relative_to(SOURCE), "Internal package points outside snapshot")
        record["packages"] = packages_observation(config)
        check(all("error" not in row for row in record["packages"]), "Package root/lib metadata or readability failed")
        record["tools"] = []
        for item in main_metadata["tools"]:
            path = Path(item["path"])
            no_link(path)
            info = path.stat()
            current = {"path": str(path), "bytes": info.st_size, "mtimeNs": info.st_mtime_ns, "sha256": hash_file(path)}
            record["tools"].append(current)
            check(all(current[key] == item[key] for key in ("bytes", "mtimeNs", "sha256")), "Pinned SDK tool changed")
        revision = subprocess.run(["git", "--no-optional-locks", "-C", str(SDK), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True, timeout=min(10, max(0.1, cutoff-time.monotonic())),
            creationflags=subprocess.CREATE_NO_WINDOW).stdout.strip()
        record["sdkGitRevision"] = revision
        record["flutterToolArgsEmpty"] = not os.environ.get("FLUTTER_TOOL_ARGS", "")
        check(revision == SDK_REVISION and record["flutterToolArgsEmpty"], "SDK revision/tool arguments changed")
        check(not (SDK / "bin/internal/bootstrap.bat").exists(), "SDK bootstrap hook exists")
        check((SDK / "packages/flutter_tools/pubspec.yaml").stat().st_mtime_ns <=
              (SDK / "packages/flutter_tools/pubspec.lock").stat().st_mtime_ns, "SDK bootstrap rebuild would be needed")
        record["disk"] = {drive: {"freeBytes": shutil.disk_usage(drive).free} for drive in ("C:\\", "D:\\")}
        record["sdkProcesses"] = sdk_processes()
        class MemoryStatus(ctypes.Structure):
            _fields_ = [("length", wintypes.DWORD), ("load", wintypes.DWORD)] + [(name, ctypes.c_ulonglong)
                for name in ("totalPhysical", "availablePhysical", "totalPagefile", "availablePagefile",
                             "totalVirtual", "availableVirtual", "availableExtendedVirtual")]
        memory = MemoryStatus()
        memory.length = ctypes.sizeof(memory)
        check(ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(memory)), "Memory metadata unavailable")
        record["availablePhysicalBytes"] = memory.availablePhysical
        record["totalPhysicalBytes"] = memory.totalPhysical
        check(not record["sdkProcesses"], "A shared SDK process is still active")
        check(memory.availablePhysical >= 2 * 1024**3, "Available RAM is below 2 GiB")
        check(record["disk"]["C:\\"]["freeBytes"] >= 1024**3 and record["disk"]["D:\\"]["freeBytes"] >= 2 * 1024**3, "Disk gate failed")
        record["passed"] = True
    except Exception as error:
        record["passed"] = False
        record["errors"].append(type(error).__name__ + ": " + str(error))
    finally:
        record["finishedAtUtc"] = utc()
        write_json(observation_path, record)
        work["observations"].append({"path": str(observation_path), "sha256": sha(observation_path), "passed": record["passed"]})
        write_json(STATE, work)
    check(record["passed"], "Gate failed: " + label + ": " + "; ".join(record["errors"]))
    return record


def worker(cutoff):
    check(sys.stdin.readline().strip() == "OWNED_JOB_READY", "Supervisor did not assign the owned job")
    work = {"status": "RUNNING", "runTag": "complete-parent-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"),
            "observations": [], "stages": []}
    write_json(STATE, work)
    manifest = main_metadata = None
    try:
        load_audited_functions()
        for path in (TASK, VARIANT, SOURCE, VARIANT / "out", VARIANT / "tmp"):
            no_link(path)
        check(sha(VARIANT / "input-manifest.json") == MANIFEST_SHA, "Manifest pin mismatch")
        check(sha(TASK / "complete-parent-v3-main-pins.json") == MAIN_METADATA_SHA, "Main metadata mismatch")
        manifest = json.loads((VARIANT / "input-manifest.json").read_bytes())
        main_metadata = json.loads((TASK / "complete-parent-v3-main-pins.json").read_bytes())
        check(len(manifest["sourceFiles"]) == 400 and len(manifest["explicitOverlays"]) == 6, "Frozen input shape differs")
        work["testFiles"] = sorted(item["path"] for item in manifest["sourceFiles"]
            if item["path"].startswith("apps/parent/test/") and item["path"].endswith("_test.dart"))
        check(len(work["testFiles"]) == 58, "Frozen test-file scope differs")
        scoped = [str(Path(item["path"]).relative_to("apps/parent")) for item in manifest["explicitOverlays"] if item["owner"] == "Root"]
        check(len(scoped) == 5, "Expected precisely 5 Root analysis files")
        stages = [("full", 240, ["--no-version-check", "--suppress-analytics", "test", "--no-pub", "--concurrency=1", "--reporter=expanded"]),
                  ("analyze", 60, ["--no-version-check", "--suppress-analytics", "analyze", "--no-pub"] + scoped)]
        for label, cap, args in stages:
            sample_gate("before-" + label, manifest, main_metadata, work, cutoff)
            budget = min(cap, cutoff - time.monotonic() - 8)
            check(budget > 0, "Insufficient time for command and release")
            log = VARIANT / "out" / (work["runTag"] + "-" + label + ".log")
            env = os.environ.copy()
            env["TEMP"] = env["TMP"] = str(VARIANT / "tmp")
            env["PUB_HOSTED_URL"] = env["FLUTTER_STORAGE_BASE_URL"] = "http://127.0.0.1:9"
            item = {"label": label, "argv": [str(SDK / "bin/flutter.bat")] + args,
                    "startedAtUtc": utc(), "budgetSeconds": budget, "log": str(log),
                    "workingDirectory": str(SOURCE / "apps/parent"), "processLocalTemp": env["TEMP"],
                    "childDownloadEndpoints": {name: env[name] for name in ("PUB_HOSTED_URL", "FLUTTER_STORAGE_BASE_URL")}}
            with log.open("xb") as stream:
                child = subprocess.Popen([os.environ["COMSPEC"], "/d", "/c", str(SDK / "bin/flutter.bat")] + args,
                    cwd=SOURCE / "apps/parent", env=env, stdout=stream, stderr=subprocess.STDOUT,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                item["pid"] = child.pid
                work["stages"].append(item)
                write_json(STATE, work)
                print(json.dumps({"stage": label, "pid": child.pid, "budgetSeconds": budget}), flush=True)
                try:
                    item["exitCode"] = child.wait(timeout=budget)
                    item["naturalExit"] = True
                except subprocess.TimeoutExpired:
                    item.update(exitCode=None, naturalExit=False, timedOut=True, timeoutObservedAtUtc=utc())
                    write_json(STATE, work)
                    raise RuntimeError("Command timed out; supervisor must terminate its owned job")
            item["endedAtUtc"] = utc()
            item["logSha256"] = sha(log)
            text = log.read_text(encoding="utf-8", errors="replace")
            check(item["exitCode"] == 0, label + " returned nonzero")
            if label == "full":
                summary = re.search(r"(?m)^\d+:\d+\s+\+(\d+): All tests passed!\s*$", text)
                check(summary is not None, "Full suite has no genuine All tests passed summary")
                item["actualPassedCount"] = int(summary.group(1))
            write_json(STATE, work)
        sample_gate("release", manifest, main_metadata, work, cutoff)
        work["status"] = "COMPLETE_CANDIDATE"
    except Exception as error:
        work["status"] = "FAILED"
        work["error"] = type(error).__name__ + ": " + str(error)
        active_timeout = any(item.get("timedOut") for item in work["stages"])
        if not active_timeout and manifest is not None and main_metadata is not None and time.monotonic() < cutoff - 3:
            try:
                sample_gate("failed-release", manifest, main_metadata, work, cutoff)
            except Exception as release_error:
                work["releaseError"] = str(release_error)
    finally:
        work["finishedAtUtc"] = utc()
        write_json(STATE, work)
    return 0 if work["status"] == "COMPLETE_CANDIDATE" else 1


class Job:
    """Kernel ownership boundary: kill only this worker and inherited children."""
    def __init__(self):
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.CreateJobObjectW.restype = wintypes.HANDLE
        self.api.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        self.api.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        self.api.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        self.api.QueryInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p]
        self.api.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        self.api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.api.OpenProcess.restype = wintypes.HANDLE
        self.api.IsProcessInJob.argtypes = [wintypes.HANDLE, wintypes.HANDLE, ctypes.POINTER(wintypes.BOOL)]
        self.api.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        class Basic(ctypes.Structure):
            _fields_ = [("processTime", ctypes.c_longlong), ("jobTime", ctypes.c_longlong), ("flags", wintypes.DWORD),
                ("minimum", ctypes.c_size_t), ("maximum", ctypes.c_size_t), ("active", wintypes.DWORD),
                ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD), ("scheduling", wintypes.DWORD)]
        class Extended(ctypes.Structure):
            _fields_ = [("basic", Basic), ("io", ctypes.c_ulonglong * 6), ("processMemory", ctypes.c_size_t),
                ("jobMemory", ctypes.c_size_t), ("peakProcess", ctypes.c_size_t), ("peakJob", ctypes.c_size_t)]
        self.handle = self.api.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = Extended()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.api.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            raise ctypes.WinError(ctypes.get_last_error())

    def assign(self, child):
        if not self.api.AssignProcessToJobObject(self.handle, wintypes.HANDLE(int(child._handle))):
            raise ctypes.WinError(ctypes.get_last_error())

    def active(self):
        class Accounting(ctypes.Structure):
            _fields_ = [("times", ctypes.c_longlong * 4), ("pageFaults", wintypes.DWORD),
                        ("total", wintypes.DWORD), ("active", wintypes.DWORD), ("terminated", wintypes.DWORD)]
        value = Accounting()
        if not self.api.QueryInformationJobObject(self.handle, 1, ctypes.byref(value), ctypes.sizeof(value), None):
            raise ctypes.WinError(ctypes.get_last_error())
        return value.active

    def terminate(self):
        if not self.api.TerminateJobObject(self.handle, 124):
            raise ctypes.WinError(ctypes.get_last_error())


def supervisor():
    start = time.monotonic()
    start_utc = datetime.datetime.now(datetime.timezone.utc)
    hard_deadline = start + 330
    cutoff = hard_deadline - 6
    result = {"status": "RUNNING", "startedAtUtc": start_utc.isoformat(),
              "deadlineUtc": (start_utc + datetime.timedelta(seconds=330)).isoformat(),
              "outerBudgetSeconds": 330, "terminationReserveSeconds": 6,
              "manifestSha256": MANIFEST_SHA, "mainMetadataSha256": MAIN_METADATA_SHA}
    check(not STATE.exists(), "Single-use worker state already exists")
    with RESULT.open("x", encoding="utf-8") as stream:
        json.dump(result, stream)
    print(json.dumps(result), flush=True)
    job = child = timer = hard_timer = None
    assigned = False
    stage_handles = {}
    expired = threading.Event()
    try:
        check(os.name == "nt", "This bounded runner requires the Windows job API")
        job = Job()
        def expire():
            expired.set()
            job.terminate()
        timer = threading.Timer(max(0, cutoff-time.monotonic()), expire)
        timer.daemon = True
        timer.start()
        # Last-resort process terminal bound, including supervisor publication.
        # Closing this process also closes its kill-on-close owned job handle.
        hard_timer = threading.Timer(max(0, hard_deadline-time.monotonic()), lambda: os._exit(124))
        hard_timer.daemon = True
        hard_timer.start()
        child = subprocess.Popen([sys.executable, "-B", str(Path(__file__).resolve()), "--worker", str(cutoff)],
            stdin=subprocess.PIPE, text=True, creationflags=subprocess.CREATE_NO_WINDOW)
        result["workerPid"] = child.pid
        job.assign(child)
        assigned = True
        child.stdin.write("OWNED_JOB_READY\n")
        child.stdin.flush()
        child.stdin.close()
        while child.poll() is None and time.monotonic() < hard_deadline:
            if STATE.exists():
                state = json.loads(STATE.read_text(encoding="utf-8"))
                for item in state.get("stages", []):
                    pid = item["pid"]
                    if pid not in stage_handles:
                        handle = job.api.OpenProcess(0x1000 | 0x100000, False, pid)
                        if handle:
                            belongs = wintypes.BOOL()
                            if job.api.IsProcessInJob(handle, job.handle, ctypes.byref(belongs)) and belongs.value:
                                stage_handles[pid] = handle
                            else:
                                job.api.CloseHandle(handle)
            time.sleep(0.1)
        if child.poll() is None or job.active() != 0:
            job.terminate()
        child.wait(timeout=max(0.1, min(3, hard_deadline-time.monotonic())))
        while job.active() and time.monotonic() < hard_deadline:
            time.sleep(0.05)
        result["workerActualExitCode"] = child.returncode
        result["ownedJobActiveProcesses"] = job.active()
        result["ownedTreeTerminalConfirmed"] = result["ownedJobActiveProcesses"] == 0
        result["watchdogExpired"] = expired.is_set()
        result["worker"] = json.loads(STATE.read_text(encoding="utf-8")) if STATE.exists() else None
        for item in (result["worker"] or {}).get("stages", []):
            if item["pid"] in stage_handles:
                actual = wintypes.DWORD()
                if job.api.GetExitCodeProcess(stage_handles[item["pid"]], ctypes.byref(actual)):
                    item["actualExitCodeFromOwnedHandle"] = actual.value
            log = Path(item["log"])
            if log.is_file():
                item["finalLogSha256AfterOwnedTreeTerminal"] = sha(log)
            item.setdefault("endedAtUtc", utc())
        passed = (not expired.is_set() and child.returncode == 0 and result["ownedTreeTerminalConfirmed"]
                  and result["worker"] and result["worker"]["status"] == "COMPLETE_CANDIDATE"
                  and time.monotonic() < hard_deadline)
        result["status"] = "COMPLETE" if passed else "FAILED"
    except Exception as error:
        result.update(status="FAILED", supervisorError=type(error).__name__ + ": " + str(error))
        if job is not None:
            job.terminate()
        if child is not None and not assigned:
            if child.stdin is not None and not child.stdin.closed:
                child.stdin.close()
            if child.poll() is None:
                child.terminate()  # Exact Popen handle; handshake was never sent.
        if child is not None:
            child.wait(timeout=max(0.1, min(3, hard_deadline-time.monotonic())))
    finally:
        if timer is not None:
            timer.cancel()
            timer.join(timeout=max(0.1, min(1, hard_deadline-time.monotonic())))
        if job is not None:
            for handle in stage_handles.values():
                job.api.CloseHandle(handle)
            try:
                result["ownedTreeTerminalConfirmed"] = job.active() == 0 and (child is None or child.poll() is not None)
            except Exception as terminal_error:
                result["ownedTreeTerminalConfirmed"] = False
                result["terminalVerificationError"] = str(terminal_error)
            finally:
                job.api.CloseHandle(job.handle)
        result["finishedAtUtc"] = utc()
        result["elapsedSeconds"] = time.monotonic() - start
        if result["elapsedSeconds"] >= 330 or not result.get("ownedTreeTerminalConfirmed"):
            result["status"] = "FAILED"
        write_json(RESULT, result)
        print(json.dumps({"status": result["status"], "elapsedSeconds": result["elapsedSeconds"],
                          "result": str(RESULT), "sha256": sha(RESULT)}), flush=True)
        if hard_timer is not None:
            hard_timer.cancel()
    return 0 if result["status"] == "COMPLETE" else 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["--worker"]:
        raise SystemExit(worker(float(sys.argv[2])))
    check(not sys.argv[1:], "No retry, filter, pub, format, or alternate-input arguments are accepted")
    raise SystemExit(supervisor())
