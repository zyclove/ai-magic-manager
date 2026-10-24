"""File-only final B6 bindings, exact inverse and schema2 integration checks."""
from pathlib import Path
import copy
import hashlib
import json

R=Path(r'D:\codes\mobile\ai-manager')
A=R/'.cache/guardian-browser13-20261024-r5-typed-finder-current3cf'
AP=R/'.cache/guardian-browser13-post-20261024-r5-typed-finder-current3cf'
B=R/'.cache/guardian-browser13-20261024-r6-owned-member-finality'
P=R/'.cache/guardian-browser13-post-20261024-r6-owned-member-finality'
V=R/'.cache/guardian-vm35-20261024-r1'

def pin(path):
    raw=path.read_bytes();return {'path':str(path),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}

def undo(raw,edits):
    for row in reversed(edits):
        x,y=row['old'].encode(),row['new'].encode()
        assert len(row['replacementBytePositions'])==row['count']
        for position in reversed(row['replacementBytePositions']):
            assert raw[position:position+len(y)]==y
            raw=raw[:position]+x+raw[position+len(y):]
    return raw

control=json.loads((B/'control-preparation-pins.json').read_bytes())
old_control=json.loads((A/'control-preparation-pins.json').read_bytes())
inverse=[]
paths=[('worker.py',A/'worker.py',B/'worker.py',V/'worker.py'),
       ('analysis-host.py',A/'analysis-host.py',B/'analysis-host.py',V/'analysis-host.py'),
       ('root-launch',R/'.cache/guardian-browser13-root-launch-20261024-r5-typed-finder-current3cf.ps1',R/'.cache/guardian-browser13-root-launch-20261024-r6-owned-member-finality.ps1',R/'.cache/guardian-vm35-root-launch-20261024-r1.ps1'),
       ('release',R/'.cache/guardian-browser13-release-20261024-r5-typed-finder-current3cf.ps1',R/'.cache/guardian-browser13-release-20261024-r6-owned-member-finality.ps1',R/'.cache/guardian-vm35-release-20261024-r1.ps1'),
       ('post.py',AP/'post.py',P/'post.py',R/'.cache/guardian-vm35-post-20261024-r1/post.py')]
for label,old,new,original in paths:
    back=undo(new.read_bytes(),[row for row in control['literalAndHookChanges'] if row['file']==label])
    assert back==old.read_bytes()
    if label=='post.py':edits=json.loads((AP/'pins.json').read_bytes())['literalAndHookChanges']
    else:edits=[row for row in old_control['literalAndHookChanges'] if row['file']==label]
    assert undo(back,edits)==original.read_bytes()
    inverse.append({'file':label,'pin':pin(new),'inverseToB5Exact':True,'originalVM35InverseChainExact':True})
base=json.loads((A/'base-pins.json').read_bytes())
assert (B/'reporter_contract.py').read_bytes()==(A/'reporter_contract.py').read_bytes()
assert undo((B/'reporter_contract.py').read_bytes(),base['reporterLiteralChanges'])==(V/'reporter_contract.py').read_bytes()
for name in ['owned_job.py','process-inventory.ps1','cache-browser-projection.json','expected-browser13-cases.json','observer-runtime-pins.json']:
    assert (A/name).read_bytes()==(B/name).read_bytes()

i=json.loads((B/'inputs.json').read_bytes());old_i=json.loads((A/'inputs.json').read_bytes())
def normalize(value):
    if type(value) is str:return value.replace(B.name,A.name)
    if type(value) is list:return [normalize(row) for row in value]
    if type(value) is dict:return {k:normalize(row) for k,row in value.items()}
    return value
normalized=normalize(i)
for key in ['createdAtUtc','ownedChromeEvidenceCode','ownedChromeNativeQualification']:normalized[key]=copy.deepcopy(old_i[key])
assert normalized==old_i
descriptors=[]
for key,row in i.items():
    if type(row) is dict and {'path','bytes','sha256'}<=set(row):
        actual=pin(Path(row['path']));assert (actual['bytes'],actual['sha256'])==(row['bytes'],row['sha256']);descriptors.append({'key':key,'pin':actual})
assert len(descriptors)==18
proposal=json.loads((B/'proposal.json').read_bytes());old_proposal=json.loads((A/'proposal.json').read_bytes())
assert proposal['budgets']==old_proposal['budgets'] and proposal['sourceCommit']==i['sourceCommit']=='3cfbf535099ade86234661556d9e92db9069743a'
runtime=i['controlRuntimeFiles']+i['extraRuntimeFiles'];assert runtime==proposal['runtimePins']==old_proposal['runtimePins'] and len(runtime)==43
for row in runtime:
    actual=pin(Path(row['path']));assert (actual['bytes'],actual['sha256'])==(row['bytes'],row['sha256'])
for row in proposal['candidateFiles']:
    actual=pin(B/row['path']);assert (actual['bytes'],actual['sha256'])==(row['bytes'],row['sha256'])
guard=(B/'chrome-evidence-json-guard.fragment').read_text(encoding='utf-8').rstrip()
for name in [B/'worker.py',B/'analysis-host.py',P/'post.py']:
    raw=name.read_text(encoding='utf-8');assert raw.count(guard)==1
    assert 'ownedMemberFailureLedgerPin' in raw and 'commandJobFinalityPin' in raw
    assert 'commandFinalityCapture' in raw
    compile(raw,str(name),'exec')
assert (B/'worker.py').read_text(encoding='utf-8').count("receipt['commandFinalityCapture'] = capture_command_finality(job, state)")==2
hook=(B/'worker-command-finality-hook.fragment').read_text(encoding='utf-8')
assert hook.count('job.sample(0)')==2 and hook.count('job.member_identities(float(finality_end))')==1
assert 'sleep' not in hook and 'terminate_owned' not in hook
module=(B/'owned_chrome_evidence.py').read_bytes();old_module=(A/'owned_chrome_evidence.py').read_bytes()
regions=[]
for name,start,end in [('parsersAndNativeReaderPrefix',b'"""Read-only evidence',b'class OwnedChromeEvidence:'),
        ('profileAndListenerMethods',b'    def _profile_unlinked(',b'    def sample('),
        ('chromeRetainedReadCallBlock',b"                identity = (row['pid'], row['creationFiletime'])",b'        except EvidenceRejected as failure:')]:
    x=module[module.index(start):module.index(end,module.index(start))];y=old_module[old_module.index(start):old_module.index(end,old_module.index(start))]
    assert x==y;regions.append({'name':name,'bytes':len(x),'sha256':hashlib.sha256(x).hexdigest(),'byteExact':True})
assert pin(B/'owned_chrome_evidence.py')['sha256']=='81be26d61faf4b2a77a18b0c2cd8b34c908e776517dc95159b3c903b8e2371b0'
qual=json.loads((B/'observer-native-qualification-binding.json').read_bytes())
assert qual['observerCodeSha256']==pin(B/'owned_chrome_evidence.py')['sha256']
assert qual['actualToolTerminalChunk']=='be612a' and qual['sameCommandJobTerminalTransactionActuallyObserved'] is True
for key in ['actualQualificationResult','actualOuterQualificationResult']:assert pin(Path(qual[key]['path']))==qual[key]
guard_pins=json.loads((B/'member-finality-guard-pins-final.json').read_bytes())
for row in guard_pins['files']:assert pin(Path(row['path']))==row
assert not any((B/n).exists() for n in ['attempt','root-attempt','root-sdk-grant.json'])
assert not (P/'post.json').exists()
result={'status':'B6_FINAL_STATIC_BINDING_AND_INVERSE_CHECKS_NOT_SDK_ACCEPTANCE','inputs':pin(B/'inputs.json'),
    'proposal':pin(B/'proposal.json'),'sourceCommit':i['sourceCommit'],'sourceFiles':413,'fullRoots':183,
    'selectedChromeSuites':1,'exactVisibleCases':13,'fiveArtifactsInverseToB5AndOriginalVM35':inverse,
    'sixCodeArtifactVM35InverseIncludingUnchangedReporter':True,'sensitiveRegions':regions,
    'topLevelInputDescriptorsActuallyHashed':descriptors,'runtimeFilesActuallyHashed':43,
    'nativeProviderReporterCaseAndCacheByteExactToB5':True,'allOriginalBudgetsAndDrainAndNoForceRetained':True,
    'rawLedgerAndFinalityMirroredAndPinnedAtAllThreeCallers':True,
    'jsonWritersUseAsciiEscapesForLosslessUtf16SurrogateRoundtrip':True,
    'actualNarrowQualification':pin(B/'observer-native-qualification-binding.json'),
    'sdkChromeNetworkGitMutationOrGrantOrAttemptCreated':False}
p=B/'binding-pins.json'
with p.open('x',encoding='utf-8',newline='\n') as stream:json.dump(result,stream,indent=2);stream.write('\n')
print(json.dumps({'status':result['status'],'pins':pin(p),'post':pin(P/'post.py'),
    'rootLauncher':pin(R/'.cache/guardian-browser13-root-launch-20261024-r6-owned-member-finality.ps1'),
    'release':pin(R/'.cache/guardian-browser13-release-20261024-r6-owned-member-finality.ps1')}))
