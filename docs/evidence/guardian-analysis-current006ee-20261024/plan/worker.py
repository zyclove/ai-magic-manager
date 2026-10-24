"""Static candidate: one fixed full Guardian analysis, gated by Root's frozen input."""
from time import monotonic
START = monotonic()
import sys

import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import psutil

HARD = START + 165
COMMAND_END = START + 135.0
CLEANUP_END = START + 140.0
CANDIDATE = Path(__file__).absolute().parent
ATTEMPT = CANDIDATE / 'attempt'
REPO = CANDIDATE.parents[1]
FROZEN = REPO / '.cache/guardian-current-20261024-r15-login-schedule'
SOURCE_COMMIT = '006ee45850c9b6b0f90570d9478bced3beb0e0fe'
SOURCE = FROZEN / 'src'
MODULE = SOURCE / 'apps/guardian'
INPUT = CANDIDATE / 'inputs.json'
INPUT_BYTES = 17023
INPUT_SHA256 = 'ee2387b44bf6b172ee65baba0864f554b49d3e8f53a7aa635104034cc1b0ccb9'
PWSH = Path(r'C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe')
PROCESS_INVENTORY = CANDIDATE / 'process-inventory.ps1'
PROCESS_INVENTORY_SHA256 = 'f3c4349381fb6fc612b322e1a2a7ba59b6b21e4653e3212bfbac2b252028a046'
HELPER_SHA256 = 'f8b44764ed30d638781b7dc913e651fbbc6311b8f0945cc0d71b67c65abc141b'
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
             'aapt2.exe', 'qemu-system-x86_64.exe', 'compile.exe', 'link.exe', 'asm.exe', 'cgo.exe',
             'mvn.exe', 'gradle.exe', 'vet.exe'}
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


def unique_json_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'Duplicate process inventory JSON key')
        value[key] = item
    return value


def process_inventory():
    budget()
    script = inputs['processInventoryProvider']
    require(type(script) is dict and set(script) == {'path', 'bytes', 'sha256'}
            and Path(script['path']) == PROCESS_INVENTORY
            and type(script['bytes']) is int and script['bytes'] == 2439
            and script['sha256'] == PROCESS_INVENTORY_SHA256, 'Fixed process inventory script required')
    verify_pin(script)
    providers = [row for row in inputs['controlRuntimeFiles'] + inputs['extraRuntimeFiles']
                 if Path(row['path']) == PWSH]
    require(len(providers) == 1, 'Unique fixed PowerShell runtime pin required')
    verify_pin(providers[0])
    temporary = safe(ATTEMPT / 'host-tmp')
    require(temporary.is_dir(), 'Existing owned host temporary directory required')
    environment = {'SystemRoot': 'C:\\Windows', 'WINDIR': 'C:\\Windows',
                   'PATH': 'C:\\Windows\\System32', 'TEMP': str(temporary), 'TMP': str(temporary),
                   'PSModulePath': str(PWSH.parent / 'Modules'), 'POWERSHELL_TELEMETRY_OPTOUT': '1'}
    process = None
    try:
        require(HARD - monotonic() > 0.0, 'No original provider budget remains')
        process = subprocess.Popen([str(PWSH), '-NoLogo', '-NoProfile', '-NonInteractive',
                                    '-File', str(PROCESS_INVENTORY)],
                                   cwd=CANDIDATE, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        remaining = HARD - monotonic()
        require(remaining > 0.0, 'Original worker deadline exhausted during provider start')
        stdout, stderr = process.communicate(timeout=min(5.0, remaining))
        budget()
        require(process.returncode == 0 and stderr == b'', 'Process name provider nonzero/stderr')
        require(0 < len(stdout) <= 2 * 1024 * 1024, 'Empty/oversized process inventory output')
        value = json.loads(stdout.decode('utf-8'), object_pairs_hook=unique_json_object)
    finally:
        if process is not None:
            if process.poll() is None:
                # Only the exact child handle just created above is controlled.
                receipt['processNameProviderForced'] = True
                process.kill()
                remaining = HARD - monotonic()
                if remaining > 0.0:
                    process.wait(timeout=min(1.0, remaining))
            if process.poll() is not None:
                process.stdout.close()
                process.stderr.close()
    require(type(value) is dict and set(value) == {'schemaVersion', 'provider', 'purpose', 'powerShellVersion',
                     'sampleStartedAtUtc', 'sampleFinishedAtUtc', 'enumerationSucceeded',
                     'providerErrors', 'rowCount', 'rows'},
            'Exact complete process inventory schema required')
    require(type(value['schemaVersion']) is int and value['schemaVersion'] == 1
            and value['provider'] == 'PowerShell7 Get-Process / System.Diagnostics.Process'
            and value['purpose'] == 'FULL_FRESH_NAME_INVENTORY_NOT_PROCESS_CONTROL_IDENTITY'
            and value['powerShellVersion'] == '7.6.5'
            and all(type(value[key]) is str and value[key].strip()
                    for key in ('sampleStartedAtUtc', 'sampleFinishedAtUtc'))
            and value['enumerationSucceeded'] is True
            and type(value['providerErrors']) is list and value['providerErrors'] == []
            and type(value['rowCount']) is int and value['rowCount'] > 0
            and type(value['rows']) is list and len(value['rows']) == value['rowCount'],
            'Incomplete/failed process name enumeration')
    seen = set()
    for row in value['rows']:
        require(type(row) is dict and set(row) == {'pid', 'name', 'errors'}
                and type(row['pid']) is int and row['pid'] >= 0 and row['pid'] not in seen
                and type(row['name']) is str and row['name'].strip()
                and type(row['errors']) is list and row['errors'] == [],
                'Unknown/error/duplicate/invalid process name row')
        seen.add(row['pid'])
    budget()
    return value


def resources():
    budget()
    snapshot = process_inventory()
    sdk = []
    for row in snapshot['rows']:
        lowered = row['name'].lower()
        stem = lowered[:-4] if lowered.endswith('.exe') else lowered
        if stem + '.exe' in SDK_NAMES or stem.endswith('.test'):
            sdk.append({'pid': row['pid'], 'name': row['name']})
    return {'utc': utc(), 'sdkProcesses': sdk, 'unknownProcessNames': [],
            'processNameInventory': snapshot,
            'processNameProviderScriptSha256': PROCESS_INVENTORY_SHA256,
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
    require(Path(cwd) in (REPO, SDK), 'Only fixed repository and SDK Git directories allowed')
    environment = os.environ.copy()
    environment.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0',
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL')
    value = subprocess.check_output([inputs['gitExecutable'], '-c', 'safe.directory=' + str(cwd),
                                    '-c', 'core.fsmonitor=false',
                                    '-c', 'core.untrackedCache=false', *arguments],
                                   cwd=cwd, env=environment,
                                   timeout=max(0.1, min(5, HARD-time.monotonic())),
                                   creationflags=subprocess.CREATE_NO_WINDOW)
    budget()
    return value


def source_check():
    manifest = load_pin(inputs['sourceManifest'])
    require(inputs['sourceCommit'] == SOURCE_COMMIT
            and inputs['sourceFiles'] == 413 and inputs['sourceCount'] == 413
            and manifest['head'] == inputs['sourceCommit']
            and manifest['sourceTreeSha256'] == inputs['sourceTreeSha256'],
            'Original committed 413-source identity changed')
    seal = load_pin(inputs['sourceSeal'])
    require(seal['sourceCommit'] == inputs['sourceCommit']
            and seal['sourceFiles'] == 413 and seal['newViewLifetimeHelperIncluded'] is True
            and seal['sourceTreeSha256'] == inputs['sourceTreeSha256'], 'Current source seal changed')
    verify_pin(inputs['sourceDirectoryList'])
    bindings = load_pin(inputs['fullRegressionInventoryBinding'])
    cases = load_pin(inputs['expectedCaseContract'])
    require(bindings['sourceCommit'] == inputs['sourceCommit']
            and bindings['sourceTreeSha256'] == inputs['sourceTreeSha256']
            and bindings['rootFiles'] == 183 and len(bindings['rows']) == 183
            and cases['sourceCommit'] == inputs['sourceCommit']
            and cases['sourceTreeSha256'] == inputs['sourceTreeSha256']
            and len(cases['cases']) == 80 and len(cases['selectors']) == 7,
            'Current regression metadata binding changed; not test execution')
    rows = manifest['sourceFiles']
    require(manifest['roots'] == ROOTS and len(rows) == 413 and manifest['sourceCount'] == 413,
            'Frozen seven-root/413 source boundary changed')
    expected = {row['path'] for row in rows}
    require(len(expected) == 413, 'Duplicate source input')
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
    require(git('rev-parse', 'HEAD').decode('ascii').strip() == inputs['sourceCommit'],
            'Frozen original HEAD changed')
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
    observed['regressionMetadataBoundOnlyNotExecuted'] = True
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
    qualification = load_pin(inputs['qualifiedHostRuntimeManifest'])
    require(qualification['sdkAllowed'] is False
            and qualification['realControllerEntryEnabled'] is False,
            'Qualification provenance must not be repurposed as an SDK grant')
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


def finite(value):
    return type(value) is float and math.isfinite(value)


def natural_command(state):
    return (type(state) is dict and state.get('terminal') is True
            and state.get('signaled') is True
            and type(state.get('exitCode')) is int and state['exitCode'] == 0
            and type(state.get('activeProcesses')) is int and state['activeProcesses'] == 0
            and finite(state.get('firstSignaledQpc'))
            and finite(state.get('firstCompleteTerminalQpc'))
            and START <= state['firstSignaledQpc'] <= state['firstCompleteTerminalQpc']
            < min(COMMAND_END, state['firstSignaledQpc'] + 0.5))


def monitor_command(job):
    state = None
    first_signaled = None
    drain_end = None
    deadline_reached = False
    maximum_total = 0
    while True:
        sample_end = min(COMMAND_END, drain_end) if drain_end is not None else COMMAND_END
        state = job.sample(max(0, min(50, int(max(0.0, sample_end - monotonic()) * 1000))))
        maximum_total = max(maximum_total, state['totalProcesses'])
        if state['signaled'] and first_signaled is None:
            first_signaled = dict(state)
        if state['terminal']:
            break
        if state['signaled']:
            if drain_end is None:
                drain_end = min(COMMAND_END, state['firstSignaledQpc'] + 0.5)
            if monotonic() < drain_end:
                time.sleep(min(0.01, max(0.0, drain_end - monotonic())))
                continue
        if monotonic() >= COMMAND_END or (state['signaled'] and drain_end is not None
                                          and monotonic() >= drain_end):
            deadline_reached = monotonic() >= COMMAND_END
            state = job.sample(0)
            maximum_total = max(maximum_total, state['totalProcesses'])
            if state['signaled'] and first_signaled is None:
                first_signaled = dict(state)
            if state['terminal']:
                break
            job.terminate_owned()
            break
    while not state['terminal'] and monotonic() < CLEANUP_END:
        state = job.sample(max(0, min(50, int(max(0.0, CLEANUP_END - monotonic()) * 1000))))
        maximum_total = max(maximum_total, state['totalProcesses'])
        if state['signaled'] and first_signaled is None:
            first_signaled = dict(state)
    return state, first_signaled, drain_end, deadline_reached, maximum_total


receipt = {'status': 'NOT_ACCEPTED', 'phaseScope': 'FULL_GUARDIAN_ANALYZE',
           'startedAtUtc': utc(), 'workerStartQpc': START, 'workerDeadlineQpc': HARD,
           'commandDeadlineQpc': COMMAND_END, 'commandCleanupDeadlineQpc': CLEANUP_END,
           'workerBudgetSeconds': 165, 'commandWorkerRelativeSeconds': 135,
           'commandCleanupWorkerRelativeSeconds': 140, 'minimumPostflightReserveSeconds': 25,
           'sdkCalls': 0, 'testsRun': False, 'pubRun': False, 'downloadsAllowed': False,
           'cacheCopied': False, 'mainSourceWritten': False, 'forcedTermination': False,
           'commandCloseFallback': False, 'commandNaturalCompleteBeforeDeadline': False,
           'processNameProviderForced': False, 'postflightSkipped': False,
           'naturalDrainLimitSeconds': 0.5, 'nativeMemoryLimitClaimed': False}
command_job = None
command_launched = False
job_closed = False
inputs = None
code = 1
try:
    require(len(sys.argv) == 1 and os.name == 'nt' and sys.flags.isolated == 1
            and sys.dont_write_bytecode, 'Fixed isolated Windows worker only; no arguments')
    require(time.get_clock_info('monotonic').implementation == 'QueryPerformanceCounter()',
            'Shared Windows QPC required')
    require(re.fullmatch('[0-9a-f]{64}', INPUT_SHA256) is not None,
            'Fixed Root input SHA required')
    actual_input = pin(INPUT)
    require(actual_input['bytes'] == INPUT_BYTES and actual_input['sha256'] == INPUT_SHA256,
            'Frozen Root input bytes/hash changed')
    input_bytes = actual_input['bytes']
    inputs = json.loads(INPUT.read_bytes())
    require(inputs['phase'] == 'analyze-all-guardian', 'Only one fixed Guardian analysis phase')
    require(set(inputs['generatedExclusions']['directories']) == GENERATED_DIRS
            and set(inputs['generatedExclusions']['files']) == GENERATED_FILES,
            'Root/source generated exclusions differ')
    first = resources()
    save('initial-gate.json', first)
    resource_gate(first)
    receipt['preflight'] = full_check('preflight')
    for name in ('tmp', 'out'):
        (ATTEMPT / name).mkdir()
    helper = CANDIDATE / 'owned_job.py'
    require(pin(helper)['sha256'] == HELPER_SHA256, 'Qualified native OwnedJob bytes changed')
    spec = importlib.util.spec_from_file_location('guardian_fixed_analysis_job', helper)
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    command_job = native.OwnedJob()
    ready = resources()
    save('launch-gate.json', ready)
    resource_gate(ready)
    require(monotonic() + 1.0 < COMMAND_END, 'No original command budget remains; SDK not created')
    environment = os.environ.copy()
    environment.update(TEMP=str(ATTEMPT / 'tmp'), TMP=str(ATTEMPT / 'tmp'),
                       PATH=inputs['processPath'],
                       PUB_HOSTED_URL='http://127.0.0.1:9',
                       FLUTTER_STORAGE_BASE_URL='http://127.0.0.1:9',
                       FLUTTER_SUPPRESS_ANALYTICS='true', DART_SUPPRESS_ANALYTICS='true',
                       CI='true', COMSPEC=str(CMD), GIT_OPTIONAL_LOCKS='0',
                       GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL',
                       GIT_CONFIG_COUNT='2', GIT_CONFIG_KEY_0='safe.directory',
                       GIT_CONFIG_VALUE_0=str(REPO), GIT_CONFIG_KEY_1='safe.directory',
                       GIT_CONFIG_VALUE_1=str(SDK))
    tail = str(FLUTTER) + ' ' + ' '.join(FLAGS)
    require(not any(char in tail for char in '&|<>^%!"\r\n'), 'Unsafe fixed command spelling')
    argv = [str(CMD), '/d', '/v:off', '/c', tail]
    command_job.create_suspended(argv, MODULE, ATTEMPT / 'out/analyze.log', environment)
    command_launched = True
    receipt['sdkCalls'] = 1
    paused = command_job.sample(0)
    require(not paused['signaled'] and paused['activeProcesses'] == 1,
            'Unexpected suspended SDK command membership')
    launch = {'utc': utc(), 'pid': command_job.pid, 'creationFiletime': command_job.identity,
              'argv': argv, 'workingDirectory': str(MODULE), 'selectorCount': 0,
              'workerStartQpc': START, 'commandDeadlineQpc': COMMAND_END,
              'commandCleanupDeadlineQpc': CLEANUP_END, 'workerDeadlineQpc': HARD,
              'commandBudgetSeconds': COMMAND_END - monotonic(),
              'workerElapsedAtLaunch': monotonic() - START,
              'postflightReserveSeconds': 25, 'processLocalTemp': str(ATTEMPT / 'tmp'),
              'pubAndStorageLoopbackDisabled': True, 'nativeProcessHandleRetained': True,
              'atomicNestedJobMembership': True, 'launchRecordBeforeResume': True,
              'sdkProcessSafeDirectories': [str(REPO), str(SDK)],
              'nativeMemoryLimitClaimed': False}
    # File output finishes while the root is still suspended, before monitoring.
    save('launch.json', launch)
    require(monotonic() + 1.0 < COMMAND_END,
            'Original command deadline exhausted before resume')
    receipt['commandResumeBeforeQpc'] = monotonic()
    command_job.resume()
    state, first_signal, drain_end, reached, maximum_total = monitor_command(command_job)
    receipt['commandTerminalState'] = state
    receipt['firstSignaledCommandState'] = first_signal
    receipt['commandNaturalDrainDeadlineQpc'] = drain_end
    receipt['commandDeadlineReached'] = reached
    receipt['maximumObservedCommandJobTotal'] = maximum_total
    receipt['forcedTermination'] = command_job.force_requested
    receipt['terminationCallSucceeded'] = command_job.force_succeeded
    receipt['commandNaturalCompleteBeforeDeadline'] = natural_command(state)
except Exception as error:
    receipt.update(errorType=type(error).__name__, reason=str(error))
    if command_job is not None and command_job.process is not None:
        receipt['sdkCalls'] = 1
        try:
            state = command_job.sample(0)
            if not state['terminal']:
                command_job.terminate_owned()
                while monotonic() < CLEANUP_END:
                    state = command_job.sample(max(0, min(50, int(max(0.0, CLEANUP_END - monotonic()) * 1000))))
                    if state['terminal']:
                        break
            receipt['commandTerminalState'] = state
            receipt['forcedTermination'] = command_job.force_requested
            receipt['terminationCallSucceeded'] = command_job.force_succeeded
        except Exception as cleanup_error:
            receipt['commandCleanupError'] = type(cleanup_error).__name__ + ': ' + str(cleanup_error)
finally:
    if command_job is not None and command_job.process is not None:
        known = receipt.get('commandTerminalState')
        if not (type(known) is dict and known.get('terminal') is True):
            # Kernel kill-on-close is a failure fallback, never terminal/PASS evidence.
            receipt['commandCloseFallback'] = True
            receipt['forcedTermination'] = True
            command_job.close()
            job_closed = True
    if receipt['sdkCalls'] == 0:
        receipt['postflightSkipped'] = True
        receipt['postflight'] = {'complete': False, 'skipped': True,
                                 'reason': 'SDK_NOT_STARTED', 'sdkCalls': 0}
        save('postflight-skipped.json', receipt['postflight'])
    elif inputs is not None:
        try:
            receipt['postflight'] = full_check('postflight')
        except Exception as post_error:
            receipt['postflightError'] = type(post_error).__name__ + ': ' + str(post_error)
    if command_job is not None and not job_closed:
        try:
            receipt['commandTerminalStateAfterPostflight'] = command_job.sample(0)
            receipt['forcedTermination'] = receipt['forcedTermination'] or command_job.force_requested
            receipt['terminationCallSucceeded'] = command_job.force_succeeded
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
    terminal = receipt.get('commandTerminalStateAfterPostflight')
    initial_terminal = receipt.get('commandTerminalState')
    passed = (command_launched and receipt['sdkCalls'] == 1 and not receipt['forcedTermination']
              and receipt['processNameProviderForced'] is False
              and receipt['postflightSkipped'] is False
              and not receipt['commandCloseFallback'] and natural_command(initial_terminal)
              and natural_command(terminal)
              and initial_terminal['creationFiletime'] == terminal['creationFiletime']
              and initial_terminal['firstSignaledQpc'] == terminal['firstSignaledQpc']
              and initial_terminal['firstCompleteTerminalQpc'] == terminal['firstCompleteTerminalQpc']
              and receipt.get('noIssuesFound') is True
              and receipt.get('preflight', {}).get('complete') is True
              and receipt.get('postflight', {}).get('complete') is True
              and not any(name.endswith('Error') for name in receipt)
              and 'errorType' not in receipt and monotonic() < HARD)
    receipt['status'] = 'FULL_GUARDIAN_ANALYZE_WORKER_PASSED' if passed else 'NOT_ACCEPTED'
    receipt['finishedAtUtc'] = utc()
    receipt['workerFinishedQpc'] = monotonic()
    receipt['elapsedCompleteSeconds'] = receipt['workerFinishedQpc'] - START
    receipt['outerExternalAcceptanceRequired'] = True
    save('receipt.json', receipt)
    print(json.dumps({'status': receipt['status'], 'sdkCalls': receipt['sdkCalls'],
                      'elapsedCompleteSeconds': receipt['elapsedCompleteSeconds']}), flush=True)
    code = 0 if passed and monotonic() < HARD else 1
raise SystemExit(code)
