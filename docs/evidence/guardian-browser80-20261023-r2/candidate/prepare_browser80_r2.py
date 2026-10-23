"""Rebind Browser80 r1 to a newly sealed commit. Text/AST/hash only; never import controls."""
from pathlib import Path
import ast
import copy
import datetime
import difflib
import hashlib
import json
import os

ROOT = Path(__file__).absolute().parent
REPO = ROOT.parents[1]
R1 = REPO / '.cache/guardian-browser80-20261023-r1'
REVIEW = REPO / '.cache/guardian-browser80-independent-20261023-r1'
SNAP = REPO / '.cache/guardian-observation-current-20261023-r2'
OLD_SNAP = REPO / '.cache/guardian-observation-current-20261023-r1'
RED = REPO / 'docs/evidence/guardian-full-analysis-20261023-r7'
COMMIT = '45950b88a270e2fded2409e333fb126851b6f861'
EXPECTED_SEAL_SHA = 'cb7b531b176433c2b1e8ed5154d49710a53a642268f9296816a9af07f8139957'
PAGE = 'apps/guardian/lib/pages/observation_page.dart'


def raw(path):
    path = Path(path)
    for parent in (path, *path.parents):
        if os.path.lexists(parent):
            assert not parent.is_symlink() and not parent.is_junction(), str(parent)
    before = path.stat()
    value = path.read_bytes()
    after = path.stat()
    assert (before.st_dev, before.st_ino, before.st_nlink, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_nlink, after.st_size, after.st_mtime_ns)
    return value


def pin(path, absolute=False):
    value = raw(path)
    row = {'path': str(path), 'bytes': len(value), 'sha256': hashlib.sha256(value).hexdigest()}
    if absolute:
        row['absolute'] = True
    return row


def verify(row, base=ROOT):
    path = Path(row['path']) if row.get('absolute') or Path(row['path']).is_absolute() else base / row['path']
    value = raw(path)
    assert len(value) == row['bytes'] and hashlib.sha256(value).hexdigest() == row['sha256'], str(path)
    return path


def load(path):
    return json.loads(raw(path))


def write(name, value):
    path = ROOT / name
    assert path.parent == ROOT
    with path.open('xb') as stream:
        stream.write(value)
    return pin(path)


def save(name, value):
    return write(name, (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode())


def diff(name, before, after):
    return ''.join(difflib.unified_diff(before.splitlines(keepends=True), after.splitlines(keepends=True),
        fromfile='sealed-browser80-r1/' + name, tofile='browser80-r2/' + name)).encode()


assert {p.name for p in ROOT.iterdir()} == {'prepare_browser80_r2.py'}
assert EXPECTED_SEAL_SHA != '__SOURCE_SEAL_PENDING__'
assert pin(SNAP / 'out/seal-static-source.json')['sha256'] == EXPECTED_SEAL_SHA
source_seal = load(SNAP / 'out/seal-static-source.json')
manifest = load(SNAP / 'out/source-manifest.json')
prep = load(SNAP / 'out/preparation-review.json')
contract = load(SNAP / 'out/expected-cases.json')
old_manifest = load(OLD_SNAP / 'out/source-manifest.json')
old_contract = load(OLD_SNAP / 'out/expected-cases.json')
assert source_seal['sourceCommit'] == manifest['head'] == prep['sourceCommit'] == COMMIT
assert source_seal['sourceFiles'] == manifest['sourceCount'] == len(manifest['sourceFiles']) == 409
assert contract['expectedVisibleCases'] == len(contract['cases']) == 80 and contract['expectedPhysicalSuites'] == len(contract['selectors']) == 7
assert contract['cases'] == old_contract['cases'] and contract['selectedSources'] == old_contract['selectedSources']
assert contract['selectors'] == old_contract['selectors'] and contract['sourceCaseCounts'] == [8, 4, 19, 7, 8, 21, 13]
old_rows = {row['path']: row for row in old_manifest['sourceFiles']}
assert set(old_rows) == {row['path'] for row in manifest['sourceFiles']}
changed_rows = [row['path'] for row in manifest['sourceFiles'] if row != old_rows[row['path']]]
assert changed_rows == [PAGE]
for row in source_seal['files']:
    verify(row, SNAP)
for row in manifest['sourceFiles']:
    assert pin(SNAP / 'src' / row['path'])['sha256'] == row['sha256']
    assert pin(REPO / row['path'])['sha256'] == row['workingTreeRawSha256']
before_page = raw(OLD_SNAP / 'src' / PAGE)
after_page = raw(SNAP / 'src' / PAGE)
assert before_page.count(b'observationRoute == null || observationRoute!.available') == 1
assert before_page.replace(b'observationRoute == null || observationRoute!.available', b'observationRoute == null || observationRoute.available') == after_page
assert len(before_page) == 11504 and len(after_page) == 11503
assert hashlib.sha256(after_page).hexdigest() == 'ac0e30966f2a5c5f6b65dc12a8445a3ae7d52d8cda45cbb979b0b58a18e83816'
expected_paths = {row['path'] for row in manifest['sourceFiles']}
for base in (REPO, SNAP / 'src'):
    found = set()
    for root in manifest['roots']:
        for directory, dirs, files in os.walk(base / root):
            here = Path(directory)
            assert not here.is_symlink() and not here.is_junction()
            dirs[:] = [d for d in dirs if d not in prep['sourceMembershipExclusions']['directories']]
            for file in files:
                if file not in prep['sourceMembershipExclusions']['files']:
                    found.add((here / file).relative_to(base).as_posix())
    assert found == expected_paths

r1_before = [pin(p) for p in sorted(R1.iterdir()) if p.is_file()]
assert len(r1_before) == 23
old_proposal = load(R1 / 'proposal.json')
assert pin(R1 / 'proposal.json')['sha256'] == 'b602e13ad6319606709fbf6c28265fdbd389d38832e93ffd4c0f721281203b95'
assert pin(R1 / 'seal-receipt.json')['sha256'] == 'ac861a5649725f4023b8c364f99ab9883738e55b3f74930e317347bee861ace0'
review = load(REVIEW / 'review.json')
assert review['status'] == 'BROWSER80_R1_STATIC_CONTROL_REVIEW_NO_BLOCKER_HISTORICAL_SOURCE_DO_NOT_RUN'
assert review['blockingFindings'] == []
old_inputs = load(R1 / 'inputs.json')
for row in load(R1 / 'delivery-pins.json')['files']:
    verify(row)
history = []
for field in ('candidateFiles', 'controlRuntimeFiles', 'historicalMetadataFiles'):
    for row in old_proposal[field]:
        path = verify(row, R1)
        history.append({**row, 'path': str(path), 'absolute': True})
assert len(history) == 269
for path in ('proposal.json', 'seal-receipt.json', 'delivery-pins.json', 'static-final-readback.json'):
    history.append(pin(R1 / path, True))
for path in sorted(REVIEW.iterdir()):
    if path.is_file():
        history.append(pin(path, True))
for path in ('out/seal-static-source.json', *[row['path'] for row in source_seal['files'] if not row['path'].startswith('src/')]):
    history.append(pin(SNAP / path, True))
for path in sorted(RED.rglob('*')):
    if path.is_file():
        assert not any(part in ('src', 'tmp', '.dart_tool', 'build') for part in path.relative_to(RED).parts)
        history.append(pin(path, True))
assert load(RED / 'summary.json')['analysisAccepted'] is False
assert load(RED / 'summary.json')['sourceCommit'] == 'a55849d902b248fe02d06e23cd0bad3d28912a27'
assert old_inputs['cacheManifest']['sha256'] == '8c0cfde01a9d6d5cb4bf002c1ed6d5069af28b0f27f110bec292f46e281f66c0'
cache = load(verify(old_inputs['cacheManifest']))
assert cache['totals']['files'] == 3537 and len(cache['trees']) == 70 and len(cache['fixedFiles']) == 33
verify(old_inputs['chromeExecutablePin'])

unchanged = ['controller.py', 'heap1536_windows_job.py', 'reporter_contract.py', 'owned_chrome_observer.py', 'budget-policy.json']
for name in unchanged:
    write(name, raw(R1 / name))
    assert raw(ROOT / name) == raw(R1 / name)
    write('mechanical-' + name + '.diff', b'')
inputs = copy.deepcopy(old_inputs)
inputs.update(createdAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    sourceCommit=COMMIT, sourceTreeSha256=manifest['sourceTreeSha256'], sevenRootGitTrees=manifest['sevenRootGitTrees'],
    sourceManifest=prep['sourceManifest'], dependencyLibraryPins=prep['dependencyLibraryPins'],
    candidatePackageConfig=prep['candidatePackageConfig'], candidatePackageConfigTemplate=prep['candidatePackageConfigTemplate'],
    originalPackageConfig=prep['originalPackageConfig'], expectedCaseContract=prep['expectedCaseContract'],
    sourceSnapshotSeal=pin(SNAP / 'out/seal-static-source.json'),
    reporterContractCode=pin(ROOT / 'reporter_contract.py'), ownedChromeObserverCode=pin(ROOT / 'owned_chrome_observer.py'))
# Phase, counts, name parser policy, cache3537, SDK roots, runtime, bootstrap and Chrome
# metadata remain inherited. Historical Chrome readback stays an explicitly old record.
input_pin = save('inputs.json', inputs)
old_worker = raw(R1 / 'worker.py').decode('utf8')
old_frozen = "FROZEN = Path(r'D:\\codes\\mobile\\ai-manager\\.cache\\guardian-observation-current-20261023-r1')"
new_frozen = "FROZEN = Path(r'D:\\codes\\mobile\\ai-manager\\.cache\\guardian-observation-current-20261023-r2')"
old_input_constant = "INPUT_SHA256 = '" + pin(R1 / 'inputs.json')['sha256'] + "'"
new_input_constant = "INPUT_SHA256 = '" + input_pin['sha256'] + "'"
assert old_worker.count(old_frozen) == old_worker.count(old_input_constant) == 1
worker = old_worker.replace(old_frozen, new_frozen).replace(old_input_constant, new_input_constant)
assert worker.replace(new_frozen, old_frozen).replace(new_input_constant, old_input_constant) == old_worker
write('worker.py', worker.encode())
write('mechanical-worker.py.diff', diff('worker.py', old_worker, worker))
before_ast, after_ast = ast.parse(old_worker), ast.parse(worker)
assert len(before_ast.body) == len(after_ast.body)
changed_nodes = []
for before, after in zip(before_ast.body, after_ast.body):
    if ast.dump(before, include_attributes=False) != ast.dump(after, include_attributes=False):
        assert isinstance(before, ast.Assign) and isinstance(before.targets[0], ast.Name)
        changed_nodes.append(before.targets[0].id)
assert changed_nodes == ['FROZEN', 'INPUT_SHA256']
for name in ('controller.py', 'heap1536_windows_job.py', 'reporter_contract.py', 'owned_chrome_observer.py', 'prepare_browser80_r2.py'):
    ast.parse(raw(ROOT / name), filename=name)
save('ast-diff-proof.json', {'status': 'STATIC_AST_ONLY_NO_CANDIDATE_IMPORTS_OR_CALLS',
    'workerChangedTopLevelAssignments': changed_nodes, 'workerReversesExactlyByOnlyTwoReplacements': True,
    'oldWorker': pin(R1 / 'worker.py'), 'newWorker': pin(ROOT / 'worker.py'),
    'allOtherWorkerAstNodesIdentical': True, 'allWorkerFunctionsIncludingSourceCheckAndAuxQualificationIdentical': True,
    'controlsByteIdenticalToR1': unchanged, 'budgetsProtocolCountsFlagsAndFirstRetainedTerminalGateUnchanged': True,
    'source409OnlyChangedFile': PAGE, 'sourceChangeBytes': -1, 'old80AllNameAndSelectedSourceMetadataExact': True,
    'gitOrNetworkOrSdkOrNativeProcessCalls': 0, 'candidateFunctionsImportedOrCalled': False})
save('input-metadata-diff.json', {'status': 'SOURCE_AND_PACKAGE_URI_REBIND_ONLY_RUNTIME_UNRUN',
    'oldInputs': pin(R1 / 'inputs.json'), 'newInputs': input_pin,
    'changedFields': {name: {'before': old_inputs.get(name), 'after': inputs.get(name)} for name in sorted(set(inputs) | set(old_inputs)) if inputs.get(name) != old_inputs.get(name)},
    'cacheManifestAnd3537BoundaryUnchanged': old_inputs['cacheManifest'] == inputs['cacheManifest'],
    'selectorsAndCasesNotRegenerated': True, 'runtimeSourceNameParserAdded': False})
save('old-r1-preservation.json', {'status': 'SEALED_R1_AND_HISTORICAL_FAILURES_UNCHANGED',
    'before': r1_before, 'all269OriginalProposalPinsRetainedAsHistoricalReferences': True,
    'originalR7SourceA558RemainsRed': True, 'r1SourceA558NotExecutableForCurrentMain': True,
    'browser80R1AndR2CasesExecuted': 0, 'runtimeOrSourceOrCacheCopy': False})
write('README.md', b'''# Guardian Browser80 r2 -- UNRUN, no execution grant

This new package rebinds the independently reviewed Browser80 r1 controls to committed
45950b88a270e2fded2409e333fb126851b6f861. Source remains409 files /80 exact cases /
7 HTML Chrome suites. The only production change from the historical a558 snapshot
is removal of the redundant observation_page.dart null assertion, one byte. All408
other source rows and all80 case/selected-source metadata remain exact. No source tree
or cache contents are copied; use the newly sealed observation-current-r2/src directly.

Controller, native Job inventory helper, reporter, owned Chrome observer and complete
budget-policy bytes are identical to r1. Worker differs only in FROZEN and INPUT_SHA256;
all functions, phase, counts, selectors, flags and retained-terminal gate remain exact.
Input/package root URIs and source manifest/tree/seal provenance bind the new commit.
This is static text/AST/hash assembly, not Dart compilation, tests or browser validation.

The numerical policy remains outer300/soft294/workerFinishBy288/controller final6,
local285 max, command210 max, cleanup6 and full postflight45. Phase remains
BROWSER80_OWNED_AUX with OWNED_JOB_READY_BROWSER80_V2. Both success scopes require the
same retained Popen first observed terminal strictly before finite workerHard and
finishBy. Natural Job0 keeps forced/cleanup=false; the qualified owned non-SDK auxiliary
branch keeps forced/auxCleanupRequested/auxCleanup=true, sdkForced=false and
legacyStrictAccepted=false. SDK/unknown/drift/deadline/outer cleanup/Job close fallback
rejects; there is no global-name/PID kill or input-method whitelist. Exact member
PID/FILETIME/image/retained handle/IsProcessInJob/TotalProcesses, post-intent fsync full
requalification, strict report/log pins and all source/package/cache/runtime pre/post
gates remain. OS sampling/action is not atomic; an observation can conservatively
reject an earlier exit. Pre-I/O receipt elapsed never replaces real outer terminal
before300 or the full final release gates.

The complete3537 browser cache (70 trees/33 fixed, including unchanged pinned Chrome)
is inherited; the analysis3536 projection is not used. Chrome executable content is
rechecked only as a file pin during assembly. Historical Chrome observation remains
historical; no browser/process was inspected or started. All3537 runtime contents must
still be fully rehashed before and after any later grant; no fresh cache rebaseline
or runtime verification is claimed here.70 package rows and7 internal URIs are retained.

Old Browser80 r1 and all previous designs/failures remain unchanged and pinned. Original
r7 a558 analysis stays RED/NOT_ACCEPTED and its actual independent readback/release
evidence is preserved; the one-character correction has no inherited runtime pass.
All80 browser cases in both packages remain UNRUN. No candidate/reporter/observer/native
function, SDK, browser, process API, network or Git command was invoked; no Main/service
or old source/cache was written. Root must independently review source/pins, obtain
another control review, fresh resources/SDK0/unknown0 and an exclusive window, issue a
new explicit grant, and observe actual outer terminal and postflight. No grant/attempt
exists, and no automatic execution or chaining is authorized by these files.
''')
save('static-review.json', {'status': 'STATIC_BROWSER80_R2_REBOUND_REVIEW_REQUIRED_ALL80_UNRUN',
    'sourceCommit': COMMIT, 'sourceManifest': prep['sourceManifest'], 'sourceSnapshotSeal': pin(SNAP / 'out/seal-static-source.json'),
    'sourceFiles': 409, 'sourceSealFilesVerified': len(source_seal['files']),
    'mainAndNewFrozenRawHashesAndMembershipMatched': True, 'gitInvoked': False,
    'gitProvenanceLimit': 'Published seal/Root-provided commit only; Root must independently confirm current Git identities before grant.',
    'onlySourceRowChangedFromA558': PAGE, 'oneByteNullAssertionRemovalVerified': True,
    'all80CaseAndSelectedSourceMetadataIdentical': True, 'preparedCases': 80, 'physicalSuites': 7,
    'controlsBudgetByteIdenticalToR1': unchanged, 'workerOnlyChangedAssignments': changed_nodes,
    'fullRuntimeCacheRehashPerformed': False, 'browserCacheBoundary': 3537,
    'runtimeSourceParserAdded': False, 'candidateImportedOrCalled': False, 'sdkBrowserProcessGitNetworkCalls': 0,
    'attemptExists': False, 'executionApproved': False, 'oldR1FilesPreserved': len(r1_before)})
for row in history:
    verify(row)
assert [pin(p) for p in sorted(R1.iterdir()) if p.is_file()] == r1_before
names = [p.name for p in sorted(ROOT.iterdir()) if p.is_file()]
candidate = [{**pin(ROOT / name), 'path': name} for name in names]
proposal = copy.deepcopy(old_proposal)
proposal.update(status='STATIC_BROWSER80_R2_CANDIDATE_ONLY_NEW_INDEPENDENT_REVIEW_AND_GRANT_REQUIRED',
    sourceCommit=COMMIT, sevenRootGitTrees=manifest['sevenRootGitTrees'],
    inputs={**input_pin, 'absolute': True}, candidateFiles=candidate, historicalMetadataFiles=history,
    sourceSnapshotSeal=pin(SNAP / 'out/seal-static-source.json'), sourceDirectory=str(SNAP / 'src'),
    workingDirectory=str(SNAP / 'src/apps/guardian'), attemptDirectory=str(ROOT / 'attempt'),
    preparationScript=pin(ROOT / 'prepare_browser80_r2.py'), priorBrowser80R1Proposal=pin(R1 / 'proposal.json'),
    priorBrowser80R1IndependentReview=pin(REVIEW / 'review.json'),
    old80CaseAndSelectedSourceMetadataExact=True, source409OnlyOneByteCorrectionFromA558=True,
    oldR7RedSourceCommit='a55849d902b248fe02d06e23cd0bad3d28912a27', oldR7AnalysisStillNotAccepted=True,
    workerOnlyTwoAssignmentsChanged=changed_nodes, unchangedR1Controls=unchanged,
    newExplicitGrantRequired=True, executionApproved=False, actualCasesExecuted=None)
proposal_pin = save('proposal.json', proposal)
receipt_pin = save('seal-receipt.json', {'status': 'STATIC_BROWSER80_R2_SEALED_ALL80_UNRUN_NOT_EXECUTION_AUTHORIZATION',
    'proposal': proposal_pin, 'inputs': input_pin, 'sourceManifest': inputs['sourceManifest'],
    'sourceSnapshotSeal': pin(SNAP / 'out/seal-static-source.json'), 'expectedCaseContract': inputs['expectedCaseContract'],
    'candidateFiles': len(candidate), 'controlRuntimeFiles': len(proposal['controlRuntimeFiles']), 'historicalMetadataFiles': len(history),
    'sourceFiles': 409, 'visibleCases': 80, 'physicalSuites': 7, 'workerOnlyAssignmentsChanged': changed_nodes,
    'sdkCalls': 0, 'browserStarted': False, 'candidateImportedOrCalled': False, 'processInspectionPerformed': False,
    'gitOrNetworkCalls': 0, 'mainOrOldCandidateWrites': False, 'sourceCopied': False, 'cacheCopied': False,
    'attemptExists': False, 'executionApproved': False})
print(json.dumps({'status': 'BROWSER80_R2_SEALED_RUNTIME_UNRUN', 'proposal': proposal_pin, 'seal': receipt_pin,
    'candidateFiles': len(candidate), 'runtimeFiles': len(proposal['controlRuntimeFiles']), 'historicalFiles': len(history),
    'worker': pin(ROOT / 'worker.py'), 'sourceSeal': pin(SNAP / 'out/seal-static-source.json')}, ensure_ascii=False))
