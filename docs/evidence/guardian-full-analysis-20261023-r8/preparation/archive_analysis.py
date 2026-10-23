"""Reuse r7 exact-byte archival; only later explicit Root notification permits docs."""
from pathlib import Path
import hashlib
import json
import ntpath
import os
import re
import stat
import sys

BASE = Path(__file__).absolute().parent
REPO = BASE.parents[1]
RUN = REPO / '.cache/guardian-analyze-20261023-r8'
SNAP = REPO / '.cache/guardian-observation-current-20261023-r2'
OUT = REPO / 'docs/evidence/guardian-full-analysis-20261023-r8'
PLAN = BASE / 'plan-preview-r2.json'
SOURCE_COMMIT = '45950b88a270e2fded2409e333fb126851b6f861'
PROPOSAL_SHA = 'f6f9a00027a9b070a2b289e5560a34d31c3314e2137a40cd75a8b1dd76e03ae1'
EXTERNAL_SHA = '88bd0bed6b87103835a3814fe08c93dd5ab22b28e350609f36b98227c09f016f'
GATE_SHA = '66dc83b50c52f5f7c6fac5aa0635ebe8106f8e81963f16f49fc7f2ba7770ed76'


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
    len(sys.argv) == 4 and sys.argv[1] == '--write-after-root-notification'
    and re.fullmatch('[0-9a-f]{64}', sys.argv[2])
    and re.fullmatch('[0-9a-f]{40}', sys.argv[3]))
writing = sys.argv[1] == '--write-after-root-notification'
assert not OUT.exists(), 'A durable archive is never overwritten'
proposal = load(RUN / 'proposal.json')
assert sha(raw(RUN / 'proposal.json')) == PROPOSAL_SHA
assert proposal['sourceCommit'] == SOURCE_COMMIT
candidate_rows, control_rows, history_rows = [proposal[key] for key in
    ('candidateFiles', 'controlRuntimeFiles', 'historicalMetadataFiles')]
assert [len(candidate_rows), len(control_rows), len(history_rows)] == [12, 11, 250]
assert proposal['mechanicalTemplateActualStatus'] == 'NOT_ACCEPTED'
assert proposal['actualAcceptedTemplate']['sha256'] == 'b4cf7534705500f7a3dd1cd825a2c314bbb5654295e63aa21b007b496cffb7b5'
result, receipt, launch, external, gate = [load(RUN / 'attempt' / name) for name in
    ('result.json', 'receipt.json', 'launch.json', 'external-observation-root.json', 'root-final-system-gate.json')]
assert sha(raw(RUN / 'attempt/external-observation-root.json')) == EXTERNAL_SHA
assert sha(raw(RUN / 'attempt/root-final-system-gate.json')) == GATE_SHA
assert result['status'] == 'FULL_GUARDIAN_ANALYZE_PASSED'
assert receipt['status'] == 'FULL_GUARDIAN_ANALYZE_WORKER_PASSED'
assert result['workerExitCode'] == 0 and result['workerPid'] == 32440
assert result['ownedJobActiveProcessesFinal'] == result['ownedJobActiveProcesses'] == 0
assert not result['ownedCleanupPerformed'] and not result['watchdogExpired']
assert result['postCandidateAndControlRuntimeMismatches'] == []
assert receipt['commandTerminalState']['pid'] == 62080
for terminal in (receipt['commandTerminalState'], receipt['commandTerminalStateAfterPostflight']):
    assert terminal['rootExitCode'] == 0 and terminal['rootHandleSignaled']
    assert terminal['terminalVerified'] and terminal['activeProcesses'] == 0
    assert not terminal['timedOut'] and not terminal['terminationRequested']
assert not receipt['forcedTermination'] and not receipt['testsRun'] and receipt['noIssuesFound']
assert receipt['sdkCalls'] == 1 and not receipt['pubRun'] and not receipt['downloadsAllowed']
for name in ('preflight-pins.json', 'postflight-pins.json'):
    phase = load(RUN / 'attempt' / name)
    assert phase['complete']
    assert phase['source']['frozenRawGit']['files'] == phase['source']['mainRaw']['files'] == 409
    assert phase['packages']['packages'] == 70 and phase['packages']['metadataPreserved']
    assert phase['cache']['totals'] == {'files': 3536, 'bytes': 633817159}
    assert phase['cache']['allMembersDirectoriesBytesAndHashesMatch']
strict_bound = launch['workerElapsedAtLaunch'] + launch['commandBudgetSeconds']
assert result['elapsedCompleteSeconds'] < strict_bound == 135 < 180
log = pinned(RUN / 'attempt/out/analyze.log', receipt['logPin'])
text = log.decode('utf-8-sig')
assert text.count('No issues found!') == 1
assert not re.findall(r'^\s*(error|warning|info)\s+-\s+', text, re.M)
assert external['status'] == 'ANALYSIS_BYTES_AND_ACTUAL_TERMINAL_INDEPENDENTLY_MATCHED_AWAIT_FRESH_SYSTEM_GATE'
assert gate['status'] == 'FULL_GUARDIAN_ANALYZE_EXTERNALLY_ACCEPTED'
assert external['actualToolSession'] == gate['actualSession'] == 95689
assert external['initialToolChunk'] == gate['actualInitialChunk'] == 'af428c'
assert external['finalToolChunk'] == gate['actualFinalChunk'] == 'af189a'
assert external['naturalExitCode'] == gate['naturalExitCode'] == 0
assert external['sourceCommit'] == gate['sourceCommit'] == SOURCE_COMMIT
assert external['outerElapsedSeconds'] == result['elapsedCompleteSeconds']
assert external['strictCompleteBoundSeconds'] == strict_bound
assert external['sourceFilesIndependentlyRehashedBothTrees'] == 409
assert external['cacheFilesIndependentlyRehashed'] == 3536
assert external['cacheBytesIndependentlyRehashed'] == 633817159
assert external['candidateAndRuntimeMetadataPinsMatched'] == 273
assert external['diagnostics'] == {'errors': 0, 'warnings': 0, 'infos': 0}
assert external['rawLogSha256'] == sha(log) and external['prePostComplete']
assert external['knownOwnedPidsAbsent'] == [32440, 62080]
assert not external['forcedTermination'] and not external['testsRun'] and not external['browserRun']
assert not external['servicesUpdated'] and not external['wholeProductAccepted']
assert gate['formalRelease'] and gate['sdkCount'] == gate['unknownProcessNameCount'] == 0
assert gate['ownedJobActiveProcesses'] == external['ownedJobActiveProcesses'] == 0
assert gate['availableRamBytes'] == 2812280832 and gate['readbackChunk'] == '933c3c'
assert not gate['browserTestsRun'] and not gate['wholeProductAccepted']

# Derive runtime occurrences from actual descriptor paths, never from a guessed total.
controls_by_path = {}
for row in control_rows:
    canonical = norm(row['path'])
    assert canonical not in controls_by_path
    controls_by_path[canonical] = row
    pinned(Path(row['path']), row)
runtime_history, metadata_history = [], []
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
copies, originals = {}, {}


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
add(REPO / '.cache/guardian-analyze-r8-post-readback-root-20261023.py', 'reviews/root-actual-post-readback.py')
for name in ('review.md', 'review.json', 'report-pins.json'):
    add(REPO / '.cache/guardian-source409r2-r8-independent-20261023-r1' / name, 'reviews/independent-' + name)
for path in sorted((RUN / 'attempt').rglob('*')):
    relative = path.relative_to(RUN / 'attempt')
    if path.is_file() and 'tmp' not in relative.parts:
        add(path, 'attempt/' + relative.as_posix())
add(Path(__file__), 'preparation/archive_analysis.py')
add(SNAP / 'out/seal-static-source.json', 'inputs/source-snapshot-seal.json')
snapshot_seal = load(SNAP / 'out/seal-static-source.json')
assert snapshot_seal['sourceCommit'] == SOURCE_COMMIT and snapshot_seal['sourceFiles'] == 409
for row in snapshot_seal['files']:
    if not row['path'].startswith('src/'):
        add(SNAP / row['path'], 'inputs/source-snapshot/' + row['path'], row)
inputs = load(RUN / 'inputs.json')
for key in ('sourceManifest', 'dependencyLibraryPins', 'cacheManifest', 'originalPackageConfig',
            'candidatePackageConfig', 'candidatePackageConfigTemplate'):
    row = inputs[key]
    add(Path(row['path']), 'inputs/' + key + '.json', row)

# Search prior committed inventories first; byte equality supplies a raw reference, not new lineage.
existing = []
for name in ('guardian-full-analysis-20261023-r7', 'guardian-full-analysis-20261023-r6',
             'guardian-full-analysis-20261023-r5', 'guardian-full-analysis-20261023-r4',
             'guardian-full-analysis-20261023-r3', 'guardian-baseline-analysis-20261021',
             'guardian-browser38-20261023-r1'):
    root = REPO / 'docs/evidence' / name
    inventory = load(root / 'archive-inventory.json')
    inventory_raw = raw(root / 'archive-inventory.json')
    existing.append((root / 'archive-inventory.json',
        {'bytes': len(inventory_raw), 'sha256': sha(inventory_raw)}))
    for row in inventory['files']:
        existing.append((root / row['archivePath'], row))
    for row in inventory.get('durableHistoricalMetadataPins', []):
        existing.append((REPO / row['durableArchivePath'], row))
durable = []
for index, row, source in metadata_history:
    target = next((path for path, old in existing
        if old['bytes'] == row['bytes'] and old['sha256'] == row['sha256']), None)
    if target is not None:
        pinned(target, row)
    elif norm(source) in originals:
        target = OUT / originals[norm(source)]
    else:
        target = add(source, f'historical/{index:03d}-' + source.name, row)
    durable.append({'historicalIndex': index, 'originalPath': str(source),
        'durableArchivePath': target.relative_to(REPO).as_posix(), 'bytes': row['bytes'], 'sha256': row['sha256']})
assert len(durable) + len(runtime_history) == len(history_rows)
runtime_unique = {norm(row['path']) for row in runtime_history}
prior_durable = [row for row in durable if not row['durableArchivePath'].startswith(OUT.relative_to(REPO).as_posix() + '/')]
facts = {
    'status': 'FULL_GUARDIAN_ANALYSIS_ACCEPTED_BROWSER80_UNRUN_AT_ANALYSIS_RELEASE',
    'analysisAccepted': True, 'sourceCommit': SOURCE_COMMIT, 'sourceFiles': 409,
    'scope': 'Entire Guardian lib/test fatal-infos/fatal-warnings analysis; no application tests',
    'actualSession': 95689, 'initialChunk': 'af428c', 'finalChunk': 'af189a', 'naturalExitCode': 0,
    'workerPid': 32440, 'nativeCommandPid': 62080,
    'outerElapsedSeconds': result['elapsedCompleteSeconds'], 'strictCompleteBoundSeconds': strict_bound,
    'diagnostics': external['diagnostics'], 'fullSourcePrePost': 409, 'packageRows': 70,
    'cacheFiles': 3536, 'cacheBytes': 633817159, 'candidateAndRuntimeMetadataPins': 273,
    'historicalDescriptors': len(history_rows), 'historicalMetadataDurableReferences': len(durable),
    'historicalMetadataReferencesToPriorDurableArchives': len(prior_durable),
    'historicalRuntimeDescriptorOccurrences': len(runtime_history), 'historicalRuntimeUniqueFiles': len(runtime_unique),
    'directControlRuntimeDescriptors': len(control_rows),
    'allRuntimeDescriptorOccurrencesAcrossBothLists': len(control_rows) + len(runtime_history),
    'allRuntimeUniqueFilesAcrossBothLists': len(set(controls_by_path) | runtime_unique),
    'browserCasesPrepared': 80, 'physicalSuitesPrepared': 7, 'browserCasesExecutedByThisAnalysis': 0,
    'browserStatusAtAnalysisRelease': 'UNRUN', 'laterBrowserRunOutsideThisArchive': True,
    'testsRun': False, 'servicesUpdated': False, 'wholeProductAccepted': False,
    'forcedTermination': False, 'timedOut': False, 'ownedJobActiveProcesses': 0,
    'rawLogSha256': sha(log), 'rawLogBytes': len(log), 'actualAnalysisSdkCalls': 1,
    'preparationRecordsPreservedVerbatimAsUnrun': True,
    'mechanicalPredecessorR7ActualAnalysis': 'RED_NOT_ACCEPTED_ONE_WARNING_NATURAL1_UNCHANGED',
    'acceptedControlLineageAtPreparation': 'R6_ACTUAL_NATURAL0',
    'r7SingleCharacterCorrectionAnalysis': 'R8_FULL_ANALYSIS_ACCEPTED_NO_APPLICATION_TESTS',
    'actualIndependentPostReadbackScript': 'reviews/root-actual-post-readback.py',
    'actualIndependentReadbackChunk': gate['readbackChunk'],
    'externalObserverStatus': external['status'], 'formalSystemGateStatus': gate['status'],
    'sdkCountAtRelease': gate['sdkCount'], 'unknownProcessNamesAtRelease': gate['unknownProcessNameCount'],
    'availableRamBytesAtRelease': gate['availableRamBytes'],
    'externalObserverSha256': EXTERNAL_SHA, 'formalSystemGateSha256': GATE_SHA,
    'independentReadbackAndFormalReleaseAlreadyObserved': True,
    'archiverSdkCalls': 0, 'archiverCandidateFunctionsImportedOrCalled': False, 'archiverMainOrGitWritten': False,
}
copies['summary.json'] = (encode(facts), None)
copies['.gitattributes'] = (b'* -text\n', None)
readme = f'''# Guardian full analysis — 2026-10-23 r8

**Full analysis accepted.** Complete Guardian lib/test at source commit
{SOURCE_COMMIT} produced no errors, warnings or infos under fatal-infos and
fatal-warnings. Retained outer session95689 (af428c → af189a), native command
and worker all exited naturally with0 in{result['elapsedCompleteSeconds']} seconds,
below strict{strict_bound} and outer180. No timeout/forced termination; private Jobs0.

Original pre/post verification covered409 Main/frozen source files,70 package
rows,3536 cache files /633817159 bytes and273 candidate/runtime/historical pins.
Root actual post-terminal readback933c3c independently repeated those byte checks.
A separate fresh full system gate formally released the window with SDK0/unknown0
and2812280832 available RAM bytes. Actual helper, output and terminal IDs are raw.

At this analysis release,80 browser cases in7 suites were **UNRUN**. This run
executed no application tests. A later browser run has separate evidence outside
this archive. Services were not updated; real provider/device acceptance,
deployment and product-wide completion are not implied.

R7 remains RED/NOT_ACCEPTED with one warning and natural1. R8 checks its committed
one-character correction without rewriting that result or then-UNRUN fix receipt.
Original r8 preparation seals/reviews remain verbatim UNRUN checkpoints. Actual
accepted control lineage at preparation was r6; r7 was the mechanical baseline.
R8's new actual acceptance is recorded here.

Exact raw candidate/control source text, source/package/cache metadata, receipts,
log and independent reviews are retained. Runtime binaries, cache contents and
application source trees are not copied. Historical250 descriptors resolve to
{len(durable)} metadata references ({len(prior_durable)} in prior archives) and
{len(runtime_history)} runtime occurrences representing{len(runtime_unique)} unique files.
The11 direct runtime descriptors are separate; both lists contain
{len(control_rows)+len(runtime_history)} occurrences. Archived scripts retain original
paths as evidence and are not runnable relocations.
'''
copies['README.md'] = (readme.encode('utf-8'), None)
assert sum(len(value) for value, _ in copies.values()) < 8 * 1024**2
inventory_rows = [{'archivePath': target, 'bytes': len(value), 'sha256': sha(value), 'originalPath': source}
    for target, (value, source) in sorted(copies.items())]
inventory = {'status': 'RAW_ACCEPTED_ANALYSIS_METADATA_ARCHIVE_ONLY_NOT_EXECUTABLE',
    'rootReleasedAtUtc': gate['atUtc'], 'files': inventory_rows,
    'durableHistoricalMetadataPins': durable, 'runtimePinDescriptorsOnly': runtime_history,
    'directControlRuntimeDescriptorsOnly': control_rows, 'historicalMetadataDescriptors': len(history_rows),
    'historicalMetadataDurable': len(durable), 'historicalMetadataReferencesToPriorDurableArchives': len(prior_durable),
    'runtimeContentsCopied': False, 'cacheContentsCopied': False, 'applicationSourceTreeCopied': False}
copies['archive-inventory.json'] = (encode(inventory), None)
stage_rows = []
for target, (value, source) in sorted(copies.items()):
    stage_rows.append({'path': (OUT / target).relative_to(REPO).as_posix(), 'bytes': len(value), 'sha256': sha(value),
        'gitRawBlobSha1': hashlib.sha1(b'blob ' + str(len(value)).encode() + b'\0' + value).hexdigest(),
        'originalPath': source})
preview = {'status': 'CACHE_PLAN_ONLY_DO_NOT_TREAT_AS_DURABLE_ARCHIVE', 'proposedArchive': str(OUT),
    'sourceCommit': SOURCE_COMMIT, 'facts': facts, 'plannedFiles': stage_rows,
    'durableHistoricalMetadataPins': durable, 'runtimePinDescriptorsOnly': runtime_history,
    'directControlRuntimeDescriptorsOnly': control_rows, 'noRuntimeCacheOrApplicationSourceContentsCopied': True,
    'rawCopies': sum(source is not None for value, source in copies.values()),
    'docsWritten': False, 'gitWritten': False, 'mainWritten': False,
    'pendingUntilRootNotification': ['explicit instruction to generate docs', 'Root-selected combined commit parent']}
if not writing:
    created(PLAN, encode(preview))
    print(json.dumps({'status': preview['status'], 'path': str(PLAN), 'bytes': len(raw(PLAN)), 'sha256': sha(raw(PLAN)),
        'plannedFiles': len(stage_rows), 'plannedBytes': sum(row['bytes'] for row in stage_rows),
        'rawCopies': preview['rawCopies'], 'metadataDurable': len(durable), 'priorDurableReferences': len(prior_durable),
        'runtimeHistoricalOccurrences': len(runtime_history), 'runtimeHistoricalUniqueFiles': len(runtime_unique),
        'runtimeDirectControlDescriptors': len(control_rows), 'docsWritten': False, 'sdkCalls': 0}, ensure_ascii=False))
    raise SystemExit(0)

# A cache plan alone does not authorize this branch; await a later explicit Root message.
assert sha(raw(PLAN)) == sys.argv[2]
assert load(PLAN) == preview, 'Inputs changed since the exact cache plan'
for target, (value, source) in sorted(copies.items()):
    created(OUT / target, value)
created(BASE / 'stage-pins.json', encode({'status': 'EXACT_R8_EVIDENCE_STAGE_PLAN_NOT_GIT_OPERATION',
    'parentExplicitlyProvidedByRoot': sys.argv[3], 'files': stage_rows,
    'sourceCommitOfAnalysisSnapshot': SOURCE_COMMIT, 'changedMainSourceFiles': [],
    'scope': 'Exact accepted r8 analysis evidence; no Main/Git mutation or foreign WIP staging'}))
print(json.dumps({'status': 'R8_ANALYSIS_EVIDENCE_WRITTEN_NOT_COMMITTED', 'files': len(stage_rows),
    'rawCopies': preview['rawCopies'], 'docsWritten': True, 'gitWritten': False, 'mainWritten': False,
    'stagePlan': str(BASE / 'stage-pins.json')}, ensure_ascii=False))
