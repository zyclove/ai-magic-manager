from pathlib import Path
import hashlib, importlib.util, json
R = Path(r'D:\codes\mobile\ai-manager')
B = R / '.cache/guardian-null-version-reader-check-20261024-r1'
HELPER = R / '.cache/guardian-vm21-20261024-r2/reporter_contract.py'
LOG = R / '.cache/guardian-vm21-20261024-r1/attempt/out/tests.jsonl'
CONTRACT = R / '.cache/guardian-vm21-20261024-r2/expected-vm21-cases.json'
MODULE = R / '.cache/guardian-current-20261024-r13-headace/src/apps/guardian'
def pin(p):
    raw = p.read_bytes()
    return {'path': str(p), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
assert pin(HELPER)['sha256'] == '83c527e3138e77afe7b7ecfbd5919ab25f6e2ea764bc0ec9db47d23362138ba5'
assert pin(LOG)['sha256'] == '15b449a5f7259c4789ff98d2e52b2c7bf3be90a474c53bd7293a0a110d6c7cce'
assert not B.exists()
B.mkdir()
spec = importlib.util.spec_from_file_location('fixed_guardian_reader_check', HELPER)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)
contract = json.loads(CONTRACT.read_bytes())
accepted = reader.validate_report(LOG, contract, MODULE)
assert accepted['successfulVisibleTests'] == 21 and accepted['skipped'] == 0
lines = LOG.read_bytes().splitlines(keepends=True)
first = json.loads(lines[1])
assert first['runnerVersion'] is None
rows = []
for label, present, value in [('missing', False, None), ('false', True, False), ('zero', True, 0), ('empty', True, ''), ('list', True, []), ('object', True, {})]:
    start = dict(first)
    if present:
        start['runnerVersion'] = value
    else:
        del start['runnerVersion']
    bad = B / (label + '.jsonl')
    with bad.open('xb') as out:
        out.write(lines[0] + (json.dumps(start) + '\n').encode() + b''.join(lines[2:]))
    try:
        reader.validate_report(bad, contract, MODULE)
    except ValueError as error:
        rows.append({'case': label, 'rejected': True, 'reason': str(error), 'input': pin(bad)})
    else:
        raise AssertionError('Malformed start accepted: ' + label)
result = {'status': 'READER_ONLY_REGRESSION_PASSED_NOT_NEW_SDK_OR_ATTEMPT_ACCEPTANCE', 'helper': pin(HELPER), 'originalLog': pin(LOG), 'contract': pin(CONTRACT), 'validNullRawReport': accepted, 'invalidStartsRejected': rows, 'newSdkCalls': 0, 'newApplicationTestsRun': False, 'reporterModuleActuallyImportedAndCalled': True, 'originalR1OverallRedUntouched': True, 'newR2RootPostReleaseStillRequired': True}
with (B / 'result.json').open('x', encoding='utf-8', newline='\n') as out:
    json.dump(result, out, ensure_ascii=False, indent=2)
    out.write('\n')
print(json.dumps({'status': result['status'], 'originalVisibleSuccesses': 21, 'invalidStartsRejected': len(rows), 'result': pin(B / 'result.json')}))
