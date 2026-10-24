"""Exercise only the pure JSON guard, with hand-authored lifecycle fixtures."""
from pathlib import Path
import copy
import hashlib
import json
import sys

HERE = Path(__file__).resolve().parent
fragment = Path(sys.argv[1]).absolute()
output = HERE / sys.argv[2]
namespace = {}
exec(compile(fragment.read_text(encoding='utf-8'), str(fragment), 'exec'), namespace)
guard = namespace['chrome_evidence_valid']
SCOPE = 'This private Job only; read-only handles, no command line/environment, no PID termination'
ATTEMPT = Path(r'D:\fixture\attempt')
INPUTS = {'browserExecutable':{'path':r'C:\Chrome\chrome.exe'}}


def listing(pids, qpc):
    return dict(qpc=qpc, complete=True, assigned=len(pids), listed=len(pids), limit=32, error=0, pids=list(pids))


def row(pid, creation, qpc, image=None, image_error=None):
    value = dict(pid=pid, openedFromOwnJobList=True, verifiedOwnMembership=True,
        retainedRootHandleUsed=pid == 101, creationFiletime=creation, exitFiletime=0,
        kernel100ns=0, user100ns=0, signaled=False, sampleQpc=qpc)
    if image is not None:
        value['imagePath'] = image
    if image_error is not None:
        value['imageError'] = image_error
        value['exitFiletime'] = 1003
    return value


def base():
    state = dict(pid=101, creationFiletime=1000, firstSignaledQpc=150.0, sampleQpc=150.049,
        signaled=True, exitCode=0, exitFiletime=2000, kernel100ns=0, user100ns=0,
        jobAccountingObservedQpc=150.05, firstCompleteTerminalQpc=150.05,
        activeProcesses=0, totalProcesses=5, terminatedProcesses=0, terminal=True)
    chrome = dict(pid=201, creationFiletime=1001, commandCreationFiletime=1000,
        imagePath=r'C:\Chrome\chrome.exe', profile=r'D:\fixture\attempt\tmp\private', debuggingPort=55002,
        testServerOrigins=['http://localhost:55001'],
        testTargets=[dict(scheme='http',host='localhost',port=55001,path='/static/index.html',urlSha256='a'*64)],
        managerTarget=dict(scheme='ws',host='localhost',port=55001), headless=True,
        argvTestTargetLoopback=True, flutterManagerTargetSameLoopbackOrigin=True,
        commandLineUtf16Sha256='b'*64, commandLineReadBeforeQpc=110.0, commandLineReadAfterQpc=110.001,
        sameReadHandleVerified=True, ownedMembershipVerifiedBeforeAndAfter=True, liveBeforeAndAfter=True,
        observedQpc=110.02, debugListenerAddresses=[dict(address='127.0.0.1',port=55002,family='AF_INET',status='LISTEN')],
        listenerReadBeforeQpc=110.01, listenerReadAfterQpc=110.02,
        listenerSameHandleIdentityVerifiedBeforeAndAfter=True, debugBindingLoopbackObserved=True)
    pending = row(301,1002,120.005,image_error=5)
    known = row(101,1000,120.001,image=r'C:\Windows\System32\cmd.exe')
    snapshot = dict(startedQpc=120.0, deadlineQpc=235.0, before=listing([101,301],120.0),
        identities=[known,pending], after=listing([101,301,401],120.01), identityRowsLimitedByDeadline=False,
        scope=SCOPE,causeClassified=False)
    occurrence = dict(snapshotIndex=0,rowIndex=1,sampleOrdinal=5,pid=301,creationFiletime=1002)
    ledger = dict(schemaVersion=1,maximumFailureSnapshots=8,maximumSerializedBytes=262144,
        totalFailureSnapshotsSeen=1,storedFailureSnapshots=1,droppedFailureSnapshots=0,overflow=False,
        snapshots=[dict(sampleOrdinal=5,jobRootPid=101,jobRootCreationFiletime=1000,rawSnapshot=snapshot,afterOnlyNotQueried=[401])],
        firstIdentityObservations=[dict(sampleOrdinal=1,pid=101,creationFiletime=1000,rawRow=row(101,1000,105.0,image=r'C:\Windows\System32\cmd.exe')),
            dict(sampleOrdinal=1,pid=201,creationFiletime=1001,rawRow=row(201,1001,110.0,image=r'C:\Chrome\chrome.exe')),
            dict(sampleOrdinal=5,pid=301,creationFiletime=1002,rawRow=copy.deepcopy(pending))],
        identityConflicts=[],pendingOccurrences=[occurrence],
        resolvedOccurrences=[dict(occurrence,resolution='OWNED_MEMBER_CLOSED_IMAGE_UNKNOWN')],fatalProblems=[])
    a0,a1=copy.deepcopy(state),copy.deepcopy(state)
    a0.update(sampleQpc=150.06,jobAccountingObservedQpc=150.061)
    a1.update(sampleQpc=150.064,jobAccountingObservedQpc=150.065)
    middle=dict(startedQpc=150.062,deadlineQpc=150.5,before=listing([],150.062),identities=[],
        after=listing([],150.063),identityRowsLimitedByDeadline=False,scope=SCOPE,causeClassified=False)
    finality=dict(schemaVersion=1,source='SAME_COMMAND_OWNED_JOB',jobRootPid=101,jobRootCreationFiletime=1000,
        originalCommandDeadlineQpc=235.0,deadlineQpc=150.5,naturalDrainSeconds=0.5,A0=a0,M=middle,A1=a1,
        forceRequested=False,closeFallback=False)
    value=dict(schemaVersion=2,status='OWNED_CHROME_BOUNDARIES_OBSERVED',chromeRoots=[chrome],problems=[],
        sampleCalls=10,pinnedBrowserPath=r'C:\Chrome\chrome.exe',temporaryRoot=r'D:\fixture\attempt\tmp',
        commandCreationFiletime=1000,observationDeadlineQpc=235.0,
        commandLineSource='SAME_RETAINED_HANDLE_PBI0_READPROCESSMEMORY',
        debugBindingProof='PID_FILTERED_LISTEN_ROWS_BRACKETED_BY_SAME_HANDLE_IDENTITY',
        foreignCommandLinesRead=False,processesTerminated=False,environmentRead=False,
        nativeReadPathQualificationSeparate=True,observedProblems=['OWN_JOB_MEMBER_IDENTITY_UNPROVED'],
        failureLedger=ledger,terminalFinality=finality)
    return value,state


checks=[]


def check(name, expected, change=None):
    value,state=base()
    if change:
        change(value,state)
    actual=guard(value,INPUTS,state,100.0,235.0,ATTEMPT)
    checks.append(dict(name=name,expected=expected,actual=actual))
    assert actual is expected,name


def set_path(value, path, item):
    for part in path[:-1]:
        value=value[part]
    value[path[-1]]=item


def mutate(path,item):
    return lambda value,state:set_path(value,path,item)


try:
    check('known-own-image-unknown-closes-with-original-bracketed-same-job-finality',True)
    for code in (0,87,299,4294967295):
        def vary(value,state,code=code):
            value['failureLedger']['snapshots'][0]['rawSnapshot']['identities'][1]['imageError']=code
            value['failureLedger']['firstIdentityObservations'][2]['rawRow']['imageError']=code
        check('image-error-'+str(code)+'-does-not-change-lifecycle-meaning',True,vary)
    def no_failure(value,state):
        ledger=value['failureLedger']
        ledger.update(totalFailureSnapshotsSeen=0,storedFailureSnapshots=0,snapshots=[],pendingOccurrences=[],resolvedOccurrences=[])
        ledger['firstIdentityObservations']=ledger['firstIdentityObservations'][:2]
        value['observedProblems']=[]
    check('empty-failure-ledger-with-complete-terminal-transaction',True,no_failure)
    changes=[
        ('schema1-not-retroactively-accepted',['schemaVersion'],1),
        ('fatal-problem-never-cleared',['failureLedger','fatalProblems'],['MEMBER_TIMES_FAILED']),
        ('unresolved-problem-rejects',['problems'],['OWN_JOB_MEMBER_IDENTITY_UNPROVED']),
        ('observed-problem-cannot-be-erased',['observedProblems'],[]),
        ('overflow-rejects',['failureLedger','overflow'],True),
        ('drop-rejects',['failureLedger','droppedFailureSnapshots'],1),
        ('failure-count-mismatch',['failureLedger','totalFailureSnapshotsSeen'],2),
        ('stored-count-mismatch',['failureLedger','storedFailureSnapshots'],0),
        ('cap-change-rejects',['failureLedger','maximumFailureSnapshots'],9),
        ('byte-cap-change-rejects',['failureLedger','maximumSerializedBytes'],524288),
        ('identity-conflict-rejects',['failureLedger','identityConflicts'],[{}]),
        ('missing-occurrence-rejects',['failureLedger','pendingOccurrences'],[]),
        ('missing-resolution-rejects',['failureLedger','resolvedOccurrences'],[]),
        ('resolution-must-keep-image-unknown',['failureLedger','resolvedOccurrences',0,'resolution'],'IMAGE_PROVEN'),
        ('occurrence-cannot-point-after-only',['failureLedger','pendingOccurrences',0,'pid'],401),
        ('wrong-snapshot-job',['failureLedger','snapshots',0,'jobRootPid'],909),
        ('wrong-snapshot-creation',['failureLedger','snapshots',0,'jobRootCreationFiletime'],1009),
        ('after-only-observation-cannot-be-hidden',['failureLedger','snapshots',0,'afterOnlyNotQueried'],[]),
        ('before-list-incomplete',['failureLedger','snapshots',0,'rawSnapshot','before','complete'],False),
        ('after-list-incomplete',['failureLedger','snapshots',0,'rawSnapshot','after','complete'],False),
        ('before-list-query-error',['failureLedger','snapshots',0,'rawSnapshot','before','error'],5),
        ('before-list-count-mismatch',['failureLedger','snapshots',0,'rawSnapshot','before','assigned'],3),
        ('snapshot-limited-rejects',['failureLedger','snapshots',0,'rawSnapshot','identityRowsLimitedByDeadline'],True),
        ('wrong-snapshot-deadline',['failureLedger','snapshots',0,'rawSnapshot','deadlineQpc'],240.0),
        ('unknown-row-ownership',['failureLedger','snapshots',0,'rawSnapshot','identities',1,'verifiedOwnMembership'],False),
        ('creation-zero',['failureLedger','snapshots',0,'rawSnapshot','identities',1,'creationFiletime'],0),
        ('creation-conflict',['failureLedger','snapshots',0,'rawSnapshot','identities',1,'creationFiletime'],1009),
        ('bad-retained-flag',['failureLedger','snapshots',0,'rawSnapshot','identities',1,'retainedRootHandleUsed'],True),
        ('first-identity-missing',['failureLedger','firstIdentityObservations'],[]),
        ('first-identity-conflict',['failureLedger','firstIdentityObservations',2,'creationFiletime'],1009),
        ('terminal-proof-missing',['terminalFinality'],None),
        ('wrong-finality-source',['terminalFinality','source'],'OUTER_WORKER_JOB'),
        ('wrong-finality-root',['terminalFinality','jobRootPid'],909),
        ('wrong-finality-creation',['terminalFinality','jobRootCreationFiletime'],1009),
        ('new-original-deadline-forbidden',['terminalFinality','originalCommandDeadlineQpc'],240.0),
        ('new-drain-deadline-forbidden',['terminalFinality','deadlineQpc'],151.0),
        ('new-grace-forbidden',['terminalFinality','naturalDrainSeconds'],1.0),
        ('force-forbidden',['terminalFinality','forceRequested'],True),
        ('close-fallback-forbidden',['terminalFinality','closeFallback'],True),
        ('a0-nonzero-exit',['terminalFinality','A0','exitCode'],1),
        ('a1-nonzero-exit',['terminalFinality','A1','exitCode'],1),
        ('a0-nonempty-accounting',['terminalFinality','A0','activeProcesses'],1),
        ('a1-nonempty-accounting',['terminalFinality','A1','activeProcesses'],1),
        ('a1-identity-changed',['terminalFinality','A1','creationFiletime'],1009),
        ('reset-first-signal-anchor',['terminalFinality','A1','firstSignaledQpc'],150.01),
        ('reset-first-terminal-anchor',['terminalFinality','A1','firstCompleteTerminalQpc'],150.06),
        ('accounting-counter-changed',['terminalFinality','A1','totalProcesses'],6),
        ('equal-boundary-rejects',['terminalFinality','A1','jobAccountingObservedQpc'],150.5),
        ('postflight-time-rejects',['terminalFinality','A1','sampleQpc'],170.0),
        ('middle-wrong-deadline',['terminalFinality','M','deadlineQpc'],235.0),
        ('middle-before-incomplete',['terminalFinality','M','before','complete'],False),
        ('middle-after-error',['terminalFinality','M','after','error'],5),
        ('middle-identities-not-empty',['terminalFinality','M','identities'],[{}]),
        ('middle-before-not-empty',['terminalFinality','M','before','pids'],[301]),
        ('middle-after-not-empty',['terminalFinality','M','after','pids'],[301]),
        ('a1-before-middle-completes',['terminalFinality','A1','sampleQpc'],150.0625),
        ('original-chrome-listener-proof-still-required',['chromeRoots',0,'debugBindingLoopbackObserved'],False),
        ('original-manager-origin-still-required',['chromeRoots',0,'managerTarget','port'],55009),
        ('original-chrome24-schema-still-exact',['chromeRoots',0,'imageUnknown'],True),
    ]
    for name,path,item in changes:
        check(name,False,mutate(path,item))
    for error in ('openError','membershipQueryError','timesError','waitError','exitCodeError'):
        check('extra-api-error-'+error+'-fatal-even-zero',False,
              mutate(['failureLedger','snapshots',0,'rawSnapshot','identities',1,error],0))
    check('hard-error-after-first-pending-is-not-hidden',False,
          lambda v,s:v['failureLedger']['snapshots'][0]['rawSnapshot']['identities'].append(dict(row(999,1008,120.006,image_error=5),openError=5)))
    check('duplicate-before-row-rejects',False,
          lambda v,s:v['failureLedger']['snapshots'][0]['rawSnapshot']['identities'].append(copy.deepcopy(v['failureLedger']['snapshots'][0]['rawSnapshot']['identities'][1])))
    check('missing-before-row-rejects',False,
          lambda v,s:v['failureLedger']['snapshots'][0]['rawSnapshot']['identities'].pop())
    check('after-only-cannot-be-fabricated-as-queried-row',False,
          lambda v,s:v['failureLedger']['snapshots'][0]['rawSnapshot']['identities'].append(row(401,1004,120.006,image=r'C:\other.exe')))
    check('duplicate-resolution-rejects',False,
          lambda v,s:v['failureLedger']['resolvedOccurrences'].append(copy.deepcopy(v['failureLedger']['resolvedOccurrences'][0])))
    check('more-than-eight-failure-frames-rejects',False,
          lambda v,s:v['failureLedger'].update(snapshots=[copy.deepcopy(v['failureLedger']['snapshots'][0]) for _ in range(9)],totalFailureSnapshotsSeen=9,storedFailureSnapshots=9))
    check('ledger-byte-overflow-rejects',False,
          lambda v,s:v['failureLedger']['firstIdentityObservations'].extend([copy.deepcopy(v['failureLedger']['firstIdentityObservations'][0]) for _ in range(1000)]))
    check('resolved-index-bool-is-not-integer',False,
          mutate(['failureLedger','resolvedOccurrences',0,'snapshotIndex'],False))
    def forged_after_only(value,state):
        value['failureLedger']['firstIdentityObservations'].append(dict(sampleOrdinal=5,pid=401,
            creationFiletime=1004,rawRow=row(401,1004,120.006,image=r'C:\other.exe')))
    check('after-only-first-row-cannot-be-invented-in-same-snapshot',False,forged_after_only)
    def covered_hard_after_pending(value,state):
        frame=value['failureLedger']['snapshots'][0]
        frame['rawSnapshot']['before']=listing([101,301,401],120.0)
        frame['afterOnlyNotQueried']=[]
        healthy=row(401,1004,110.0,image=r'C:\other.exe')
        value['failureLedger']['firstIdentityObservations'].insert(2,dict(sampleOrdinal=1,pid=401,creationFiletime=1004,rawRow=healthy))
        frame['rawSnapshot']['identities'].append(dict(row(401,1004,120.006,image=r'C:\other.exe'),waitError=0))
    check('covered-hard-error-after-pending-is-not-short-circuited',False,covered_hard_after_pending)
    def signaled_pending(value,state):
        for r in (value['failureLedger']['snapshots'][0]['rawSnapshot']['identities'][1],
                  value['failureLedger']['firstIdentityObservations'][2]['rawRow']):
            r.update(signaled=True,exitCode=7)
    check('queried-signaled-row-keeps-image-unknown-until-scope-closure',True,signaled_pending)
    def varied_pid(value,state):
        ledger=value['failureLedger'];frame=ledger['snapshots'][0]
        for key in ('before','after'):
            frame['rawSnapshot'][key]['pids']=[999 if pid==301 else pid for pid in frame['rawSnapshot'][key]['pids']]
        frame['rawSnapshot']['identities'][1]['pid']=999
        ledger['firstIdentityObservations'][2]['pid']=999
        ledger['firstIdentityObservations'][2]['rawRow']['pid']=999
        ledger['pendingOccurrences'][0]['pid']=999
        ledger['resolvedOccurrences'][0]['pid']=999
    check('pending-pid-value-is-not-a-whitelist',True,varied_pid)
    def future_chrome(value,state):
        value['chromeRoots'][0].update(commandLineReadBeforeQpc=151.0,commandLineReadAfterQpc=151.001,
            listenerReadBeforeQpc=151.01,listenerReadAfterQpc=151.02,observedQpc=151.02)
    check('chrome-live-proof-after-terminal-transaction-is-contradictory',False,future_chrome)
    def future_failure(value,state):
        raw=value['failureLedger']['snapshots'][0]['rawSnapshot']
        raw.update(startedQpc=150.066,before=listing([101,301],150.066),after=listing([101,301,401],150.069))
        raw['identities'][0]['sampleQpc']=150.067
        raw['identities'][1]['sampleQpc']=150.068
        value['failureLedger']['firstIdentityObservations'][2]['rawRow']=copy.deepcopy(raw['identities'][1])
    check('pending-observation-after-terminal-transaction-cannot-be-closed-by-it',False,future_failure)
    status='PURE_JSON_FINALITY_GUARD_CHECKS_PASSED_NOT_NATIVE_QUALIFICATION'
    code=0
except AssertionError as failure:
    status='PURE_JSON_GUARD_EXPECTATION_FAILED'
    code=1
    checks.append(dict(failedAssertion=str(failure)))
result=dict(status=status,checks=checks,guardPin=dict(path=str(fragment),bytes=fragment.stat().st_size,
    sha256=hashlib.sha256(fragment.read_bytes()).hexdigest()),nativeOrSdkOrProcessOrNetworkCalls=False,
    applicationTestsRun=False)
with output.open('x',encoding='utf-8',newline='\n') as stream:
    json.dump(result,stream,indent=2);stream.write('\n')
print(json.dumps(dict(status=status,checks=len(checks),result=str(output))))
sys.exit(code)
