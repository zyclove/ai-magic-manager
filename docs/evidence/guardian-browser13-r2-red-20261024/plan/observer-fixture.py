"""One bounded qualification of the new same-handle readonly command reader."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import time

HERE = Path(__file__).absolute().parent
ROOT = HERE.parents[1]
RUN = HERE/'observer-fixture'
START = time.monotonic()
END = START + 8.0
RUN.mkdir()
(RUN/'tmp').mkdir()
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
native_path = ROOT/'.cache/guardian-vm35-20261024-r1/owned_job.py'
assert sha(native_path) == 'f8b44764ed30d638781b7dc913e651fbbc6311b8f0945cc0d71b67c65abc141b'
manifest = json.loads((ROOT/'.cache/guardian-supervisor-20261023-r3/manifest.json').read_bytes())
for row in manifest['runtimePins']:
    path = Path(row['path'])
    assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256']
native = load('browser13_fixture_existing_f8', native_path)
evidence = load('browser13_fixture_evidence', HERE/'owned_chrome_evidence.py')
job = native.OwnedJob()
reader = evidence.RetainedJobReader(job, END)
python = r'C:\Python313\python.exe'
args = [python, '-I', '-B', '-S', str(HERE/'observer-fixture-child.py'),
        '--fixture-token=only-task-owned-no-secret']
environment = {'SystemRoot':r'C:\Windows','WINDIR':r'C:\Windows',
               'PATH':r'C:\Windows\System32','TEMP':str(RUN/'tmp'),'TMP':str(RUN/'tmp')}
receipt = {'status':'NOT_ACCEPTED','sdkStarted':False,'chromeStarted':False,
    'networkQueriesOrRequests':False,'environmentRead':False,
    'newReadPathOnlyNotF8Requalification':True,'chromeLifecycleQualified':False,
    'observerSha256':sha(HERE/'owned_chrome_evidence.py'),
    'originalDeadlineQpc':END,'forced':False,'naturalJobZero':False,'cases':[]}
state = None
try:
    job.create_suspended(args, HERE, RUN/'child.log', environment)
    receipt['pid'],receipt['creationFiletime'] = job.pid,job.identity
    job.resume()
    handle = reader.open_member(job.pid, job.identity, python)
    try:
        argv, proof = reader.command_line(handle, job.pid, job.identity, python)
        assert argv == args
        receipt['cases'].append({'case':'own-job-retained-handle-command-line',
            'accepted':True,'proof':proof,'rawCommandLineSaved':False})
    finally:
        job.k.CloseHandle(handle)
    before = reader.rpm_calls
    try:
        handle = reader.open_member(job.pid,job.identity+1,python)
    except evidence.EvidenceRejected as error:
        assert str(error)=='MEMBER_CREATION_MISMATCH'
        assert reader.rpm_calls==before
        receipt['cases'].append({'case':'wrong-creation','rejected':True,'memoryReads':0})
    else:
        job.k.CloseHandle(handle)
        raise AssertionError('Wrong creation was accepted')
    before = reader.rpm_calls
    try:
        handle = reader.open_member(os.getpid(),job.identity,python)
    except evidence.EvidenceRejected as error:
        assert str(error)=='NOT_A_MEMBER_OF_THIS_JOB'
        assert reader.rpm_calls==before
        receipt['cases'].append({'case':'task-parent-outside-private-job','rejected':True,'memoryReads':0})
    else:
        job.k.CloseHandle(handle)
        raise AssertionError('Outside private Job was accepted')
    before = reader.rpm_calls
    try:
        reader.read_exact(None,0,65537)
    except evidence.EvidenceRejected as error:
        assert str(error)=='INVALID_REMOTE_READ_SPAN'
        assert reader.rpm_calls==before
        receipt['cases'].append({'case':'invalid-read-length','rejected':True,'memoryReads':0})
    else:
        raise AssertionError('Invalid read span was accepted')
    while time.monotonic() < END:
        state = job.sample(20)
        if state['terminal']:
            break
    assert state and state['terminal'] and state['exitCode']==0 and state['activeProcesses']==0
    assert not job.force_requested and time.monotonic() < END
    assert state['firstCompleteTerminalQpc'] < min(END,state['firstSignaledQpc']+0.5)
    receipt.update(status='OWNED_READ_PATH_FIXTURE_ACCEPTED_NOT_CHROME_QUALIFICATION',
                   naturalJobZero=True,terminal=state,remoteMemoryReads=reader.rpm_calls,
                   commandLineReads=reader.command_line_reads)
except BaseException as failure:
    receipt.update(failureType=type(failure).__name__,
                   failureCode=str(failure) if isinstance(failure,evidence.EvidenceRejected) else 'FIXTURE_ASSERTION_OR_API_FAILED')
finally:
    if job.process is not None:
        current=job.sample(0)
        receipt['terminalAtClose']=current
        if not current['terminal']:
            receipt['forced']=True
            job.terminate_owned()
            while time.monotonic() < END:
                current=job.sample(20)
                if current['terminal']:
                    break
            receipt['terminalAtClose']=current
        receipt['forced']=receipt['forced'] or job.force_requested
    job.close()
    receipt['elapsedSeconds']=time.monotonic()-START
    if receipt['forced'] or receipt['elapsedSeconds']>=8.0:
        receipt['status']='NOT_ACCEPTED'
    assert not (RUN/'result.json').exists()
    (RUN/'result.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(receipt))
    raise SystemExit(0 if receipt['status']=='OWNED_READ_PATH_FIXTURE_ACCEPTED_NOT_CHROME_QUALIFICATION' else 1)
