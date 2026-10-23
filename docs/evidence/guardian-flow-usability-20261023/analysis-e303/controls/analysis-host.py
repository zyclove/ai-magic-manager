"""Fixed analysis host source; requires a separately granted exact proposal SHA."""
from time import monotonic
ANCHOR = monotonic()
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import sys
import time

HERE = Path(__file__).absolute().parent
EXPECTED_HERE = Path(r'D:\codes\mobile\ai-manager\.cache\guardian-analyze-20261023-r10-e303')
PYTHON = Path(r'C:\Python313\python.exe')
SOURCE_COMMIT = 'e303580030192497a63492d1147156e465082706'
BUDGETS = {'outer': 180, 'working': 174, 'worker': 165, 'command': 135,
           'commandCleanup': 140, 'postflightReserve': 25}
NAMES = {'analysis-host.py', 'worker.py', 'owned_job.py'}
WORK_END = ANCHOR + 174.0
FINISH_END = ANCHOR + 180.0


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def finite(value):
    return type(value) is float and math.isfinite(value)


def before(deadline):
    require(finite(deadline) and monotonic() < deadline, 'Original deadline exhausted')


def safe(path):
    path = Path(path)
    require(path.is_absolute() and not str(path).startswith('\\\\')
            and ':' not in str(path)[2:], 'Local absolute non-ADS path required')
    for item in (path, *path.parents):
        require(not item.is_symlink() and not item.is_junction(), 'Linked path refused')
    return path


def digest(path, deadline):
    before(deadline)
    path = safe(path)
    first = path.stat()
    require(path.is_file(), 'Regular pinned file required')
    value = hashlib.sha256()
    count = 0
    with path.open('rb') as stream:
        while True:
            before(deadline)
            part = stream.read(1024 * 1024)
            if not part:
                break
            value.update(part)
            count += len(part)
    last = safe(path).stat()
    require((first.st_dev, first.st_ino, first.st_nlink, first.st_size, first.st_mtime_ns)
            == (last.st_dev, last.st_ino, last.st_nlink, last.st_size, last.st_mtime_ns)
            and count == first.st_size, 'Input changed during hash')
    before(deadline)
    return count, value.hexdigest()


def descriptor(row, deadline, *, candidate=False):
    require(type(row) is dict and set(row) in
            ({'path', 'bytes', 'sha256'}, {'path', 'bytes', 'sha256', 'absolute'}),
            'Exact descriptor fields required')
    require(type(row['path']) is str and type(row['bytes']) is int and row['bytes'] >= 0
            and type(row['sha256']) is str
            and re.fullmatch('[a-f0-9]{64}', row['sha256']) is not None,
            'Typed descriptor required')
    if 'absolute' in row:
        require(row['absolute'] is True, 'Only true absolute marker permitted')
    if candidate:
        require(row['path'] in NAMES and 'absolute' not in row, 'Fixed relative control file required')
        path = HERE / row['path']
    else:
        path = Path(row['path'])
        require(path.is_absolute(), 'Absolute runtime/input descriptor required')
    count, observed = digest(path, deadline)
    require(count == row['bytes'] and observed == row['sha256'], 'Pinned input changed: ' + str(path))
    return str(path).casefold(), count, observed


def save(path, value):
    with path.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def complete_terminal(state):
    return (type(state) is dict and state.get('terminal') is True
            and state.get('signaled') is True and type(state.get('exitCode')) is int
            and type(state.get('activeProcesses')) is int and state['activeProcesses'] == 0
            and type(state.get('creationFiletime')) is int and state['creationFiletime'] > 0
            and type(state.get('exitFiletime')) is int
            and state['exitFiletime'] >= state['creationFiletime']
            and finite(state.get('firstSignaledQpc'))
            and finite(state.get('firstCompleteTerminalQpc')))


def worker_outcome(receipt, terminal, before_resume, attempt):
    if type(receipt) is not dict or not finite(before_resume) or not complete_terminal(terminal):
        return False
    start = receipt.get('workerStartQpc')
    finished = receipt.get('workerFinishedQpc')
    elapsed = receipt.get('elapsedCompleteSeconds')
    if not (finite(start) and finite(finished) and finite(elapsed)
            and before_resume <= start <= finished <= terminal['firstSignaledQpc']
            and 0.0 <= elapsed < 165.0 and elapsed == finished - start
            and receipt.get('workerDeadlineQpc') == start + 165.0
            and type(receipt.get('workerDeadlineQpc')) is float
            and receipt.get('commandDeadlineQpc') == start + 135.0
            and type(receipt.get('commandDeadlineQpc')) is float
            and receipt.get('commandCleanupDeadlineQpc') == start + 140.0
            and type(receipt.get('commandCleanupDeadlineQpc')) is float
            and terminal['firstCompleteTerminalQpc'] < start + 165.0):
        return False
    if not (type(receipt.get('sdkCalls')) is int and receipt['sdkCalls'] == 1
            and receipt.get('forcedTermination') is False
            and receipt.get('commandCloseFallback') is False
            and receipt.get('commandNaturalCompleteBeforeDeadline') is True
            and receipt.get('noIssuesFound') is True
            and receipt.get('testsRun') is False and receipt.get('pubRun') is False
            and receipt.get('downloadsAllowed') is False and receipt.get('cacheCopied') is False
            and receipt.get('mainSourceWritten') is False
            and type(receipt.get('preflight')) is dict
            and receipt['preflight'].get('complete') is True
            and type(receipt.get('postflight')) is dict
            and receipt['postflight'].get('complete') is True
            and 'errorType' not in receipt
            and not any(name.endswith('Error') for name in receipt)):
        return False
    first = receipt.get('commandTerminalState')
    last = receipt.get('commandTerminalStateAfterPostflight')
    if not (complete_terminal(first) and complete_terminal(last)
            and first['exitCode'] == 0 and last['exitCode'] == 0
            and first['creationFiletime'] == last['creationFiletime']
            and first['firstSignaledQpc'] == last['firstSignaledQpc']
            and first['firstCompleteTerminalQpc'] == last['firstCompleteTerminalQpc']
            and start <= first['firstSignaledQpc'] <= first['firstCompleteTerminalQpc']
            < min(start + 135.0, first['firstSignaledQpc'] + 0.5)):
        return False
    gate = receipt.get('resourceAfter')
    if not (type(gate) is dict and type(gate.get('sdkProcesses')) is list
            and gate['sdkProcesses'] == [] and type(gate.get('unknownProcessNames')) is list
            and gate['unknownProcessNames'] == []
            and type(gate.get('availableRamBytes')) is int and gate['availableRamBytes'] >= 2**31
            and type(gate.get('diskFreeBytes')) is dict
            and set(gate['diskFreeBytes']) == {'C:/', 'D:/'}
            and all(type(v) is int and v >= 2**31 for v in gate['diskFreeBytes'].values())):
        return False
    log_pin = receipt.get('logPin')
    if type(log_pin) is not dict or Path(log_pin.get('path', '')) != attempt / 'out/analyze.log':
        return False
    descriptor(log_pin, FINISH_END)
    return 'No issues found!' in (attempt / 'out/analyze.log').read_text('utf-8', errors='replace')


def main():
    require(os.name == 'nt' and sys.version_info[:2] == (3, 13), 'Fixed Windows Python 3.13 only')
    require(sys.flags.isolated == 1 and sys.dont_write_bytecode, 'Host requires -I -B')
    require(Path(sys.executable).absolute() == PYTHON and HERE == EXPECTED_HERE,
            'Fixed host path and Python executable required')
    require(time.get_clock_info('monotonic').implementation == 'QueryPerformanceCounter()',
            'Shared Windows QPC required')
    require(len(sys.argv) == 3 and sys.argv[1] == 'analyze'
            and re.fullmatch('[a-f0-9]{64}', sys.argv[2]) is not None,
            'Only analyze exact-proposal-SHA interface')
    safe(HERE)
    proposal_path = HERE / 'proposal.json'
    require(digest(proposal_path, WORK_END)[1] == sys.argv[2], 'Approved proposal changed')
    proposal = json.loads(proposal_path.read_bytes())
    require(type(proposal) is dict and set(proposal) == {'schemaVersion', 'phase', 'sourceCommit',
            'inputs', 'candidateFiles', 'runtimePins', 'pythonExecutable', 'budgets'},
            'Exact fixed analysis proposal schema required')
    require(type(proposal['schemaVersion']) is int and proposal['schemaVersion'] == 1
            and proposal['phase'] == 'analyze-all-guardian' and proposal['sourceCommit'] == SOURCE_COMMIT
            and proposal['pythonExecutable'] == 'C:/Python313/python.exe', 'Fixed phase/source/runtime required')
    budgets = proposal['budgets']
    require(type(budgets) is dict and set(budgets) == set(BUDGETS)
            and all(type(budgets[k]) is int and budgets[k] == v for k, v in BUDGETS.items()),
            'Original absolute budget ceilings required')
    require(type(proposal['candidateFiles']) is list and len(proposal['candidateFiles']) == 3
            and {r.get('path') for r in proposal['candidateFiles'] if type(r) is dict} == NAMES,
            'Only three fixed controls allowed')
    for row in proposal['candidateFiles']:
        descriptor(row, WORK_END, candidate=True)
    descriptor(proposal['inputs'], WORK_END)
    require(Path(proposal['inputs']['path']) == HERE / 'inputs.json', 'Fixed input path required')
    inputs = json.loads((HERE / 'inputs.json').read_bytes())
    require(inputs['phase'] == 'analyze-all-guardian' and inputs['sourceCommit'] == SOURCE_COMMIT,
            'Input phase/source changed')
    require(type(proposal['runtimePins']) is list and proposal['runtimePins'], 'Runtime pins required')
    runtime_rows = [descriptor(r, WORK_END) for r in proposal['runtimePins']]
    input_runtime = [descriptor(r, WORK_END)
                     for r in inputs['controlRuntimeFiles'] + inputs['extraRuntimeFiles']]
    require(len(runtime_rows) == len(set(runtime_rows)) and set(runtime_rows) == set(input_runtime)
            and any(Path(r['path']) == PYTHON for r in proposal['runtimePins']),
            'Complete exact input runtime union required')
    attempt = HERE / 'attempt'
    require(not attempt.is_symlink() and not attempt.is_junction(), 'Linked attempt refused')
    attempt.mkdir()
    host_temp = attempt / 'host-tmp'
    host_temp.mkdir()
    save(attempt / 'request.json', {'approvedProposalSha256': sys.argv[2], 'qpcAnchor': ANCHOR,
         'workDeadlineQpc': WORK_END, 'cleanupDeadlineQpc': FINISH_END,
         'sourceCommit': SOURCE_COMMIT, 'phase': 'analyze-all-guardian'})
    spec = importlib.util.spec_from_file_location('guardian_analysis_owned_job', HERE / 'owned_job.py')
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    environment = os.environ.copy()
    environment.update(TEMP=str(host_temp), TMP=str(host_temp))
    job = None
    state = None
    events = []
    error = None
    drain_end = None
    first_signaled_state = None
    first_signaled_members = None
    final_members = None
    before_resume = None
    maximum_total = 0
    deadline_reached = False
    def event(name):
        if len(events) < 64:
            events.append({'stage': name, 'qpc': monotonic()})
    def capture_first(current, deadline):
        nonlocal first_signaled_state, first_signaled_members
        if current['signaled'] and first_signaled_state is None:
            first_signaled_state = dict(current)
            first_signaled_members = job.member_identities(deadline)
    try:
        before(WORK_END)
        job = native.OwnedJob()
        event('before-create-suspended')
        job.create_suspended([str(PYTHON), '-I', '-B', '-u', str(HERE / 'worker.py')],
                             HERE, attempt / 'worker-console.log', environment)
        before(WORK_END)
        paused = job.sample(0)
        require(not paused['signaled'] and paused['activeProcesses'] == 1,
                'Unexpected suspended worker membership')
        before_resume = monotonic()
        job.resume()
        event('after-resume')
        while True:
            sample_deadline = min(WORK_END, drain_end) if drain_end is not None else WORK_END
            remaining = sample_deadline - monotonic()
            state = job.sample(max(0, min(50, int(max(0.0, remaining) * 1000))))
            maximum_total = max(maximum_total, state['totalProcesses'])
            if state['signaled']:
                capture_first(state, min(WORK_END, state['firstSignaledQpc'] + 0.5))
            if state['terminal']:
                break
            if state['signaled']:
                if drain_end is None:
                    drain_end = min(WORK_END, state['firstSignaledQpc'] + 0.5)
                    event('natural-drain-started')
                if monotonic() < drain_end:
                    time.sleep(min(0.01, max(0.0, drain_end - monotonic())))
                    continue
                event('natural-drain-exhausted')
            if monotonic() >= WORK_END or (state['signaled'] and drain_end is not None
                                          and monotonic() >= drain_end):
                deadline_reached = monotonic() >= WORK_END
                state = job.sample(0)
                maximum_total = max(maximum_total, state['totalProcesses'])
                capture_first(state, WORK_END)
                if state['terminal']:
                    break
                job.terminate_owned()
                event('owned-termination-requested')
                break
        while state is not None and not state['terminal'] and monotonic() < FINISH_END:
            state = job.sample(max(0, min(50, int(max(0.0, FINISH_END - monotonic()) * 1000))))
            maximum_total = max(maximum_total, state['totalProcesses'])
            capture_first(state, FINISH_END)
    except Exception as failure:
        error = type(failure).__name__ + ': ' + str(failure)
        if job is not None and job.process is not None:
            job.terminate_owned()
            while monotonic() < FINISH_END:
                state = job.sample(max(0, min(50, int(max(0.0, FINISH_END - monotonic()) * 1000))))
                maximum_total = max(maximum_total, state['totalProcesses'])
                capture_first(state, FINISH_END)
                if state['terminal']:
                    break
    finally:
        forced = job.force_requested if job else False
        force_ok = job.force_succeeded if job else False
        close_fallback = not (state and state['terminal'])
        if job and job.process:
            try:
                final_members = job.member_identities(FINISH_END)
            except Exception as failure:
                error = error or type(failure).__name__ + ': ' + str(failure)
        if job:
            job.close()
    # All receipt/log/hash/output I/O is after monitoring, under the original 180 ceiling.
    pins_after = False
    receipt = None
    reported = False
    derived = False
    try:
        require(digest(proposal_path, FINISH_END)[1] == sys.argv[2], 'Proposal changed after launch')
        for row in proposal['candidateFiles']:
            descriptor(row, FINISH_END, candidate=True)
        descriptor(proposal['inputs'], FINISH_END)
        for row in proposal['runtimePins']:
            descriptor(row, FINISH_END)
        pins_after = True
        receipt_path = safe(attempt / 'receipt.json')
        require(receipt_path.is_file() and receipt_path.stat().st_size <= 2 * 1024 * 1024,
                'Bounded worker receipt missing')
        receipt = json.loads(receipt_path.read_bytes())
        reported = type(receipt) is dict and receipt.get('status') == 'FULL_GUARDIAN_ANALYZE_WORKER_PASSED'
        derived = worker_outcome(receipt, state, before_resume, attempt)
        if reported != derived:
            error = error or 'Worker reported/derived result mismatch'
    except Exception as failure:
        error = error or type(failure).__name__ + ': ' + str(failure)
    natural = (complete_terminal(state) and state['exitCode'] == 0
               and state['firstSignaledQpc'] <= state['firstCompleteTerminalQpc']
               < min(WORK_END, state['firstSignaledQpc'] + 0.5))
    accepted = bool(natural and not forced and not close_fallback and not deadline_reached
                    and error is None and pins_after and reported and derived
                    and monotonic() < FINISH_END)
    result = {'status': 'FULL_GUARDIAN_ANALYZE_HOST_OBSERVED' if accepted else 'NOT_ACCEPTED',
              'phase': 'analyze-all-guardian', 'sourceCommit': SOURCE_COMMIT,
              'approvedProposalSha256': sys.argv[2], 'qpcAnchor': ANCHOR,
              'workDeadlineQpc': WORK_END, 'cleanupDeadlineQpc': FINISH_END,
              'workerResumeBeforeQpc': before_resume, 'terminal': state,
              'firstSignaledState': first_signaled_state,
              'firstSignaledOwnJobMembers': first_signaled_members, 'finalOwnJobMembers': final_members,
              'maximumObservedJobTotal': maximum_total, 'naturalDrainLimitSeconds': 0.5,
              'naturalDrainDeadlineQpc': drain_end, 'naturalCompleteTerminalTimely': natural,
              'forcedCleanupRequested': forced, 'terminationCallSucceeded': force_ok,
              'closedWithLiveOrUnknownMembers': close_fallback, 'deadlineReached': deadline_reached,
              'candidateAndRuntimePinsMatchAfter': pins_after, 'workerReportedPassed': reported,
              'workerDerivedPassed': derived, 'workerReportedDerivedConsistent': reported == derived,
              'workerReceipt': receipt, 'error': error, 'events': events,
              'analysisAcceptedBeforeOutput': accepted, 'rootActualSameHandleExitStillRequired': True,
              'rootFullProcessReleaseStillRequired': True, 'sdkCalls': receipt.get('sdkCalls') if type(receipt) is dict else None,
              'testsRun': False, 'entirePythonOrSdkInstallationPinned': False}
    result['observedBeforeOutputQpc'] = monotonic()
    result['elapsedBeforeOutputSeconds'] = result['observedBeforeOutputQpc'] - ANCHOR
    save(attempt / 'result.json', result)
    print(json.dumps({'status': result['status'], 'rootActualSameHandleExitStillRequired': True}), flush=True)
    return 0 if accepted and monotonic() < FINISH_END else 1


if __name__ == '__main__':
    try:
        code = main()
    except Exception as failure:
        print(json.dumps({'status': 'NOT_ACCEPTED', 'errorType': type(failure).__name__,
                          'reason': str(failure), 'rootActualSameHandleExitStillRequired': True}), flush=True)
        code = 1
    os._exit(code)
