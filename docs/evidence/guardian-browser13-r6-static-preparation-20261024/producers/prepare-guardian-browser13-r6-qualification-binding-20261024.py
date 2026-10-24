"""Bind one actually completed own-Python reader + same-Job finality fixture."""
from pathlib import Path
import argparse
import hashlib
import json

R=Path(r'D:\codes\mobile\ai-manager')
B=R/'.cache/guardian-browser13-20261024-r6-owned-member-finality'
parser=argparse.ArgumentParser()
for name in ['actual-terminal-chunk','observer-sha256','result-sha256','outer-sha256']:
    parser.add_argument('--'+name,required=True)
args=parser.parse_args()

def pin(path):
    raw=path.read_bytes();return {'path':str(path),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}

code=pin(B/'owned_chrome_evidence.py');result=pin(B/'observer-fixture/result.json');outer=pin(B/'observer-fixture-host/result.json')
assert code['sha256']==args.observer_sha256 and result['sha256']==args.result_sha256 and outer['sha256']==args.outer_sha256
actual=json.loads(Path(result['path']).read_bytes());host=json.loads(Path(outer['path']).read_bytes())
assert actual['observerSha256']==code['sha256']
assert actual['status']=='OWNED_READ_PATH_FIXTURE_ACCEPTED_NOT_CHROME_QUALIFICATION'
assert actual['forced'] is False and actual['naturalJobZero'] is True
assert actual['sdkStarted'] is actual['chromeStarted'] is actual['networkQueriesOrRequests'] is False
assert actual['newReadPathOnlyNotF8Requalification'] is True
assert len(actual['cases'])==4 and actual['cases'][0]['accepted'] is True
assert all(row['rejected'] is True and row['memoryReads']==0 for row in actual['cases'][1:])
assert host['status']=='OWNED_OBSERVER_FIXTURE_HOST_NATURAL_ZERO' and host['terminal'] is True
assert host['exitCode']==0 and host['forced'] is False and host['sdkOrChromeStarted'] is False
assert 0 <= host['firstObservedTerminalSeconds'] < host['limitSeconds']==10
assert actual['sameCommandJobTerminalTransactionActuallyObserved'] is True
proof=actual['terminalFinality'];state=actual['terminal']
assert proof['schemaVersion']==1 and proof['source']=='SAME_COMMAND_OWNED_JOB'
assert proof['jobRootPid']==actual['pid']==state['pid'] and proof['jobRootCreationFiletime']==actual['creationFiletime']==state['creationFiletime']
assert proof['originalCommandDeadlineQpc']==actual['originalDeadlineQpc']
assert proof['deadlineQpc']==min(actual['originalDeadlineQpc'],state['firstSignaledQpc']+.5)
assert proof['naturalDrainSeconds']==.5 and proof['forceRequested'] is False and proof['closeFallback'] is False
a0,middle,a1=proof['A0'],proof['M'],proof['A1']
for terminal in [state,a0,a1]:
    assert terminal['signaled'] is True and terminal['terminal'] is True and terminal['exitCode']==0 and terminal['activeProcesses']==0
    assert all(terminal[key]==state[key] for key in ['pid','creationFiletime','firstSignaledQpc','firstCompleteTerminalQpc','exitFiletime','totalProcesses','terminatedProcesses'])
assert middle['identities']==[] and middle['identityRowsLimitedByDeadline'] is False and middle['causeClassified'] is False
assert middle['deadlineQpc']==proof['deadlineQpc'] and middle['startedQpc']==middle['before']['qpc']
assert middle['scope']=='This private Job only; read-only handles, no command line/environment, no PID termination'
for listing in [middle['before'],middle['after']]:
    assert set(listing)=={'qpc','complete','assigned','listed','limit','error','pids'}
    assert listing['complete'] is True and listing['assigned']==listing['listed']==listing['error']==0 and listing['pids']==[] and listing['limit']==32
assert state['firstSignaledQpc'] <= state['firstCompleteTerminalQpc'] <= a0['sampleQpc'] <= a0['jobAccountingObservedQpc'] <= middle['before']['qpc'] <= middle['after']['qpc'] <= a1['sampleQpc'] <= a1['jobAccountingObservedQpc'] < proof['deadlineQpc']
value={'status':'CURRENT_SCHEMA2_MODULE_NARROW_READER_AND_SAME_JOB_FINALITY_FIXTURE_NOT_APPLICATION_ACCEPTANCE',
    'observerCodeSha256':code['sha256'],'sourceObserverPin':code,'newNativeReadPathActuallyQualified':True,
    'sameCommandJobTerminalTransactionActuallyObserved':True,'actualQualificationResult':result,
    'actualOuterQualificationResult':outer,'actualToolTerminalChunk':args.actual_terminal_chunk,
    'actualToolTerminalExitCode':0,'nativeReaderAndAbiUnchanged':True,'f8RequalificationRepeated':False,
    'scope':'One own-Python retained-handle reader fixture with original narrow positive/negative cases plus actual same-Job A0/empty-M/A1 inside original 0.5s and 8s fixture deadline; no Chrome/TCP/SDK/application qualification.',
    'sdkOrChromeLifecycleOrTcpQualified':False,'applicationAcceptanceQualified':False}
p=B/'observer-native-qualification-binding.json'
with p.open('x',encoding='utf-8',newline='\n') as stream:json.dump(value,stream,indent=2);stream.write('\n')
print(json.dumps({'status':value['status'],'pin':pin(p)}))
