"""Exercise extracted monitor/hook functions with fake data, no candidate import."""
from pathlib import Path
import copy
import json
import sys

HERE=Path(__file__).absolute().parent
worker=Path(sys.argv[1])
raw=worker.read_text(encoding='utf-8')
start=raw.index('def natural_command(state):')
end=raw.index('\nreceipt = ',start)
functions=raw[start:end]
hook=(HERE/'worker-command-finality-hook.fragment').read_text(encoding='utf-8') if '--with-hook' in sys.argv or '--prepared-worker' in sys.argv else ''
state=dict(pid=1,creationFiletime=100,firstSignaledQpc=150.0,sampleQpc=150.02,signaled=True,
    exitCode=0,exitFiletime=300,kernel100ns=0,user100ns=0,jobAccountingObservedQpc=150.021,
    firstCompleteTerminalQpc=150.021,activeProcesses=0,totalProcesses=2,terminatedProcesses=0,terminal=True)
SCOPE='This private Job only; read-only handles, no command line/environment, no PID termination'
def listing(t):return dict(qpc=t,complete=True,assigned=0,listed=0,limit=32,error=0,pids=[])
middle=dict(startedQpc=150.04,deadlineQpc=150.5,before=listing(150.04),identities=[],after=listing(150.041),
    identityRowsLimitedByDeadline=False,scope=SCOPE,causeClassified=False)
class Job:
    pid=1;identity=100;force_requested=False
    def __init__(self):self.calls=[]
    def sample(self,wait):
        self.calls.append(('sample',wait));value=copy.deepcopy(state)
        if len(self.calls)>1:
            value['sampleQpc']=150.03 if len(self.calls)==2 else 150.05
            value['jobAccountingObservedQpc']=value['sampleQpc']+.001
        return value
    def member_identities(self,deadline):self.calls.append(('members',deadline));return copy.deepcopy(middle)
    def terminate_owned(self):raise AssertionError('natural fake terminal must never be terminated')
receipt={'commandCloseFallback':False}
namespace=dict(START=100.0,COMMAND_END=235.0,CLEANUP_END=240.0,monotonic=lambda:150.06,
    receipt=receipt,finite=lambda v:type(v) is float,require=lambda x,msg:None if x else (_ for _ in ()).throw(AssertionError(msg)),
    same_json=lambda a,b:json.dumps(a,sort_keys=True)==json.dumps(b,sort_keys=True))
if hook and '--prepared-worker' not in sys.argv:
    old="        if state['terminal']:\n            break"
    new="        if state['terminal']:\n            receipt['commandFinalityCapture'] = capture_command_finality(job, state)\n            break"
    assert functions.count(old)==1;functions=functions.replace(old,new)
    old="            if state['terminal']:\n                break"
    new="            if state['terminal']:\n                receipt['commandFinalityCapture'] = capture_command_finality(job, state)\n                break"
    assert functions.count(old)==1;functions=functions.replace(old,new)
exec(compile(hook+'\n'+functions,str(worker)+'#pure-monitor','exec'),namespace)
job=Job();outcome=namespace['monitor_command'](job)
assert type(receipt.get('commandFinalityCapture')) is dict, 'terminal monitor is missing same-command-Job finality transaction'
proof=receipt['commandFinalityCapture']
assert job.calls==[('sample',50),('sample',0),('members',150.5),('sample',0)],job.calls
assert proof['A0']['pid']==proof['A1']['pid']==1 and proof['M']==middle
assert proof['deadlineQpc']==150.5 and proof['forceRequested'] is False and proof['closeFallback'] is False
print(json.dumps({'status':'PURE_MONITOR_SINGLE_FINALITY_TRANSACTION_CHECKED_NO_NATIVE','calls':job.calls,
    'outcomeTerminal':outcome[0]['terminal'],'candidateImported':False,'nativeOrSdkOrProcessOrNetworkCalls':False}))
