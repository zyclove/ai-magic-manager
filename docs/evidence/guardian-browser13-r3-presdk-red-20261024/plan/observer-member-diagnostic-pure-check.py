"""Pure mocked Job data only; no native reader, process, socket or SDK calls."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).absolute().parent
spec = importlib.util.spec_from_file_location('browser13_mock_member_diagnostics', HERE/'owned_chrome_evidence.py')
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)

class Clock:
    def __init__(self):
        self.value = 10.0
    def monotonic(self):
        self.value += 0.001
        return self.value

def listing(pids):
    return {'qpc':9.0,'complete':True,'assigned':len(pids),'listed':len(pids),
            'limit':32,'error':0,'pids':list(pids)}

def snapshot(rows):
    pids = [row['pid'] for row in rows]
    return {'before':listing(pids),'after':listing(pids),
            'identities':copy.deepcopy(rows),'identityRowsLimitedByDeadline':False}

class MockJob:
    identity = 1
    def __init__(self, events, clock, advance=False):
        self.events, self.clock, self.advance = events, clock, advance
        self.calls = 0
        self.deadlines = []
    def member_identities(self, deadline):
        self.deadlines.append(deadline)
        item = self.events[min(self.calls, len(self.events)-1)]
        self.calls += 1
        if self.advance and self.calls == 1:
            self.clock.value = deadline
        if isinstance(item, Exception):
            raise item
        return copy.deepcopy(item)

def setup(events, *, advance=False):
    clock = Clock()
    e.time = clock
    job = MockJob(events, clock, advance)
    value = e.OwnedChromeEvidence.__new__(e.OwnedChromeEvidence)
    value.job = job
    value.deadline = 1000.0
    value.reader = SimpleNamespace(deadline=1000.0)
    value.reader.check_deadline = lambda:e.demand(clock.monotonic()<value.reader.deadline,'ORIGINAL_OBSERVATION_DEADLINE')
    value.executable = r'c:\program files\google\chrome\application\chrome.exe'
    value.temporary = str(HERE/'attempt/tmp')
    value.problems, value.checked, value.pending, value.complete = set(),set(),{},{}
    value.samples = 0
    value._initialize_diagnostics()
    return value,job

cases=[]
bad={'pid':57,'openedFromOwnJobList':True,'verifiedOwnMembership':True,
     'signaled':False,'imagePath':r'D:\DO_NOT_LOG_SECRET\worker.exe',
     'imageError':5,'openError':87,'ignoredSecret':'DO_NOT_LOG_SECRET'}
initial=snapshot([bad])

# Even a complete second snapshot with no member never bypasses the old demand.
value,job=setup([initial,snapshot([])])
value.sample()
diag=value.diagnostics()
assert job.calls==2 and 'OWN_JOB_MEMBER_IDENTITY_UNPROVED' in value.problems
assert diag['memberIdentityFailureCount']==diag['failedSampleCalls']==1
assert diag['records'][0]['resample']['snapshot']['before']['pids']==[]
assert diag['records'][0]['resample']['snapshot']['after']['pids']==[]
assert diag['records'][0]['firstSnapshot']['before']['pids']==[57]
assert diag['records'][0]['failedRow']['imageBaseName']=='worker.exe'
assert diag['records'][0]['failedRow']['imagePathSha256']==hashlib.sha256(bad['imagePath'].encode()).hexdigest()
assert 'DO_NOT_LOG_SECRET' not in json.dumps(diag)
assert value.finish()['status']=='NOT_ACCEPTED'
cases.append('gone-second-snapshot-recorded-still-rejected')

value,job=setup([initial])
for _ in range(20):
    value.sample()
diag=value.diagnostics()
assert diag['memberIdentityFailureCount']==diag['failedSampleCalls']==20
assert len(diag['records'])==diag['recordsAttempted']==8
assert diag['recordsDropped']==12 and diag['resampleCalls']==8 and job.calls==28
assert all(record['resample']['status']=='RECORDED' for record in diag['records'])
assert all(deadline==1000.0 for deadline in job.deadlines)
assert diag['sampleElapsedTotalSeconds']>=diag['sampleElapsedMaximumSeconds']>=0
assert diag['sampleElapsedMaximumSeconds']>0
assert diag['firstMemberFailureQpc']<=diag['lastMemberFailureQpc']
assert len((json.dumps(diag,ensure_ascii=False,indent=2)+'\n').encode())<=32768
cases.append('twenty-failures-eight-records-eight-resamples-max')

# Check worst-case encoding is bounded, without changing the input row semantics.
large=dict(bad,imagePath='D:\\'+('私'*30000)+'\\'+('界'*260)+'.exe')
value,job=setup([snapshot([large])])
for _ in range(20):
    value.sample()
diag=value.diagnostics()
assert len(diag['records'])<=8 and diag['recordsAttempted']<=8 and diag['resampleCalls']<=8
assert len((json.dumps(diag,ensure_ascii=True,indent=2)+'\n').encode())<=32768
assert len((json.dumps(diag,ensure_ascii=False,indent=2)+'\n').encode())<=32768
assert 'OWN_JOB_MEMBER_IDENTITY_UNPROVED' in value.problems
cases.append('byte-cap-for-large-redacted-image-metadata')

value,job=setup([initial],advance=True)
value.sample()
diag=value.diagnostics()
assert job.calls==1 and diag['resampleCalls']==0
assert diag['records'][0]['resample']['status']=='SKIPPED_ORIGINAL_DEADLINE'
assert 'OWN_JOB_MEMBER_IDENTITY_UNPROVED' in value.problems
assert diag['originalCommandDeadlineQpc']==1000.0 and value.reader.deadline==1000.0
cases.append('no-original-time-no-extra-query-still-rejected')

value,job=setup([initial,RuntimeError('DO_NOT_LOG_SECRET')])
value.sample()
diag=value.diagnostics()
assert job.calls==2 and diag['resampleCalls']==1
assert diag['records'][0]['resample']=={'status':'ERROR','errorType':'RuntimeError'}
assert 'DO_NOT_LOG_SECRET' not in json.dumps(diag)
assert 'OWN_JOB_MEMBER_IDENTITY_UNPROVED' in value.problems
cases.append('resample-error-type-only-still-rejected')

value,job=setup([initial,None])
value.sample()
diag=value.diagnostics()
assert diag['records'][0]['resample']['status']=='ERROR'
assert 'OWN_JOB_MEMBER_IDENTITY_UNPROVED' in value.problems
cases.append('malformed-resample-cannot-bypass-original-failure')

value,job=setup([initial])
value.sample()
before_calls=job.calls
first=value.diagnostics()
first['records'][0]['failedRow']['pid']=999
second=value.diagnostics()
assert second['records'][0]['failedRow']['pid']==57 and job.calls==before_calls
assert second['nativeOrNetworkQueriesPerformedByDiagnosticsMethod'] is False
assert second['acceptanceRulesChanged'] is False
cases.append('diagnostics-is-detached-pure-aggregation')

value,job=setup([snapshot([])])
value.sample()
diag=value.diagnostics()
assert not value.problems and diag['failedSampleCalls']==diag['memberIdentityFailureCount']==0
assert diag['records']==[] and diag['resampleCalls']==0
cases.append('no-unknown-row-no-diagnostic-resample')

value,job=setup([initial])
value.sample(deadline_qpc=2000.0)
assert all(deadline==1000.0 for deadline in job.deadlines)
assert value.reader.deadline==1000.0
cases.append('higher-caller-deadline-cannot-extend-original')

result={'status':'PURE_MOCKED_JOB_MEMBER_DIAGNOSTICS_CHECKED_NOT_PROCESS_QUALIFICATION',
    'cases':cases,'caseCount':len(cases),
    'observerPin':{'path':str(HERE/'owned_chrome_evidence.py'),
        'bytes':(HERE/'owned_chrome_evidence.py').stat().st_size,
        'sha256':hashlib.sha256((HERE/'owned_chrome_evidence.py').read_bytes()).hexdigest()},
    'nativeReaderInitialized':False,'realJobOrProcessQueried':False,
    'sdkOrChromeStarted':False,'networkQueriedOrRequested':False,
    'unknownMemberBypassed':False,'r2CauseEstablished':False,'applicationCasesVerified':0}
out=HERE/'observer-member-diagnostic-pure-result.json'
with out.open('x',encoding='utf-8') as stream:
    json.dump(result,stream,indent=2);stream.write('\n')
print(json.dumps(result))
