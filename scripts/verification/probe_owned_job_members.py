"""Qualify retained member handles using two controlled Python processes only."""
import ctypes as C
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import sys
import time
from types import SimpleNamespace

from owned_job import OwnedJob

ROOT = Path(__file__).resolve().parents[2]
CLASSIFIER = Path(__file__).with_name('owned_chrome_evidence.py')
CLASSIFIER_SHA = '81be26d61faf4b2a77a18b0c2cd8b34c908e776517dc95159b3c903b8e2371b0'
FINALITY_HOOK = Path(__file__).with_name('worker-command-finality-hook.fragment')
FINALITY_SHA = '332e6e3830b33d26208f0bc42ec3fa089d1812c9972b1ce94eb062c5d4ab89b4'
CHILD = '''import gc, json, subprocess, sys, time
from pathlib import Path
work = Path(sys.argv[-1])
deadline = time.monotonic() + 8
def wait(name):
    while not (work / name).exists():
        if time.monotonic() >= deadline: raise SystemExit(2)
        time.sleep(.005)
if sys.argv[1] == '--child':
    wait('release-child')
else:
    child = subprocess.Popen([sys.executable, __file__, '--child', str(work)])
    (work / 'ready.json').write_text(json.dumps({'childPid': child.pid}))
    if child.wait(timeout=8) != 0: raise SystemExit(3)
    del child
    gc.collect()
    (work / 'child-reaped').touch()
    wait('finish-root')
'''


def require(value, message):
    if not value:
        raise RuntimeError(message)


def wait_file(path, deadline):
    while not path.exists():
        require(time.monotonic() < deadline, 'Owned handshake timed out')
        time.sleep(.005)


def resource_gate():
    class MemoryStatus(C.Structure):
        _fields_ = [('length', C.c_ulong), ('load', C.c_ulong)] + [
            (name, C.c_ulonglong) for name in (
                'totalPhys', 'availPhys', 'totalPage', 'availPage',
                'totalVirtual', 'availVirtual', 'availExtended')]
    status = MemoryStatus()
    status.length = C.sizeof(status)
    kernel = C.WinDLL('kernel32', use_last_error=True)
    query = kernel.GlobalMemoryStatusEx
    query.argtypes = [C.POINTER(MemoryStatus)]
    query.restype = C.c_int
    require(query(C.byref(status)), 'Cannot read original resource gate')
    return {'ram': int(status.availPhys),
            'cFree': shutil.disk_usage('C:/').free,
            'dFree': shutil.disk_usage('D:/').free}


def run(output):
    require(os.name == 'nt', 'This native probe is Windows-only')
    task = (ROOT / '.cache/retained-member-20261026-r1').resolve()
    output = output.resolve()
    require(output.parent == task, 'Output must remain in the exact task directory')
    output.mkdir(exist_ok=False)
    deadline = time.monotonic() + 12
    receipt = {'status': 'NOT_RUN', 'sdkCalls': 0, 'nativeRoots': 0,
               'foreignProcessesRead': 0, 'commandLinesRead': 0,
               'childEnvironmentsRead': 0, 'browserAcceptanceClaimed': False}
    job = None
    original_query = None
    try:
        require(hashlib.sha256(CLASSIFIER.read_bytes()).hexdigest() == CLASSIFIER_SHA,
                'Original member classifier changed')
        require(hashlib.sha256(FINALITY_HOOK.read_bytes()).hexdigest() == FINALITY_SHA,
                'Original finality transaction changed')
        receipt['resourcesBefore'] = resource_gate()
        require(min(receipt['resourcesBefore'].values()) >= 2**31,
                'Original resource gate not met')
        (output / 'tmp').mkdir()
        child_source = output / 'controlled_child.py'
        child_source.write_text(CHILD, encoding='utf-8')
        environment = os.environ.copy()
        environment.update(TEMP=str(output / 'tmp'), TMP=str(output / 'tmp'))
        job = OwnedJob()
        job.create_suspended([sys.executable, str(child_source), '--root', str(output)],
                             ROOT, output / 'root.log', environment)
        receipt['nativeRoots'] = 1
        job.resume()
        wait_file(output / 'ready.json', deadline)
        child_pid = json.loads((output / 'ready.json').read_text())['childPid']
        first = job.member_identities(deadline)
        child = next(row for row in first['identities'] if row['pid'] == child_pid)
        require(child.get('verifiedOwnMembership') is True
                and child.get('creationFiletime', 0) >= job.identity,
                'Child identity was not proved before releasing it')
        creation = child['creationFiletime']
        before_stats = dict(job.member_cache_stats)
        receipt.update(firstSnapshot=first, statsBefore=before_stats)
        verified_children = [row for row in first['identities']
                             if row['pid'] != job.pid
                             and row.get('verifiedOwnMembership') is True
                             and row.get('creationFiletime', 0) >= job.identity]
        require(before_stats['retained'] == len(verified_children)
                and before_stats['retained'] > 0,
                'Every retained child must have its own same-handle identity proof')
        original_query = job.k.QueryInformationJobObject
        release_once = [True]

        def controlled_query(handle, kind, buffer, size, returned):
            okay = original_query(handle, kind, buffer, size, returned)
            if okay and kind == 3 and release_once[0]:
                listing = buffer._obj
                pids = [int(listing.ids[i]) for i in range(int(listing.listed))]
                require(child_pid in pids, 'Child absent from the controlled before list')
                release_once[0] = False
                (output / 'release-child').touch()
                wait_file(output / 'child-reaped', min(deadline, time.monotonic() + 3))
            return okay

        job.k.QueryInformationJobObject = controlled_query
        second = job.member_identities(deadline)
        job.k.QueryInformationJobObject = original_query
        original_query = None
        receipt['exitedSnapshot'] = second
        exited = next(row for row in second['identities'] if row['pid'] == child_pid)
        require(exited.get('verifiedOwnMembership') is True
                and exited.get('creationFiletime') == creation
                and exited.get('signaled') is True and exited.get('exitCode') == 0,
                'Retained child identity/exit was not proved with the original handle')
        after_stats = dict(job.member_cache_stats)
        require(after_stats['opens'] == before_stats['opens']
                and after_stats['reuses'] > before_stats['reuses'],
                'Exited child was reopened by PID instead of reusing its handle')
        spec = importlib.util.spec_from_file_location('original_member_classifier', CLASSIFIER)
        classifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(classifier)
        observer = classifier.OwnedChromeEvidence.__new__(classifier.OwnedChromeEvidence)
        observer.job = job
        observer.reader = SimpleNamespace(deadline=deadline)
        observer.deadline = deadline
        kinds = observer._snapshot_kinds(second)
        require('fatal' not in kinds, 'Original unchanged identity classifier rejected snapshot')
        (output / 'finish-root').touch()
        state = job.sample(0)
        while not state['terminal'] and time.monotonic() < deadline:
            state = job.sample(20)
        require(state['terminal'] and state['exitCode'] == 0
                and not job.force_requested, 'Private job did not drain naturally')
        def natural_command(value):
            return (type(value) is dict and value.get('terminal') is True
                    and value.get('signaled') is True
                    and type(value.get('exitCode')) is int and value['exitCode'] == 0
                    and type(value.get('activeProcesses')) is int
                    and value['activeProcesses'] == 0
                    and type(value.get('firstSignaledQpc')) is float
                    and math.isfinite(value['firstSignaledQpc'])
                    and type(value.get('firstCompleteTerminalQpc')) is float
                    and math.isfinite(value['firstCompleteTerminalQpc'])
                    and deadline - 12 <= value['firstSignaledQpc']
                    <= value['firstCompleteTerminalQpc']
                    < min(deadline, value['firstSignaledQpc'] + .5))

        namespace = {
            'natural_command': natural_command, 'require': require,
            'receipt': {'commandCloseFallback': False}, 'COMMAND_END': deadline,
            'monotonic': time.monotonic,
            'same_json': lambda left, right: json.dumps(left, sort_keys=True,
                allow_nan=False) == json.dumps(right, sort_keys=True, allow_nan=False),
        }
        exec(compile(FINALITY_HOOK.read_text(encoding='utf-8'), str(FINALITY_HOOK), 'exec'),
             namespace)
        finality = namespace['capture_command_finality'](job, state)
        require(observer._finality_valid(finality),
                'Original finality gate rejected retained-handle job drain')
        receipt.update(status='PASSED', firstSnapshot=first, exitedSnapshot=second,
                       originalClassifierKinds=kinds, classifierSha256=CLASSIFIER_SHA,
                       originalFinality=finality, originalFinalityAccepted=True,
                       finalityHookSha256=FINALITY_SHA,
                       statsBefore=before_stats, statsAfter=after_stats, terminal=state)
    except BaseException as error:
        receipt['status'] = 'NOT_ACCEPTED' if receipt['nativeRoots'] else 'NO_START'
        receipt['error'] = str(error)
    finally:
        if job is not None:
            if original_query is not None:
                job.k.QueryInformationJobObject = original_query
            state = job.sample(0) if job.process else None
            if state is not None and not state['terminal']:
                job.terminate_owned()
                end = time.monotonic() + 2
                while not state['terminal'] and time.monotonic() < end:
                    state = job.sample(20)
            receipt['forceRequested'] = job.force_requested
            receipt['finalOwnedState'] = state
            job.close()
            receipt['statsClosed'] = dict(job.member_cache_stats)
            if receipt['statsClosed']['retained'] or receipt['statsClosed']['closeErrors']:
                receipt['status'] = 'NOT_ACCEPTED'
        (output / 'result.json').write_text(
            json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: receipt[key] for key in (
        'status', 'nativeRoots', 'sdkCalls', 'browserAcceptanceClaimed')}
        | ({'error': receipt['error']} if 'error' in receipt else {})))
    return 0 if receipt['status'] == 'PASSED' else 1


if __name__ == '__main__':
    require(len(sys.argv) == 3 and sys.argv[1] == '--output',
            'Use --output .cache/retained-member-20261026-r1/native')
    raise SystemExit(run(ROOT / sys.argv[2]))
