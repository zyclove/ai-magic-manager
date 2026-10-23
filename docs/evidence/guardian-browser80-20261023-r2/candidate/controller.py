"""Static candidate. Invoke only with a separately granted proposal digest."""
from time import monotonic, get_clock_info
START = monotonic()
import sys, os, threading, json, hashlib, re, subprocess, datetime, math
from pathlib import Path
CANDIDATE = Path(__file__).absolute().parent
REPO = CANDIDATE.parents[1]
ATTEMPT = CANDIDATE/'attempt'
HARD = START+300
CUTOFF = HARD-6
CONTROLLER_FINAL_RESERVE = 6
WORKER_FINISH_BY = CUTOFF-CONTROLLER_FINAL_RESERVE
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
result={'status':'NOT_ACCEPTED','outerBudgetSeconds':300,'terminationReserveSeconds':6,'startedAtUtc':utc(),'workerPid':None,'phaseScope':'BROWSER80_OWNED_AUX', 'legacyStrictAccepted':False}
code=1;assigned=False;cleanup=False;console=None;soft_timer=None;attempt_created=False
try:
    if len(sys.argv)!=2 or not re.fullmatch('[0-9a-f]{64}',sys.argv[1]):raise RuntimeError('Exact approved proposal SHA required')
    for p in [CANDIDATE,*CANDIDATE.parents]:
        if p.is_symlink() or p.is_junction():raise RuntimeError('Linked validation path refused')
        if p==REPO:break
    if sha(CANDIDATE/'proposal.json')!=sys.argv[1]:raise RuntimeError('Approved proposal bytes changed')
    proposal=json.loads((CANDIDATE/'proposal.json').read_text('utf-8'))
    approved_sdk_names=['aapt2.exe', 'asm.exe', 'cgo.exe', 'compile.exe', 'dart.exe', 'dartaotruntime.exe', 'flutter.exe', 'flutter_tester.exe', 'gen_snapshot.exe', 'go.exe', 'gofmt.exe', 'java.exe', 'javac.exe', 'javaw.exe', 'link.exe', 'qemu-system-x86_64.exe']
    if type(proposal.get('sdkNames')) is not list or len(proposal['sdkNames'])!=16 or set(proposal['sdkNames'])!=set(approved_sdk_names):raise RuntimeError('Exact approved 16-name SDK policy required')
    ATTEMPT.mkdir()  # Single-use attempt; an existing directory is never reused.
    attempt_created=True
    save(ATTEMPT/'request.json',{'approvedProposalSha256':sys.argv[1],'outerBudgetSeconds':300,'startedAtUtc':result['startedAtUtc']})
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
    if expired.is_set() or monotonic()+52>=WORKER_FINISH_BY:raise RuntimeError('No outer-bound phase reserve remains for worker launch')
    console=(ATTEMPT/'worker-console.log').open('xb')
    child=subprocess.Popen([sys.executable,'-I','-B','-u',str(CANDIDATE/'worker.py')],stdin=subprocess.PIPE,stdout=console,stderr=subprocess.STDOUT,text=True,creationflags=subprocess.CREATE_NO_WINDOW)
    result['workerPid']=child.pid
    # Only this exact Popen-owned handle is assigned; the worker blocks before imports/SDK work.
    win32job.AssignProcessToJobObject(job,int(child._handle));assigned=True
    if expired.is_set() or monotonic()+52>=WORKER_FINISH_BY:raise RuntimeError('Outer-bound phase reserve exhausted before handshake')
    budget_handshake={'protocol':'OWNED_JOB_READY_BROWSER80_V2',
                      'clockImplementation':get_clock_info('monotonic').implementation,
                      'outerStartedMonotonic':START,'outerHardMonotonic':HARD,
                      'outerSoftMonotonic':CUTOFF,'controllerFinalReserveSeconds':CONTROLLER_FINAL_RESERVE,
                      'workerFinishByMonotonic':WORKER_FINISH_BY}
    result['workerBudgetHandshake']=budget_handshake
    child.stdin.write(json.dumps(budget_handshake,allow_nan=False)+'\n');child.stdin.flush();child.stdin.close()
    print(json.dumps({'state':'OWNED_BROWSER80_AUX_WORKER_STARTED','workerPid':child.pid,'attempt':str(ATTEMPT),'outerBudgetSeconds':300}),flush=True)
    announced=False
    worker_terminal_observed=None
    while True:
        worker_exit_code=child.poll()  # Same retained Popen-owned process handle; no PID lookup.
        if worker_exit_code is not None:
            worker_terminal_observed=monotonic()  # First terminal observation, before receipt I/O.
            result.update(workerTerminalObservedMonotonic=worker_terminal_observed,
                          workerTerminalExitCodeObserved=worker_exit_code,
                          workerTerminalObservationSource='retained Popen.poll')
            break
        if monotonic()>=WORKER_FINISH_BY:break
        launch=ATTEMPT/'launch.json'
        if not announced and launch.is_file():
            try:
                row=json.loads(launch.read_text('utf-8'));print(json.dumps({'state':'BROWSER80_AUX_COMMAND_STARTED','pid':row['pid'],'utc':row['utc']}),flush=True);announced=True
            except (OSError,json.JSONDecodeError):pass
        threading.Event().wait(0.1)
    active=win32job.QueryInformationJobObject(job,win32job.JobObjectBasicAccountingInformation)['ActiveProcesses']
    # Windows may briefly report a just-exited process in Job accounting.
    drain_until=min(CUTOFF,monotonic()+1.0)
    while worker_terminal_observed is not None and active and monotonic()<drain_until:
        threading.Event().wait(0.01)
        active=win32job.QueryInformationJobObject(job,win32job.JobObjectBasicAccountingInformation)['ActiveProcesses']
    if worker_terminal_observed is None or active:
        cleanup=True;win32job.TerminateJobObject(job,124)
    child.wait(timeout=max(0.1,min(3,HARD-monotonic())))
    worker_wait_observed=monotonic()
    if worker_terminal_observed is None:
        worker_terminal_observed=worker_wait_observed  # Late/containment evidence; cleanup stays true.
        result.update(workerTerminalObservedMonotonic=worker_terminal_observed,
                      workerTerminalExitCodeObserved=child.returncode,
                      workerTerminalObservationSource='retained Popen.wait after cleanup requested')
    while win32job.QueryInformationJobObject(job,win32job.JobObjectBasicAccountingInformation)['ActiveProcesses'] and monotonic()<HARD-1:threading.Event().wait(0.05)
    active=win32job.QueryInformationJobObject(job,win32job.JobObjectBasicAccountingInformation)['ActiveProcesses']
    receipt=ATTEMPT/'receipt.json';worker=json.loads(receipt.read_text('utf-8')) if receipt.is_file() else None
    import psutil
    sdk_names=set(proposal['sdkNames']);sdk=[];unknown=[]
    for p in psutil.process_iter(['pid','name'],ad_value=None):
        if p.info['name'] is None and p.pid not in (0,4):unknown.append(p.pid)
        elif (p.info['name'] or '').lower() in sdk_names:sdk.append(p.info)
    result.update(workerExitCode=child.returncode,workerReceipt=worker,ownedJobActiveProcesses=active,ownedCleanupPerformed=cleanup,watchdogExpired=expired.is_set(),sdkProcessesAfter=sdk,unknownProcessNames=unknown,availableRamBytesAfter=psutil.virtual_memory().available,workerConsoleSha256=sha(ATTEMPT/'worker-console.log'))
    worker_hard=worker.get('workerHardMonotonic') if type(worker) is dict else None
    worker_terminal_budget_ok = (type(worker_hard) in (int,float) and math.isfinite(worker_hard)
        and START < worker_hard <= WORKER_FINISH_BY
        and worker_terminal_observed is not None
        and START <= worker_terminal_observed < worker_hard
        and worker_terminal_observed < WORKER_FINISH_BY)
    result.update(workerTerminalBudgetAccepted=worker_terminal_budget_ok,
                  workerHardFromReceipt=worker_hard,workerFinishByMonotonic=WORKER_FINISH_BY)
    worker_scope_ok = (worker and worker_terminal_budget_ok and worker.get('phaseScope') == 'BROWSER80_OWNED_AUX'
        and worker.get('outerBudgetBinding') == budget_handshake
        and worker.get('sdkRootNaturalZero') is True and worker.get('sdkForced') is False
        and worker.get('legacyStrictAccepted') is False and not worker.get('commandTreeCloseFallbackRequested') and (
        (worker.get('status') == 'BROWSER_CASES_PASSED_WITH_OWNED_AUX_CLEANUP' and worker.get('auxCleanup') is True and worker.get('auxCleanupRequested') is True
         and worker.get('commandTreeForced') is True and worker.get('forcedTermination') is True) or
        (worker.get('status') == 'BROWSER_CASES_PASSED_NATURAL_JOB_ZERO' and worker.get('auxCleanup') is False and worker.get('auxCleanupRequested',False) is False
         and worker.get('commandTreeForced') is False and worker.get('forcedTermination') is False)))
    passed=child.returncode==0 and worker_scope_ok and active==0 and not cleanup and not expired.is_set() and not sdk and not unknown and monotonic()<HARD
    result.update(commandTreeForced=worker.get('commandTreeForced') if worker else None,
                  auxCleanup=worker.get('auxCleanup') if worker else None,
                  sdkRootNaturalZero=worker.get('sdkRootNaturalZero') if worker else None)
    post_pin_mismatches=[]
    for row in proposal['candidateFiles']+proposal['controlRuntimeFiles']+proposal['historicalMetadataFiles']:
        path=Path(row['path']) if row.get('absolute') else CANDIDATE/row['path']
        if not path.is_file() or path.stat().st_size!=row['bytes'] or sha(path)!=row['sha256']:post_pin_mismatches.append(str(path))
    result['postCandidateAndControlRuntimeMismatches']=post_pin_mismatches
    passed=passed and not post_pin_mismatches and not expired.is_set() and monotonic()<CUTOFF
    result['status']=worker['status'] if passed else 'NOT_ACCEPTED';code=0 if passed else 1
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
    result['watchdogExpired']=expired.is_set()
    if result.get('ownedJobActiveProcessesFinal')!=0 or expired.is_set() or monotonic()>=CUTOFF or result['elapsedCompleteSeconds']>=300:result['status']='NOT_ACCEPTED';code=1
    if attempt_created:save(ATTEMPT/'result.json',result)
    print(json.dumps({'status':result['status'],'elapsedCompleteSeconds':result['elapsedCompleteSeconds'],'result':str(ATTEMPT/'result.json'),'workerPid':result['workerPid']}),flush=True)
os._exit(code)
