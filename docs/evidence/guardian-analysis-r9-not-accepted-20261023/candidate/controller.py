"""Static candidate. Invoke only with a separately granted proposal digest."""
from time import monotonic
START = monotonic()
import sys, os, threading, json, hashlib, re, subprocess, datetime
from pathlib import Path
CANDIDATE = Path(__file__).absolute().parent
REPO = CANDIDATE.parents[1]
ATTEMPT = CANDIDATE/'attempt'
HARD = START+180
CUTOFF = HARD-6
job = child = None
expired = threading.Event()

def utc():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def save(path,value):
    with path.open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(value,stream,ensure_ascii=False,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
def hard_stop():
    os._exit(124)  # OS closes the private kill-on-close Job handle.
hard_timer=threading.Timer(max(0,HARD-monotonic()),hard_stop);hard_timer.daemon=True;hard_timer.start()
result={'status':'NOT_ACCEPTED','outerBudgetSeconds':180,'terminationReserveSeconds':6,'startedAtUtc':utc(),'workerPid':None,'phaseScope':'FULL_GUARDIAN_ANALYZE'}
code=1;assigned=False;cleanup=False;console=None;soft_timer=None;attempt_created=False
try:
    if len(sys.argv)!=2 or not re.fullmatch('[0-9a-f]{64}',sys.argv[1]):raise RuntimeError('Exact approved proposal SHA required')
    for p in [CANDIDATE,*CANDIDATE.parents]:
        if p.is_symlink() or p.is_junction():raise RuntimeError('Linked validation path refused')
        if p==REPO:break
    if sha(CANDIDATE/'proposal.json')!=sys.argv[1]:raise RuntimeError('Approved proposal bytes changed')
    proposal=json.loads((CANDIDATE/'proposal.json').read_text('utf-8'))
    ATTEMPT.mkdir()  # Single-use attempt; an existing directory is never reused.
    attempt_created=True
    save(ATTEMPT/'request.json',{'approvedProposalSha256':sys.argv[1],'outerBudgetSeconds':180,'startedAtUtc':result['startedAtUtc']})
    for row in proposal['candidateFiles']+proposal['controlRuntimeFiles']+proposal['historicalMetadataFiles']:
        p=Path(row['path']) if row.get('absolute') else CANDIDATE/row['path']
        if p.is_symlink() or p.is_junction() or p.stat().st_size!=row['bytes'] or sha(p)!=row['sha256']:raise RuntimeError('Pinned validation/runtime file changed')
    import win32job
    job=win32job.CreateJobObject(None,'')
    limits=win32job.QueryInformationJobObject(job,win32job.JobObjectExtendedLimitInformation)
    limits['BasicLimitInformation']['LimitFlags'] |= win32job.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    win32job.SetInformationJobObject(job,win32job.JobObjectExtendedLimitInformation,limits)
    def expire():
        expired.set()
        try:win32job.TerminateJobObject(job,124)
        except Exception:pass
    soft_timer=threading.Timer(max(0,CUTOFF-monotonic()),expire);soft_timer.daemon=True;soft_timer.start()
    if expired.is_set() or monotonic()>=CUTOFF:raise RuntimeError('No working budget remains')
    console=(ATTEMPT/'worker-console.log').open('xb')
    child=subprocess.Popen([sys.executable,'-I','-B','-u',str(CANDIDATE/'worker.py')],stdin=subprocess.PIPE,stdout=console,stderr=subprocess.STDOUT,text=True,creationflags=subprocess.CREATE_NO_WINDOW)
    result['workerPid']=child.pid
    # Only this exact Popen-owned handle is assigned; the worker blocks before imports/SDK work.
    win32job.AssignProcessToJobObject(job,int(child._handle));assigned=True
    if expired.is_set() or monotonic()>=CUTOFF:raise RuntimeError('Working deadline reached before handshake')
    child.stdin.write('OWNED_JOB_READY\n');child.stdin.flush();child.stdin.close()
    print(json.dumps({'state':'OWNED_GUARDIAN_ANALYZE_WORKER_STARTED','workerPid':child.pid,'attempt':str(ATTEMPT),'outerBudgetSeconds':180}),flush=True)
    announced=False
    while child.poll() is None and monotonic()<CUTOFF:
        launch=ATTEMPT/'launch.json'
        if not announced and launch.is_file():
            try:
                row=json.loads(launch.read_text('utf-8'));print(json.dumps({'state':'GUARDIAN_ANALYZE_COMMAND_STARTED','pid':row['pid'],'utc':row['utc']}),flush=True);announced=True
            except (OSError,json.JSONDecodeError):pass
        threading.Event().wait(0.1)
    active=win32job.QueryInformationJobObject(job,win32job.JobObjectBasicAccountingInformation)['ActiveProcesses']
    # Windows may briefly report a just-exited process in Job accounting.
    drain_until=min(CUTOFF,monotonic()+1.0)
    while child.poll() is not None and active and monotonic()<drain_until:
        threading.Event().wait(0.01)
        active=win32job.QueryInformationJobObject(job,win32job.JobObjectBasicAccountingInformation)['ActiveProcesses']
    if child.poll() is None or active:
        cleanup=True;win32job.TerminateJobObject(job,124)
    child.wait(timeout=max(0.1,min(3,HARD-monotonic())))
    while win32job.QueryInformationJobObject(job,win32job.JobObjectBasicAccountingInformation)['ActiveProcesses'] and monotonic()<HARD-1:threading.Event().wait(0.05)
    active=win32job.QueryInformationJobObject(job,win32job.JobObjectBasicAccountingInformation)['ActiveProcesses']
    receipt=ATTEMPT/'receipt.json';worker=json.loads(receipt.read_text('utf-8')) if receipt.is_file() else None
    import psutil
    sdk_names=set(proposal['sdkNames']);sdk=[];unknown=[]
    for p in psutil.process_iter(['pid','name'],ad_value=None):
        if p.info['name'] is None and p.pid not in (0,4):unknown.append(p.pid)
        elif (p.info['name'] or '').lower() in sdk_names:sdk.append(p.info)
    result.update(workerExitCode=child.returncode,workerReceipt=worker,ownedJobActiveProcesses=active,ownedCleanupPerformed=cleanup,watchdogExpired=expired.is_set(),sdkProcessesAfter=sdk,unknownProcessNames=unknown,availableRamBytesAfter=psutil.virtual_memory().available,workerConsoleSha256=sha(ATTEMPT/'worker-console.log'))
    passed=child.returncode==0 and worker and worker.get('status')=='FULL_GUARDIAN_ANALYZE_WORKER_PASSED' and active==0 and not cleanup and not expired.is_set() and not sdk and not unknown and monotonic()<HARD
    post_pin_mismatches=[]
    for row in proposal['candidateFiles']+proposal['controlRuntimeFiles']+proposal['historicalMetadataFiles']:
        path=Path(row['path']) if row.get('absolute') else CANDIDATE/row['path']
        if not path.is_file() or path.stat().st_size!=row['bytes'] or sha(path)!=row['sha256']:post_pin_mismatches.append(str(path))
    result['postCandidateAndControlRuntimeMismatches']=post_pin_mismatches
    passed=passed and not post_pin_mismatches and monotonic()<HARD
    result['status']='FULL_GUARDIAN_ANALYZE_PASSED' if passed else 'NOT_ACCEPTED';code=0 if passed else 1
except Exception as error:
    result['errorType']=type(error).__name__;result['reason']=str(error)
    if job is not None:
        try:win32job.TerminateJobObject(job,124);cleanup=True
        except Exception:pass
    if child is not None and not assigned:
        if child.stdin and not child.stdin.closed:child.stdin.close()
        if child.poll() is None:child.terminate()  # Exact owned worker; handshake was never sent.
    if child is not None:
        try:child.wait(timeout=max(0.1,min(3,HARD-monotonic())))
        except Exception:pass
finally:
    if soft_timer:soft_timer.cancel()
    if job is not None:
        try:result['ownedJobActiveProcessesFinal']=win32job.QueryInformationJobObject(job,win32job.JobObjectBasicAccountingInformation)['ActiveProcesses']
        except Exception:result['ownedJobActiveProcessesFinal']=None
        job.Close()
    if console:console.close()
    result['finishedAtUtc']=utc();result['elapsedCompleteSeconds']=monotonic()-START
    if result.get('ownedJobActiveProcessesFinal')!=0 or result['elapsedCompleteSeconds']>=180:result['status']='NOT_ACCEPTED';code=1
    if attempt_created:save(ATTEMPT/'result.json',result)
    print(json.dumps({'status':result['status'],'elapsedCompleteSeconds':result['elapsedCompleteSeconds'],'result':str(ATTEMPT/'result.json'),'workerPid':result['workerPid']}),flush=True)
os._exit(code)
