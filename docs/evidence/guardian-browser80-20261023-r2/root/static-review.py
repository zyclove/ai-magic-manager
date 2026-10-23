"""Root static qualification only. No candidate/reporter/observer/native execution."""
from pathlib import Path
import ast,datetime,hashlib,json,subprocess
repo=Path(__file__).resolve().parents[1]
base=repo/'.cache/guardian-browser80-20261023-r2'
old=repo/'.cache/guardian-browser80-20261023-r1'
load=lambda p:json.loads(p.read_bytes())
sha=lambda raw:hashlib.sha256(raw).hexdigest()
p=load(base/'proposal.json');q=load(old/'proposal.json')
assert sha((base/'proposal.json').read_bytes())=='a9951961c2d4a933567bd38446228bb177cc469cdbe23a8d9b42b816f11857be'
assert p['sourceCommit']=='45950b88a270e2fded2409e333fb126851b6f861'
assert p['sourceFiles']==409 and p['expectedVisibleCases']==80 and p['expectedPhysicalSuites']==7
assert len(p['selectedTestFiles'])==7
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo).decode().strip()==p['sourceCommit']
def rows(x):return x['candidateFiles']+x['controlRuntimeFiles']+x['historicalMetadataFiles']
def path(b,r):return Path(r['path']) if r.get('absolute') else b/r['path']
assert len(rows(p))==381
identity=set()
for r in rows(p):
    f=path(base,r);raw=f.read_bytes();assert len(raw)==r['bytes'] and sha(raw)==r['sha256']
    identity.add((str(f.resolve()).lower(),r['bytes'],r['sha256']))
assert len(rows(q))==269
assert all((str(path(old,r).resolve()).lower(),r['bytes'],r['sha256']) in identity for r in rows(q))
for name in ('controller.py','heap1536_windows_job.py','reporter_contract.py','owned_chrome_observer.py','budget-policy.json'):
    assert (base/name).read_bytes()==(old/name).read_bytes()
a=ast.parse((old/'worker.py').read_text(encoding='utf-8'));b=ast.parse((base/'worker.py').read_text(encoding='utf-8'))
assert len(a.body)==len(b.body)
changes=[]
for before,after in zip(a.body,b.body):
    if ast.dump(before)==ast.dump(after):continue
    assert isinstance(before,ast.Assign) and isinstance(after,ast.Assign)
    name=before.targets[0].id;assert name==after.targets[0].id and name in {'FROZEN','INPUT_SHA256'};changes.append(name)
assert changes==['FROZEN','INPUT_SHA256']
for key in ('outerBudgetSeconds','outerSoftCutoffSeconds','outerContainmentTailSeconds','workerFinishByOuterSeconds','controllerFinalReserveSeconds','workerLocalSecondsMaximum','commandCapSecondsMaximum','cleanupSecondsMaximum','minimumPostflightReserveSeconds','minimumRamBytes','minimumEachDiskBytes','sdkNames','sdkExecutableRoots','handshakeProtocol','command','selectedTestFiles','successStatusWhitelist','legacyStrictAccepted'):
    assert p[key]==q[key]
i=load(base/'inputs.json');j=load(old/'inputs.json')
delta={k:{'before':j.get(k),'after':i.get(k)} for k in i.keys()|j.keys() if i.get(k)!=j.get(k)}
assert delta==load(base/'input-metadata-diff.json')['changedFields'] and len(delta)==13
assert not set(delta)&{'forbiddenEnvironmentOverrides','processPath','generatedExclusions','sdkBootstrap','controlRuntimeFiles','extraRuntimeFiles','sdkExecutableRoots','launcherSourcePins','versionFilePins'}
assert Path(i['cacheManifest']['path']).read_bytes()==Path(j['cacheManifest']['path']).read_bytes()
cache=load(Path(i['cacheManifest']['path']));assert cache['totals']['files']==3537 and len(cache['fixedFiles'])==33
expected=load(Path(i['expectedCaseContract']['path']));prior=load(Path(j['expectedCaseContract']['path']))
assert expected['expectedVisibleCases']==80 and expected['expectedPhysicalSuites']==7
assert expected['selectedSources']==prior['selectedSources']
manifest=load(Path(i['sourceManifest']['path']))
for r in manifest['sourceFiles']:
    raw=(repo/r['path']).read_bytes();assert len(raw)==r['workingTreeRawBytes'] and sha(raw)==r['workingTreeRawSha256']
analysis=repo/'.cache/guardian-analyze-20261023-r8/attempt'
assert load(analysis/'result.json')['status']=='FULL_GUARDIAN_ANALYZE_PASSED'
gate=load(analysis/'root-final-system-gate.json')
assert gate['sourceCommit']==p['sourceCommit'] and gate['formalRelease'] and gate['status']=='FULL_GUARDIAN_ANALYZE_EXTERNALLY_ACCEPTED'
assert not (base/'attempt').exists()
value={'status':'ROOT_BROWSER80_R2_STATIC_CONTROL_INPUT_SOURCE_MATCHED_UNRUN',
 'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceCommit':p['sourceCommit'],'pinsMatched':381,
 'oldR1PinsPreserved':269,'fiveControlsByteIdentical':True,'workerAstChanges':changes,
 'actualInputDeltaKeys':sorted(delta),'numericalBudgetsUnchanged':True,'browserCacheFiles':3537,
 'r8ActualAnalysisPrerequisiteAccepted':True,'r7RedPreserved':True,'testsExecuted':0,'attemptCreated':False,'sdkCalls':0}
with (repo/'.cache/guardian-browser80-r2-root-static-review-20261023.json').open('x',encoding='utf-8') as stream:json.dump(value,stream,indent=2);stream.write('\n')
print(json.dumps(value))
