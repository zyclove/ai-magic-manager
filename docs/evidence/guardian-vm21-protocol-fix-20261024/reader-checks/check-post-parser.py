from pathlib import Path
import hashlib, importlib.util, json
R = Path(r'D:\codes\mobile\ai-manager')
B = R / '.cache/guardian-null-version-post-reader-check-20261024-r1'
P = R / '.cache/guardian-vm21-post-20261024-r2/post.py'
L = R / '.cache/guardian-vm21-20261024-r1/attempt/out/tests.jsonl'
M = R / '.cache/guardian-current-20261024-r13-headace/src/apps/guardian'
def pin(p):
    raw = p.read_bytes()
    return {'path': str(p), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
assert pin(P)['sha256'] == '1e23da30c25311470366e27dc9c78cd3e21c5723c85d3b1e9889e4c18c6542ce'
assert not B.exists()
spec = importlib.util.spec_from_file_location('guardian_fixed_post_parser_check', P)
post = importlib.util.module_from_spec(spec)
spec.loader.exec_module(post)
contract = json.loads((R / '.cache/guardian-vm21-20261024-r2/expected-vm21-cases.json').read_bytes())
actual = post.independent_vm21(L.read_bytes(), contract, M, pin(L))
prior = json.loads((R / '.cache/guardian-null-version-reader-check-20261024-r1/result.json').read_bytes())
canonical = lambda v: json.dumps(v, sort_keys=True, separators=(',', ':'), allow_nan=False)
assert canonical(actual) == canonical(prior['validNullRawReport'])
rows = []
for bad in prior['invalidStartsRejected']:
    p = Path(bad['input']['path'])
    assert pin(p) == bad['input']
    try:
        post.independent_vm21(p.read_bytes(), contract, M, pin(p))
    except ValueError as error:
        rows.append({'case': bad['case'], 'rejected': True, 'reason': str(error)})
    else:
        raise AssertionError('Malformed start accepted by independent parser')
B.mkdir()
result = {'status': 'INDEPENDENT_FILE_PARSER_REGRESSION_PASSED_NOT_ROOT_POST_ACCEPTANCE', 'postCode': pin(P), 'originalLog': pin(L), 'visibleSuccesses': 21, 'sameTypedReportAsFixedHelper': True, 'invalidStartsRejected': rows, 'pureParserActuallyImportedAndCalled': True, 'postMainEntryInvoked': False, 'newSdkCalls': 0, 'r1OverallRedUnchanged': True, 'r2ActualRootPostReleaseStillRequired': True}
with (B / 'result.json').open('x', encoding='utf-8', newline='\n') as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(json.dumps({'status': result['status'], 'invalidStartsRejected': len(rows), 'result': pin(B/'result.json')}))
