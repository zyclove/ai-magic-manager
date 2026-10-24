"""Bind reviewed schema2 B6 controls. Never run a candidate or the SDK."""
from pathlib import Path
import datetime
import difflib
import hashlib
import json
import subprocess

R=Path(r'D:\codes\mobile\ai-manager')
A=R/'.cache/guardian-browser13-20261024-r5-typed-finder-current3cf'
AP=R/'.cache/guardian-browser13-post-20261024-r5-typed-finder-current3cf'
B=R/'.cache/guardian-browser13-20261024-r6-owned-member-finality'
P=R/'.cache/guardian-browser13-post-20261024-r6-owned-member-finality'
HEAD='3cfbf535099ade86234661556d9e92db9069743a'
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=R).decode().strip()==HEAD
assert not any((B/n).exists() for n in ['attempt','root-attempt','root-sdk-grant.json'])

def pin(path,relative=False):
    raw=path.read_bytes();return {'path':path.name if relative else str(path),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}

def create(path,raw):
    if path.exists():assert path.read_bytes()==raw,str(path)+' changed'
    else:
        with path.open('xb') as stream:stream.write(raw)
    return pin(path)

def dump(path,value):return create(path,(json.dumps(value,indent=2)+'\n').encode())

changes=[]
def replace(raw,old,new,label):
    x,y=old.encode(),new.encode();positions=[];cursor=0
    while True:
        offset=raw.find(x,cursor)
        if offset<0:break
        positions.append(offset);cursor=offset+len(x)
    assert positions,(label,old)
    changes.append({'file':label,'old':old,'new':new,'count':len(positions),
        'replacementBytePositions':[p+i*(len(y)-len(x)) for i,p in enumerate(positions)]})
    return raw.replace(x,y)

def artifact(old,new,label,raw):
    before=old.read_bytes();create(new,raw)
    return create(B/(label+'-vs-b5.patch'),''.join(difflib.unified_diff(before.decode().splitlines(True),raw.decode().splitlines(True),fromfile=str(old),tofile=str(new))).encode())

guard_path=B/'chrome-evidence-json-guard.fragment'
guard=guard_path.read_text(encoding='utf-8').rstrip()
assert pin(guard_path)['sha256']=='0f44fe849b8dbdacdca28c111232f8ad29511ad35d87d935df423b08d9547a3d'
old_guard=(A/'chrome-evidence-json-guard.fragment').read_text(encoding='utf-8').rstrip()
qual_path=B/'observer-native-qualification-binding.json'
qual=json.loads(qual_path.read_bytes());code_pin=pin(B/'owned_chrome_evidence.py')
assert qual['observerCodeSha256']==code_pin['sha256'] and qual['newNativeReadPathActuallyQualified'] is True
assert qual['sameCommandJobTerminalTransactionActuallyObserved'] is True
for key in ['actualQualificationResult','actualOuterQualificationResult']:assert pin(Path(qual[key]['path']))==qual[key]

original=json.loads((A/'inputs.json').read_bytes());i=json.loads(json.dumps(original))
stamp=B/'binding-start.json'
if not stamp.exists():dump(stamp,{'createdAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat()})
i['createdAtUtc']=json.loads(stamp.read_bytes())['createdAtUtc']
for key,name in [('cacheManifest','cache-browser-projection.json'),('testCaseContract','expected-browser13-cases.json'),
                 ('reporterContractCode','reporter_contract.py'),('processInventoryProvider','process-inventory.ps1')]:i[key]=pin(B/name)
i['ownedChromeEvidenceCode']=code_pin;i['ownedChromeNativeQualification']=pin(qual_path)
descriptor_rows=[]
for key,row in i.items():
    if type(row) is dict and {'path','bytes','sha256'}<=set(row):
        actual=pin(Path(row['path']));assert (actual['bytes'],actual['sha256'])==(row['bytes'],row['sha256']),(key,'descriptor drift')
        descriptor_rows.append({'key':key,'pin':actual})
runtime=i['controlRuntimeFiles']+i['extraRuntimeFiles']
assert len(runtime)==len({row['path'].replace('\\','/').casefold() for row in runtime})==43
for row in runtime:
    actual=pin(Path(row['path']));assert (actual['bytes'],actual['sha256'])==(row['bytes'],row['sha256'])
ip=dump(B/'inputs.json',i);old_ip=pin(A/'inputs.json')

worker=(A/'worker.py').read_bytes()
worker=replace(worker,old_ip['sha256'],ip['sha256'],'worker.py')
worker=replace(worker,'INPUT_BYTES = '+str(old_ip['bytes']),'INPUT_BYTES = '+str(ip['bytes']),'worker.py')
worker=replace(worker,old_guard,guard,'worker.py')
worker=replace(worker,'json.dump(value, stream, ensure_ascii=False, indent=2)',
    'json.dump(value, stream, ensure_ascii=True, indent=2)','worker.py')
worker=replace(worker,'json.dumps(chrome_diagnostics, ensure_ascii=False, indent=2)',
    'json.dumps(chrome_diagnostics, ensure_ascii=True, indent=2)','worker.py')
hook=(B/'worker-command-finality-hook.fragment').read_text(encoding='utf-8')
worker=replace(worker,'def natural_command(state):',hook+'\n\ndef natural_command(state):','worker.py')
start=worker.index(b'def monitor_command(job):');end=worker.index(b'\nreceipt = ',start)
monitor=worker[start:end].decode();updated=monitor
old="        if state['terminal']:\n            break"
new="        if state['terminal']:\n            receipt['commandFinalityCapture'] = capture_command_finality(job, state)\n            break"
assert updated.count(old)==1;updated=updated.replace(old,new)
old="            if state['terminal']:\n                break"
new="            if state['terminal']:\n                receipt['commandFinalityCapture'] = capture_command_finality(job, state)\n                break"
assert updated.count(old)==1;updated=updated.replace(old,new)
worker=replace(worker,monitor,updated,'worker.py')
worker=replace(worker,'chrome_evidence = chrome_observer.finish()',
    "chrome_evidence = chrome_observer.finish(receipt.get('commandFinalityCapture'))",'worker.py')
raw_hook=(B/'raw-member-artifacts-worker.fragment').read_text(encoding='utf-8')
worker=replace(worker,"            save('owned-chrome-evidence.json', chrome_evidence)",
    raw_hook+"            save('owned-chrome-evidence.json', chrome_evidence)",'worker.py')
artifact(A/'worker.py',B/'worker.py','worker',worker)

host=(A/'analysis-host.py').read_bytes()
for old,new in [(old_ip['sha256'],ip['sha256']),('INPUT_BYTES = '+str(old_ip['bytes']),'INPUT_BYTES = '+str(ip['bytes'])),
                (A.name,B.name),(old_guard,guard)]:host=replace(host,old,new,'analysis-host.py')
host=replace(host,'json.dump(value, stream, ensure_ascii=False, indent=2)',
    'json.dump(value, stream, ensure_ascii=True, indent=2)','analysis-host.py')
anchor="    if not (same_json(chrome_raw, receipt.get('ownedChromeEvidence'))"
host=replace(host,anchor,(B/'raw-member-artifacts-host.fragment').read_text(encoding='utf-8')+anchor,'analysis-host.py')
artifact(A/'analysis-host.py',B/'analysis-host.py','host',host)

proposal=json.loads((A/'proposal.json').read_bytes());proposal['inputs']=ip
names=['analysis-host.py','worker.py','owned_job.py','process-inventory.ps1','reporter_contract.py','owned_chrome_evidence.py']
proposal['candidateFiles']=[pin(B/name,True) for name in names];assert proposal['runtimePins']==runtime
pp=dump(B/'proposal.json',proposal);old_pp=pin(A/'proposal.json')
for kind in ['root-launch','release']:
    old=R/('.cache/guardian-browser13-'+kind+'-20261024-r5-typed-finder-current3cf.ps1')
    new=R/('.cache/guardian-browser13-'+kind+'-20261024-r6-owned-member-finality.ps1')
    raw=old.read_bytes();raw=replace(raw,A.name,B.name,kind)
    if kind=='root-launch':raw=replace(raw,old_pp['sha256'],pp['sha256'],kind)
    else:raw=replace(raw,AP.name,P.name,kind)
    artifact(old,new,kind,raw)

post=(AP/'post.py').read_bytes()
for old,new in [(A.name,B.name),(AP.name,P.name),
    ('guardian-browser13-root-launch-20261024-r5-typed-finder-current3cf.ps1','guardian-browser13-root-launch-20261024-r6-owned-member-finality.ps1'),
    (old_ip['sha256'],ip['sha256']),(old_pp['sha256'],pp['sha256']),
    ("proposal['inputs']['bytes'] == "+str(old_ip['bytes']),"proposal['inputs']['bytes'] == "+str(ip['bytes'])),(old_guard,guard)]:
    post=replace(post,old,new,'post.py')
post=replace(post,'json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False)',
    'json.dump(result, stream, ensure_ascii=True, indent=2, allow_nan=False)','post.py')
anchor="    require(same(chrome_raw, receipt.get('ownedChromeEvidence'))"
post=replace(post,anchor,(B/'raw-member-artifacts-post.fragment').read_text(encoding='utf-8')+anchor,'post.py')
P.mkdir(exist_ok=True);post_pin=create(P/'post.py',post)
create(P/'post-vs-b5.patch',''.join(difflib.unified_diff((AP/'post.py').read_text(encoding='utf-8').splitlines(True),post.decode().splitlines(True),fromfile=str(AP/'post.py'),tofile=str(P/'post.py'))).encode())
post_pins=dump(P/'pins.json',{'status':'SCHEMA2_RAW_LEDGER_FINALITY_POST_PREPARED_NOT_EXECUTED','post':post_pin,
    'inputs':ip,'proposal':pp,'guard':pin(guard_path),'noCandidateImportOrSDKOrBrowserRun':True})
control=dump(B/'control-preparation-pins.json',{'status':'SCHEMA2_B6_CONTROLS_PREPARED_NOT_EXECUTED',
    'inputs':ip,'proposal':pp,'candidateFiles':proposal['candidateFiles'],'runtimeUnionCount':43,
    'sourceCommit':HEAD,'budgets':proposal['budgets'],'literalAndHookChanges':changes,
    'guardFragment':pin(guard_path),'qualification':pin(qual_path),'postPins':post_pins,
    'topLevelInputDescriptorsActuallyHashed':descriptor_rows,'runtimeFilesActuallyHashed':43,
    'sdkBrowserAstCandidateOrTestsExecuted':False,'rootGrantOrAttemptCreated':False})
print(json.dumps({'status':'B6_CONTROLS_AND_POST_PREPARED_NO_EXECUTION','inputs':ip,'proposal':pp,
    'post':post_pin,'controlPins':control}))
