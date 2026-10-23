"""Read actual terminal evidence; never execute SDK code or change acceptance."""
from pathlib import Path
import collections
import datetime
import hashlib
import json
import os
import subprocess
import psutil

root = Path(__file__).resolve().parent
repo = root.parents[1]
attempt = root / 'attempt'
read = lambda p: json.loads(p.read_bytes())
proposal = read(root / 'proposal.json')
result = read(attempt / 'result.json')
receipt = read(attempt / 'receipt.json')
assert result['status'] == receipt['status'] == 'NOT_ACCEPTED'
assert result['workerExitCode'] == 1 and result['ownedJobActiveProcessesFinal'] == 0
assert not result['ownedCleanupPerformed'] and not result['watchdogExpired']
assert result['elapsedCompleteSeconds'] < 510
terminal = receipt['commandTerminalStateAfterPostflight']
assert terminal['terminalVerified'] and terminal['rootExitCode'] == 0 and terminal['activeProcesses'] == 0
assert terminal['timedOut'] and terminal['terminationRequested'] and receipt['forcedTermination']
rows = proposal['candidateFiles'] + proposal['controlRuntimeFiles'] + proposal['historicalMetadataFiles']
def pin(path, row):
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    assert path.stat().st_size == row['bytes'] and digest == row['sha256'], str(path)
for row in rows:
    pin(Path(row['path']) if row.get('absolute') else root / row['path'], row)
assert len(rows) == 136
for name in ('preflight-pins.json', 'postflight-pins.json'):
    phase = read(attempt / name)
    assert phase['complete']
    assert phase['source']['frozenRawGit']['files'] == phase['source']['mainRaw']['files'] == 406
    assert phase['cache']['totals'] == {'files': 3537, 'bytes': 638537951}
manifest = read(root / 'out/source-manifest.json')
assert len(manifest['sourceFiles']) == 406
for base in (repo, root / 'src'):
    for row in manifest['sourceFiles']:
        expected = row if base != repo else {'bytes': row['workingTreeRawBytes'], 'sha256': row['workingTreeRawSha256']}
        pin(base / row['path'], expected)
git = lambda *args: subprocess.check_output(['git', *args], cwd=repo).decode().strip()
for path, tree in proposal['sevenRootGitTrees'].items():
    assert git('rev-parse', 'HEAD:' + path) == tree
cache = read(root / 'cache-content-chrome-refreshed.json')
for tree in cache['trees']:
    base = Path(tree['root'])
    actual_files, actual_dirs = set(), set()
    for directory, dirs, files in os.walk(base):
        dp = Path(directory)
        assert not dp.is_symlink() and not dp.is_junction()
        actual_dirs.add(dp.relative_to(base).as_posix())
        for name in files:
            p = dp / name
            assert not p.is_symlink() and not p.is_junction()
            actual_files.add(p.relative_to(base).as_posix())
    assert actual_files == {r['relativePath'] for r in tree['entries']}
    assert actual_dirs == set(tree['directories'])
    for row in tree['entries']:
        pin(base / row['relativePath'], row)
for row in cache['fixedFiles']:
    pin(Path(row['path']), row)
log = (attempt / 'out/browser38.jsonl').read_bytes()
assert hashlib.sha256(log).hexdigest() == receipt['logPin']['sha256']
lines = log.decode('utf-8').splitlines()
assert [v for v in lines if not v.startswith('{')] == ['Flutter assets will be downloaded from http://127.0.0.1:9. Make sure you trust this source!']
events = [json.loads(v) for v in lines if v.startswith('{')]
tests = {e['test']['id']: e['test'] for e in events if e['type'] == 'testStart'}
suites = {e['suite']['id']: e['suite'] for e in events if e['type'] == 'suite'}
done = [e for e in events if e['type'] == 'testDone' and not e['hidden']]
assert len(done) == 38 and all(e['result'] == 'success' and not e['skipped'] for e in done)
assert not [e for e in events if e['type'] == 'error']
assert [e['success'] for e in events if e['type'] == 'done'] == [True]
contract = read(root / 'expected-cases.json')
module = root / 'src/apps/guardian'
actual = collections.Counter((Path(suites[tests[e['testID']]['suiteID']]['path']).relative_to(module).as_posix(), tests[e['testID']]['name']) for e in done)
assert actual == collections.Counter((r['selector'], r['name']) for r in contract['cases'])
assert len(suites) == 4
tree_observation = read(attempt / 'root-owned-tree-observation.json')
assert not tree_observation['problems'] and not tree_observation['lastLiveIdentities']
for row in tree_observation['observedIdentities']:
    try:
        current = psutil.Process(row['pid'])
        assert abs(current.create_time() - row['created']) > 0.001, row
    except psutil.NoSuchProcess:
        pass
processes = list(psutil.process_iter(['pid', 'name'], ad_value=None))
sdk = [p.info for p in processes if (p.info['name'] or '').lower() in set(proposal['sdkNames'])]
unknown = [p.pid for p in processes if p.info['name'] is None and p.pid not in (0, 4)]
assert not sdk and not unknown and not psutil.pid_exists(result['workerPid'])
value = {
    'status': 'BROWSER38_CASES_PASSED_COMMAND_TREE_TIMEOUT_NOT_ACCEPTED',
    'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'grant': 'guardian-browser38-r1-root-20261023',
    'actualToolSession': 21954, 'initialChunk': 'aa8215', 'finalChunk': 'c0295c',
    'actualNaturalOuterExitCode': 1, 'outerElapsedSeconds': result['elapsedCompleteSeconds'],
    'originalStatusPreserved': 'NOT_ACCEPTED', 'nativeRootExitCode': 0,
    'visibleCases': 38, 'success': 38, 'errors': 0, 'skips': 0,
    'exactNamesAndFourSuiteMembershipMatched': True, 'reporterDoneSuccess': True,
    'forcedCommandTreeCleanup': True, 'allOwnedJobActiveCountsFinal': 0,
    'strictWholeRunAccepted': False, 'wholeUiAccepted': False,
    'sourceFilesIndependentlyRehashedMainAndFrozen': 406,
    'cacheFilesIndependentlyRehashed': 3537, 'cacheMembershipExact': True,
    'metadataPinsRehashed': len(rows), 'currentSevenRootGitTreesMatched': True,
    'originalPreAndPostComplete': True,
    'ownedAncestryObserver': {'actualSession': 9369, 'finalChunk': 'a76699',
        'naturalExitCode': 0, 'observedIdentityCount': len(tree_observation['observedIdentities']),
        'sameIdentitiesAbsent': True, 'independentJobMembershipClaimed': False},
    'sdkProcesses': sdk, 'unknownProcessNames': unknown,
    'availableRamBytes': psutil.virtual_memory().available,
    'pubRun': False, 'downloadsAllowed': False, 'servicesUpdated': False,
    'automaticRetry': False
}
with (attempt / 'external-observation-root.json').open('x', encoding='utf-8', newline='\n') as stream:
    json.dump(value, stream, ensure_ascii=False, indent=2); stream.write('\n')
print(json.dumps(value))
