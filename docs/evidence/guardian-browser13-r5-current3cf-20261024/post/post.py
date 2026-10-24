"""Fixed file-only result derivation. No candidate imports or process/native APIs."""
from pathlib import Path
import hashlib
import json
import math
import ntpath
import os
import re
import stat
import sys

REPO = Path(r'D:\codes\mobile\ai-manager')
BASE = REPO / '.cache/guardian-browser13-20261024-r5-typed-finder-current3cf'
OUT = REPO / '.cache/guardian-browser13-post-20261024-r5-typed-finder-current3cf'
LAUNCHER = REPO / '.cache/guardian-browser13-root-launch-20261024-r5-typed-finder-current3cf.ps1'
COMMIT = '3cfbf535099ade86234661556d9e92db9069743a'
INPUT_SHA = '3e769ab0ecded31dc6b0927661591df69fb1e6199293145977e67ded236ecd92'
BUDGETS = {'outer': 180, 'working': 174, 'worker': 165, 'command': 135,
           'commandCleanup': 140, 'postflightReserve': 25}
NAMES = {'analysis-host.py', 'worker.py', 'owned_job.py', 'process-inventory.ps1', 'reporter_contract.py', 'owned_chrome_evidence.py'}
PROPOSAL_SHA = '1fa692d44a033e8ed6060e0b20803fcf565875177388807be17c3213a006cf02'
SELECTORS = ['test/editor_submit_guard_test.dart']
REPORTER_SHA = 'dcd85cf451b20bd24857cef6726d0f1ebb406c67096146d3d3c82306942b67e8'
CASE_SHA = '11f16121ffa11a0359852e5f0af7a830a83355b9fa55cec91edc85482d945f2b'
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
            'trees': 70, 'fixedFiles': 185, 'allMembersDirectoriesBytesAndHashesMatch': True,
            'totals': {'files': 3689, 'bytes': 646535928}}), 'Full cache guard summary differs')
    require(same(value.get('runtime'), {'sdkGitRevision': inputs['sdkBootstrap']['sdkGitRevision'],
            'controlAndExtraRuntimePinsMatch': True, 'snapshotAndStampReady': True,
            'pubspecNotNewerThanLock': True, 'forbiddenEnvironmentOverridesAbsent': True,
            'bootstrapAbsent': True, 'engineDartStampMatchesEngineVersion': True,
            'fixedProcessPathVerified': True, 'bootstrapAllowed': False}), 'SDK/runtime guard summary differs')


def chrome_evidence_valid(value, inputs, command_state, start, end, attempt):
    """Derive Chrome boundaries from pinned JSON; no process or network API."""
    import ipaddress
    import math
    import ntpath
    import re
    from urllib.parse import urlsplit

    def number(item):
        return type(item) is float and math.isfinite(item)

    def positive(item):
        return type(item) is int and item > 0

    def digest(item):
        return type(item) is str and re.fullmatch('[a-f0-9]{64}', item) is not None

    def canonical(item):
        if not (type(item) is str and 0 < len(item) <= 32766
                and re.match(r'^[A-Za-z]:[\\/]', item)
                and not any(ord(char) < 32 for char in item)
                and '..' not in item.replace('/', '\\').split('\\')):
            raise ValueError('Nonlocal or unsafe Chrome evidence path')
        drive, tail = ntpath.splitdrive(item)
        if ':' in tail:
            raise ValueError('ADS Chrome evidence path')
        return ntpath.normcase(ntpath.normpath(item))

    try:
        keys = {'schemaVersion', 'status', 'chromeRoots', 'problems', 'sampleCalls',
                'pinnedBrowserPath', 'temporaryRoot', 'commandCreationFiletime',
                'observationDeadlineQpc', 'commandLineSource', 'debugBindingProof',
                'foreignCommandLinesRead', 'processesTerminated', 'environmentRead',
                'nativeReadPathQualificationSeparate'}
        if not (type(value) is dict and set(value) == keys
                and type(value['schemaVersion']) is int and value['schemaVersion'] == 1
                and value['status'] == 'OWNED_CHROME_BOUNDARIES_OBSERVED'
                and type(value['problems']) is list and value['problems'] == []
                and positive(value['sampleCalls']) and value['sampleCalls'] <= 100000
                and value['foreignCommandLinesRead'] is False
                and value['processesTerminated'] is False and value['environmentRead'] is False
                and value['nativeReadPathQualificationSeparate'] is True
                and value['commandLineSource'] == 'SAME_RETAINED_HANDLE_PBI0_READPROCESSMEMORY'
                and value['debugBindingProof'] == 'PID_FILTERED_LISTEN_ROWS_BRACKETED_BY_SAME_HANDLE_IDENTITY'
                and type(command_state) is dict and positive(command_state.get('pid'))
                and positive(command_state.get('creationFiletime'))
                and positive(value['commandCreationFiletime'])
                and value['commandCreationFiletime'] == command_state['creationFiletime']
                and number(start) and number(end) and start < end
                and number(value['observationDeadlineQpc'])
                and value['observationDeadlineQpc'] == end):
            return False
        executable = canonical(inputs['browserExecutable']['path'])
        temporary = canonical(str(attempt / 'tmp'))
        if canonical(value['pinnedBrowserPath']) != executable or canonical(value['temporaryRoot']) != temporary:
            return False
        roots = value['chromeRoots']
        if type(roots) is not list or not 1 <= len(roots) <= 64:
            return False
        identities, profiles, ports = set(), set(), set()
        row_keys = {'pid', 'creationFiletime', 'commandCreationFiletime', 'imagePath', 'profile',
                    'debuggingPort', 'testServerOrigins', 'testTargets', 'managerTarget', 'headless',
                    'argvTestTargetLoopback', 'flutterManagerTargetSameLoopbackOrigin',
                    'commandLineUtf16Sha256', 'commandLineReadBeforeQpc', 'commandLineReadAfterQpc',
                    'sameReadHandleVerified', 'ownedMembershipVerifiedBeforeAndAfter', 'liveBeforeAndAfter',
                    'observedQpc', 'debugListenerAddresses', 'listenerReadBeforeQpc', 'listenerReadAfterQpc',
                    'listenerSameHandleIdentityVerifiedBeforeAndAfter', 'debugBindingLoopbackObserved'}
        for row in roots:
            if not (type(row) is dict and set(row) == row_keys
                    and positive(row['pid']) and row['pid'] != command_state['pid']
                    and positive(row['creationFiletime'])
                    and row['creationFiletime'] >= command_state['creationFiletime']
                    and positive(row['commandCreationFiletime'])
                    and row['commandCreationFiletime'] == command_state['creationFiletime']
                    and canonical(row['imagePath']) == executable
                    and positive(row['debuggingPort']) and row['debuggingPort'] < 65536
                    and all(row[key] is True for key in ('headless', 'argvTestTargetLoopback',
                        'flutterManagerTargetSameLoopbackOrigin', 'sameReadHandleVerified',
                        'ownedMembershipVerifiedBeforeAndAfter', 'liveBeforeAndAfter',
                        'listenerSameHandleIdentityVerifiedBeforeAndAfter', 'debugBindingLoopbackObserved'))
                    and digest(row['commandLineUtf16Sha256'])):
                return False
            identity = (row['pid'], row['creationFiletime'])
            profile = canonical(row['profile'])
            port = row['debuggingPort']
            if not profile.startswith(temporary.rstrip('\\') + '\\') or len(profile.split('\\')) > 64:
                return False
            if identity in identities or profile in profiles or port in ports:
                return False
            identities.add(identity); profiles.add(profile); ports.add(port)
            times = [row[key] for key in ('commandLineReadBeforeQpc', 'commandLineReadAfterQpc',
                'listenerReadBeforeQpc', 'listenerReadAfterQpc', 'observedQpc')]
            if not (all(number(item) for item in times)
                    and start <= times[0] <= times[1] <= times[2] <= times[3] == times[4] < end):
                return False
            targets, origins = row['testTargets'], row['testServerOrigins']
            if not (type(targets) is list and len(targets) == 1
                    and type(origins) is list and len(origins) == 1 and type(origins[0]) is str):
                return False
            target = targets[0]
            if not (type(target) is dict and set(target) == {'scheme', 'host', 'port', 'path', 'urlSha256'}
                    and target['scheme'] == 'http' and target['host'] in ('localhost', '127.0.0.1', '::1')
                    and positive(target['port']) and target['port'] < 65536
                    and target['path'] == '/static/index.html' and digest(target['urlSha256'])):
                return False
            manager = row['managerTarget']
            if not (type(manager) is dict and set(manager) == {'scheme', 'host', 'port'}
                    and type(manager['scheme']) is str and manager['scheme'] == 'ws'
                    and type(manager['host']) is str
                    and manager['host'] in ('localhost', '127.0.0.1', '::1')
                    and positive(manager['port']) and manager['port'] < 65536
                    and manager['host'] == target['host'] and manager['port'] == target['port']):
                return False
            origin = urlsplit(origins[0])
            if not (origin.scheme == 'http' and origin.hostname == target['host']
                    and origin.port == target['port'] and origin.path == ''
                    and origin.username is None and origin.password is None
                    and not origin.query and not origin.fragment):
                return False
            listeners = row['debugListenerAddresses']
            if type(listeners) is not list or not 1 <= len(listeners) <= 32:
                return False
            seen = set()
            for listener in listeners:
                if not (type(listener) is dict and set(listener) == {'address', 'port', 'family', 'status'}
                        and type(listener['address']) is str and len(listener['address']) <= 64
                        and type(listener['port']) is int and listener['port'] == port
                        and listener['status'] == 'LISTEN' and listener['family'] in ('AF_INET', 'AF_INET6')):
                    return False
                address = ipaddress.ip_address(listener['address'])
                if not (address.is_loopback and
                        ((address.version == 4 and listener['family'] == 'AF_INET')
                         or (address.version == 6 and listener['family'] == 'AF_INET6'))):
                    return False
                entry = (str(address), listener['port'], listener['family'], listener['status'])
                if entry in seen:
                    return False
                seen.add(entry)
        return True
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
        return False


def independent_browser13(raw, contract, module, log_pin):
    """Derive the fixed reporter result from ordinary JSON; import no helper."""
    require(type(contract) is dict and type(contract.get('schemaVersion')) is int
            and contract['schemaVersion'] == 1 and contract.get('module') == 'apps/guardian'
            and contract.get('platform') == 'Flutter chrome browser'
            and same(contract.get('selectors'), SELECTORS)
            and type(contract.get('expectedVisibleCases')) is int and contract['expectedVisibleCases'] == 13
            and type(contract.get('expectedTestRoots')) is int and contract['expectedTestRoots'] == 1
            and same(contract.get('sourceCaseCounts'), [13]), 'Exact BROWSER13 case contract required')
    require(type(contract.get('cases')) is list and len(contract['cases']) == 13,
            'Thirteen contract rows required')
    wanted = []
    for row in contract['cases']:
        require(type(row) is dict and type(row.get('selector')) is str and row['selector'] in SELECTORS
                and type(row.get('name')) is str and bool(row['name'].strip()), 'Malformed expected case')
        wanted.append((row['selector'], row['name']))
    require(len(set(wanted)) == 13 and [sum(path == selector for path, name in wanted)
            for selector in SELECTORS] == [13], 'Duplicate/misallocated expected names')
    require(type(raw) is bytes and 0 < len(raw) <= 16 * 1024 * 1024 and raw.endswith(b'\n'),
            'Bounded complete JSONL log required')
    text = raw.decode('utf-8-sig', errors='strict')
    lines = text.split('\n')[:-1]
    require(len(lines) <= 100000, 'Too many JSONL events')
    banner = 'Flutter assets will be downloaded from http://127.0.0.1:9. Make sure you trust this source!'
    bootstrap = int(bool(lines) and lines[0].removesuffix('\r') == banner)
    if bootstrap:
        lines = lines[1:]
    events = []
    for line in lines:
        line = line.removesuffix('\r')
        require(bool(line.strip()), 'Blank non-JSON line')
        value = decode(line.encode('utf-8'))
        pending = [value]
        while pending:
            node = pending.pop()
            if type(node) is float:
                require(math.isfinite(node), 'Nonfinite event number')
            elif type(node) is dict:
                pending.extend(node.values())
            elif type(node) is list:
                pending.extend(node)
        require(type(value.get('type')) is str, 'Event type missing')
        events.append(value)
    require(bool(events) and events[0]['type'] == 'start' and events[-1]['type'] == 'done',
            'Complete reporter start/done required')
    suites, groups, running, done = {}, {}, {}, {}
    identifiers, completed_names = set(), set()
    start_count = suite_count = finish_count = output_count = 0
    last_time = -1
    def natural_id(value):
        return type(value) is int and value >= 0
    def metadata(value):
        require(type(value) is dict and set(value) == {'skip', 'skipReason'}
                and value['skip'] is False and value['skipReason'] is None, 'Skip/malformed metadata')
    base = ntpath.normcase(ntpath.normpath(str(module)))
    for event in events:
        require(finish_count == 0, 'Reporter event after done')
        when = event.get('time')
        require(natural_id(when) and when >= last_time, 'Nonmonotonic reporter time')
        last_time = when
        kind = event['type']
        if kind == 'start':
            start_count += 1
            require(start_count == 1 and event is events[0] and event.get('protocolVersion') == '0.1.1'
                    and natural_id(event.get('pid')) and event['pid'] > 0
                    and 'runnerVersion' in event
                    and (event['runnerVersion'] is None
                         or (type(event['runnerVersion']) is str and bool(event['runnerVersion']))),
                    'Invalid reporter start')
        elif kind == 'allSuites':
            suite_count += 1
            require(suite_count == 1 and type(event.get('count')) is int and event['count'] == 1,
                    'Incorrect physical-suite discovery')
        elif kind in ('suite', 'group', 'testStart'):
            row = event.get({'suite': 'suite', 'group': 'group', 'testStart': 'test'}[kind])
            require(type(row) is dict and natural_id(row.get('id')) and row['id'] not in identifiers,
                    'Malformed/duplicate global event ID')
            identifier = row['id']
            identifiers.add(identifier)
            if kind == 'suite':
                require(row.get('platform') == 'chrome' and type(row.get('path')) is str
                        and bool(row['path']) and '\x00' not in row['path'] and '://' not in row['path']
                        and not row['path'].startswith(('\\\\', '//')), 'Non-Chrome or nonlocal suite')
                path = row['path']
                drive, tail = ntpath.splitdrive(path)
                require(':' not in tail and (not drive or ntpath.isabs(path)), 'ADS/drive-relative suite')
                absolute = ntpath.normcase(ntpath.normpath(
                    path if ntpath.isabs(path) else ntpath.join(base, path)))
                require(ntpath.commonpath([base, absolute]) == base and absolute != base,
                        'Suite outside module')
                selector = ntpath.relpath(absolute, base).replace('\\', '/')
                require(selector in SELECTORS and selector not in suites.values(), 'Unknown/duplicate selector')
                suites[identifier] = selector
            else:
                require(natural_id(row.get('suiteID')) and row['suiteID'] in suites,
                        'Unknown suite ownership')
                metadata(row.get('metadata'))
                if kind == 'group':
                    parent = row.get('parentID')
                    require(type(row.get('name')) is str and natural_id(row.get('testCount'))
                            and (parent is None or (natural_id(parent) and parent in groups
                            and groups[parent][0] == row['suiteID'])), 'Invalid group ancestry')
                    groups[identifier] = (row['suiteID'], parent)
                else:
                    memberships = row.get('groupIDs')
                    require(type(row.get('name')) is str and bool(row['name'].strip())
                            and type(memberships) is list and all(natural_id(g) for g in memberships)
                            and len(set(memberships)) == len(memberships), 'Malformed test/group IDs')
                    parent = None
                    for group in memberships:
                        require(group in groups and groups[group] == (row['suiteID'], parent),
                                'Group chain/suite mismatch')
                        parent = group
                    running[identifier] = (suites[row['suiteID']], row['name'])
        elif kind == 'testDone':
            identifier = event.get('testID')
            require(natural_id(identifier) and identifier in running and identifier not in done,
                    'Unknown/duplicate testDone')
            require(event.get('result') == 'success' and event.get('skipped') is False
                    and type(event.get('hidden')) is bool, 'Failure/error/skip completion')
            pair = running[identifier]
            require(pair not in completed_names, 'Duplicate completed name')
            completed_names.add(pair)
            require((pair not in wanted) if event['hidden'] else (pair in wanted),
                    'Hidden expected or unexpected visible case')
            done[identifier] = event['hidden']
        elif kind == 'print':
            require(natural_id(event.get('testID')) and event['testID'] in running
                    and event.get('messageType') == 'print' and type(event.get('message')) is str,
                    'Unexpected/skip print event')
            output_count += 1
        elif kind == 'error':
            raise ValueError('Reporter error, including late errors')
        elif kind == 'done':
            finish_count += 1
            require(event.get('success') is True, 'Terminal done false/null/missing')
        else:
            raise ValueError('Unknown reporter event: ' + kind)
    require(start_count == suite_count == finish_count == 1 and len(suites) == 1
            and set(running) == set(done), 'Incomplete reporter stream')
    visible, hidden = [], []
    for identifier, pair in running.items():
        row = {'selector': pair[0], 'name': pair[1], 'testID': identifier,
               'result': 'success', 'skipped': False, 'hidden': done[identifier]}
        (hidden if done[identifier] else visible).append(row)
    visible = sorted(visible, key=lambda row: (row['selector'], row['name']))
    hidden = sorted(hidden, key=lambda row: (row['selector'], row['name']))
    actual = [(row['selector'], row['name']) for row in visible]
    require(len(actual) == len(set(actual)) == 13 and set(actual) == set(wanted),
            '13 exact visible cases differ')
    return {'status': 'EXACT_BROWSER13_REPORT_ACCEPTED', 'protocolVersion': '0.1.1',
            'expectedSuiteCount': 1, 'actualSuiteCount': 1, 'suiteCount': 1,
            'suitePaths': sorted(suites.values()), 'expectedVisibleTests': 13,
            'visibleTests': 13, 'successfulVisibleTests': 13, 'failures': 0, 'errors': 0, 'skipped': 0,
            'actualVisibleCases': visible, 'hiddenSuccessfulTests': hidden,
            'allStartedTestsCompleted': True, 'terminalDoneSuccess': True,
            'eventCount': len(events), 'printEvents': output_count, 'bootstrapNotices': bootstrap,
            'logPin': log_pin, 'nativeExitAndJobChecksRemainCallerResponsibility': True}


def main(approved_sha):
    require(approved_sha == PROPOSAL_SHA, 'Supply the fixed BROWSER13 R1 approved proposal SHA')
    proposal_raw = read(BASE / 'proposal.json')
    require(hashlib.sha256(proposal_raw).hexdigest() == approved_sha, 'Approved proposal drift')
    proposal = decode(proposal_raw)
    require(set(proposal) == {'schemaVersion', 'phase', 'sourceCommit', 'inputs', 'candidateFiles',
            'runtimePins', 'pythonExecutable', 'budgets'}, 'Fixed proposal schema differs')
    require(type(proposal['schemaVersion']) is int and proposal['schemaVersion'] == 1
            and proposal['phase'] == 'guardian-browser13' and proposal['sourceCommit'] == COMMIT
            and proposal['pythonExecutable'] == 'C:/Python313/python.exe'
            and same(proposal['budgets'], BUDGETS), 'Proposal scope or original budgets differ')
    require(type(proposal['candidateFiles']) is list and len(proposal['candidateFiles']) == 6
            and {row.get('path') for row in proposal['candidateFiles'] if type(row) is dict} == NAMES,
            'Exact five candidate controls required')
    for row in proposal['candidateFiles']:
        descriptor(row, candidate=True)
    require(Path(proposal['inputs']['path']) == BASE / 'inputs.json'
            and type(proposal['inputs']['bytes']) is int and proposal['inputs']['bytes'] == 20346
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
    descriptor(inputs['ownedChromeEvidenceCode'])
    require(Path(inputs['ownedChromeEvidenceCode']['path']) == BASE / 'owned_chrome_evidence.py',
            'Fixed Chrome evidence code path differs')
    descriptor(inputs['ownedChromeNativeQualification'])
    chrome_qualification = load(Path(inputs['ownedChromeNativeQualification']['path']))
    require(chrome_qualification['observerCodeSha256'] == inputs['ownedChromeEvidenceCode']['sha256']
            and chrome_qualification['newNativeReadPathActuallyQualified'] is True
            and chrome_qualification['sdkOrChromeLifecycleOrTcpQualified'] is False,
            'Narrow actual reader qualification differs')
    descriptor(chrome_qualification['actualQualificationResult'])
    descriptor(chrome_qualification['actualOuterQualificationResult'])
    grant = load(BASE / 'root-sdk-grant.json')
    launcher_raw = read(LAUNCHER)
    launcher_sha = hashlib.sha256(launcher_raw).hexdigest()
    require(grant.get('status') == 'ROOT_APPROVED_SINGLE_FIXED_TEST'
            and grant.get('proposalSha256') == approved_sha and grant.get('launcherSha256') == launcher_sha
            and grant.get('sourceCommit') == COMMIT and type(grant.get('sdkCallsAllowed')) is int
            and grant['sdkCallsAllowed'] == 1, 'Root exact grant/launcher does not match')
    root_pre = load(BASE / 'root-attempt/preflight.json')
    root = load(BASE / 'root-attempt/result.json')
    require(root_pre.get('status') == 'ROOT_FIXED_BROWSER13_STARTED', 'Wrong Root preflight')
    for key, value in root_pre.items():
        if key != 'status':
            require(key in root and same(root[key], value), 'Root preflight/result field changed: ' + key)
    for row in (root_pre, root):
        require(row.get('sourceCommit') == COMMIT and row.get('proposalSha256') == approved_sha
                and row.get('launcherSha256') == launcher_sha, 'Root identity differs')
        require(type(row.get('sdkCount')) is int and row['sdkCount'] == 0
                and type(row.get('unknownCount')) is int and row['unknownCount'] == 0
                and type(row.get('maximumHostSeconds')) is int and row['maximumHostSeconds'] == 180
                and row.get('reusedBudget') is False and row.get('applicationTestsRequested') is True,
                'Root fresh preflight gate fields invalid')
        integer(row.get('availableRamBytes'), 2**31)
        require(type(row.get('disks')) is list and len(row['disks']) == 2
                and {item.get('Name') for item in row['disks']} == {'C', 'D'}, 'Root disk scope differs')
        for disk in row['disks']:
            integer(disk.get('Free'), 2**31)
    require(root.get('status') == 'ROOT_HOST_TERMINAL_PENDING_INDEPENDENT_BROWSER13_POST'
            and root.get('sameHandleSignaled') is True and type(root.get('actualHostExitCode')) is int
            and root['actualHostExitCode'] == 0 and root.get('rootForcedOwnHost') is False
            and root.get('emergencyCleanupAttempted') is False and root.get('failure') is None
            and root.get('hostTimelyAgainstOriginalRootAnchor') is True
            and root.get('candidateRuntimePinsMatchAfter') is True and root.get('rootHostTerminalAccepted') is True
            and root.get('testAccepted') is False, 'Root retained-handle natural exit proof rejected')
    integer(root.get('hostPid'), 1)
    for key in ('sameHandleCreationFiletime', 'sameHandleExitFiletime'):
        require(type(root.get(key)) is str and re.fullmatch('[1-9][0-9]*', root[key]) is not None,
                'Root FILETIME must be positive canonical decimal text')
    require(int(root['sameHandleExitFiletime']) >= int(root['sameHandleCreationFiletime']), 'Root retained FILETIME order invalid')
    root_signal = number(root.get('firstWaitSignaledElapsedSeconds'))
    require(0.0 <= root_signal < 180.0 and number(root.get('rootElapsedBeforeReceiptSeconds')) >= root_signal,
            'Root first same-handle signal was not within original180')

    require(type(proposal['runtimePins']) is list and len(proposal['runtimePins']) == 43, 'Runtime union changed')
    runtime = [descriptor(row) for row in proposal['runtimePins']]
    expected_runtime = [descriptor(row) for row in inputs['controlRuntimeFiles'] + inputs['extraRuntimeFiles']]
    require(len(runtime) == len(set(runtime)) == 43 and set(runtime) == set(expected_runtime),
            'Runtime union does not match exact input runtime guards')
    # Bound input metadata are read; external641MB cache payload is not rehashed
    # by this file-only post. Actual pre/post guard reports are cross-checked below.
    for key in ('sourceSeal', 'sourceManifest', 'sourceDirectoryList', 'dependencyLibraryPins',
                'candidatePackageConfig', 'candidatePackageConfigTemplate', 'originalPackageConfig',
                'fullRegressionInventoryBinding', 'expectedCaseContract', 'cacheManifest',
                'cacheProjectionParentManifest', 'qualifiedHostRuntimeManifest'):
        descriptor(inputs[key])

    require(grant.get('phase') == 'guardian-browser13' and grant.get('testsAllowed') is True
            and type(grant.get('selectedRoots')) is int and grant['selectedRoots'] == 1
            and type(grant.get('expectedVisibleCases')) is int and grant['expectedVisibleCases'] == 13,
            'Root BROWSER13 selection grant differs')
    require(Path(inputs['reporterContractCode']['path']) == BASE / 'reporter_contract.py'
            and type(inputs['reporterContractCode']['bytes']) is int and inputs['reporterContractCode']['bytes'] == 14280
            and inputs['reporterContractCode']['sha256'] == REPORTER_SHA
            and Path(inputs['testCaseContract']['path']) == BASE / 'expected-browser13-cases.json'
            and type(inputs['testCaseContract']['bytes']) is int and inputs['testCaseContract']['bytes'] == 6343
            and inputs['testCaseContract']['sha256'] == CASE_SHA,
            'Fixed reporter code/case contract descriptors differ')
    descriptor(inputs['reporterContractCode'])
    descriptor(inputs['testCaseContract'])
    case_contract = load(Path(inputs['testCaseContract']['path']))
    require(same(inputs.get('testSelectors'), SELECTORS)
            and type(inputs.get('expectedVisibleCases')) is int and inputs['expectedVisibleCases'] == 13
            and type(inputs.get('expectedBrowserTestRoots')) is int and inputs['expectedBrowserTestRoots'] == 1
            and type(inputs.get('otherFullRegressionRootsNotExecutedByThisBatch')) is int
            and inputs['otherFullRegressionRootsNotExecutedByThisBatch'] == 182,
            'BROWSER13 versus full183 scope differs')

    attempt = BASE / 'attempt'
    request = load(attempt / 'request.json')
    host = load(attempt / 'result.json')
    receipt = load(attempt / 'receipt.json')
    launch = load(attempt / 'launch.json')
    require(set(request) == {'approvedProposalSha256', 'qpcAnchor', 'workDeadlineQpc',
            'cleanupDeadlineQpc', 'sourceCommit', 'phase'}, 'Host request schema differs')
    anchor = qpc(request.get('qpcAnchor'))
    require(request.get('approvedProposalSha256') == approved_sha and request.get('sourceCommit') == COMMIT
            and request.get('phase') == 'guardian-browser13'
            and qpc(request.get('workDeadlineQpc')) == anchor + 174.0
            and qpc(request.get('cleanupDeadlineQpc')) == anchor + 180.0, 'Host request budget anchor differs')
    for key in request:
        require(key in host and same(host[key], request[key]), 'Host request/result field differs: ' + key)
    require(host.get('status') == 'GUARDIAN_BROWSER13_HOST_OBSERVED'
            and host.get('naturalCompleteTerminalTimely') is True and host.get('forcedCleanupRequested') is False
            and host.get('terminationCallSucceeded') is False and host.get('closedWithLiveOrUnknownMembers') is False
            and host.get('deadlineReached') is False and host.get('candidateAndRuntimePinsMatchAfter') is True
            and host.get('error') is None and host.get('testAcceptedBeforeOutput') is True
            and host.get('rootActualSameHandleExitStillRequired') is True
            and host.get('rootFullProcessReleaseStillRequired') is True
            and type(host.get('sdkCalls')) is int and host['sdkCalls'] == 1 and host.get('testsRun') is True,
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
    require(receipt.get('phaseScope') == 'GUARDIAN_BROWSER13'
            and receipt.get('workerBudgetSeconds') == 165 and type(receipt.get('workerBudgetSeconds')) is int
            and receipt.get('commandWorkerRelativeSeconds') == 135 and type(receipt.get('commandWorkerRelativeSeconds')) is int
            and receipt.get('commandCleanupWorkerRelativeSeconds') == 140 and type(receipt.get('commandCleanupWorkerRelativeSeconds')) is int
            and receipt.get('minimumPostflightReserveSeconds') == 25 and type(receipt.get('minimumPostflightReserveSeconds')) is int,
            'Reported fixed budget ceilings changed')
    for flag in ('forcedTermination', 'terminationCallSucceeded', 'commandCloseFallback', 'commandDeadlineReached', 'processNameProviderForced', 'postflightSkipped',
                 'pubRun', 'downloadsAllowed', 'cacheCopied', 'mainSourceWritten', 'nativeMemoryLimitClaimed'):
        require(receipt.get(flag) is False, 'Forbidden worker flag: ' + flag)
    require(type(receipt.get('sdkCalls')) is int and receipt['sdkCalls'] == 1
            and receipt.get('commandNaturalCompleteBeforeDeadline') is True
            and receipt.get('testsRun') is True and receipt.get('exactTestReportAccepted') is True
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
        r'D:\softwares\flutter\bin\flutter.bat --no-version-check --suppress-analytics test --platform=chrome --no-pub --web-renderer=html --reporter=json test/editor_submit_guard_test.dart']
    require(same(launch.get('argv'), expected_argv)
            and launch.get('workingDirectory') == str(REPO / '.cache/guardian-current-20261024-r16-typed-schedule-finder/src/apps/guardian')
            and type(launch.get('pid')) is int and launch['pid'] == command['pid']
            and type(launch.get('creationFiletime')) is int and launch['creationFiletime'] == command['creationFiletime']
            and type(launch.get('selectorCount')) is int and launch['selectorCount'] == 1
            and same(launch.get('selectors'), SELECTORS)
            and type(launch.get('expectedVisibleCases')) is int and launch['expectedVisibleCases'] == 13
            and same(launch.get('testCaseContractPin'), inputs['testCaseContract'])
            and same(launch.get('reporterContractCodePin'), inputs['reporterContractCode']),
            'Fixed command launch identity/argv/module differs')
    require(same(launch.get('sdkProcessSafeDirectories'),
                 [REPO.as_posix(), Path(r'D:\softwares\flutter').as_posix()]),
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
    chrome_pin = receipt.get('ownedChromeEvidencePin')
    require(type(chrome_pin) is dict
            and Path(chrome_pin.get('path', '')) == attempt / 'owned-chrome-evidence.json'
            and receipt.get('ownedChromeBoundariesAccepted') is True
            and same(receipt.get('ownedChromeEvidenceCodePin'), inputs['ownedChromeEvidenceCode'])
            and same(receipt.get('browserExecutablePin'), inputs['browserExecutable']),
            'Bound raw Chrome evidence descriptor missing')
    descriptor(chrome_pin)
    chrome_raw = load(Path(chrome_pin['path']))
    descriptor(chrome_pin)
    require(same(chrome_raw, receipt.get('ownedChromeEvidence'))
            and chrome_evidence_valid(chrome_raw, inputs, command, start, start + 135.0, attempt),
            'Chrome ownership/profile/actual-loopback evidence does not independently derive')
    require(launch.get('chromeExecutable') == inputs['browserExecutable']['path']
            and same(launch.get('browserToolSources'), inputs['browserToolSources'])
            and same(launch.get('ownedChromeEvidenceCodePin'), inputs['ownedChromeEvidenceCode']),
            'Fixed Chrome executable/tool-source environment launch differs')
    log_path = attempt / 'out/tests.jsonl'
    require(Path(receipt.get('logPin', {}).get('path', '')) == log_path, 'Fixed BROWSER13 JSON log required')
    descriptor(receipt['logPin'])
    raw_log = read(log_path, 16 * 1024 * 1024)
    log_pin = {'path': str(log_path), 'bytes': len(raw_log), 'sha256': hashlib.sha256(raw_log).hexdigest()}
    require(same(log_pin, receipt['logPin']), 'Raw log pin differs')
    require(same(receipt.get('reporterContractCodePin'), inputs['reporterContractCode'])
            and same(receipt.get('testCaseContractPin'), inputs['testCaseContract']),
            'Receipt reporter provenance differs')
    require(Path(receipt.get('reporterValidationPin', {}).get('path', '')) == attempt / 'reporter-validation.json',
            'Fixed raw reporter validation path required')
    descriptor(receipt['reporterValidationPin'])
    raw_validation = load(attempt / 'reporter-validation.json')
    independently_derived = independent_browser13(raw_log, case_contract,
        REPO / '.cache/guardian-current-20261024-r16-typed-schedule-finder/src/apps/guardian', log_pin)
    require(same(raw_validation, receipt.get('reporterValidation'))
            and same(independently_derived, raw_validation),
            'Independent raw JSON derivation differs from reporter raw/embedded result')
    descriptor(receipt['logPin'])
    descriptor(receipt['reporterValidationPin'])
    descriptor(inputs['reporterContractCode'])
    descriptor(inputs['testCaseContract'])
    console = decode(read(attempt / 'worker-console.log', 1024 * 1024))
    require(same(console, {'status': 'GUARDIAN_BROWSER13_WORKER_PASSED', 'sdkCalls': 1,
                          'elapsedCompleteSeconds': receipt['elapsedCompleteSeconds']}), 'Worker console outcome differs')
    derived_worker = True  # Reached only after independent file/timing/identity/guard checks above.
    reported_worker = receipt.get('status') == 'GUARDIAN_BROWSER13_WORKER_PASSED'
    require(reported_worker is derived_worker and host.get('workerReportedPassed') is reported_worker
            and host.get('workerDerivedPassed') is derived_worker and host.get('workerReportedDerivedConsistent') is True,
            'Worker/host reported versus independently derived outcome differs')
    return {'status': 'DERIVED_BROWSER13_CONSISTENT_PENDING_ROOT_RELEASE', 'sourceCommit': COMMIT,
        'approvedProposalSha256': approved_sha, 'rootRecordedSameHandleNaturalZero': True,
        'rootRecordedFirstWaitSeconds': root_signal, 'hostOriginalBudgets': BUDGETS,
        'workerDerivedConsistent': True, 'sdkCalls': 1, 'applicationTestsRun': True,
        'reporterDerivedConsistent': True, 'independentReporterValidation': independently_derived,
        'ownedChromeEvidenceIndependentlyDerived': True, 'ownedChromeEvidencePin': chrome_pin,
        'chromeBoundaries': {'roots': len(chrome_raw['chromeRoots']),
            'sameHandleOwnJobRead': True, 'privateProfiles': True, 'headless': True,
            'testTargetLoopback': True, 'debugLoopbackListenerActuallyObserved': True,
            'auxiliaryCleanupUsed': False, 'foreignCommandLinesRead': False},
        'selectedTestRoots': 1, 'expectedVisibleCases': 13, 'otherFullRegressionRootsNotExecutedByThisBatch': 182,
        'hostPreOutputElapsedNotUsedAsOuterExit': True,
        'rootActualToolTerminalEvidenceInspected': False, 'freshFullProcessReleaseInspected': False,
        'rootActualToolTerminalStillRequired': True, 'freshFullProcessReleaseStillRequired': True,
        'testAccepted': False, 'runtimeClosureComplete': False,
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
            'reason': str(error), 'testAccepted': False,
            'rootActualToolTerminalStillRequired': True, 'freshFullProcessReleaseStillRequired': True,
            'observedFilePins': observed_pins}
    # Single-use own output only. An early/partial failure is never overwritten.
    safe(OUT)
    with (OUT / 'post.json').open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    print(json.dumps({'status': result['status'], 'testAccepted': False}, ensure_ascii=False))
    raise SystemExit(code)
