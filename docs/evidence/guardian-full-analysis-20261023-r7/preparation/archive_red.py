"""Plan exact r7 RED metadata archival; only explicit post-release mode writes docs."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import ntpath
import os
import re
import stat
import sys

BASE = Path(__file__).absolute().parent
REPO = BASE.parents[1]
RUN = REPO / '.cache/guardian-analyze-20261023-r7'
SNAP = REPO / '.cache/guardian-observation-current-20261023-r1'
OUT = REPO / 'docs/evidence/guardian-full-analysis-20261023-r7'
STAGE = BASE / 'stage-pins.json'
PROPOSAL_SHA = '2c1c4e32c0255b3a3eaa4272058ef5eb5f2e5388e5eb58b45d5a1ceb6d37ef36'

def sha(value):
    return hashlib.sha256(value).hexdigest()

def raw(path):
    path = Path(path)
    for parent in (path, *path.parents):
        if os.path.lexists(parent):
            info = parent.lstat()
            assert not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400, str(parent)
    before = path.stat()
    value = path.read_bytes()
    after = path.stat()
    assert (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    return value

def load(path):
    return json.loads(raw(path))

def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')

def pinned(path, descriptor):
    value = raw(path)
    assert len(value) == descriptor['bytes'] and sha(value) == descriptor['sha256'], str(path)
    return value

def norm(path):
    return ntpath.normcase(ntpath.normpath(str(path)))

def created(path, value):
    assert path.is_relative_to(BASE) or path.is_relative_to(OUT), str(path)
    for parent in path.parents:
        if os.path.lexists(parent):
            info = parent.lstat()
            assert not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400, str(parent)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())
    assert raw(path) == value

assert sys.argv[1:] == ['--plan'] or (
    len(sys.argv) == 5 and sys.argv[1] == '--write-after-root-release'
    and re.fullmatch('[0-9a-f]{64}', sys.argv[2])
    and re.fullmatch('[0-9a-f]{64}', sys.argv[3])
    and re.fullmatch('[0-9a-f]{40}', sys.argv[4]))
writing = sys.argv[1] == '--write-after-root-release'
assert not OUT.exists(), 'A durable archive is never overwritten'
proposal = load(RUN / 'proposal.json')
assert sha(raw(RUN / 'proposal.json')) == PROPOSAL_SHA
assert proposal['sourceCommit'] == 'a55849d902b248fe02d06e23cd0bad3d28912a27'
candidate_rows = proposal['candidateFiles']
control_rows = proposal['controlRuntimeFiles']
history_rows = proposal['historicalMetadataFiles']
assert len(candidate_rows) + len(control_rows) + len(history_rows) == 212
result = load(RUN / 'attempt/result.json')
receipt = load(RUN / 'attempt/receipt.json')
launch = load(RUN / 'attempt/launch.json')
assert result['status'] == receipt['status'] == 'NOT_ACCEPTED'
assert result['workerExitCode'] == 1 and result['workerPid'] == 62388
assert result['ownedJobActiveProcessesFinal'] == result['ownedJobActiveProcesses'] == 0
assert not result['ownedCleanupPerformed'] and not result['watchdogExpired']
assert result['postCandidateAndControlRuntimeMismatches'] == []
assert receipt['commandTerminalState']['pid'] == 3724
for terminal in (receipt['commandTerminalState'], receipt['commandTerminalStateAfterPostflight']):
    assert terminal['rootExitCode'] == 1 and terminal['rootHandleSignaled']
    assert terminal['terminalVerified'] and terminal['activeProcesses'] == 0
    assert not terminal['timedOut'] and not terminal['terminationRequested']
assert not receipt['forcedTermination'] and not receipt['testsRun'] and not receipt['noIssuesFound']
assert receipt['postflight']['complete']
assert receipt['postflight']['source']['frozenRawGit']['files'] == receipt['postflight']['source']['mainRaw']['files'] == 409
assert receipt['postflight']['packages']['packages'] == 70
assert receipt['postflight']['cache']['totals'] == {'files': 3536, 'bytes': 633817159}
strict_bound = launch['workerElapsedAtLaunch'] + launch['commandBudgetSeconds']
assert result['elapsedCompleteSeconds'] < strict_bound < 180
log = pinned(RUN / 'attempt/out/analyze.log', receipt['logPin'])
text = log.decode('utf-8-sig')
diagnostics = re.findall(r'^\s*(error|warning|info)\s+-\s+(.+?)\s+-\s+(.+?):(\d+):(\d+)\s+-\s+(\S+)\s*$', text, re.M)
assert len(diagnostics) == 1, diagnostics
assert diagnostics[0] == ('warning', "The '!' will have no effect because the receiver can't be null", 'lib\\pages\\observation_page.dart', '31', '52', 'unnecessary_non_null_assertion')
assert '1 issue found.' in text and 'No issues found!' not in text

external = gate = None
if writing:
    assert sha(raw(RUN / 'attempt/external-red-readback-root.json')) == sys.argv[2]
    assert sha(raw(RUN / 'attempt/root-final-system-gate.json')) == sys.argv[3]
    external = load(RUN / 'attempt/external-red-readback-root.json')
    gate = load(RUN / 'attempt/root-final-system-gate.json')
    assert gate['formalRelease'] and gate['sdkCount'] == gate['unknownProcessNameCount'] == 0
    assert gate['ownedJobActiveProcesses'] == 0
    assert gate['actualSession'] == external['actualSession'] == 1854
    assert gate['naturalExitCode'] == external['naturalExitCode'] == 1
    assert gate['actualFinalChunk'] == external['finalChunk'] == 'dff5b1'
    assert gate['status'] == 'R7_ANALYSIS_RED_WINDOW_FORMALLY_RELEASED'
    assert external['status'] == 'R7_ANALYSIS_RED_INDEPENDENTLY_CONFIRMED_AWAIT_FRESH_SYSTEM_RELEASE'
    assert external['pinsMatched'] == 212
    assert external['sourceFilesRehashedBothTrees'] == 409
    assert external['cacheFilesRehashed'] == 3536
    assert external['cacheBytesRehashed'] == 633817159
    assert external['diagnostics'] == {'errors': 0, 'warnings': 1, 'infos': 0}
    assert not external['forcedTermination'] and external['analysisAccepted'] is False
    assert external['outerElapsedSeconds'] == result['elapsedCompleteSeconds']
    assert external['strictCompleteDeadlineSeconds'] == strict_bound
    assert gate.get('analysisAccepted', False) is False
    assert gate.get('wholeProductAccepted', False) is False

# Runtime classification is derived from the real proposal, not a guessed count.
controls_by_path = {}
for row in control_rows:
    canonical = norm(row['path'])
    assert canonical not in controls_by_path
    controls_by_path[canonical] = row
    pinned(Path(row['path']), row)
runtime_history = []
metadata_history = []
for index, row in enumerate(history_rows):
    path = Path(row['path']) if row.get('absolute') else RUN / row['path']
    if norm(path) in controls_by_path:
        expected = controls_by_path[norm(path)]
        assert (row['bytes'], row['sha256']) == (expected['bytes'], expected['sha256'])
        runtime_history.append({'historicalIndex': index, **row,
            'evidenceKind': 'PIN_DESCRIPTOR_ONLY_NO_RUNTIME_CONTENT_COPY'})
    else:
        pinned(path, row)
        metadata_history.append((index, row, path))

copies = {}
originals = {}
def add(source, target, descriptor=None):
    source = Path(source)
    assert source.is_relative_to(REPO), str(source)
    assert 'src' not in source.relative_to(REPO).parts or source.name == 'package_config.json', str(source)
    value = pinned(source, descriptor) if descriptor else raw(source)
    assert len(value) < 2 * 1024**2
    canonical = norm(source)
    if canonical in originals:
        return OUT / originals[canonical]
    assert target not in copies and '..' not in Path(target).parts
    copies[target] = (value, str(source))
    originals[canonical] = target
    return OUT / target

for row in candidate_rows:
    add(RUN / row['path'], 'candidate/' + row['path'], row)
for name in ('proposal.json', 'inputs.json', 'seal-receipt.json'):
    add(RUN / name, 'candidate/' + name)
observer = RUN / 'external_observe_root.py'
assert not (RUN / 'attempt/external-observation-root.json').exists(), 'Unused PASS observer must not gain a fictitious output'
if observer.is_file():
    add(observer, 'candidate/external_observe_root.py')
add(RUN / 'root-static-review.json', 'reviews/root-static-review.json')
add(REPO / '.cache/guardian-analyze-r7-root-static-review-20261023.py',
    'reviews/root-static-review.py')
add(REPO / '.cache/guardian-analyze-r7-red-readback-root-20261023.py',
    'reviews/root-actual-red-readback.py')
for name in ('review.md', 'r7-review.json', 'source-review.json'):
    add(REPO / '.cache/guardian-observation409-r7-independent-20261023-r1' / name,
        'reviews/independent-' + name)
for path in sorted((RUN / 'attempt').rglob('*')):
    relative = path.relative_to(RUN / 'attempt')
    if path.is_file() and 'tmp' not in relative.parts:
        add(path, 'attempt/' + relative.as_posix())
add(Path(__file__), 'preparation/archive_red.py')
fix_receipt_path = REPO / '.cache/guardian-observation-lint-fix-20261023/receipt.json'
fix_receipt = load(fix_receipt_path)
assert fix_receipt['status'] == 'ONE_REDUNDANT_ASSERTION_REMOVED_RUNTIME_RECHECK_PENDING'
assert fix_receipt['sourceParent'] == proposal['sourceCommit']
assert fix_receipt['analysisRecheck'] == 'UNRUN' and not fix_receipt['testsRun']
assert fix_receipt['path'] == 'apps/guardian/lib/pages/observation_page.dart'
fix_after = pinned(REPO / fix_receipt['path'], fix_receipt['after'])
assert fix_receipt['after']['bytes'] == 11503
assert fix_receipt['after']['sha256'] == 'ac0e30966f2a5c5f6b65dc12a8445a3ae7d52d8cda45cbb979b0b58a18e83816'
fix_before = raw(SNAP / 'src' / fix_receipt['path'])
assert len(fix_before) == fix_receipt['before']['bytes'] and sha(fix_before) == fix_receipt['before']['sha256']
before_expression = b'observationRoute == null || observationRoute!.available'
after_expression = b'observationRoute == null || observationRoute.available'
assert fix_before.count(before_expression) == 1
assert fix_before.replace(before_expression, after_expression) == fix_after
add(fix_receipt_path, 'fix/root-one-character-fix-receipt.json')
add(REPO / '.cache/guardian-observation-nonnull-static-20261023-r1/review.md',
    'fix/independent-static-review.md')
add(REPO / '.cache/guardian-observation-nonnull-static-20261023-r1/review.json',
    'fix/independent-static-review.json')
add(SNAP / 'out/seal-static-source.json', 'inputs/source-snapshot-seal.json')
snapshot_seal = load(SNAP / 'out/seal-static-source.json')
for row in snapshot_seal['files']:
    if not row['path'].startswith('src/'):
        add(SNAP / row['path'], 'inputs/source-snapshot/' + row['path'], row)
inputs = load(RUN / 'inputs.json')
for key in ('sourceManifest', 'dependencyLibraryPins', 'cacheManifest',
            'originalPackageConfig', 'candidatePackageConfig', 'candidatePackageConfigTemplate'):
    row = inputs[key]
    add(Path(row['path']), 'inputs/' + key + '.json', row)

# Previously committed metadata can serve exact raw-byte references.
existing = []
for name in ('guardian-full-analysis-20261023-r6', 'guardian-full-analysis-20261023-r5',
             'guardian-full-analysis-20261023-r4', 'guardian-full-analysis-20261023-r3',
             'guardian-baseline-analysis-20261021', 'guardian-browser38-20261023-r1'):
    root = REPO / 'docs/evidence' / name
    inventory = load(root / 'archive-inventory.json')
    for row in inventory['files']:
        existing.append((root / row['archivePath'], row))
    for row in inventory.get('durableHistoricalMetadataPins', []):
        existing.append((REPO / row['durableArchivePath'], row))
durable = []
for index, row, source in metadata_history:
    if norm(source) in originals:
        target = OUT / originals[norm(source)]
    else:
        target = next((path for path, old in existing
            if old['bytes'] == row['bytes'] and old['sha256'] == row['sha256']), None)
        if target is not None:
            pinned(target, row)
        else:
            target = add(source, f'historical/{index:03d}-' + source.name, row)
    durable.append({'historicalIndex': index, 'originalPath': str(source),
        'durableArchivePath': target.relative_to(REPO).as_posix(),
        'bytes': row['bytes'], 'sha256': row['sha256']})
assert len(durable) + len(runtime_history) == len(history_rows)

runtime_unique = {norm(row['path']) for row in runtime_history}
facts = {
    'status': 'FULL_GUARDIAN_ANALYSIS_RED_NOT_ACCEPTED_BROWSER80_UNRUN',
    'analysisAccepted': False, 'sourceCommit': proposal['sourceCommit'], 'sourceFiles': 409,
    'scope': 'Entire Guardian lib/test fatal-infos/fatal-warnings analysis; no application tests',
    'actualSession': 1854, 'initialChunk': '804cf2', 'finalChunk': 'dff5b1', 'naturalExitCode': 1,
    'workerPid': 62388, 'nativeCommandPid': 3724,
    'outerElapsedSeconds': result['elapsedCompleteSeconds'], 'strictCompleteBoundSeconds': strict_bound,
    'diagnostics': {'errors': 0, 'warnings': 1, 'infos': 0},
    'onlyDiagnostic': {'severity': 'warning', 'file': diagnostics[0][2], 'line': 31, 'column': 52,
        'code': 'unnecessary_non_null_assertion', 'message': diagnostics[0][1]},
    'fullSourcePrePost': 409, 'packageRows': 70, 'cacheFiles': 3536, 'cacheBytes': 633817159,
    'candidateAndRuntimeMetadataPins': 212, 'historicalDescriptors': len(history_rows),
    'historicalMetadataDurableReferences': len(durable),
    'historicalRuntimeDescriptorOccurrences': len(runtime_history),
    'historicalRuntimeUniqueFiles': len(runtime_unique),
    'directControlRuntimeDescriptors': len(control_rows),
    'allRuntimeDescriptorOccurrencesAcrossBothLists': len(control_rows) + len(runtime_history),
    'allRuntimeUniqueFilesAcrossBothLists': len(set(controls_by_path) | runtime_unique),
    'browserCasesPrepared': 80, 'physicalSuitesPrepared': 7, 'browserCasesExecuted': 0,
    'testsRun': False, 'servicesUpdated': False, 'wholeProductAccepted': False,
    'forcedTermination': False, 'timedOut': False, 'ownedJobActiveProcesses': 0,
    'rawLogSha256': sha(log), 'rawLogBytes': len(log),
    'preparationRecordsPreservedVerbatimAsUnrun': True,
    'staticReviewDidNotPredictLintAndWasNotAnSdkRun': True,
    'preparedPassObserver': {'path': 'candidate/external_observe_root.py',
        'status': 'UNUSED_PREPARED_EXPECTED_PASS_HELPER_NEVER_INVOKED',
        'outputExternalObservationRootJsonExists': False},
    'actualIndependentRedReadbackScript': 'reviews/root-actual-red-readback.py',
    'currentMainRevalidatedAgainstRedSnapshotDuringArchival': False,
    'currentMainFixOnlyNewAfterPinVerified': fix_receipt['after'],
    'singleCharacterFixRuntimeRecheck': 'UNRUN',
    'singleCharacterFixTestsRun': False,
    'independentReadbackAndFormalReleaseRequiredBeforeDocsWrite': True,
    'formalReleaseObservedForThisArchive': writing,
}
if writing:
    facts.update(externalObserverStatus=external['status'], formalSystemGateStatus=gate['status'],
        sdkCountAtRelease=gate['sdkCount'], unknownProcessNamesAtRelease=gate['unknownProcessNameCount'],
        externalObserverSha256=sys.argv[2], formalSystemGateSha256=sys.argv[3],
        actualIndependentRedReadbackChunk=gate['readbackChunk'])
preview = {
    'status': 'CACHE_PLAN_ONLY_DO_NOT_TREAT_AS_DURABLE_ARCHIVE',
    'createdUtc': datetime.now(timezone.utc).isoformat(), 'proposedArchive': str(OUT),
    'facts': facts, 'plannedCopiesBeforeGeneratedSummaryReadme': [
        {'archivePath': target, 'bytes': len(value), 'sha256': sha(value), 'originalPath': original}
        for target, (value, original) in sorted(copies.items())],
    'durableHistoricalMetadataPins': durable, 'runtimePinDescriptorsOnly': runtime_history,
    'directControlRuntimeDescriptorsOnly': control_rows,
    'noRuntimeCacheOrApplicationSourceContentsCopied': True,
    'pendingUntilRootNotification': ['independent actual terminal/source/cache readback',
        'fresh complete system release gate', 'explicit instruction to generate docs'],
}
if not writing:
    target = BASE / 'plan-preview.json'
    created(target, encode(preview))
    print(json.dumps({'status': preview['status'], 'path': str(target), 'bytes': target.stat().st_size,
        'sha256': sha(raw(target)), 'historical': len(history_rows), 'metadataDurable': len(durable),
        'runtimeHistoricalOccurrences': len(runtime_history), 'runtimeHistoricalUniqueFiles': len(runtime_unique),
        'runtimeDirectControlDescriptors': len(control_rows), 'docsWritten': False,
        'candidateFunctionsImportedOrCalled': False}, ensure_ascii=False))
    raise SystemExit(0)

copies['summary.json'] = (encode(facts), None)
copies['.gitattributes'] = (b'* -text\n', None)
readme = f'''# Guardian full analysis — 2026-10-23 r7 RED

**NOT_ACCEPTED.** Strict full Guardian lib/test analysis of committed source
`{proposal['sourceCommit']}` found one warning: `unnecessary_non_null_assertion`
at observation_page.dart:31:52; no errors or infos. Fatal warnings made the native
command, worker and retained outer process return 1. Actual session1854
(804cf2 → dff5b1) exited naturally in{result['elapsedCompleteSeconds']} seconds,
below outer180 and the conservative {strict_bound}-second boundary. There was
no timeout or forced termination; private Jobs0. This RED has not been promoted.

Original execution pre/post checks covered all409 source files,70 package rows,
3536 cache files /633817159 bytes and212 candidate/runtime/historical pins.
Independent post-terminal readback and the separate fresh full system API gate
are retained raw. Their formal release concerns process/resource ownership;
it does not make the analysis pass. No current-Main/source identity is inferred
after Root's later one-character lint correction.

The prepared expected-PASS `candidate/external_observe_root.py` was **UNUSED**:
it was never invoked and no external-observation-root.json was generated.
The actual readback used `reviews/root-actual-red-readback.py` (ddbf41), which
produced external-red-readback-root.json. These two helpers are not interchangeable.

All80 prepared browser cases in7 suites remain **UNRUN**. No app tests, real
provider/device acceptance, deployment or product-wide completion is implied.
Static preparation seals/reviews remain verbatim UNRUN evidence. Their failure
to predict this lint does not mean a type checker or tests had been run earlier.

Root subsequently removed only the redundant `!` from the same synchronous
null-guard expression (11504 →11503 bytes). Its receipt and separate independent
static review are preserved. This correction's analysis and tests remain UNRUN;
the exact commit plan lists that source fix alongside the RED archive. Original
RED snapshot bytes and results are not rewritten.

The archive copies exact candidate/control source text, input/package/cache
metadata, source-snapshot metadata, raw receipts/log and independent records.
It copies no runtime binary, cache content or application source tree. Its
{len(history_rows)} historical descriptors resolve to{len(durable)} durable raw
metadata references and{len(runtime_history)} runtime descriptor occurrences
representing{len(runtime_unique)} unique files. The{len(control_rows)} direct
runtime descriptors are listed separately; together these two lists contain
{len(control_rows)+len(runtime_history)} occurrences, not{len(runtime_history)}.
Archived scripts keep original paths and are evidence, not a runnable relocation.
'''
copies['README.md'] = (readme.encode('utf-8'), None)
assert sum(len(value) for value, _ in copies.values()) < 8 * 1024**2
inventory_rows = []
for target, (value, source) in sorted(copies.items()):
    created(OUT / target, value)
    inventory_rows.append({'archivePath': target, 'bytes': len(value), 'sha256': sha(value), 'originalPath': source})
inventory = {'status': 'RAW_RED_METADATA_ARCHIVE_ONLY_NOT_EXECUTABLE',
    'createdUtc': datetime.now(timezone.utc).isoformat(), 'files': inventory_rows,
    'durableHistoricalMetadataPins': durable, 'runtimePinDescriptorsOnly': runtime_history,
    'directControlRuntimeDescriptorsOnly': control_rows,
    'historicalMetadataDescriptors': len(history_rows),
    'historicalMetadataDurable': len(durable), 'runtimeContentsCopied': False,
    'cacheContentsCopied': False, 'applicationSourceTreeCopied': False}
created(OUT / 'archive-inventory.json', encode(inventory))
stage_rows = []
for path in sorted(OUT.rglob('*')):
    if path.is_file():
        value = raw(path)
        stage_rows.append({'path': path.relative_to(REPO).as_posix(), 'bytes': len(value), 'sha256': sha(value),
            'gitRawBlobSha1': hashlib.sha1(b'blob ' + str(len(value)).encode() + b'\0' + value).hexdigest()})
stage_rows.append({'path': fix_receipt['path'], 'bytes': len(fix_after), 'sha256': sha(fix_after),
    'gitRawBlobSha1': hashlib.sha1(b'blob ' + str(len(fix_after)).encode() + b'\0' + fix_after).hexdigest()})
stage_rows.sort(key=lambda row: row['path'])
assert raw(REPO / fix_receipt['path']) == fix_after
created(STAGE, encode({'status': 'EXACT_RED_EVIDENCE_STAGE_PLAN_NOT_GIT_OPERATION',
    'parentExplicitlyProvidedByRoot': sys.argv[4], 'files': stage_rows,
    'sourceCommitOfRedSnapshot': proposal['sourceCommit'], 'changedMainSourceFiles': [fix_receipt['path']],
    'scope': 'Exact r7 RED archive plus Root-owned one-character Main fix; no Main/Git mutation or foreign WIP staging'}))
print(json.dumps({'status': 'R7_RED_EVIDENCE_WRITTEN_NOT_COMMITTED', 'files': len(stage_rows),
    'bytes': sum(row['bytes'] for row in stage_rows), 'stagePlan': str(STAGE),
    'rawCopies': sum(source is not None for value, source in copies.values()),
    'metadataDurable': len(durable), 'runtimeHistoricalOccurrences': len(runtime_history),
    'runtimeHistoricalUniqueFiles': len(runtime_unique), 'analysisAccepted': False,
    'browserCasesExecuted': 0}, ensure_ascii=False))
