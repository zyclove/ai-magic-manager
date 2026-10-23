"""Observe this already terminal analysis; never starts or stops any SDK."""
from pathlib import Path
import datetime
import hashlib
import json
import re
import sys
import psutil

root = Path(__file__).absolute().parent
attempt = root / 'attempt'
proposal = json.loads((root / 'proposal.json').read_bytes())
result = json.loads((attempt / 'result.json').read_bytes())
receipt = json.loads((attempt / 'receipt.json').read_bytes())
pre = json.loads((attempt / 'preflight-pins.json').read_bytes())
post = json.loads((attempt / 'postflight-pins.json').read_bytes())
assert result['status'] == 'FULL_GUARDIAN_ANALYZE_PASSED'
assert receipt['status'] == 'FULL_GUARDIAN_ANALYZE_WORKER_PASSED'
assert result['workerExitCode'] == 0 and result['ownedJobActiveProcessesFinal'] == 0
assert not result['ownedCleanupPerformed'] and not result['watchdogExpired']
assert result['elapsedCompleteSeconds'] < 180 and receipt['sdkCalls'] == 1
launch = json.loads((attempt / 'launch.json').read_bytes())
assert result['elapsedCompleteSeconds'] < launch['workerElapsedAtLaunch'] + launch['commandBudgetSeconds']
terminal = receipt['commandTerminalStateAfterPostflight']
assert terminal['terminalVerified'] and terminal['rootExitCode'] == 0 and terminal['activeProcesses'] == 0
assert not terminal['terminationRequested'] and not terminal['timedOut'] and not receipt['forcedTermination']
assert pre['complete'] and post['complete']
for phase in (pre, post):
    assert phase['source']['frozenRawGit']['files'] == phase['source']['mainRaw']['files'] == 407
    assert phase['cache']['totals'] == {'files': 3536, 'bytes': 633817159}
    assert phase['cache']['trees'] == 70 and phase['cache']['fixedFiles'] == 32
rows = proposal['candidateFiles'] + proposal['controlRuntimeFiles'] + proposal['historicalMetadataFiles']
for row in rows:
    path = Path(row['path']) if row.get('absolute') else root / row['path']
    raw = path.read_bytes()
    assert len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256']
log = (attempt / 'out/analyze.log').read_bytes()
log_sha = hashlib.sha256(log).hexdigest()
assert log_sha == receipt['logPin']['sha256']
text = log.decode('utf-8')
assert text.count('No issues found!') == 1
assert not re.findall(r'^\s+(info|warning|error) - (.*)$', text, re.M)
sdk_names = set(proposal['sdkNames'])
processes = list(psutil.process_iter(['pid', 'name'], ad_value=None))
sdk = [p.info for p in processes if (p.info['name'] or '').lower() in sdk_names]
unknown = [p.pid for p in processes if p.info['name'] is None and p.pid not in (0, 4)]
assert not sdk and not unknown
known = [result['workerPid'], terminal['pid']]
assert not any(psutil.pid_exists(pid) for pid in known)
value = {
    'status': 'FULL_GUARDIAN_ANALYZE_EXTERNALLY_ACCEPTED',
    'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'grant': 'guardian-analyze-r5-root-20261023',
    'actualToolSession': 76515, 'initialToolChunk': '4ab17c', 'finalToolChunk': sys.argv[1],
    'actualNaturalExitCode': 0, 'outerElapsedSeconds': result['elapsedCompleteSeconds'],
    'ownedJobActiveProcesses': 0, 'knownOwnedPidsAbsent': known,
    'sdkProcesses': sdk, 'unknownProcessNames': unknown,
    'availableRamBytes': psutil.virtual_memory().available,
    'fullAnalysisAccepted': True,
    'strictCompleteOuterBeforeCommandDeadline': True,
    'scope': '1ca1f7f seven-root 407-file snapshot, entire Guardian lib/test analysis; no test execution',
    'diagnostics': {'errors': 0, 'warnings': 0, 'infos': 0},
    'candidateAndRuntimeMetadataPinsMatched': len(rows),
    'preAndPost': {'complete': True, 'sourceFiles': 407, 'cacheFiles': 3536,
                   'cacheBytes': 633817159, 'packageRows': 70},
    'analysisCacheProjection': 'Unchanged historical parent minus only Chrome unused by analyze; browser phase needs its own current browser pin.',
    'rawLogSha256': log_sha, 'forcedTermination': False, 'pubRun': False,
    'downloadsAllowed': False, 'testsRun': False, 'browserRun': False,
    'mainOrFrozenSourceChangedByRunner': False, 'servicesUpdated': False,
    'wholeProductAccepted': False
}
with (attempt / 'external-observation-root.json').open('x', encoding='utf-8', newline='\n') as stream:
    json.dump(value, stream, ensure_ascii=False, indent=2); stream.write('\n')
print(json.dumps(value))
