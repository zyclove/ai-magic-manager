"""Independent metadata/source review only; never imports the candidate or starts an SDK."""
from pathlib import Path
import ast
import datetime
import hashlib
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
FROZEN = ROOT / '.cache/guardian-current-20261023-r3'
EXPECTED_PROPOSAL = '06b3c62694c4ff6abd87ea7ad37b3c13d1aba5b771ed9ffb1034783ed636593e'

def digest(raw): return hashlib.sha256(raw).hexdigest()
def read(path): return path.read_bytes()
def verify(row, base=HERE):
    path = Path(row['path']) if row.get('absolute') or Path(row['path']).is_absolute() else base / row['path']
    raw = read(path)
    assert len(raw) == row['bytes'] and digest(raw) == row['sha256'], str(path)
    return raw

proposal_raw = read(HERE / 'proposal.json')
assert digest(proposal_raw) == EXPECTED_PROPOSAL
proposal = json.loads(proposal_raw)
rows = proposal['candidateFiles'] + proposal['controlRuntimeFiles'] + proposal['historicalMetadataFiles']
for row in rows: verify(row)
assert len(rows) == 27
assert not (HERE / 'attempt').exists()
for name in ('controller.py', 'worker.py', 'heap1536_windows_job.py'):
    ast.parse(read(HERE / name).decode('utf-8'), filename=name)
    if name != 'worker.py':
        assert read(HERE / name) == read(ROOT / '.cache/guardian-analyze-20261021-r1' / name)
inputs = json.loads(verify(proposal['analysisInputs']))
manifest = json.loads(verify(inputs['sourceManifest']))
assert inputs['sourceCommit'] == proposal['sourceCommit'] == '080e41c66a348d48d8ac313cde77e4dd8f36cc47'
assert manifest['sourceCount'] == len(manifest['sourceFiles']) == 405
roots = proposal['sourceRoots']
expected = {row['path'] for row in manifest['sourceFiles']}
assert len(expected) == 405
excluded_dirs = set(inputs['generatedExclusions']['directories'])
excluded_files = set(inputs['generatedExclusions']['files'])
for base in (ROOT, FROZEN / 'src'):
    actual = set()
    for root in roots:
        for directory, folders, names in os.walk(base / root, followlinks=False):
            folders[:] = [name for name in folders if name not in excluded_dirs]
            for name in names:
                if name not in excluded_files:
                    path = Path(directory) / name
                    assert not path.is_symlink() and not path.is_junction()
                    actual.add(path.relative_to(base).as_posix())
    assert actual == expected
for row in manifest['sourceFiles']:
    main = read(ROOT / row['path'])
    frozen = read(FROZEN / 'src' / row['path'])
    assert digest(main) == row['workingTreeRawSha256']
    assert digest(frozen) == row['sha256'] and len(frozen) == row['bytes']
    assert main.replace(b'\r\n', b'\n') == frozen.replace(b'\r\n', b'\n')
env = os.environ.copy()
env.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL')
trees = subprocess.check_output([inputs['gitExecutable'], '-c', 'safe.directory=' + ROOT.as_posix(),
    'rev-parse', *['HEAD:' + root for root in roots]], cwd=ROOT, env=env).decode().splitlines()
assert dict(zip(roots, trees)) == inputs['sevenRootGitTrees'] == proposal['sevenRootGitTrees']
parent = json.loads(verify(inputs['cacheProjectionParentManifest']))
cache = json.loads(verify(inputs['cacheManifest']))
assert cache['trees'] == parent['trees'] and len(cache['trees']) == 70
excluded = cache['excludedFixedFiles']
assert len(excluded) == 1 and excluded[0]['path'].replace('\\', '/').lower().endswith('/google/chrome/application/chrome.exe')
assert cache['fixedFiles'] == [row for row in parent['fixedFiles'] if row not in excluded]
assert len(cache['fixedFiles']) == 32 and cache['totals']['files'] == 3536
assert cache['totals']['bytes'] == parent['totals']['bytes'] - excluded[0]['bytes']
assert cache['parentManifest'] == inputs['cacheProjectionParentManifest']
original = json.loads(verify(inputs['originalPackageConfig']))
candidate = json.loads(verify(inputs['candidatePackageConfig']))
internal = inputs['internalPackageRoots']
assert len(original['packages']) == len(candidate['packages']) == 70 and len(internal) == 7
for old, new in zip(original['packages'], candidate['packages']):
    expected_row = dict(old)
    if old['name'] in internal:
        expected_row['rootUri'] = (FROZEN / 'src' / internal[old['name']]).as_uri()
    assert new == expected_row
assert proposal['command'][-1].endswith('analyze --no-pub --fatal-infos --fatal-warnings')
assert proposal['noSelectors'] and proposal['outerBudgetSeconds'] == 210
assert proposal['commandCapSeconds'] == 180 and proposal['minimumPostflightReserveSeconds'] == 25
receipt = {'status': 'ROOT_STATIC_REVIEWED_NOT_RUNTIME_ACCEPTANCE',
    'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'proposalSha256': EXPECTED_PROPOSAL, 'pinnedMetadataAndControls': len(rows),
    'sourceFiles': 405, 'mainAndFrozenMembershipAndHashesMatched': True,
    'sevenGitTreesMatched': True, 'packageRows': 70, 'internalRemappedRows': 7,
    'analysisCacheProjection': {'trees': 70, 'fixedFiles': 32, 'files': 3536,
                               'onlyUnusedChromeExcluded': True, 'remainingParentRowsExact': True},
    'cacheContentsNotRehashedByThisStaticReview': True,
    'controllerAndNativeHelperByteIdenticalToActuallyRunR1': True,
    'workerMechanicalDiffReadByRoot': True, 'astParsedWithoutImport': True,
    'sdkStarted': False, 'runtimeAttemptExists': False, 'analysisPassed': False}
with (HERE / 'root-static-review.json').open('x', encoding='utf-8', newline='\n') as stream:
    json.dump(receipt, stream, indent=2); stream.write('\n')
print(json.dumps(receipt))
