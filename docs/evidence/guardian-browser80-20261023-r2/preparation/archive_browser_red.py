"""Exact raw Browser80-r2 RED evidence archive; no candidate/runtime execution."""
from pathlib import Path
import collections
import hashlib
import json
import ntpath
import os
import stat

BASE = Path(__file__).absolute().parent
REPO = BASE.parents[1]
RUN = REPO / '.cache/guardian-browser80-20261023-r2'
OUT = REPO / 'docs/evidence/guardian-browser80-20261023-r2'
PARENT = 'ab6d01becf72ce83a6159fcc59d08a42d963beb8'
SOURCE = '45950b88a270e2fded2409e333fb126851b6f861'


def sha(value):
    return hashlib.sha256(value).hexdigest()


def raw(path):
    path = Path(path)
    for p in (path, *path.parents):
        if os.path.lexists(p):
            info = p.lstat()
            assert not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400, str(p)
    before = path.stat()
    value = path.read_bytes()
    after = path.stat()
    assert (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    assert stat.S_ISREG(after.st_mode)
    return value


def load(path):
    return json.loads(raw(path))


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def pinned(path, row):
    value = raw(path)
    assert len(value) == row['bytes'] and sha(value) == row['sha256'], str(path)
    return value


def create(path, value):
    assert path.is_relative_to(BASE) or path.is_relative_to(OUT)
    for p in path.parents:
        if p.exists():
            info = p.lstat()
            assert not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as stream:
        stream.write(value); stream.flush(); os.fsync(stream.fileno())
    assert raw(path) == value


assert not OUT.exists(), 'An existing archive is never overwritten'
proposal = load(RUN / 'proposal.json')
assert sha(raw(RUN / 'proposal.json')) == 'a9951961c2d4a933567bd38446228bb177cc469cdbe23a8d9b42b816f11857be'
assert proposal['sourceCommit'] == SOURCE
candidate, runtime, historical = [proposal[key] for key in ('candidateFiles', 'controlRuntimeFiles', 'historicalMetadataFiles')]
assert [len(candidate), len(runtime), len(historical)] == [19, 11, 351]
result, receipt, launch = [load(RUN / 'attempt' / name) for name in ('result.json', 'receipt.json', 'launch.json')]
external_path = REPO / '.cache/guardian-browser80-r2-root-independent-red-readback-20261023.json'
gate_path = REPO / '.cache/guardian-browser80-r2-root-final-system-gate-20261023.json'
terminal_path = REPO / '.cache/guardian-browser80-r2-root-actual-terminal-20261023.json'
external, gate, terminal = map(load, (external_path, gate_path, terminal_path))
assert result['status'] == receipt['status'] == 'NOT_ACCEPTED' and result['workerReceipt'] == receipt
assert result['workerPid'] == 32892 and result['workerExitCode'] == 1 and launch['pid'] == 61824
assert launch['commandBudgetSeconds'] == 210
assert result['ownedJobActiveProcesses'] == result['ownedJobActiveProcessesFinal'] == 0
assert not result['ownedCleanupPerformed'] and not result['watchdogExpired']
assert result['postCandidateAndControlRuntimeMismatches'] == []
assert receipt['forcedTermination'] and receipt['commandTreeForced'] and not receipt['auxCleanup']
assert not receipt['sdkRootNaturalZero'] and receipt['sdkForced'] is None and not receipt['commandTreeCloseFallbackRequested']
assert receipt['reason'] == 'SDK command deadline exceeded'
for state in (receipt['commandTerminalState'], receipt['commandTerminalStateAfterPostflight']):
    assert state['rootExitCode'] == 124 and state['pid'] == 61824 and state['activeProcesses'] == 0
    assert state['timedOut'] and state['terminationRequested'] and state['terminationCallSucceeded'] and state['terminalVerified']
assert external['status'] == 'BROWSER80_RED_BYTES_AND_ACTUAL_TERMINAL_INDEPENDENTLY_CONFIRMED_AWAIT_FRESH_SYSTEM_RELEASE'
assert external['pinsMatched'] == 381 and external['sourceFilesIndependentlyRehashedBothTrees'] == 409
assert external['cacheFilesIndependentlyRehashed'] == 3537 and external['cacheBytesIndependentlyRehashed'] == 638537951
assert external['browser80Accepted'] is False
assert gate['status'] == 'BROWSER80_R2_NOT_ACCEPTED_FORMALLY_RELEASED' and gate['formalRelease']
assert gate['sdkCount'] == gate['unknownProcessNameCount'] == gate['ownedJobActiveProcesses'] == 0
assert gate['knownOwnedPidsAbsent'] and gate['independentReadbackActualSession'] == 35508 and gate['independentReadbackFinalChunk'] == 'fa939c'
assert gate['browser80Accepted'] is False and not gate['servicesUpdated'] and not gate['wholeProductAccepted']
assert terminal['actualSession'] == gate['actualSession'] == external['actualSession'] == 84534
assert terminal['initialChunk'] == gate['initialChunk'] == external['initialChunk'] == '939a2c'
assert terminal['finalChunk'] == gate['finalChunk'] == external['finalChunk'] == 'c39c42'
assert terminal['naturalExitCode'] == gate['naturalOuterExitCode'] == external['naturalExitCode'] == 1
assert 0 < terminal['anchorToAfterToolTerminalSeconds'] < 300 and terminal['conservativeActualOuterTerminalBefore300']
assert terminal['candidateReceiptElapsedNotUsedAsOuterExitProof']

# Count actual raw events independently; original bytes are the canonical name evidence.
log = pinned(RUN / 'attempt/out/browser80.jsonl', receipt['logPin'])
assert len(log) == 32505 and sha(log) == '5e537a317c9acc32b73f267d387f8df20cdb538b6f18a7c4392e74ee1f6c28c0'
events = [json.loads(line) for line in log.decode('utf-8-sig').splitlines() if line.strip() and line.startswith('{')]
counts = collections.Counter(e['type'] for e in events)
starts = {e['test']['id']: e['test'] for e in events if e['type'] == 'testStart'}
done = {e['testID']: e for e in events if e['type'] == 'testDone'}
visible = [starts[i] for i,e in done.items() if not e['hidden']]
pending = [row for i,row in starts.items() if i not in done]
assert len(visible) == 54 and len(pending) == 1 and counts['suite'] == 6 and counts['done'] == counts['error'] == 0
assert all(e['result'] == 'success' and e['skipped'] is False for e in done.values())
assert pending[0]['name'] == 'standalone void dialog permits a covered retry but rejects held submit immediately after its own close completes the route'
assert external['rawPartialReport']['visibleSuccessfulTests'] == 54 and external['rawPartialReport']['suiteCount'] == 6
assert not external['rawPartialReport']['donePresent'] and len(external['rawPartialReport']['pendingTests']) == 1
for name in ('preflight-pins.json', 'postflight-pins.json'):
    phase = load(RUN / 'attempt' / name)
    assert phase['complete'] and phase['source']['mainRaw']['files'] == phase['source']['frozenRawGit']['files'] == 409
    assert phase['packages']['packages'] == 70 and phase['cache']['totals'] == {'files': 3537, 'bytes': 638537951}

copies = {}
def add(source, target, row=None):
    source = Path(source)
    assert source.is_relative_to(REPO) and 'tmp' not in source.relative_to(REPO).parts
    assert 'src' not in source.relative_to(REPO).parts
    value = pinned(source, row) if row else raw(source)
    assert len(value) < 2 * 1024**2 and target not in copies and '..' not in Path(target).parts
    copies[target] = (value, str(source))


for row in candidate:
    add(RUN / row['path'], 'candidate/' + row['path'], row)
for name in ('proposal.json', 'seal-receipt.json', 'delivery-pins.json', 'static-final-readback.json'):
    add(RUN / name, 'candidate/' + name)
for directory, folders, names in os.walk(RUN / 'attempt', followlinks=False):
    folders[:] = [name for name in folders if name != 'tmp']
    for name in names:
        path = Path(directory) / name
        add(path, 'attempt/' + path.relative_to(RUN / 'attempt').as_posix())
for path, name in ((external_path, 'actual-independent-red-readback.json'),
                   (gate_path, 'final-system-gate.json'), (terminal_path, 'actual-outer-terminal.json')):
    add(path, 'root/' + name)
for name, target in (
    ('guardian-browser80-r2-root-preflight-system-20261023.json', 'preflight-system-gate.json'),
    ('guardian-browser80-r2-root-prelaunch-20261023.json', 'prelaunch-qpc-anchor.json'),
    ('guardian-browser80-r2-root-timing-20261023.py', 'timing-helper.py'),
    ('guardian-browser80-r2-root-launch-20261023.ps1', 'launch.ps1'),
    ('guardian-browser80-r2-root-static-review-20261023.json', 'static-review.json'),
    ('guardian-browser80-r2-root-static-review-20261023.py', 'static-review.py')):
    add(REPO / '.cache' / name, 'root/' + target)
helper = REPO / '.cache/guardian-browser80-r2-independent-post-20261023/readback-red.py'
assert sha(raw(helper)) == 'cb8afb603e800ac94ef59b20002096ffa8c375f004ea5974561048583b82fbf9'
add(helper, 'root/actual-red-readback-helper.py')
for name in ('review.md', 'review.json', 'report-pins.json'):
    add(REPO / '.cache/guardian-browser80-independent-20261023-r2' / name, 'reviews/independent-' + name)
inputs = load(RUN / 'inputs.json')
contract_pin = inputs['expectedCaseContract']
add(Path(contract_pin['path']), 'inputs/expected-80-cases.json', contract_pin)
add(Path(__file__), 'preparation/archive_browser_red.py')

# Keep descriptor groups in their original proposal, without copying historical/runtime/cache/source trees.
facts = {'status': 'BROWSER80_R2_RED_NOT_ACCEPTED_FORMALLY_RELEASED', 'browser80Accepted': False,
    'sourceCommit': SOURCE, 'sourceFiles': 409, 'actualSession': 84534, 'initialChunk': '939a2c', 'finalChunk': 'c39c42',
    'naturalOuterExitCode': 1, 'candidateRecordedOuterSeconds': result['elapsedCompleteSeconds'],
    'actualOuterAnchorToAfterTerminalSeconds': terminal['anchorToAfterToolTerminalSeconds'],
    'actualOuterTerminalBefore300': True, 'candidatePreIoElapsedUsedAsActualOuterExit': False,
    'workerPid': 32892, 'workerExitCode': 1, 'nativePid': 61824, 'nativeExitCode': 124, 'commandDeadlineSeconds': 210,
    'commandTimedOut': True, 'commandTreeForced': True, 'forcedTermination': True, 'auxCleanup': False,
    'sdkRootNaturalZero': False, 'sdkForced': None, 'legacyStrictAccepted': False,
    'outerCleanupPerformed': False, 'outerWatchdogExpired': False, 'ownedJobActiveProcesses': 0,
    'physicalSuitesObserved': 6, 'physicalSuitesExpected': 7, 'successfulVisibleCases': 54,
    'expectedVisibleCases': 80, 'pendingCases': 1, 'pendingCaseName': pending[0]['name'],
    'errorEvents': 0, 'terminalDonePresent': False, 'entire80Executed': False,
    'uncompletedExpectedCasesIncludingPending': 26,
    'sourcePrePostComplete': True, 'packageRows': 70, 'cacheFiles': 3537, 'cacheBytes': 638537951,
    'proposalDescriptors': 381, 'candidateDescriptors': 19, 'directRuntimeDescriptors': 11, 'historicalDescriptors': 351,
    'descriptorListsPreservedVerbatimIn': 'candidate/proposal.json',
    'historicalOrRuntimeContentsRecopied': False, 'rawLogSha256': sha(log), 'rawLogBytes': len(log),
    'independentReadbackActualSession': 35508, 'independentReadbackInitialChunk': 'c871f0', 'independentReadbackFinalChunk': 'fa939c',
    'firstRestrictedReadback': 'f77542 WinError5; no output file; never treated as completed',
    'formalRelease': True, 'formalReleaseAtUtc': gate['atUtc'], 'sdkCountAtRelease': 0, 'unknownProcessNameCountAtRelease': 0,
    'availableRamBytesAtRelease': gate['availableRamBytes'], 'formalReleaseIsNotBrowserAcceptance': True,
    'preparationAndStaticReviewUnrunCheckpointsPreserved': True,
    'followupSchedulingCorrection': 'Separate UNRUN candidate; no correction or successful rerun inferred here',
    'r8AcceptedAnalysisIsSeparate': 'docs/evidence/guardian-full-analysis-20261023-r8',
    'servicesUpdated': False, 'wholeProductAccepted': False, 'archiverSdkOrProcessOrNetworkOrGitCalls': 0}
copies['summary.json'] = (encode(facts), None)
copies['.gitattributes'] = (b'* -text\n', None)
readme = f'''# Guardian Browser80 r2 — RED

**NOT_ACCEPTED.** Source {SOURCE}. Retained outer session84534
(939a2c → c39c42) exited naturally with1. The210-second command deadline was
exceeded; the owned native tree was terminated with124/timeout. Outer cleanup
was false, watchdog was false, and final private Jobs0. This was not an accepted
owned non-SDK auxiliary cleanup: sdkRootNaturalZero=false and sdkForced remains
unknown/null. Containment does not turn the test run green.

Raw reporter evidence contains54 successful visible cases,1 pending standalone
void dialog case,6 observed suites, no error event and **no terminal done**.
The selected batch was80 cases/7 suites: the other26 cases include the pending
case and were not completed. These are partial successes, not a passed batch.
Exact names come from the raw UTF-8 JSONL and the retained expected80 contract.

Candidate pre-I/O outer elapsed was{result['elapsedCompleteSeconds']} seconds.
The independent prelaunch-QPC anchor and observation after the actual same-session
terminal establish{terminal['anchorToAfterToolTerminalSeconds']} seconds, below300.
The candidate's pre-I/O elapsed is not used as proof of actual outer exit.

Original complete pre/post checks and Root's independent post-terminal readback
covered381 pins,409 Main/frozen source files,70 package mappings and the full
3537-file /638537951-byte browser cache including Chrome. Root readback session
35508 (c871f0 → fa939c) returned natural0 as a RED evidence check. Its earlier
restricted WinError5 attempt was not a completed readback. The subsequent fresh
full system gate formally released SDK0/unknown0 and confirmed owned PIDs absent.
Release acknowledges ownership/resource closure; browser80 remains NOT_ACCEPTED.

Exact19 candidate files, proposal/seal, actual non-tmp attempt metadata/log,
Root receipts/launch/timing/readback sources, independent reviews and expected
contract are preserved raw. All381 descriptor lists remain in the exact original
proposal. No runtime binaries, cache contents, temporary files or application
source trees are copied. Archived scripts retain original paths as evidence.

Preparation UNRUN seals are historical checkpoints. A later test-scheduling
correction is a separate UNRUN candidate and does not rewrite this failed run.
The accepted r8 full analysis is a separate archive. Services were not updated;
deployment and whole-product completion are not implied.
'''
copies['README.md'] = (readme.encode('utf-8'), None)
inventory = {'status': 'RAW_BROWSER80_R2_RED_EVIDENCE_ONLY_NOT_EXECUTABLE', 'parentExplicitlyProvidedByRoot': PARENT,
    'sourceCommit': SOURCE, 'files': [{'archivePath': target, 'bytes': len(value), 'sha256': sha(value), 'originalPath': source}
        for target,(value,source) in sorted(copies.items())],
    'descriptorGroupsRetainedInExactProposal': {'candidate': 19, 'controlRuntime': 11, 'historicalMetadata': 351, 'total': 381},
    'runtimeContentsCopied': False, 'cacheContentsCopied': False, 'applicationSourceTreeCopied': False, 'tmpCopied': False}
copies['archive-inventory.json'] = (encode(inventory), None)
assert sum(len(value) for value,_ in copies.values()) < 4*1024**2
stage = []
for target,(value,source) in sorted(copies.items()):
    create(OUT / target,value)
    stage.append({'path': (OUT/target).relative_to(REPO).as_posix(), 'bytes': len(value), 'sha256': sha(value),
        'gitRawBlobSha1': hashlib.sha1(b'blob '+str(len(value)).encode()+b'\0'+value).hexdigest(), 'originalPath': source})
create(BASE / 'stage-pins.json', encode({'status': 'EXACT_BROWSER80_R2_RED_STAGE_PLAN_NOT_GIT_OPERATION',
    'parentExplicitlyProvidedByRoot': PARENT, 'files': stage, 'changedMainSourceFiles': [],
    'scope': 'Only this new RED evidence archive; no Git/index/Main/foreign changes'}))
print(json.dumps({'status': 'BROWSER80_R2_RED_EVIDENCE_WRITTEN_NOT_COMMITTED', 'files': len(stage),
    'bytes': sum(row['bytes'] for row in stage), 'rawCopies': sum(source is not None for value,source in copies.values()),
    'stagePlan': str(BASE/'stage-pins.json'), 'sdkCalls': 0, 'gitWritten': False, 'mainWritten': False}))
