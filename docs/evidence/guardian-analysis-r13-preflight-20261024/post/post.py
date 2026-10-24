"""Fixed file-only result derivation. No candidate imports or process/native APIs."""
from pathlib import Path
import hashlib
import json
import math
import os
import re
import stat
import sys

REPO = Path(r'D:\codes\mobile\ai-manager')
BASE = REPO / '.cache/guardian-analyze-20261024-r13-current006ee'
OUT = REPO / '.cache/guardian-analyze-r13-post-20261024-r1'
LAUNCHER = REPO / '.cache/guardian-analyze-root-launch-20261024-r13-current006ee.ps1'
COMMIT = '006ee45850c9b6b0f90570d9478bced3beb0e0fe'
INPUT_SHA = 'bc9a2510cdbf9ce8f672dab340a254d3463bb4d3b4bf5b34a26b5c477d219902'
BUDGETS = {'outer': 180, 'working': 174, 'worker': 165, 'command': 135,
           'commandCleanup': 140, 'postflightReserve': 25}
NAMES = {'analysis-host.py', 'worker.py', 'owned_job.py', 'process-inventory.ps1'}
PROCESS_INVENTORY_SHA = 'f3c4349381fb6fc612b322e1a2a7ba59b6b21e4653e3212bfbac2b252028a046'
SDK_NAMES = {'java.exe', 'javaw.exe', 'javac.exe', 'dart.exe', 'dartaotruntime.exe',
             'go.exe', 'gofmt.exe', 'flutter.exe', 'flutter_tester.exe', 'gen_snapshot.exe',
             'aapt2.exe', 'qemu-system-x86_64.exe', 'compile.exe', 'link.exe', 'asm.exe', 'cgo.exe',
             'mvn.exe', 'gradle.exe', 'vet.exe'}
observed_pins = []


def require(value, message):
    if value is not True:
        raise ValueError(message)


def integer(value, minimum=0):
    require(type(value) is int and value >= minimum, 'Expected bounded integer')
    return value


def number(value):
    require(type(value) in (int, float) and math.isfinite(value), 'Expected finite JSON number')
    return value


def qpc(value):
    require(type(value) is float and math.isfinite(value) and value > 0.0, 'Expected positive finite QPC float')
    return value


def same(left, right):
    # JSON serialization retains bool/int and int/float distinctions.
    return json.dumps(left, sort_keys=True, allow_nan=False) == json.dumps(right, sort_keys=True, allow_nan=False)


def safe(path):
    path = Path(path)
    require(path.is_absolute() and not str(path).startswith('\\\\') and ':' not in str(path)[2:],
            'Only local absolute non-ADS paths')
    for item in (path, *path.parents):
        if os.path.lexists(item):
            info = item.lstat()
            require(not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400,
                    'Linked/reparse path refused: ' + str(item))
    return path


def read(path, limit=4 * 1024 * 1024):
    path = safe(path)
    first = path.stat()
    require(stat.S_ISREG(first.st_mode) and first.st_size <= limit, 'Missing/nonregular/oversized file: ' + str(path))
    raw = path.read_bytes()
    last = path.stat()
    identity = lambda item: (item.st_dev, item.st_ino, item.st_nlink, item.st_size, item.st_mtime_ns)
    require(identity(first) == identity(last) and len(raw) == first.st_size, 'File changed during read')
    observed_pins.append({'path': str(path), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
    return raw


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, 'Duplicate JSON key: ' + key)
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError('Nonfinite JSON constant: ' + value)


def decode(raw):
    value = json.loads(raw.decode('utf-8-sig'), object_pairs_hook=pairs, parse_constant=reject_constant)
    require(type(value) is dict, 'Expected JSON object')
    return value


def load(path, limit=2 * 1024 * 1024):
    return decode(read(path, limit))


def descriptor(row, candidate=False):
    require(type(row) is dict and set(row) in ({'path', 'bytes', 'sha256'}, {'path', 'bytes', 'sha256', 'absolute'}),
            'Exact descriptor schema required')
    require(type(row['path']) is str and type(row['sha256']) is str
            and re.fullmatch('[a-f0-9]{64}', row['sha256']) is not None, 'Descriptor strings invalid')
    integer(row['bytes'])
    require(row['bytes'] <= 32 * 1024 * 1024, 'Bounded fixed input/runtime/log descriptor required')
    if 'absolute' in row:
        require(row['absolute'] is True, 'Invalid absolute marker')
    if candidate:
        require(row['path'] in NAMES and 'absolute' not in row, 'Fixed relative candidate only')
        path = BASE / row['path']
    else:
        path = Path(row['path'])
    raw = read(path, 32 * 1024 * 1024)
    require(len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256'],
            'Descriptor drift: ' + str(path))
    return str(path).casefold(), row['bytes'], row['sha256']


def gate(value, inputs):
    require(type(value) is dict and set(value) == {'utc', 'sdkProcesses', 'unknownProcessNames',
            'processNameInventory', 'processNameProviderScriptSha256', 'availableRamBytes', 'diskFreeBytes'},
            'Exact worker resource gate schema required')
    require(type(value['utc']) is str and value['utc'].strip()
            and value['processNameProviderScriptSha256'] == PROCESS_INVENTORY_SHA
            and inputs['processInventoryProvider']['sha256'] == PROCESS_INVENTORY_SHA,
            'Worker process provider identity differs')
    inventory = value['processNameInventory']
    require(type(inventory) is dict and set(inventory) == {'schemaVersion', 'provider', 'purpose',
            'powerShellVersion', 'sampleStartedAtUtc', 'sampleFinishedAtUtc', 'enumerationSucceeded',
            'providerErrors', 'rowCount', 'rows'}, 'Exact complete process name inventory schema required')
    require(type(inventory['schemaVersion']) is int and inventory['schemaVersion'] == 1
            and inventory['provider'] == 'PowerShell7 Get-Process / System.Diagnostics.Process'
            and inventory['purpose'] == 'FULL_FRESH_NAME_INVENTORY_NOT_PROCESS_CONTROL_IDENTITY'
            and inventory['powerShellVersion'] == '7.6.5'
            and all(type(inventory[key]) is str and inventory[key].strip()
                    for key in ('sampleStartedAtUtc', 'sampleFinishedAtUtc'))
            and inventory['enumerationSucceeded'] is True
            and type(inventory['providerErrors']) is list and inventory['providerErrors'] == []
            and type(inventory['rowCount']) is int and inventory['rowCount'] > 0
            and type(inventory['rows']) is list and len(inventory['rows']) == inventory['rowCount'],
            'Incomplete/failed process name inventory')
    seen, sdk = set(), []
    for row in inventory['rows']:
        require(type(row) is dict and set(row) == {'pid', 'name', 'errors'}
                and type(row['pid']) is int and row['pid'] >= 0 and row['pid'] not in seen
                and type(row['name']) is str and row['name'].strip()
                and type(row['errors']) is list and row['errors'] == [],
                'Unknown/error/duplicate/invalid process name row')
        seen.add(row['pid'])
        lowered = row['name'].lower()
        stem = lowered[:-4] if lowered.endswith('.exe') else lowered
        if stem + '.exe' in SDK_NAMES or stem.endswith('.test'):
            sdk.append({'pid': row['pid'], 'name': row['name']})
    require(type(value['sdkProcesses']) is list and same(value['sdkProcesses'], sdk) and sdk == []
            and type(value['unknownProcessNames']) is list and value['unknownProcessNames'] == [],
            'Worker reported name gate differs from complete raw inventory derivation')
    integer(value['availableRamBytes'], 2**31)
    disks = value['diskFreeBytes']
    require(type(disks) is dict and set(disks) == {'C:/', 'D:/'}, 'Worker disk scope changed')
    for count in disks.values():
        integer(count, 2**31)


def terminal(value, required=True):
    fields = {'pid', 'creationFiletime', 'exitFiletime', 'kernel100ns', 'user100ns', 'firstSignaledQpc',
              'sampleQpc', 'signaled', 'exitCode', 'jobAccountingObservedQpc', 'firstCompleteTerminalQpc',
              'activeProcesses', 'totalProcesses', 'terminatedProcesses', 'terminal'}
    require(type(value) is dict and set(value) == fields, 'Owned terminal schema changed')
    for key in ('pid', 'creationFiletime', 'totalProcesses'):
        integer(value[key], 1)
    for key in ('exitFiletime', 'kernel100ns', 'user100ns', 'activeProcesses', 'terminatedProcesses'):
        integer(value[key])
    require(value['signaled'] is True and type(value['exitCode']) is int and value['exitCode'] == 0,
            'Retained process must have natural zero exit')
    require(value['exitFiletime'] >= value['creationFiletime'], 'Retained process FILETIME identity invalid')
    require(qpc(value['firstSignaledQpc']) <= qpc(value['sampleQpc']) <= qpc(value['jobAccountingObservedQpc']),
            'Retained process observation order invalid')
    actual_terminal = value['activeProcesses'] == 0
    require(value['terminal'] is actual_terminal, 'Terminal flag/accounting disagreement')
    if required:
        require(actual_terminal, 'Owned Job is not empty')
    if actual_terminal:
        require(value['firstSignaledQpc'] <= qpc(value['firstCompleteTerminalQpc'])
                <= value['jobAccountingObservedQpc'], 'Complete Job observation order invalid')
    else:
        require(value['firstCompleteTerminalQpc'] is None, 'Incomplete state has a fabricated completion')
    return value


def checked_full_check(value, stage, inputs):
    require(type(value) is dict and value.get('stage') == stage and value.get('complete') is True,
            'Incomplete or wrong pre/post stage')
    require(not any(key.endswith('Error') or key == 'errorType' for key in value), 'Pre/post error present')
    require(type(value.get('startedAtUtc')) is str and type(value.get('finishedAtUtc')) is str,
            'Pre/post timestamps missing')
    require(0.0 <= number(value.get('elapsedWorkerSeconds')) < 165.0, 'Pre/post elapsed invalid')
    expected_source = {key: {'files': 413, 'fullMembershipExact': True, 'allRawHashesMatch': True}
                       for key in ('frozenRawGit', 'mainRaw')}
    expected_source.update(currentSevenRootGitTrees=inputs['sevenRootGitTrees'],
                           regressionMetadataBoundOnlyNotExecuted=True)
    require(same(value.get('source'), expected_source), 'Complete current413 raw source summary differs')
    require(same(value.get('packages'), {'packages': 70, 'rebasedInternalRoots': 7,
            'unchangedExternalRows': 63, 'metadataPreserved': True,
            'candidateSha256': inputs['candidatePackageConfig']['sha256']}), 'Package guard summary differs')
    require(same(value.get('cache'), {'manifestSha256': inputs['cacheManifest']['sha256'],
            'trees': 70, 'fixedFiles': 32, 'allMembersDirectoriesBytesAndHashesMatch': True,
            'totals': {'files': 3536, 'bytes': 633817159}}), 'Full cache guard summary differs')
    require(same(value.get('runtime'), {'sdkGitRevision': inputs['sdkBootstrap']['sdkGitRevision'],
            'controlAndExtraRuntimePinsMatch': True, 'snapshotAndStampReady': True,
            'pubspecNotNewerThanLock': True, 'forbiddenEnvironmentOverridesAbsent': True,
            'bootstrapAbsent': True, 'engineDartStampMatchesEngineVersion': True,
            'fixedProcessPathVerified': True, 'bootstrapAllowed': False}), 'SDK/runtime guard summary differs')


def main(approved_sha):
    require(re.fullmatch('[a-f0-9]{64}', approved_sha) is not None, 'Supply exact approved proposal SHA')
    proposal_raw = read(BASE / 'proposal.json')
    require(hashlib.sha256(proposal_raw).hexdigest() == approved_sha, 'Approved proposal drift')
    proposal = decode(proposal_raw)
    require(set(proposal) == {'schemaVersion', 'phase', 'sourceCommit', 'inputs', 'candidateFiles',
            'runtimePins', 'pythonExecutable', 'budgets'}, 'Fixed proposal schema differs')
    require(type(proposal['schemaVersion']) is int and proposal['schemaVersion'] == 1
            and proposal['phase'] == 'analyze-all-guardian' and proposal['sourceCommit'] == COMMIT
            and proposal['pythonExecutable'] == 'C:/Python313/python.exe'
            and same(proposal['budgets'], BUDGETS), 'Proposal scope or original budgets differ')
    require(type(proposal['candidateFiles']) is list and len(proposal['candidateFiles']) == 4
            and {row.get('path') for row in proposal['candidateFiles'] if type(row) is dict} == NAMES,
            'Exact four candidate controls required')
    for row in proposal['candidateFiles']:
        descriptor(row, candidate=True)
    require(Path(proposal['inputs']['path']) == BASE / 'inputs.json'
            and proposal['inputs']['sha256'] == INPUT_SHA, 'Fixed current input required')
    descriptor(proposal['inputs'])
    inputs = load(BASE / 'inputs.json')
    require(Path(inputs['processInventoryProvider']['path']) == BASE / 'process-inventory.ps1'
            and type(inputs['processInventoryProvider']['bytes']) is int
            and inputs['processInventoryProvider']['bytes'] == 2439
            and inputs['processInventoryProvider']['sha256'] == PROCESS_INVENTORY_SHA,
            'Fixed process name provider descriptor required')
    descriptor(inputs['processInventoryProvider'])
    require(inputs['sourceCommit'] == COMMIT and type(inputs['sourceCount']) is int
            and inputs['sourceCount'] == 413 and inputs['sourceFiles'] == 413
            and inputs['fullRegressionRootFiles'] == 183 and inputs['runtimeClosureComplete'] is False,
            'Current413/full183 input boundary differs')
    require(type(proposal['runtimePins']) is list and len(proposal['runtimePins']) == 35, 'Runtime union changed')
    runtime = [descriptor(row) for row in proposal['runtimePins']]
    expected_runtime = [descriptor(row) for row in inputs['controlRuntimeFiles'] + inputs['extraRuntimeFiles']]
    require(len(runtime) == len(set(runtime)) == 35 and set(runtime) == set(expected_runtime),
            'Runtime union does not match exact input runtime guards')
    # Bound input metadata are read; external633MB cache payload is not rehashed
    # by this file-only post. Actual pre/post guard reports are cross-checked below.
    for key in ('sourceSeal', 'sourceManifest', 'sourceDirectoryList', 'dependencyLibraryPins',
                'candidatePackageConfig', 'candidatePackageConfigTemplate', 'originalPackageConfig',
                'fullRegressionInventoryBinding', 'expectedCaseContract', 'cacheManifest',
                'cacheProjectionParentManifest', 'qualifiedHostRuntimeManifest'):
        descriptor(inputs[key])

    grant = load(BASE / 'root-sdk-grant.json')
    launcher_raw = read(LAUNCHER)
    launcher_sha = hashlib.sha256(launcher_raw).hexdigest()
    require(grant.get('status') == 'ROOT_APPROVED_SINGLE_FIXED_ANALYSIS'
            and grant.get('proposalSha256') == approved_sha and grant.get('launcherSha256') == launcher_sha
            and grant.get('sourceCommit') == COMMIT and type(grant.get('sdkCallsAllowed')) is int
            and grant['sdkCallsAllowed'] == 1, 'Root exact grant/launcher does not match')
    root_pre = load(BASE / 'root-attempt/preflight.json')
    root = load(BASE / 'root-attempt/result.json')
    require(root_pre.get('status') == 'ROOT_FIXED_ANALYSIS_STARTED', 'Wrong Root preflight')
    for key, value in root_pre.items():
        if key != 'status':
            require(key in root and same(root[key], value), 'Root preflight/result field changed: ' + key)
    for row in (root_pre, root):
        require(row.get('sourceCommit') == COMMIT and row.get('proposalSha256') == approved_sha
                and row.get('launcherSha256') == launcher_sha, 'Root identity differs')
        require(type(row.get('sdkCount')) is int and row['sdkCount'] == 0
                and type(row.get('unknownCount')) is int and row['unknownCount'] == 0
                and type(row.get('maximumHostSeconds')) is int and row['maximumHostSeconds'] == 180
                and row.get('reusedBudget') is False and row.get('applicationTestsRun') is False,
                'Root fresh preflight gate fields invalid')
        integer(row.get('availableRamBytes'), 2**31)
        require(type(row.get('disks')) is list and len(row['disks']) == 2
                and {item.get('Name') for item in row['disks']} == {'C', 'D'}, 'Root disk scope differs')
        for disk in row['disks']:
            integer(disk.get('Free'), 2**31)
    require(root.get('status') == 'ROOT_HOST_TERMINAL_PENDING_INDEPENDENT_ANALYSIS_POST'
            and root.get('sameHandleSignaled') is True and type(root.get('actualHostExitCode')) is int
            and root['actualHostExitCode'] == 0 and root.get('rootForcedOwnHost') is False
            and root.get('emergencyCleanupAttempted') is False and root.get('failure') is None
            and root.get('hostTimelyAgainstOriginalRootAnchor') is True
            and root.get('candidateRuntimePinsMatchAfter') is True and root.get('rootHostTerminalAccepted') is True
            and root.get('analysisAccepted') is False, 'Root retained-handle natural exit proof rejected')
    integer(root.get('hostPid'), 1)
    for key in ('sameHandleCreationFiletime', 'sameHandleExitFiletime'):
        require(type(root.get(key)) is str and re.fullmatch('[1-9][0-9]*', root[key]) is not None,
                'Root FILETIME must be positive canonical decimal text')
    require(int(root['sameHandleExitFiletime']) >= int(root['sameHandleCreationFiletime']), 'Root retained FILETIME order invalid')
    root_signal = number(root.get('firstWaitSignaledElapsedSeconds'))
    require(0.0 <= root_signal < 180.0 and number(root.get('rootElapsedBeforeReceiptSeconds')) >= root_signal,
            'Root first same-handle signal was not within original180')

    attempt = BASE / 'attempt'
    request = load(attempt / 'request.json')
    host = load(attempt / 'result.json')
    receipt = load(attempt / 'receipt.json')
    launch = load(attempt / 'launch.json')
    require(set(request) == {'approvedProposalSha256', 'qpcAnchor', 'workDeadlineQpc',
            'cleanupDeadlineQpc', 'sourceCommit', 'phase'}, 'Host request schema differs')
    anchor = qpc(request.get('qpcAnchor'))
    require(request.get('approvedProposalSha256') == approved_sha and request.get('sourceCommit') == COMMIT
            and request.get('phase') == 'analyze-all-guardian'
            and qpc(request.get('workDeadlineQpc')) == anchor + 174.0
            and qpc(request.get('cleanupDeadlineQpc')) == anchor + 180.0, 'Host request budget anchor differs')
    for key in request:
        require(key in host and same(host[key], request[key]), 'Host request/result field differs: ' + key)
    require(host.get('status') == 'FULL_GUARDIAN_ANALYZE_HOST_OBSERVED'
            and host.get('naturalCompleteTerminalTimely') is True and host.get('forcedCleanupRequested') is False
            and host.get('terminationCallSucceeded') is False and host.get('closedWithLiveOrUnknownMembers') is False
            and host.get('deadlineReached') is False and host.get('candidateAndRuntimePinsMatchAfter') is True
            and host.get('error') is None and host.get('analysisAcceptedBeforeOutput') is True
            and host.get('rootActualSameHandleExitStillRequired') is True
            and host.get('rootFullProcessReleaseStillRequired') is True
            and type(host.get('sdkCalls')) is int and host['sdkCalls'] == 1 and host.get('testsRun') is False,
            'Host reported acceptance/ownership flags invalid')
    worker_terminal = terminal(host.get('terminal'))
    first_worker_signal = terminal(host.get('firstSignaledState'), required=False)
    require(first_worker_signal['pid'] == worker_terminal['pid']
            and first_worker_signal['creationFiletime'] == worker_terminal['creationFiletime']
            and first_worker_signal['firstSignaledQpc'] == worker_terminal['firstSignaledQpc']
            and worker_terminal['firstSignaledQpc'] <= worker_terminal['firstCompleteTerminalQpc']
            < min(anchor + 174.0, worker_terminal['firstSignaledQpc'] + 0.5), 'Host worker terminal is late or mismatched')
    require(type(host.get('naturalDrainLimitSeconds')) is float and host['naturalDrainLimitSeconds'] == 0.5,
            'Host natural drain ceiling changed')
    if host.get('naturalDrainDeadlineQpc') is not None:
        require(qpc(host['naturalDrainDeadlineQpc']) == min(anchor + 174.0, worker_terminal['firstSignaledQpc'] + 0.5),
                'Host drain deadline changed')
    host_output_qpc = qpc(host.get('observedBeforeOutputQpc'))
    require(worker_terminal['jobAccountingObservedQpc'] <= host_output_qpc < anchor + 180.0
            and type(host.get('elapsedBeforeOutputSeconds')) is float
            and host['elapsedBeforeOutputSeconds'] == host_output_qpc - anchor,
            'Host pre-output QPC invalid (not treated as actual process exit)')
    require(same(host.get('workerReceipt'), receipt), 'Host embedded receipt differs from raw worker receipt')

    start = qpc(receipt.get('workerStartQpc'))
    finished = qpc(receipt.get('workerFinishedQpc'))
    require(anchor <= qpc(host.get('workerResumeBeforeQpc')) <= start <= finished <= worker_terminal['firstSignaledQpc']
            and qpc(receipt.get('workerDeadlineQpc')) == start + 165.0
            and qpc(receipt.get('commandDeadlineQpc')) == start + 135.0
            and qpc(receipt.get('commandCleanupDeadlineQpc')) == start + 140.0
            and type(receipt.get('elapsedCompleteSeconds')) is float
            and 0.0 <= receipt['elapsedCompleteSeconds'] == finished - start < 165.0
            and worker_terminal['firstCompleteTerminalQpc'] < start + 165.0,
            'Original worker/command deadlines or actual observed worker exit invalid')
    require(receipt.get('phaseScope') == 'FULL_GUARDIAN_ANALYZE'
            and receipt.get('workerBudgetSeconds') == 165 and type(receipt.get('workerBudgetSeconds')) is int
            and receipt.get('commandWorkerRelativeSeconds') == 135 and type(receipt.get('commandWorkerRelativeSeconds')) is int
            and receipt.get('commandCleanupWorkerRelativeSeconds') == 140 and type(receipt.get('commandCleanupWorkerRelativeSeconds')) is int
            and receipt.get('minimumPostflightReserveSeconds') == 25 and type(receipt.get('minimumPostflightReserveSeconds')) is int,
            'Reported fixed budget ceilings changed')
    for flag in ('forcedTermination', 'terminationCallSucceeded', 'commandCloseFallback', 'commandDeadlineReached', 'processNameProviderForced', 'postflightSkipped',
                 'testsRun', 'pubRun', 'downloadsAllowed', 'cacheCopied', 'mainSourceWritten', 'nativeMemoryLimitClaimed'):
        require(receipt.get(flag) is False, 'Forbidden worker flag: ' + flag)
    require(type(receipt.get('sdkCalls')) is int and receipt['sdkCalls'] == 1
            and receipt.get('commandNaturalCompleteBeforeDeadline') is True and receipt.get('noIssuesFound') is True
            and receipt.get('outerExternalAcceptanceRequired') is True
            and 'errorType' not in receipt and not any(key.endswith('Error') for key in receipt),
            'Worker error/result flags invalid')
    command = terminal(receipt.get('commandTerminalState'))
    after_command = terminal(receipt.get('commandTerminalStateAfterPostflight'))
    for key in ('pid', 'creationFiletime', 'exitFiletime', 'firstSignaledQpc', 'firstCompleteTerminalQpc',
                'totalProcesses', 'terminatedProcesses'):
        require(same(command[key], after_command[key]), 'Command retained identity/accounting drift: ' + key)
    require(start <= qpc(receipt.get('commandResumeBeforeQpc')) <= command['firstSignaledQpc']
            <= command['firstCompleteTerminalQpc'] < min(start + 135.0, command['firstSignaledQpc'] + 0.5)
            and after_command['jobAccountingObservedQpc'] <= finished,
            'Command Job0 was not naturally complete by original135 or before receipt finish')
    require(receipt.get('naturalDrainLimitSeconds') == 0.5 and type(receipt.get('naturalDrainLimitSeconds')) is float,
            'Command natural drain limit changed')
    if receipt.get('commandNaturalDrainDeadlineQpc') is not None:
        require(qpc(receipt['commandNaturalDrainDeadlineQpc']) == min(start + 135.0, command['firstSignaledQpc'] + 0.5),
                'Command natural drain deadline changed')
    first_command = terminal(receipt.get('firstSignaledCommandState'), required=False)
    require(first_command['pid'] == command['pid'] and first_command['creationFiletime'] == command['creationFiletime']
            and first_command['firstSignaledQpc'] == command['firstSignaledQpc'], 'First command signal identity differs')
    expected_argv = [r'C:\Windows\System32\cmd.exe', '/d', '/v:off', '/c',
        r'D:\softwares\flutter\bin\flutter.bat --no-version-check --suppress-analytics analyze --no-pub --fatal-infos --fatal-warnings']
    require(same(launch.get('argv'), expected_argv)
            and launch.get('workingDirectory') == str(REPO / '.cache/guardian-current-20261024-r15-login-schedule/src/apps/guardian')
            and type(launch.get('pid')) is int and launch['pid'] == command['pid']
            and type(launch.get('creationFiletime')) is int and launch['creationFiletime'] == command['creationFiletime']
            and type(launch.get('selectorCount')) is int and launch['selectorCount'] == 0,
            'Fixed command launch identity/argv/module differs')
    require(same(launch.get('sdkProcessSafeDirectories'),
                 [str(REPO), str(Path(r'D:\softwares\flutter'))]),
            'SDK child Git safe.directory allowance is not exactly REPO and SDK')
    for key in ('workerStartQpc', 'commandDeadlineQpc', 'commandCleanupDeadlineQpc', 'workerDeadlineQpc'):
        require(same(launch.get(key), receipt[key]), 'Launch original deadline differs: ' + key)
    for key in ('pubAndStorageLoopbackDisabled', 'nativeProcessHandleRetained', 'atomicNestedJobMembership', 'launchRecordBeforeResume'):
        require(launch.get(key) is True, 'Launch containment/provenance flag invalid: ' + key)
    require(launch.get('nativeMemoryLimitClaimed') is False
            and type(launch.get('postflightReserveSeconds')) is int and launch['postflightReserveSeconds'] == 25
            and 0.0 < number(launch.get('commandBudgetSeconds')) <= 135.0
            and 0.0 <= number(launch.get('workerElapsedAtLaunch')) < 135.0
            and start + launch['workerElapsedAtLaunch'] <= receipt['commandResumeBeforeQpc']
            and launch.get('processLocalTemp') == str(attempt / 'tmp'), 'Launch budget/temp evidence invalid')

    for stage in ('preflight', 'postflight'):
        value = load(attempt / (stage + '-pins.json'))
        require(same(value, receipt.get(stage)), 'Worker raw/embedded ' + stage + ' differs')
        checked_full_check(value, stage, inputs)
    for name in ('initial-gate.json', 'launch-gate.json', 'postflight-gate.json'):
        value = load(attempt / name)
        gate(value, inputs)
        if name == 'postflight-gate.json':
            require(same(value, receipt.get('resourceAfter')), 'Worker final resource raw/embedded gate differs')
    require(Path(receipt.get('logPin', {}).get('path', '')) == attempt / 'out/analyze.log', 'Fixed analysis log path required')
    descriptor(receipt['logPin'])
    log = read(attempt / 'out/analyze.log', 16 * 1024 * 1024).decode('utf-8-sig')
    clean_log = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', log)
    require('No issues found!' in clean_log
            and re.search(r'(?im)^\s*(error|warning|info)\s*(?:[•·-]|:)', clean_log) is None
            and re.search(r'(?i)\b[1-9][0-9]*\s+issues?\s+found\b', clean_log) is None,
            'Analysis log contains diagnostics or lacks exact no-issues result')
    console = decode(read(attempt / 'worker-console.log', 1024 * 1024))
    require(same(console, {'status': 'FULL_GUARDIAN_ANALYZE_WORKER_PASSED', 'sdkCalls': 1,
                          'elapsedCompleteSeconds': receipt['elapsedCompleteSeconds']}), 'Worker console outcome differs')
    derived_worker = True  # Reached only after independent file/timing/identity/guard checks above.
    reported_worker = receipt.get('status') == 'FULL_GUARDIAN_ANALYZE_WORKER_PASSED'
    require(reported_worker is derived_worker and host.get('workerReportedPassed') is reported_worker
            and host.get('workerDerivedPassed') is derived_worker and host.get('workerReportedDerivedConsistent') is True,
            'Worker/host reported versus independently derived outcome differs')
    return {'status': 'DERIVED_ANALYSIS_CONSISTENT_PENDING_ROOT_RELEASE', 'sourceCommit': COMMIT,
        'approvedProposalSha256': approved_sha, 'rootRecordedSameHandleNaturalZero': True,
        'rootRecordedFirstWaitSeconds': root_signal, 'hostOriginalBudgets': BUDGETS,
        'workerDerivedConsistent': True, 'sdkCalls': 1, 'applicationTestsRun': False,
        'hostPreOutputElapsedNotUsedAsOuterExit': True,
        'rootActualToolTerminalEvidenceInspected': False, 'freshFullProcessReleaseInspected': False,
        'rootActualToolTerminalStillRequired': True, 'freshFullProcessReleaseStillRequired': True,
        'analysisAccepted': False, 'runtimeClosureComplete': False,
        'externalCachePayloadRehashedByThisPost': False,
        'privateJobMemberDiagnosticsCauseNotClassified': True,
        'candidateSdkAstProcessNativeOrNetworkExecutedByThisPost': False,
        'observedFilePins': observed_pins}


if __name__ == '__main__':
    code = 1
    try:
        require(len(sys.argv) == 2, 'Usage: post.py <actual-approved-proposal-sha256>')
        result = main(sys.argv[1])
        code = 0
    except Exception as error:
        result = {'status': 'NOT_ACCEPTED_FILE_READBACK', 'errorType': type(error).__name__,
            'reason': str(error), 'analysisAccepted': False,
            'rootActualToolTerminalStillRequired': True, 'freshFullProcessReleaseStillRequired': True,
            'observedFilePins': observed_pins}
    # Single-use own output only. An early/partial failure is never overwritten.
    safe(OUT)
    with (OUT / 'post.json').open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    print(json.dumps({'status': result['status'], 'analysisAccepted': False}, ensure_ascii=False))
    raise SystemExit(code)
