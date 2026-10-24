"""Pure collector regression checks; no NativeReader or real Job is constructed."""
import copy
import importlib.util
import json
from pathlib import Path
import time

HERE=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('b6_observer_pure',HERE/'owned_chrome_evidence.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
assert callable(getattr(m.OwnedChromeEvidence,'_initialize_acceptance',None)), 'schema2 complete acceptance ledger is missing'
NOW=time.monotonic()
END=NOW+60.0
SCOPE='This private Job only; read-only handles, no command line/environment, no PID termination'

def row(pid=2,creation=200,**changes):
    value=dict(pid=pid,openedFromOwnJobList=True,verifiedOwnMembership=True,retainedRootHandleUsed=pid==1,
        creationFiletime=creation,exitFiletime=0,kernel100ns=0,user100ns=0,sampleQpc=NOW-.01,
        signaled=False,imageError=5)
    value.update(changes);return value

def snapshot(rows,after=None):
    before=[r['pid'] for r in rows];after=before if after is None else after
    def listing(pids,qpc):return dict(qpc=qpc,complete=True,assigned=len(pids),listed=len(pids),limit=32,error=0,pids=pids)
    return dict(startedQpc=NOW-.02,deadlineQpc=END,before=listing(before,NOW-.02),identities=rows,
        after=listing(after,NOW-.001),identityRowsLimitedByDeadline=False,scope=SCOPE,causeClassified=False)

class FakeJob:
    pid=1;identity=100;force_requested=False
    first_signaled_qpc=NOW+1.0;first_complete_terminal_qpc=NOW+1.02
    def __init__(self,frames):self.frames=frames;self.calls=0
    def member_identities(self,deadline):
        value=copy.deepcopy(self.frames[min(self.calls,len(self.frames)-1)]);self.calls+=1;return value

class FakeReader:
    deadline=END
    def check_deadline(self):assert time.monotonic()<self.deadline
    def open_member(self,*args):raise AssertionError('pure image-unknown members must never be opened/read')

def observer(frames):
    value=m.OwnedChromeEvidence.__new__(m.OwnedChromeEvidence)
    value.job=FakeJob(frames);value.executable=r'c:\program files\google\chrome\application\chrome.exe'
    value.temporary=r'd:\task\tmp';value.deadline=END;value.reader=FakeReader()
    value.problems=set();value.checked=set();value.pending={};value.complete={};value.samples=0
    value._initialize_diagnostics();value._initialize_acceptance();return value

def finality():
    first=NOW+1.0;complete=NOW+1.02;deadline=min(END,first+.5)
    def state(qpc):return dict(pid=1,creationFiletime=100,firstSignaledQpc=first,sampleQpc=qpc,signaled=True,
        exitCode=0,exitFiletime=500,kernel100ns=0,user100ns=0,jobAccountingObservedQpc=qpc+.0001,
        firstCompleteTerminalQpc=complete,activeProcesses=0,totalProcesses=3,terminatedProcesses=0,terminal=True)
    middle=snapshot([]);middle['startedQpc']=NOW+1.05;middle['deadlineQpc']=deadline
    middle['before']['qpc']=NOW+1.05;middle['after']['qpc']=NOW+1.051
    return dict(schemaVersion=1,source='SAME_COMMAND_OWNED_JOB',jobRootPid=1,jobRootCreationFiletime=100,
        originalCommandDeadlineQpc=END,deadlineQpc=deadline,naturalDrainSeconds=.5,
        A0=state(NOW+1.04),M=middle,A1=state(NOW+1.06),forceRequested=False,closeFallback=False)

cases=[]
def check(name,condition):assert condition,name;cases.append(name)

o=observer([snapshot([row(),row(3,300,imageError=123)],[2,3,9])]);o.sample(END)
v=o.finish(finality());ledger=v['failureLedger']
check('first-pending-does-not-hide-second-before-row',len(ledger['pendingOccurrences'])==2 and len(ledger['resolvedOccurrences'])==2)
check('ordinary-after-only-is-not-fatal-or-invented-identity',ledger['snapshots'][0]['afterOnlyNotQueried']==[9] and not ledger['fatalProblems'] and all(x['pid']!=9 for x in ledger['firstIdentityObservations']))
check('diagnostic-resample-stopped',o.job.calls==1 and o.diagnostics()['resampleCalls']==0)
check('image-remains-unknown-in-resolution',all(x['resolution']=='OWNED_MEMBER_CLOSED_IMAGE_UNKNOWN' for x in ledger['resolvedOccurrences']))

o=observer([snapshot([row(),row(3,300,verifiedOwnMembership=False,membershipRaceOrChange=True)])]);o.sample(END);v=o.finish(finality())
check('hard-row-after-first-pending-stays-fatal',bool(v['failureLedger']['fatalProblems']) and v['status']=='NOT_ACCEPTED' and len(v['failureLedger']['snapshots'][0]['rawSnapshot']['identities'])==2)

o=observer([snapshot([row()])]);o.sample(END);v=o.finish(None)
check('missing-finality-does-not-resolve',not v['failureLedger']['resolvedOccurrences'])
o=observer([snapshot([row()])]);o.sample(END);proof=finality();proof['A1']['jobAccountingObservedQpc']=proof['deadlineQpc'];v=o.finish(proof)
check('at-original-drain-boundary-rejected',not v['failureLedger']['resolvedOccurrences'])
o=observer([snapshot([row()])]);o.sample(END);proof=finality();proof['jobRootPid']=999;v=o.finish(proof)
check('wrong-command-job-rejected',not v['failureLedger']['resolvedOccurrences'])
o=observer([snapshot([row()]),snapshot([row(2,201)])]);o.sample(END);o.sample(END);v=o.finish(finality())
check('creation-conflict-never-cleared',bool(v['failureLedger']['identityConflicts']) and v['status']=='NOT_ACCEPTED')
o=observer([snapshot([row()])])
for _ in range(9):o.sample(END)
v=o.finish(finality())
check('ninth-failure-overflow-is-hard',v['failureLedger']['totalFailureSnapshotsSeen']==9 and v['failureLedger']['storedFailureSnapshots']==8 and v['failureLedger']['overflow'] is True and v['status']=='NOT_ACCEPTED')

normal=row(imagePath=r'C:\Windows\System32\cmd.exe');del normal['imageError']
o=observer([snapshot([normal],[2,9])]);o.sample(END);v=o.finish(finality())
check('ordinary-spawn-does-not-consume-failure-cap',v['failureLedger']['totalFailureSnapshotsSeen']==0)
result=dict(status='PURE_MOCK_COLLECTOR_CHECKED_NOT_NATIVE_OR_APPLICATION_QUALIFICATION',caseCount=len(cases),cases=cases,
    nativeReaderConstructed=False,realJobOrProcessQueried=False,sdkChromeNetworkStarted=False)
path=HERE/'observer-ledger-pure-result.json'
with path.open('x',encoding='utf-8',newline='\n') as stream:json.dump(result,stream,indent=2);stream.write('\n')
print(json.dumps(result))
