"""Read back the actually terminal analysis. No SDK starts, stops or imports."""
from pathlib import Path
import datetime, hashlib, json, os, re, subprocess, sys
import psutil

root = Path(__file__).resolve().parent
repo = root.parents[1]
attempt = root / 'attempt'
load = lambda p: json.loads(p.read_bytes())
sha = lambda raw: hashlib.sha256(raw).hexdigest()
proposal = load(root / 'proposal.json')
result, receipt = load(attempt / 'result.json'), load(attempt / 'receipt.json')
launch = load(attempt / 'launch.json')
assert result['status'] == 'FULL_GUARDIAN_ANALYZE_PASSED'
assert receipt['status'] == 'FULL_GUARDIAN_ANALYZE_WORKER_PASSED'
assert result['workerExitCode'] == 0 and result['ownedJobActiveProcessesFinal'] == 0
assert not result['ownedCleanupPerformed'] and not result['watchdogExpired']
assert result['elapsedCompleteSeconds'] < 180
assert result['elapsedCompleteSeconds'] < launch['workerElapsedAtLaunch'] + launch['commandBudgetSeconds']
assert receipt['sdkCalls'] == 1 and not receipt['forcedTermination']
assert not receipt['testsRun'] and not receipt['pubRun'] and not receipt['downloadsAllowed']
terminal = receipt['commandTerminalStateAfterPostflight']
assert terminal['terminalVerified'] and terminal['rootExitCode'] == 0 and terminal['activeProcesses'] == 0
assert not terminal['terminationRequested'] and not terminal['timedOut']
for name in ('preflight-pins.json', 'postflight-pins.json'):
    phase = load(attempt / name)
    assert phase['complete']
    assert phase['source']['frozenRawGit']['files'] == phase['source']['mainRaw']['files'] == 409
    assert phase['cache']['totals'] == {'files':3536,'bytes':633817159}
    assert phase['cache']['allMembersDirectoriesBytesAndHashesMatch']
    assert phase['packages']['packages'] == 70 and phase['packages']['metadataPreserved']
for row in proposal['candidateFiles'] + proposal['controlRuntimeFiles'] + proposal['historicalMetadataFiles']:
    path = Path(row['path']) if row.get('absolute') else root / row['path']
    raw = path.read_bytes()
    assert len(raw) == row['bytes'] and sha(raw) == row['sha256'], str(path)
inputs = load(root / 'inputs.json')
manifest = load(Path(inputs['sourceManifest']['path']))
for row in manifest['sourceFiles']:
    for base, size, digest in ((repo, row['workingTreeRawBytes'], row['workingTreeRawSha256']),
                              (Path(proposal['sharedSourceSnapshot']), row['bytes'], row['sha256'])):
        raw = (base / row['path']).read_bytes()
        assert len(raw) == size and sha(raw) == digest
cache = load(Path(inputs['cacheManifest']['path']))
files = count_bytes = 0
for tree in cache['trees']:
    base = Path(tree['root'])
    actual_files, actual_dirs = set(), {'.'}
    for directory, dirs, names in os.walk(base):
        path = Path(directory)
        assert not path.is_symlink() and not path.is_junction()
        for d in dirs:
            child = path / d
            assert not child.is_symlink() and not child.is_junction()
            actual_dirs.add(child.relative_to(base).as_posix())
        for n in names:
            child = path / n
            assert not child.is_symlink()
            actual_files.add(child.relative_to(base).as_posix())
    assert actual_files == {r['relativePath'] for r in tree['entries']}
    assert actual_dirs == set(tree['directories'])
    for row in tree['entries']:
        raw = (base / row['relativePath']).read_bytes()
        assert len(raw) == row['bytes'] and sha(raw) == row['sha256']
        files += 1; count_bytes += len(raw)
for row in cache['fixedFiles']:
    raw = Path(row['path']).read_bytes()
    assert len(raw) == row['bytes'] and sha(raw) == row['sha256']
    files += 1; count_bytes += len(raw)
assert files == 3536 and count_bytes == 633817159
log = (attempt / 'out/analyze.log').read_bytes()
assert sha(log) == receipt['logPin']['sha256']
text = log.decode('utf-8')
assert text.count('No issues found!') == 1
assert not re.findall(r'^\s+(info|warning|error) - ',text,re.M)
known = [result['workerPid'], terminal['pid']]
assert not any(psutil.pid_exists(pid) for pid in known)
value = {'status':'ANALYSIS_BYTES_AND_ACTUAL_TERMINAL_INDEPENDENTLY_MATCHED_AWAIT_FRESH_SYSTEM_GATE',
 'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'grant':'guardian-analyze-r7-root-20261023','sourceCommit':proposal['sourceCommit'],
 'actualToolSession':int(sys.argv[1]),'initialToolChunk':sys.argv[2],'finalToolChunk':sys.argv[3],'naturalExitCode':0,
 'outerElapsedSeconds':result['elapsedCompleteSeconds'],'strictCompleteBoundSeconds':launch['workerElapsedAtLaunch'] + launch['commandBudgetSeconds'],
 'sourceFilesIndependentlyRehashedBothTrees':409,'cacheFilesIndependentlyRehashed':files,
 'cacheBytesIndependentlyRehashed':count_bytes,'candidateAndRuntimeMetadataPinsMatched':212,
 'prePostComplete':True,'ownedJobActiveProcesses':0,'knownOwnedPidsAbsent':known,
 'forcedTermination':False,'diagnostics':{'errors':0,'warnings':0,'infos':0},
 'rawLogSha256':sha(log),'testsRun':False,'browserRun':False,'servicesUpdated':False,'wholeProductAccepted':False,
 'systemGateNote':'psutil blank Secure System name is not treated as a zero unknown count; separate fresh full Get-Process inventory required before release.'}
with (attempt / 'external-observation-root.json').open('x',encoding='utf-8') as stream:
    json.dump(value,stream,indent=2);stream.write('\n')
print(json.dumps(value))
