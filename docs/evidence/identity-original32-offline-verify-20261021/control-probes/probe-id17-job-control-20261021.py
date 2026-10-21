"""Exercise only a newly owned empty Python worker; no Java/Maven/provider work."""
import datetime
import json
from pathlib import Path
import subprocess
import sys
import time
import win32job

started = time.monotonic()
job = child = None
assigned = False
record = {"startedAtUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "scope": "one self-created Python stdin-barrier worker; no SDK, source or cache copies",
          "sdkStarted": False, "accepted": False}
try:
    job = win32job.CreateJobObject(None, "")
    limits = win32job.QueryInformationJobObject(job, win32job.JobObjectExtendedLimitInformation)
    limits["BasicLimitInformation"]["LimitFlags"] |= win32job.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    win32job.SetInformationJobObject(job, win32job.JobObjectExtendedLimitInformation, limits)
    child = subprocess.Popen([sys.executable, "-I", "-B", "-c",
        "import sys; token=sys.stdin.readline(); sys.exit(0 if token=='OWNED_JOB_READY\\n' else 2)"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, creationflags=subprocess.CREATE_NO_WINDOW)
    record["workerPid"] = child.pid
    win32job.AssignProcessToJobObject(job, int(child._handle))
    assigned = True
    child.stdin.write("OWNED_JOB_READY\n")
    child.stdin.flush()
    child.stdin.close()
    child.wait(timeout=3)
    active = win32job.QueryInformationJobObject(job, win32job.JobObjectBasicAccountingInformation)["ActiveProcesses"]
    record.update(exitCode=child.returncode, ownedJobActiveProcesses=active,
                  accepted=child.returncode == 0 and active == 0)
finally:
    if child is not None and child.poll() is None:
        if assigned:
            win32job.TerminateJobObject(job, 124)
        else:
            child.terminate()
        child.wait(timeout=3)
        record["accepted"] = False
        record["forcedCleanup"] = True
    if child is not None:
        for stream in (child.stdin, child.stdout, child.stderr):
            if stream is not None and not stream.closed:
                stream.close()
    if job is not None:
        job.Close()
    record["elapsedSeconds"] = time.monotonic() - started
    record["finishedAtUtc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with Path(__file__).with_suffix(".json").open("x", encoding="utf-8", newline="\n") as output:
        json.dump(record, output, indent=2)
        output.write("\n")
    print(json.dumps(record), flush=True)
raise SystemExit(0 if record["accepted"] else 1)
