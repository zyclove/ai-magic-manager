"""Root control/input static review; does not import any candidate or start an SDK."""
from pathlib import Path
import ast,copy,datetime,hashlib,json
REPO=Path(__file__).resolve().parents[1]
NEW=REPO/'.cache/guardian-analyze-20261023-r7'
OLD=REPO/'.cache/guardian-analyze-20261023-r6'
load=lambda p:json.loads(p.read_bytes())
sha=lambda raw:hashlib.sha256(raw).hexdigest()
proposal=load(NEW/'proposal.json');old=load(OLD/'proposal.json')
assert sha((NEW/'proposal.json').read_bytes())=='2c1c4e32c0255b3a3eaa4272058ef5eb5f2e5388e5eb58b45d5a1ceb6d37ef36'
assert proposal['sourceCommit']=='a55849d902b248fe02d06e23cd0bad3d28912a27' and proposal['sourceFiles']==409
def all_rows(p):return p['candidateFiles']+p['controlRuntimeFiles']+p['historicalMetadataFiles']
def resolve(base,row):return Path(row['path']) if row.get('absolute') else base/row['path']
pins=all_rows(proposal);assert len(pins)==212
identity=set()
for r in pins:
    p=resolve(NEW,r);raw=p.read_bytes()
    assert len(raw)==r['bytes'] and sha(raw)==r['sha256'],str(p)
    identity.add((str(p.resolve()).lower(),r['bytes'],r['sha256']))
for r in all_rows(old):
    assert (str(resolve(OLD,r).resolve()).lower(),r['bytes'],r['sha256']) in identity
for key in ('outerBudgetSeconds','outerSoftCutoffSeconds','workerBudgetSeconds','commandCapSeconds','commandCleanupReserveSeconds','minimumPostflightReserveSeconds','minimumRamBytes','minimumEachDiskBytes','command','sdkNames'):
    assert proposal[key]==old[key]
for name in ('controller.py','heap1536_windows_job.py'):
    assert (NEW/name).read_bytes()==(OLD/name).read_bytes()
before=ast.parse((OLD/'worker.py').read_text(encoding='utf-8'))
after=ast.parse((NEW/'worker.py').read_text(encoding='utf-8'))
assert len(before.body)==len(after.body)
changes=[]
for a,b in zip(before.body,after.body):
    if ast.dump(a)==ast.dump(b):continue
    if isinstance(a,ast.Assign):
        name=a.targets[0].id;assert name in {'FROZEN','INPUT_SHA256'};changes.append(name)
    else:
        assert isinstance(a,ast.FunctionDef) and a.name==b.name=='source_check'
        transformed=copy.deepcopy(b)
        for n in ast.walk(transformed):
            if isinstance(n,ast.Constant) and n.value==409:n.value=408
            elif isinstance(n,ast.Constant) and isinstance(n.value,str):n.value=n.value.replace('409','408')
        assert ast.dump(a)==ast.dump(transformed);changes.append('source_check')
assert changes==['FROZEN','INPUT_SHA256','source_check']
inputs=load(NEW/'inputs.json');old_inputs=load(OLD/'inputs.json')
assert Path(inputs['cacheManifest']['path']).read_bytes()==Path(old_inputs['cacheManifest']['path']).read_bytes()
assert sha((NEW/'inputs.json').read_bytes())=='1f6f40ba9dd55123bb3a7da37078224dc32c84e7d0694109fd5c21c55a10ff70'
assert not (NEW/'attempt').exists()
value={'status':'ROOT_R7_CONTROLS_STATIC_REVIEW_MATCHED_EXECUTION_UNRUN',
 'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'proposalSha256':sha((NEW/'proposal.json').read_bytes()),
 'sourceCommit':proposal['sourceCommit'],'sourceFiles':409,'pinsMatched':212,'priorR6PinsPreserved':156,
 'controllerNativeByteIdentical':True,'workerAstChanges':changes,'budgetsUnchanged':True,
 'cacheProjectionByteIdentical':True,'sdkCalls':0,'testsRun':False,'attemptCreated':False}
with (NEW/'root-static-review.json').open('x',encoding='utf-8') as stream:json.dump(value,stream,indent=2);stream.write('\n')
print(json.dumps(value))
