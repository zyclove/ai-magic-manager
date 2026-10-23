"""Static candidate: one fixed full Guardian analysis, gated by Root's frozen input."""
import sys
if sys.stdin.readline().strip() != 'OWNED_JOB_READY':
    raise SystemExit('Owned job handshake missing; no SDK started')

import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import psutil

START = time.monotonic()
HARD = START + 165
CANDIDATE = Path(__file__).absolute().parent
ATTEMPT = CANDIDATE / 'attempt'
REPO = CANDIDATE.parents[1]
FROZEN = REPO / '.cache/guardian-reports-current-20261023-r1'
SOURCE = FROZEN / 'src'
MODULE = SOURCE / 'apps/guardian'
INPUT = CANDIDATE / 'inputs.json'
INPUT_SHA256 = 'c89ddfc7b6a1725fc23027f8b27cd73fe0aefd6f6501a344aa8bf2ecfc4749ab'
HELPER_SHA256 = '4965e39eecfe70c7eeeb7ce317c0c06f4ae484d36f025706fff3a669cec4ab12'
ROOTS = ['apps/guardian', 'packages/audit_client', 'packages/commerce_contracts',
         'packages/notification_client', 'packages/device_operations',
         'packages/usage_reporting', 'packages/usage_report_ui']
CMD = Path('C:/Windows/System32/cmd.exe')
FLUTTER = Path('D:/softwares/flutter/bin/flutter.bat')
SDK = FLUTTER.parent.parent
FLAGS = ['--no-version-check', '--suppress-analytics', 'analyze', '--no-pub',
         '--fatal-infos', '--fatal-warnings']
GENERATED_DIRS = {'.dart_tool', 'build', '.idea'}
GENERATED_FILES = {'.flutter-plugins', '.flutter-plugins-dependencies',
                   'guardian.iml', 'device_operations_showcase.iml'}
SDK_NAMES = {'java.exe', 'javaw.exe', 'javac.exe', 'dart.exe', 'dartaotruntime.exe',
             'go.exe', 'gofmt.exe', 'flutter.exe', 'flutter_tester.exe', 'gen_snapshot.exe',
             'aapt2.exe', 'qemu-system-x86_64.exe', 'compile.exe', 'link.exe', 'asm.exe', 'cgo.exe'}
REPARSE = 0x400


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def budget():
    require(time.monotonic() < HARD, 'Complete worker budget of 165 seconds exceeded')


def save(name, value):
    with (ATTEMPT / name).open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def safe(path):
    path = Path(path)
    require(path.is_absolute() and not str(path).startswith('\\\\')
            and ':' not in str(path)[2:], 'Nonlocal/relative/ADS input refused')
    for item in (path, *path.parents):
        info = item.lstat()
        require(not getattr(info, 'st_file_attributes', 0) & REPARSE,
                'Linked/reparse input refused: ' + str(item))
    return path


def pin(path, single_link=False):
    budget()
    path = safe(path)
    before = path.stat()
    require(path.is_file(), 'Expected regular file: ' + str(path))
    if single_link:
        require(before.st_nlink == 1, 'Hard-linked cache input refused: ' + str(path))
    digest = hashlib.sha256()
    total = 0
    with path.open('rb') as stream:
        while True:
            budget()
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            digest.update(chunk)
    after = safe(path).stat()
    require((before.st_dev, before.st_ino, before.st_nlink, before.st_size, before.st_mtime_ns)
            == (after.st_dev, after.st_ino, after.st_nlink, after.st_size, after.st_mtime_ns)
            and total == before.st_size, 'Input changed while hashing: ' + str(path))
    return {'path': str(path), 'bytes': total, 'sha256': digest.hexdigest()}


def verify_pin(row):
    actual = pin(Path(row['path']))
    require(actual['bytes'] == row['bytes'] and actual['sha256'] == row['sha256'],
            'Pinned input changed: ' + row['path'])
    return actual


def load_pin(row):
    verify_pin(row)
    return json.loads(Path(row['path']).read_bytes())


def relative(root, name):
    part = Path(name)
    require(not part.is_absolute() and '..' not in part.parts and ':' not in name,
            'Invalid frozen relative path')
    result = root / part
    result.relative_to(root)
    return result


def inventory(root, generated=False):
    safe(root)
    require(root.is_dir(), 'Expected input directory: ' + str(root))
    files, directories = set(), set()
    def walk_error(error):
        raise error
    for directory, folders, names in os.walk(root, followlinks=False, onerror=walk_error):
        budget()
        base = safe(Path(directory))
        if generated:
            folders[:] = [name for name in folders if name not in GENERATED_DIRS]
            names = [name for name in names if name not in GENERATED_FILES]
        directories.add(base.relative_to(root).as_posix())
        for name in folders:
            safe(base / name)
        for name in names:
            path = safe(base / name)
            require(path.is_file(), 'Unexpected non-file in fixed tree')
            files.add(path.relative_to(root).as_posix())
    return files, directories


def resources():
    budget()
    sdk, unknown = [], []
    for process in psutil.process_iter(['pid', 'name'], ad_value=None):
        name = process.info['name']
        if name is None and process.pid not in (0, 4):
            unknown.append(process.pid)
        elif (name or '').lower() in SDK_NAMES:
            sdk.append(process.info)
    return {'utc': utc(), 'sdkProcesses': sdk, 'unknownProcessNames': unknown,
            'availableRamBytes': psutil.virtual_memory().available,
            'diskFreeBytes': {drive: shutil.disk_usage(drive).free for drive in ('C:/', 'D:/')}}


def resource_gate(row):
    require(not row['sdkProcesses'] and not row['unknownProcessNames'],
            'SDK/unknown process gate failed')
    require(row['availableRamBytes'] >= 2**31
            and all(value >= 2**31 for value in row['diskFreeBytes'].values()),
            'RAM/C:/D: resource gate failed')


def git(*arguments, cwd=REPO):
    budget()
    environment = os.environ.copy()
    environment.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0',
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL')
    value = subprocess.check_output([inputs['gitExecutable'], '-c', 'core.fsmonitor=false',
                                    '-c', 'core.untrackedCache=false', *arguments],
                                   cwd=cwd, env=environment,
                                   timeout=max(0.1, min(5, HARD-time.monotonic())),
                                   creationflags=subprocess.CREATE_NO_WINDOW)
    budget()
    return value


def source_check():
    manifest = load_pin(inputs['sourceManifest'])
    rows = manifest['sourceFiles']
    require(manifest['roots'] == ROOTS and len(rows) == 408 and manifest['sourceCount'] == 408,
            'Frozen seven-root/408 source boundary changed')
    expected = {row['path'] for row in rows}
    require(len(expected) == 408, 'Duplicate source input')
    observed = {}
    for label, base in [('frozenRawGit', SOURCE), ('mainRaw', REPO)]:
        actual = set()
        for root in ROOTS:
            found, unused = inventory(base / root, generated=True)
            actual.update(root + '/' + path for path in found)
        require(actual == expected, label + ' full source membership changed')
        for row in rows:
            current = pin(relative(base, row['path']))
            wanted = row['sha256'] if label == 'frozenRawGit' else row['workingTreeRawSha256']
            require(current['sha256'] == wanted, label + ' raw source bytes changed: ' + row['path'])
            if label == 'frozenRawGit':
                require(current['bytes'] == row['bytes'], 'Raw Git source size changed')
        observed[label] = {'files': len(actual), 'fullMembershipExact': True,
                           'allRawHashesMatch': True}
    trees = git('rev-parse', *['HEAD:' + root for root in ROOTS]).decode('ascii').splitlines()
    require(dict(zip(ROOTS, trees)) == inputs['sevenRootGitTrees'] and len(trees) == 7,
            'Current seven-root Git trees changed')
    records = git('ls-tree', '-rz', 'HEAD', '--', *ROOTS)
    found = {}
    for raw in records.split(b'\0'):
        if raw:
            header, path = raw.split(b'\t', 1)
            mode, kind, oid = header.decode('ascii').split()
            require(kind == 'blob' and mode in ('100644', '100755'), 'Git link/submodule refused')
            found[path.decode('utf-8')] = oid
    require(found == {row['path']: row['gitBlob'] for row in rows}, 'Current Git source set/blob changed')
    observed['currentSevenRootGitTrees'] = inputs['sevenRootGitTrees']
    return observed


def package_check():
    original = load_pin(inputs['originalPackageConfig'])
    candidate = load_pin(inputs['candidatePackageConfig'])
    template = load_pin(inputs['candidatePackageConfigTemplate'])
    require(candidate == template, 'Root candidate mapping/template differ')
    seed = load_pin(inputs['dependencyLibraryPins'])
    rows = seed['packageMappings']
    require(len(rows) == 70 and len(original['packages']) == 70
            and len({row['name'] for row in original['packages']}) == 70,
            'Complete 70-package mapping boundary changed')
    internal = inputs['internalPackageRoots']
    require(len(internal) == 7 and set(internal.values()) == set(ROOTS), 'Seven internal roots changed')
    for name, root in internal.items():
        text = (SOURCE / root / 'pubspec.yaml').read_text('utf-8')
        match = re.search(r'(?m)^name:\s*(\S+)\s*$', text)
        require(match is not None and match.group(1) == name, 'Internal pubspec package name changed')
    require({row['name'] for row in rows} == {row['name'] for row in original['packages']},
            'Seed/original package names changed')
    expected = json.loads(json.dumps(original))
    for row in expected['packages']:
        if row['name'] in internal:
            row['rootUri'] = (SOURCE / internal[row['name']]).as_uri()
    require(candidate == expected, 'Candidate mapping changed external rows/metadata or internal roots')
    require(Path(inputs['candidatePackageConfig']['path']) == MODULE / '.dart_tool/package_config.json',
            'Candidate mapping must be the frozen Guardian configuration')
    return {'packages': 70, 'rebasedInternalRoots': 7, 'unchangedExternalRows': 63,
            'metadataPreserved': True, 'candidateSha256': inputs['candidatePackageConfig']['sha256']}


def cache_check():
    cache = load_pin(inputs['cacheManifest'])
    parent = load_pin(inputs['cacheProjectionParentManifest'])
    require(inputs['cacheProjectionParentManifest']['sha256'] == '0027b4f8d65b9054e273b3c98a8b62f8de963fe9b59e054bf750eaae1cc6f3c2'
            and parent['status'] == 'READ_ONLY_CONTENT_COLLECTION_COMPLETE_NOT_SDK_VALIDATION'
            and parent['fullAllowlistCollected'] and len(parent['trees']) == 70
            and len(parent['fixedFiles']) == 33 and parent['totals'] == {'files': 3537, 'bytes': 638417631},
            'Historical parent cache manifest changed')
    excluded = [row for row in parent['fixedFiles']
                if row['path'].replace(chr(92), '/').casefold()
                == 'c:/program files/google/chrome/application/chrome.exe']
    require(len(excluded) == 1 and excluded[0]['bytes'] == 4600472
            and excluded[0]['sha256'] == '36a30716f0994b377f1ce6b47cfe35399b9719e31d597fe0ea0d8f3b62aed532',
            'Only the known analysis-unused Chrome row may be excluded')
    require(cache == {
        'status': 'READ_ONLY_ANALYSIS_CACHE_PROJECTION_NOT_SDK_VALIDATION',
        'phase': 'analyze-all-guardian',
        'parentManifest': inputs['cacheProjectionParentManifest'],
        'excludedFixedFiles': excluded,
        'exclusionReason': 'The fixed Flutter analyze command does not consume Chrome. A browser test phase must independently pin its current browser executable.',
        'trees': parent['trees'],
        'fixedFiles': [row for row in parent['fixedFiles'] if row not in excluded],
        'totals': {'files': 3536, 'bytes': 633817159},
        'allRemainingParentRowsPreserved': True,
        'cacheContentsRehashedDuringProjection': False,
        'sdkStarted': False, 'pubRun': False, 'browserStarted': False,
        'cacheCopied': False, 'entireSdkOrBrowserInstallationPinned': False},
        'Complete analysis-only projection must preserve every remaining parent row')
    totals = {'files': 0, 'bytes': 0}
    for spec in cache['trees']:
        base = Path(spec['root'])
        actual, directories = inventory(base)
        expected = {row['relativePath'] for row in spec['entries']}
        require(len(expected) == len(spec['entries']) and actual == expected
                and directories == set(spec['directories']), 'Cache tree membership/dirs changed: ' + str(base))
        rows = []
        for row in spec['entries']:
            current = pin(relative(base, row['relativePath']), single_link=True)
            require(current['bytes'] == row['bytes'] and current['sha256'] == row['sha256'],
                    'Cache content changed: ' + str(base / row['relativePath']))
            rows.append({'relativePath': row['relativePath'], 'bytes': current['bytes'],
                         'sha256': current['sha256']})
        rows.sort(key=lambda row: row['relativePath'])
        canonical = ''.join(f"{row['relativePath']}\0{row['bytes']}\0{row['sha256']}\n" for row in rows)
        require(hashlib.sha256(canonical.encode()).hexdigest() == spec['treeSha256']
                and len(rows) == spec['files'] and sum(row['bytes'] for row in rows) == spec['bytes'],
                'Cache canonical content pin changed')
        totals['files'] += len(rows)
        totals['bytes'] += sum(row['bytes'] for row in rows)
    for row in cache['fixedFiles']:
        current = pin(Path(row['path']), single_link=True)
        require(current['bytes'] == row['bytes'] and current['sha256'] == row['sha256'],
                'Fixed runtime content changed: ' + row['path'])
        totals['files'] += 1
        totals['bytes'] += current['bytes']
    require(totals == cache['totals'], 'Full cache totals changed')
    return {'manifestSha256': inputs['cacheManifest']['sha256'], 'trees': 70, 'fixedFiles': 32,
            'allMembersDirectoriesBytesAndHashesMatch': True, 'totals': totals}


def runtime_check():
    for row in inputs['controlRuntimeFiles'] + inputs['extraRuntimeFiles']:
        verify_pin(row)
    gate = inputs['sdkBootstrap']
    revision = git('rev-parse', 'HEAD', cwd=SDK).decode('ascii').strip()
    require(revision == gate['sdkGitRevision'], 'Fixed SDK Git revision changed')
    require((SDK / 'bin/cache/flutter_tools.stamp').read_text('utf-8').strip()
            == gate['flutterToolsStampText'], 'SDK flutter_tools stamp changed')
    require(gate['flutterToolsStampText'] == '"' + revision + ':"' and not os.environ.get('FLUTTER_TOOL_ARGS'),
            'SDK stamp/revision/tool-argument readiness gate failed')
    bootstrap = Path(gate['bootstrapMustBeAbsent'])
    safe(bootstrap.parent)
    require(not os.path.lexists(bootstrap), 'SDK bootstrap.bat must remain absent')
    engine = (SDK / 'bin/internal/engine.version').read_text('utf-8').strip()
    require((SDK / 'bin/cache/engine-dart-sdk.stamp').read_text('utf-8').strip()
            == engine == gate['engineVersionText'],
            'SDK engine/Dart stamp differs from fixed engine.version')
    require((SDK / 'bin/cache/flutter_tools.snapshot').is_file(), 'SDK snapshot missing')
    require((SDK / 'packages/flutter_tools/pubspec.yaml').stat().st_mtime_ns
            <= (SDK / 'packages/flutter_tools/pubspec.lock').stat().st_mtime_ns,
            'SDK tool pubspec is newer than lock; bootstrap would be required')
    environment_names = inputs['forbiddenEnvironmentOverrides']
    forbidden = [name for name in environment_names if os.environ.get(name)]
    require(not forbidden, 'Unreviewed SDK/environment overrides present: ' + ','.join(forbidden))
    expected_path = ['C:/Windows/System32', 'C:/Program Files/Git/cmd',
                     'D:/softwares/flutter/bin/cache/dart-sdk/bin']
    require([os.path.normcase(str(Path(item))) for item in inputs['processPath'].split(';')]
            == [os.path.normcase(str(Path(item))) for item in expected_path],
            'Fixed command PATH differs from the reviewed three directories')
    return {'sdkGitRevision': revision, 'controlAndExtraRuntimePinsMatch': True,
            'snapshotAndStampReady': True, 'pubspecNotNewerThanLock': True,
            'forbiddenEnvironmentOverridesAbsent': True, 'bootstrapAbsent': True,
            'engineDartStampMatchesEngineVersion': True, 'fixedProcessPathVerified': True,
            'bootstrapAllowed': False}


def full_check(label):
    result = {'stage': label, 'startedAtUtc': utc(), 'complete': False}
    try:
        verify_pin({'path': str(INPUT), 'bytes': input_bytes, 'sha256': INPUT_SHA256})
        result['source'] = source_check()
        result['packages'] = package_check()
        result['cache'] = cache_check()
        result['runtime'] = runtime_check()
        result['complete'] = True
        return result
    finally:
        result['finishedAtUtc'] = utc()
        result['elapsedWorkerSeconds'] = time.monotonic() - START
        save(label + '-pins.json', result)


receipt = {'status': 'NOT_ACCEPTED', 'phaseScope': 'FULL_GUARDIAN_ANALYZE',
           'startedAtUtc': utc(), 'workerBudgetSeconds': 165, 'commandCapSeconds': 150,
           'commandCleanupReserveSeconds': 5, 'minimumPostflightReserveSeconds': 25,
           'sdkCalls': 0, 'testsRun': False, 'pubRun': False, 'downloadsAllowed': False,
           'cacheCopied': False, 'mainSourceWritten': False, 'forcedTermination': False}
command_job = None
command_launched = False
inputs = None
code = 1
try:
    require(len(sys.argv) == 1 and os.name == 'nt', 'Fixed Windows worker only; no arguments')
    require(re.fullmatch('[0-9a-f]{64}', INPUT_SHA256) is not None,
            'Root input SHA is pending; static draft cannot start an SDK')
    actual_input = pin(INPUT)
    require(actual_input['sha256'] == INPUT_SHA256, 'Frozen Root input changed')
    input_bytes = actual_input['bytes']
    inputs = json.loads(INPUT.read_bytes())
    require(inputs['phase'] == 'analyze-all-guardian', 'Only one fixed Guardian analysis phase')
    require(set(inputs['generatedExclusions']['directories']) == GENERATED_DIRS
            and set(inputs['generatedExclusions']['files']) == GENERATED_FILES,
            'Root/source generated exclusions differ')
    first = resources()
    save('initial-gate.json', first)
    resource_gate(first)
    full_check('preflight')
    for name in ('tmp', 'out'):
        (ATTEMPT / name).mkdir()
    helper = CANDIDATE / 'heap1536_windows_job.py'
    require(pin(helper)['sha256'] == HELPER_SHA256, 'Frozen native Job helper changed')
    spec = importlib.util.spec_from_file_location('guardian_fixed_native_job', helper)
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    command_job = native.Job()
    require(command_job.snapshot()['activeProcesses'] == 0, 'New command Job not empty')
    ready = resources()
    save('launch-gate.json', ready)
    resource_gate(ready)
    now = time.monotonic()
    deadline = min(now + 150, HARD - 30)
    cleanup_deadline = min(deadline + 5, HARD - 25)
    require(deadline > now + 1, 'Insufficient full budget after preflight; no SDK started')
    environment = os.environ.copy()
    environment.update(TEMP=str(ATTEMPT / 'tmp'), TMP=str(ATTEMPT / 'tmp'),
                       PATH=inputs['processPath'],
                       PUB_HOSTED_URL='http://127.0.0.1:9',
                       FLUTTER_STORAGE_BASE_URL='http://127.0.0.1:9',
                       FLUTTER_SUPPRESS_ANALYTICS='true', DART_SUPPRESS_ANALYTICS='true',
                       CI='true', COMSPEC=str(CMD), GIT_OPTIONAL_LOCKS='0',
                       GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL')
    tail = str(FLUTTER) + ' ' + ' '.join(FLAGS)
    require(not any(char in tail for char in '&|<>^%!"\r\n'), 'Unsafe fixed command spelling')
    argv = [str(CMD), '/d', '/v:off', '/c', tail]
    previous = os.environ.copy()
    try:
        # The reused native helper inherits only this worker-local environment.
        os.environ.clear()
        os.environ.update(environment)
        command_job.spawn(argv, MODULE, ATTEMPT / 'out/analyze.log')
    finally:
        os.environ.clear()
        os.environ.update(previous)
    command_launched = True
    receipt['sdkCalls'] = 1
    launch = {'utc': utc(), 'pid': command_job.pid, 'argv': argv,
              'workingDirectory': str(MODULE), 'selectorCount': 0,
              'commandBudgetSeconds': deadline - now, 'workerElapsedAtLaunch': now - START,
              'postflightReserveSeconds': 25, 'cleanupReserveSeconds': 5,
              'processLocalTemp': str(ATTEMPT / 'tmp'), 'pubAndStorageLoopbackDisabled': True,
              'nativeProcessHandleRetained': True, 'atomicNestedJobMembership': True}
    save('launch.json', launch)
    state = command_job.wait(deadline, cleanup_deadline)
    receipt['commandTerminalState'] = state
    receipt['forcedTermination'] = state['terminationRequested'] or state['timedOut']
except Exception as error:
    receipt.update(errorType=type(error).__name__, reason=str(error))
    if command_job is not None and command_job.process is not None:
        receipt['sdkCalls'] = 1
        try:
            state = command_job.snapshot()
            if not state['terminalVerified']:
                command_job.terminate()
                state = command_job.wait(time.monotonic(), min(time.monotonic() + 5, HARD - 25))
            receipt['commandTerminalState'] = state
            receipt['forcedTermination'] = state['terminationRequested'] or state['timedOut']
        except Exception as cleanup_error:
            receipt['commandCleanupError'] = type(cleanup_error).__name__ + ': ' + str(cleanup_error)
finally:
    if inputs is not None:
        try:
            receipt['postflight'] = full_check('postflight')
        except Exception as post_error:
            receipt['postflightError'] = type(post_error).__name__ + ': ' + str(post_error)
    if command_job is not None:
        try:
            receipt['commandTerminalStateAfterPostflight'] = command_job.snapshot()
        except Exception as state_error:
            receipt['commandFinalStateError'] = type(state_error).__name__ + ': ' + str(state_error)
        finally:
            command_job.close()
    try:
        after = resources()
        save('postflight-gate.json', after)
        resource_gate(after)
        receipt['resourceAfter'] = after
    except Exception as resource_error:
        receipt['postflightResourceError'] = type(resource_error).__name__ + ': ' + str(resource_error)
    log = ATTEMPT / 'out/analyze.log'
    if log.is_file():
        try:
            receipt['logPin'] = pin(log)
            receipt['noIssuesFound'] = 'No issues found!' in log.read_text('utf-8', errors='replace')
        except Exception as log_error:
            receipt['logError'] = type(log_error).__name__ + ': ' + str(log_error)
    terminal = receipt.get('commandTerminalStateAfterPostflight', {})
    passed = (command_launched and receipt['sdkCalls'] == 1 and not receipt['forcedTermination']
              and terminal.get('terminalVerified') is True and terminal.get('rootExitCode') == 0
              and terminal.get('activeProcesses') == 0 and not terminal.get('timedOut')
              and not terminal.get('terminationRequested') and receipt.get('noIssuesFound') is True
              and receipt.get('postflight', {}).get('complete') is True
              and not any(name.endswith('Error') for name in receipt)
              and 'errorType' not in receipt and time.monotonic() < HARD)
    receipt['status'] = 'FULL_GUARDIAN_ANALYZE_WORKER_PASSED' if passed else 'NOT_ACCEPTED'
    receipt['finishedAtUtc'] = utc()
    receipt['elapsedCompleteSeconds'] = time.monotonic() - START
    receipt['outerExternalAcceptanceRequired'] = True
    save('receipt.json', receipt)
    print(json.dumps({'status': receipt['status'], 'sdkCalls': receipt['sdkCalls'],
                      'elapsedCompleteSeconds': receipt['elapsedCompleteSeconds']}), flush=True)
    code = 0 if passed else 1
raise SystemExit(code)
