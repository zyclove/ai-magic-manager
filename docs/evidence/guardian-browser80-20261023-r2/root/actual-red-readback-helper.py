"""Root-only post-terminal readback. Stdlib/files only; no imports of candidate code.

Prints one JSON result, writes no files, starts/stops no processes. Root must first
record its real exec-session terminal with its separate prelaunch-QPC helper.
This readback never replaces the later independent full system release gate.
"""
from pathlib import Path
from urllib.parse import urlparse
import collections
import copy
import datetime
import hashlib
import json
import math
import ntpath
import os
import re
import stat
import sys

HERE = Path(__file__).absolute().parent
REPO = HERE.parents[1]
RUN = REPO / '.cache/guardian-browser80-20261023-r2'
ATTEMPT = RUN / 'attempt'
FROZEN = REPO / '.cache/guardian-observation-current-20261023-r2/src'
MODULE = FROZEN / 'apps/guardian'
PROPOSAL_SHA = 'a9951961c2d4a933567bd38446228bb177cc469cdbe23a8d9b42b816f11857be'
SOURCE_COMMIT = '45950b88a270e2fded2409e333fb126851b6f861'
SDK_NAMES = {'aapt2.exe', 'asm.exe', 'cgo.exe', 'compile.exe', 'dart.exe',
    'dartaotruntime.exe', 'flutter.exe', 'flutter_tester.exe', 'gen_snapshot.exe',
    'go.exe', 'gofmt.exe', 'java.exe', 'javac.exe', 'javaw.exe', 'link.exe',
    'qemu-system-x86_64.exe'}
BOOTSTRAP = 'Flutter assets will be downloaded from http://127.0.0.1:9. Make sure you trust this source!'


def require(value, reason):
    if not value:
        raise ValueError(reason)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def norm(path):
    return ntpath.normcase(ntpath.normpath(str(path)))


def safe(path, file=False, single=False):
    path = Path(path)
    require(path.is_absolute(), 'Absolute file boundary required')
    for p in (path, *path.parents):
        if os.path.lexists(p):
            info = p.lstat()
            require(not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400,
                    'Linked path refused: ' + str(p))
    info = path.stat()
    if file:
        require(stat.S_ISREG(info.st_mode), 'Nonregular file refused: ' + str(path))
        if single:
            require(info.st_nlink == 1, 'Multiply linked runtime/cache file refused')
    return info


def pin(path, row=None, single=False):
    path = Path(path)
    before = safe(path, True, single)
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    after = safe(path, True, single)
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns), 'File changed while hashing')
    result = {'path': str(path), 'bytes': after.st_size, 'sha256': digest}
    if row is not None:
        require(result['bytes'] == row['bytes'] and digest == row['sha256'], 'Pin mismatch: ' + str(path))
    return result


def read(path, row=None, maximum=16 * 1024**2):
    got = pin(path, row)
    require(got['bytes'] <= maximum, 'Metadata/report exceeds readback bound')
    value = Path(path).read_bytes()
    require(len(value) == got['bytes'] and hashlib.sha256(value).hexdigest() == got['sha256'], 'Read/hash drift')
    return value


def load(path, row=None):
    return json.loads(read(path, row))


def inventory(base, excluded_dirs=(), excluded_files=()):
    safe(base)
    files, directories = set(), {'.'}
    def fail(error):
        raise error
    for directory, names, entries in os.walk(base, followlinks=False, onerror=fail):
        directory = Path(directory)
        safe(directory)
        for name in names:
            safe(directory / name)
        names[:] = [name for name in names if name not in excluded_dirs]
        for name in names:
            directories.add((directory / name).relative_to(base).as_posix())
        for name in entries:
            if name not in excluded_files:
                safe(directory / name, True)
                files.add((directory / name).relative_to(base).as_posix())
    return files, directories



def partial_report(raw, contract):
    wanted = {(row['selector'], row['name']) for row in contract['cases']}
    require(len(wanted) == len(contract['cases']) == 80 and len(contract['selectors']) == 7, 'Frozen80/7 contract differs')
    suites, groups, tests, finished, seen = {}, {}, {}, {}, set()
    counts = collections.Counter(); previous = -1; errors = []; events = []
    bootstrap = 0
    for line in raw.decode('utf-8-sig').splitlines():
        if not line.strip(): continue
        if line == BOOTSTRAP:
            require(not events and bootstrap == 0, 'Bootstrap output mismatch'); bootstrap += 1; continue
        e = json.loads(line); require(type(e) is dict, 'Malformed event'); events.append(e)
        kind, t = e.get('type'), e.get('time')
        require(type(t) is int and t >= previous and t >= 0 and counts['done'] == 0, 'Event ordering/time differs')
        previous = t; counts[kind] += 1
        if kind == 'start':
            require(len(events) == 1 and counts[kind] == 1 and e['protocolVersion'] == '0.1.1', 'Reporter start differs')
        elif kind == 'allSuites':
            require(counts[kind] == 1 and e['count'] == 7, 'Discovery count differs')
        elif kind in ('suite', 'group', 'testStart'):
            row = e[{'suite':'suite','group':'group','testStart':'test'}[kind]]
            identity = row['id']; require(type(identity) is int and identity >= 0 and identity not in seen, 'Reporter ID differs'); seen.add(identity)
            if kind == 'suite':
                require(row['platform'] == 'chrome', 'Non Chrome suite')
                spelling = row['path']; require(type(spelling) is str and '\x00' not in spelling and '://' not in spelling, 'Suite path malformed')
                absolute = norm(spelling if ntpath.isabs(spelling) else ntpath.join(str(MODULE), spelling))
                require(ntpath.commonpath([norm(MODULE),absolute]) == norm(MODULE), 'Foreign suite')
                selector = ntpath.relpath(absolute,norm(MODULE)).replace('\\','/')
                require(selector in contract['selectors'] and selector not in suites.values(), 'Unexpected/repeated suite'); suites[identity] = selector
            elif kind == 'group':
                sid = row['suiteID']; require(sid in suites and (row['parentID'] is None or groups.get(row['parentID']) == sid), 'Group ownership differs'); groups[identity] = sid
            else:
                sid = row['suiteID']; require(sid in suites and type(row['name']) is str and type(row['groupIDs']) is list, 'Test start malformed')
                require(all(type(g) is int and groups.get(g) == sid for g in row['groupIDs']), 'Test group differs')
                tests[identity] = {'testID':identity,'selector':suites[sid],'name':row['name']}
        elif kind == 'testDone':
            identity = e['testID']; require(identity in tests and identity not in finished, 'Test completion differs')
            require(e['result'] == 'success' and e['skipped'] is False and type(e['hidden']) is bool, 'Unexpected failure/skip'); finished[identity] = e['hidden']
        elif kind == 'print': require(e['testID'] in tests and e['messageType'] == 'print' and type(e['message']) is str, 'Unexpected print')
        elif kind == 'error': errors.append(e)
        elif kind == 'done': require(type(e.get('success')) is bool, 'Malformed done')
        else: raise ValueError('Unknown reporter event ' + str(kind))
    visible = [tests[i] for i in finished if not finished[i]]
    hidden = [tests[i] for i in finished if finished[i]]
    pending = [row for i,row in tests.items() if i not in finished]
    pairs = [(row['selector'],row['name']) for row in visible]
    require(len(pairs) == len(set(pairs)) == 54 and set(pairs) <= wanted, 'Actual54 success names differ')
    require(all((row['selector'],row['name']) not in wanted for row in hidden), 'Expected case hidden')
    require(len(suites) == 6 and counts['start'] == counts['allSuites'] == 1 and counts['done'] == 0 and not errors, 'Actual partial6/noDone/noErrors differs')
    require(len(pending) == 1 and pending[0]['name'] == 'standalone void dialog permits a covered retry but rejects held submit immediately after its own close completes the route', 'Actual pending standalone case differs')
    require((pending[0]['selector'],pending[0]['name']) in wanted, 'Pending is outside selected scope')
    return {'status':'INCOMPLETE_BROWSER80_REPORT_NOT_ACCEPTED','suiteCount':6,'visibleSuccessfulTests':54,
        'successfulVisibleCases':visible,'hiddenSuccessfulTests':hidden,'pendingTests':pending,
        'errorEvents':0,'donePresent':False,'all80Executed':False,'uncompletedExpectedCases':[
            {'selector':s,'name':n} for s,n in sorted(wanted-set(pairs))],'eventCount':len(events)}


def main():
    terminal = load(REPO / '.cache/guardian-browser80-r2-root-actual-terminal-20261023.json')
    anchor = load(REPO / '.cache/guardian-browser80-r2-root-prelaunch-20261023.json')
    require(anchor['status'] == 'ROOT_PRELAUNCH_QPC_ANCHOR_NO_SDK_STARTED' and anchor['proposalSha256'] == PROPOSAL_SHA, 'Root prelaunch anchor differs')
    require(terminal['status'] == 'ACTUAL_EXEC_SESSION_TERMINAL_OBSERVED' and terminal['actualSession'] == 84534
            and terminal['initialChunk'] == '939a2c' and terminal['finalChunk'] == 'c39c42' and terminal['naturalExitCode'] == 1, 'Actual same-session outer natural1 differs')
    require(finite(terminal['monotonic']) and finite(anchor['monotonic']) and terminal['anchorToAfterToolTerminalSeconds'] == terminal['monotonic']-anchor['monotonic']
            and 0 < terminal['anchorToAfterToolTerminalSeconds'] < 300 and terminal['conservativeActualOuterTerminalBefore300'] is True
            and terminal['candidateReceiptElapsedNotUsedAsOuterExitProof'] is True, 'Independent actual outer terminal not proved')
    require(pin(RUN / 'proposal.json')['sha256'] == PROPOSAL_SHA, 'Proposal differs')
    proposal = load(RUN / 'proposal.json'); require(proposal['sourceCommit'] == SOURCE_COMMIT, 'Source commit differs')
    rows = proposal['candidateFiles'] + proposal['controlRuntimeFiles'] + proposal['historicalMetadataFiles']
    require(len(rows) == 381, 'Expected381 pins')
    for row in rows: pin(Path(row['path']) if row.get('absolute') else RUN / row['path'], row)
    inputs = load(RUN / 'inputs.json', proposal['inputs'])
    result, receipt, launch = [load(ATTEMPT / name) for name in ('result.json','receipt.json','launch.json')]
    require(result['workerReceipt'] == receipt and result['status'] == receipt['status'] == 'NOT_ACCEPTED', 'Actual RED status differs')
    require(result['workerPid'] == 32892 and result['workerExitCode'] == 1 and launch['pid'] == 61824 and launch['commandBudgetSeconds'] == 210, 'Actual IDs/deadline differ')
    require(result['ownedJobActiveProcesses'] == result['ownedJobActiveProcessesFinal'] == 0 and not result['ownedCleanupPerformed']
            and not result['watchdogExpired'] and not result['sdkProcessesAfter'] and not result['unknownProcessNames']
            and result['postCandidateAndControlRuntimeMismatches'] == [], 'Outer containment/pin/resource mismatch')
    require(result['phaseScope'] == receipt['phaseScope'] == 'BROWSER80_OWNED_AUX' and result['legacyStrictAccepted'] is False
            and receipt['legacyStrictAccepted'] is False and receipt['errorType'] == 'RuntimeError'
            and receipt['reason'] == 'SDK command deadline exceeded', 'Actual scope/reason differs')
    require(receipt['sdkCalls'] == 1 and receipt['testsRequested'] is True and not receipt['pubRun'] and not receipt['downloadsAllowed']
            and receipt['forcedTermination'] is True and receipt['commandTreeForced'] is True and receipt['auxCleanup'] is False
            and receipt['sdkRootNaturalZero'] is False and receipt['sdkForced'] is None
            and receipt['commandTreeCloseFallbackRequested'] is False, 'RED forced/unknown scope must stay honest')
    require(result['commandTreeForced'] is True and result['auxCleanup'] is False and result['sdkRootNaturalZero'] is False, 'Outer RED scope differs')
    for state in (receipt['commandTerminalState'],receipt['commandTerminalStateAfterPostflight']):
        require(state['pid'] == 61824 and state['rootHandleSignaled'] is True and state['rootExitCode'] == 124 and state['activeProcesses'] == 0
                and state['terminalVerified'] is True and state['timedOut'] is True and state['terminationRequested'] is True
                and state['terminationCallSucceeded'] is True, 'Actual forced-timeout native terminal differs')
    binding = result['workerBudgetHandshake']; require(receipt['outerBudgetBinding'] == binding, 'Budget binding differs')
    start, hard, soft, finish = [binding[k] for k in ('outerStartedMonotonic','outerHardMonotonic','outerSoftMonotonic','workerFinishByMonotonic')]
    require(all(finite(v) for v in (start,hard,soft,finish,receipt['workerHardMonotonic'],result['workerTerminalObservedMonotonic'])), 'Invalid worker clocks')
    require(binding['protocol'] == 'OWNED_JOB_READY_BROWSER80_V2' and binding['clockImplementation'] == 'QueryPerformanceCounter()'
            and hard == start+300 and soft == hard-6 and finish == soft-6 and binding['controllerFinalReserveSeconds'] == 6, 'Budget300/294/288 differs')
    require(result['workerTerminalBudgetAccepted'] is True and result['workerTerminalObservationSource'] == 'retained Popen.poll'
            and result['workerTerminalExitCodeObserved'] == 1 and start <= result['workerTerminalObservedMonotonic'] < receipt['workerHardMonotonic'] <= finish
            and anchor['monotonic'] <= start < terminal['monotonic'] < hard, 'Actual worker/outer timing differs')
    require(receipt['postflightReservedSecondsAtStart'] >= 45 and receipt['postflightWindowStartedMonotonic'] <= receipt['workerHardMonotonic']-45, 'Full postflight reserve missing')
    for name in ('initial-gate.json','launch-gate.json','postflight-gate.json'):
        gate = load(ATTEMPT / name); require(not gate['sdkProcesses'] and not gate['unknownProcessNames'], 'Recorded SDK/unknown gate differs')
    logpath = ATTEMPT / 'out/browser80.jsonl'; logpin = pin(logpath,receipt['logPin'])
    require(logpin['bytes'] == 32505 and logpin['sha256'] == '5e537a317c9acc32b73f267d387f8df20cdb538b6f18a7c4392e74ee1f6c28c0', 'Actual RED raw log differs')
    contract = load(Path(inputs['expectedCaseContract']['path']), inputs['expectedCaseContract'])
    partial = partial_report(read(logpath),contract)
    manifest = load(Path(inputs['sourceManifest']['path']), inputs['sourceManifest'])
    require(manifest['head'] == SOURCE_COMMIT and manifest['sourceCount'] == len(manifest['sourceFiles']) == 409 and len(manifest['roots']) == 7, 'Source manifest boundary')
    excluded = inputs['generatedExclusions']
    require(set(excluded['directories']) == {'.dart_tool', '.idea', 'build'} and set(excluded['files']) ==
            {'.flutter-plugins', '.flutter-plugins-dependencies', 'device_operations_showcase.iml', 'guardian.iml'}, 'Unexpected source exclusions')
    expectedpaths = {row['path'] for row in manifest['sourceFiles']}
    for base, prefix in ((REPO, 'workingTreeRaw'), (FROZEN, '')):
        actual = set()
        for rootpath in manifest['roots']:
            members, _ = inventory(base / rootpath, excluded['directories'], excluded['files'])
            actual.update(rootpath + '/' + name for name in members)
        require(actual == expectedpaths and len(actual) == 409, 'Source complete membership differs')
        for row in manifest['sourceFiles']:
            expected = {'bytes': row['workingTreeRawBytes'], 'sha256': row['workingTreeRawSha256']} if prefix else row
            pin(base / row['path'], expected)
            if not prefix:
                value = read(base / row['path'])
                require(hashlib.sha1(b'blob ' + str(len(value)).encode() + b'\0' + value).hexdigest() == row['gitBlob'], 'Raw committed blob SHA1 differs')
    original = load(Path(inputs['originalPackageConfig']['path']), inputs['originalPackageConfig'])
    candidate = load(Path(inputs['candidatePackageConfig']['path']), inputs['candidatePackageConfig'])
    template = load(Path(inputs['candidatePackageConfigTemplate']['path']), inputs['candidatePackageConfigTemplate'])
    seed = load(Path(inputs['dependencyLibraryPins']['path']), inputs['dependencyLibraryPins'])
    require(len(original['packages']) == len(seed['packageMappings']) == 70 and len(inputs['internalPackageRoots']) == 7, 'Package count differs')
    require(len({row['name'] for row in original['packages']}) == 70 and {row['name'] for row in seed['packageMappings']} == {row['name'] for row in original['packages']}, 'Package names differ')
    expectedconfig = copy.deepcopy(original)
    for row in expectedconfig['packages']:
        if row['name'] in inputs['internalPackageRoots']:
            target = FROZEN / inputs['internalPackageRoots'][row['name']]
            row['rootUri'] = target.as_uri()
            require(re.search(r'(?m)^name:\s*(\S+)\s*$', read(target / 'pubspec.yaml').decode()).group(1) == row['name'], 'Internal pubspec name differs')
    require(candidate == template == expectedconfig and Path(inputs['candidatePackageConfig']['path']) == MODULE / '.dart_tool/package_config.json', '70 packages/metadata/7 internal/63 external differ')
    cache = load(Path(inputs['cacheManifest']['path']), inputs['cacheManifest'])
    basecache = load(Path(inputs['browserCacheBaseManifest']['path']), inputs['browserCacheBaseManifest'])
    require(len(cache['trees']) == 70 and len(cache['fixedFiles']) == 33 and cache['totals']['files'] == 3537 and cache['fullAllowlistCollected'], 'Full3537 cache boundary')
    refreshed = copy.deepcopy(basecache)
    chromerows = [row for row in refreshed['fixedFiles'] if norm(row['path']) == norm(inputs['chromeExecutablePin']['path'])]
    require(len(chromerows) == 1, 'Expected one existing Chrome row')
    oldchrome = copy.deepcopy(chromerows[0]); chrome = inputs['chromeExecutablePin']
    chromerows[0].update(bytes=chrome['bytes'], sha256=chrome['sha256'])
    if 'expectedSha256' in chromerows[0]:
        chromerows[0]['expectedSha256'] = chrome['sha256']
    refreshed['totals']['bytes'] += chrome['bytes'] - oldchrome['bytes']
    refreshed['status'] = 'BROWSER_CHROME_REFRESH_FROM_FIXED_BASE_NOT_RUNTIME_VALIDATION'
    change = cache['browserChromeRefresh']
    require(change['baseManifestSha256'] == inputs['browserCacheBaseManifest']['sha256'] and change['originalChromeRow'] == oldchrome
            and change['approvedChromeExecutable'] == chrome and change['onlyExistingChromeExecutableRowRefreshed'] is True
            and change['otherPinnedFilesKeptWithoutRebaseline'] == 3536, 'Chrome-only cache provenance differs')
    refreshed['browserChromeRefresh'] = change
    require(refreshed == cache, 'Other cache metadata was changed')
    files = totalbytes = 0
    for tree in cache['trees']:
        rootpath = Path(tree['root'])
        members, directories = inventory(rootpath)
        require(members == {row['relativePath'] for row in tree['entries']} and len(members) == len(tree['entries'])
                and directories == set(tree['directories']), 'Cache complete membership/directories differ')
        canonical = []
        treebytes = 0
        for row in sorted(tree['entries'], key=lambda item: item['relativePath']):
            got = pin(rootpath / row['relativePath'], row, True)
            canonical.append(f"{row['relativePath']}\0{got['bytes']}\0{got['sha256']}\n")
            treebytes += got['bytes']
        require(hashlib.sha256(''.join(canonical).encode()).hexdigest() == tree['treeSha256']
                and tree['files'] == len(members) and treebytes == tree['bytes'], 'Cache canonical tree pin differs')
        files += len(members); totalbytes += treebytes
    for row in cache['fixedFiles']:
        pin(Path(row['path']), row, True)
        files += 1; totalbytes += row['bytes']
    require({'files': files, 'bytes': totalbytes} == cache['totals'], 'Cache totals differ')
    for name in ('preflight-pins.json', 'postflight-pins.json'):
        phase = load(ATTEMPT / name)
        require(phase['complete'] is True and phase['source']['frozenRawGit']['files'] == phase['source']['mainRaw']['files'] == 409
                and phase['source']['currentSevenRootGitTrees'] == inputs['sevenRootGitTrees']
                and phase['packages']['packages'] == 70 and phase['packages']['metadataPreserved'] is True
                and phase['cache']['allMembersDirectoriesBytesAndHashesMatch'] is True and phase['cache']['totals'] == cache['totals'], 'Incomplete actual pre/post boundary')
    require(receipt['postflight'] == load(ATTEMPT / 'postflight-pins.json'), 'Embedded postflight differs')
    for row in rows:
        pin(Path(row['path']) if row.get('absolute') else RUN / row['path'], row)

    print(json.dumps({'status':'BROWSER80_RED_BYTES_AND_ACTUAL_TERMINAL_INDEPENDENTLY_CONFIRMED_AWAIT_FRESH_SYSTEM_RELEASE',
        'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceCommit':SOURCE_COMMIT,
        'actualSession':84534,'initialChunk':'939a2c','finalChunk':'c39c42','naturalExitCode':1,
        'actualOuterAnchorToAfterToolTerminalSeconds':terminal['anchorToAfterToolTerminalSeconds'],
        'candidatePreIoElapsedNotUsedAsOuterExit':True,'candidateRecordedElapsedSeconds':result['elapsedCompleteSeconds'],
        'actualCandidateStatus':'NOT_ACCEPTED','sdkRootExitCode':124,'commandTimedOut':True,'commandTreeForced':True,
        'forcedTermination':True,'auxCleanup':False,'sdkRootNaturalZero':False,'sdkForced':None,
        'outerCleanupPerformed':False,'outerWatchdogExpired':False,'ownedJobActiveProcesses':0,
        'pinsMatched':381,'sourceFilesIndependentlyRehashedBothTrees':409,'packages':70,'internalRebases':7,'externalRowsUnchanged':63,
        'cacheFilesIndependentlyRehashed':files,'cacheBytesIndependentlyRehashed':totalbytes,'cacheWholeMembershipAndDirectoriesMatched':True,
        'rawLogPin':logpin,'rawPartialReport':partial,'browser80Accepted':False,'legacyStrictAccepted':False,
        'fullOsSdkAndUnknownInventoryQueriedByThisHelper':False,'formalSystemReleaseGranted':False,
        'candidateImported':False,'sdkCalls':0,'processApiCalls':0,'filesWritten':False,'servicesUpdated':False,'wholeProductAccepted':False},ensure_ascii=False))


if __name__ == '__main__':
    main()
