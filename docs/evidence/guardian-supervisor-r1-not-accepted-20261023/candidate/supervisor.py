"""Fixed no-SDK qualification host. No real controller or arbitrary command entry."""
from time import monotonic
ANCHOR=monotonic()
import hashlib,importlib.util,json,math,os,re,sys,time
from pathlib import Path

HERE=Path(__file__).resolve().parent
PYTHON=Path(r'C:\Python313\python.exe')
CASES={'natural-zero','natural-nonzero','deadline','nested-owned-child'}
def require(value,message):
    if not value:raise RuntimeError(message)
def check_deadline(deadline):
    require(type(deadline) is float and math.isfinite(deadline) and monotonic()<deadline,'Deadline exhausted')
def digest(path,deadline):
    check_deadline(deadline);h=hashlib.sha256()
    with path.open('rb') as stream:
        while True:
            check_deadline(deadline);b=stream.read(1024*1024)
            if not b:break
            h.update(b)
    check_deadline(deadline);return h.hexdigest()
def main():
    require(os.name=='nt' and sys.version_info[:2]==(3,13),'Fixed Windows Python3.13 only')
    require(sys.flags.isolated==1 and sys.dont_write_bytecode,'Host must use -I -B')
    require(Path(sys.executable).resolve()==PYTHON.resolve(),'Fixed Python executable required')
    require(time.get_clock_info('monotonic').implementation=='QueryPerformanceCounter()','QPC clock required')
    require(len(sys.argv)==4 and sys.argv[1]=='qualify' and sys.argv[2] in CASES and re.fullmatch('[a-f0-9]{64}',sys.argv[3]),'Only qualify fixed-case exact-manifest-SHA interface')
    outer_end=ANCHOR+180.0
    manifest_path=HERE/'manifest.json'
    require(digest(manifest_path,outer_end)==sys.argv[3],'Exact manifest changed')
    manifest=json.loads(manifest_path.read_bytes())
    require(manifest['realControllerEntryEnabled'] is False and manifest['sdkAllowed'] is False,'Qualification-only manifest')
    require(set(manifest['candidateNames'])=={'owned_job.py','fixtures.py','supervisor.py','qualification-cases.json','README.md','design.md'},'Fixed candidate membership required')
    require(len(manifest['candidateFiles'])==6 and {r['path'] for r in manifest['candidateFiles']}==set(manifest['candidateNames']),'Complete candidate pin set required')
    require(any(r.get('absolute') is True and Path(r['path']).resolve()==PYTHON.resolve() for r in manifest['runtimePins']),'Fixed Python runtime pin required')
    for item in (HERE,*HERE.parents):
        require(not item.is_symlink() and not item.is_junction(),'Reparse path refused')
    for row in manifest['candidateFiles']+manifest['runtimePins']:
        p=Path(row['path']) if row.get('absolute') else HERE/row['path']
        require(not p.is_symlink() and not p.is_junction() and p.stat().st_size==row['bytes'] and digest(p,outer_end)==row['sha256'],'Candidate/runtime pin changed')
    definition=json.loads((HERE/'qualification-cases.json').read_bytes())
    case=sys.argv[2];spec=definition['cases'][case]
    require(set(definition['cases'])==CASES,'Fixed four qualification cases')
    require(definition['inheritedCeilingsOnly']=={'outer':180,'working':174,'worker':165,'commandWorkerRelative':135,'commandCleanupWorkerRelative':140,'postflightReserve':25},'Original ceilings changed')
    require(spec['workSeconds'] in (4,8) and spec['cleanupSeconds']==6,'Fixed smaller qualification budgets')
    work_end=min(ANCHOR+174.0,ANCHOR+float(spec['workSeconds']))
    finish_end=min(outer_end,work_end+6.0)
    check_deadline(work_end)
    attempts=HERE/'qualification-attempts'
    require(not attempts.is_symlink() and not attempts.is_junction(),'Linked attempt root refused')
    attempts.mkdir(exist_ok=True)
    task=attempts/case;task.mkdir()  # Single use, never overwrite earlier evidence.
    temp=task/'tmp';temp.mkdir()
    environment={'SystemRoot':r'C:\Windows','WINDIR':r'C:\Windows','PATH':r'C:\Windows\System32',
        'TEMP':str(temp),'TMP':str(temp),'COMSPEC':r'C:\Windows\System32\cmd.exe'}
    native_spec=importlib.util.spec_from_file_location('guardian_supervisor_owned_job',HERE/'owned_job.py')
    native=importlib.util.module_from_spec(native_spec);native_spec.loader.exec_module(native)
    OwnedJob=native.OwnedJob
    job=None;state=None;events=[];error=None;maximum_total=0;deadline_reached=False
    def event(name):
        if len(events)<64:events.append({'stage':name,'qpc':monotonic()})
    try:
        event('before-job');job=OwnedJob();event('after-job')
        check_deadline(work_end);event('before-create-suspended')
        job.create_suspended([str(PYTHON),'-I','-B','-u',str(HERE/'fixtures.py'),case],HERE,task/'fixture-console.log',environment)
        event('after-create-suspended');check_deadline(work_end)
        require(job.sample(0)['activeProcesses']==1,'Unexpected suspended Job members')
        event('before-resume');job.resume();event('after-resume')
        while True:
            remaining=work_end-monotonic()
            state=job.sample(max(0,min(50,int(max(0.0,remaining)*1000))))
            maximum_total=max(maximum_total,state['totalProcesses'])
            if state['terminal']:break
            if monotonic()>=work_end or state['signaled']:
                deadline_reached=monotonic()>=work_end
                event('before-owned-termination');job.terminate_owned();event('after-owned-termination');break
        while state is not None and not state['terminal'] and monotonic()<finish_end:
            state=job.sample(max(0,min(50,int(max(0.0,finish_end-monotonic())*1000))))
            maximum_total=max(maximum_total,state['totalProcesses'])
        event('terminal-loop-finished')
    except Exception as failure:
        error=type(failure).__name__+': '+str(failure)
        if job is not None and job.process is not None:
            event('error-owned-termination');job.terminate_owned()
            while monotonic()<finish_end:
                state=job.sample(max(0,min(50,int(max(0.0,finish_end-monotonic())*1000))))
                maximum_total=max(maximum_total,state['totalProcesses'])
                if state['terminal']:break
    finally:
        forced=job.force_requested if job else False
        force_ok=job.force_succeeded if job else False
        if job:event('before-owned-close');job.close();event('after-owned-close')
    # No stdout, filesystem read/write or fsync occurs inside the monitoring loop.
    nested=None
    if case=='nested-owned-child' and (task/'nested-proof.json').is_file():
        proof=task/'nested-proof.json'
        require(not proof.is_symlink() and proof.stat().st_size<=4096,'Bounded native fixture proof required')
        nested=json.loads(proof.read_bytes())
    post_pins_match=False
    try:
        for row in manifest['candidateFiles']+manifest['runtimePins']:
            p=Path(row['path']) if row.get('absolute') else HERE/row['path']
            require(p.stat().st_size==row['bytes'] and digest(p,finish_end)==row['sha256'],'Postflight candidate/runtime pin changed')
        post_pins_match=True
    except Exception as post_error:
        error=error or type(post_error).__name__+': '+str(post_error)
    timely=bool(state and state['terminal'] and type(state['firstSignaledQpc']) is float and math.isfinite(state['firstSignaledQpc']) and state['firstSignaledQpc']<finish_end and monotonic()<finish_end)
    if spec['expectsForcedCleanup']:
        expected=timely and forced and force_ok and deadline_reached and state['exitCode']==124
    else:
        expected=timely and not forced and state['firstSignaledQpc']<work_end and state['exitCode']==spec['expectedExitCode']
    if case=='nested-owned-child':
        expected=expected and maximum_total>=2 and bool(nested and nested.get('atomicMembershipCheckedBeforeResume') is True and nested.get('innerJobActive')==1 and nested.get('innerJobTotal')==1 and nested.get('childSignaled') is False and nested.get('childCreationFiletime'))
    expected=bool(expected and error is None and post_pins_match)
    report={'status':'QUALIFICATION_OBSERVATION_NOT_ANALYSIS_ACCEPTANCE','case':case,'qpcAnchor':ANCHOR,
        'workDeadlineQpc':work_end,'cleanupDeadlineQpc':finish_end,'originalOuterDeadlineQpc':outer_end,
        'terminal':state,'maximumObservedJobTotal':maximum_total,'forcedCleanupRequested':forced,
        'terminationCallSucceeded':force_ok,'deadlineReached':deadline_reached,'error':error,'events':events,
        'nestedProof':nested,'expectedOutcomeObservedBeforeOutput':expected,
        'candidateAndRuntimePinsMatchAfter':post_pins_match,
        'supervisorActualTerminalBeforeDeadlineStillRequired':True,
        'kernelExitFiletimeIsUtcDomainNotQpc':True,'firstSignaledIsConservativeSampling':True,
        'sdkCalls':0,'realControllerInvoked':False,'allFourCasesQualified':False}
    with (task/'observation.json').open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(report,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
    # A blocked output tail can never supply timely host-exit proof. Root must
    # retain/observe this host too; late return is rejected, never a new budget.
    return 0 if expected and monotonic()<finish_end else 1
if __name__=='__main__':
    try:code=main()
    except Exception:code=1
    os._exit(code)
