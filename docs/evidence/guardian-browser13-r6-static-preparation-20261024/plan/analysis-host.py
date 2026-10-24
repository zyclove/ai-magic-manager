"""Fixed BROWSER13 host source; requires a separately granted exact proposal SHA."""
from time import monotonic
ANCHOR = monotonic()
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import sys
import time

HERE = Path(__file__).absolute().parent
EXPECTED_HERE = Path(r'D:\codes\mobile\ai-manager\.cache\guardian-browser13-20261024-r6-owned-member-finality')
PYTHON = Path(r'C:\Python313\python.exe')
SOURCE_COMMIT = '3cfbf535099ade86234661556d9e92db9069743a'
INPUT_BYTES = 20342
INPUT_SHA256 = '1269013619e239151e3048b7fc1d3caaa4f00cfd1036e383cc6960ccbfb7ee73'
PROCESS_INVENTORY_SHA256 = 'f3c4349381fb6fc612b322e1a2a7ba59b6b21e4653e3212bfbac2b252028a046'
BUDGETS = {'outer': 180, 'working': 174, 'worker': 165, 'command': 135,
           'commandCleanup': 140, 'postflightReserve': 25}
NAMES = {'analysis-host.py', 'worker.py', 'owned_job.py', 'process-inventory.ps1', 'reporter_contract.py', 'owned_chrome_evidence.py'}
SDK_NAMES = {'java.exe', 'javaw.exe', 'javac.exe', 'dart.exe', 'dartaotruntime.exe',
             'go.exe', 'gofmt.exe', 'flutter.exe', 'flutter_tester.exe', 'gen_snapshot.exe',
             'aapt2.exe', 'qemu-system-x86_64.exe', 'compile.exe', 'link.exe', 'asm.exe', 'cgo.exe',
             'mvn.exe', 'gradle.exe', 'vet.exe'}
WORK_END = ANCHOR + 174.0
FINISH_END = ANCHOR + 180.0


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def finite(value):
    return type(value) is float and math.isfinite(value)


def before(deadline):
    require(finite(deadline) and monotonic() < deadline, 'Original deadline exhausted')


def safe(path):
    path = Path(path)
    require(path.is_absolute() and not str(path).startswith('\\\\')
            and ':' not in str(path)[2:], 'Local absolute non-ADS path required')
    for item in (path, *path.parents):
        require(not item.is_symlink() and not item.is_junction(), 'Linked path refused')
    return path


def digest(path, deadline):
    before(deadline)
    path = safe(path)
    first = path.stat()
    require(path.is_file(), 'Regular pinned file required')
    value = hashlib.sha256()
    count = 0
    with path.open('rb') as stream:
        while True:
            before(deadline)
            part = stream.read(1024 * 1024)
            if not part:
                break
            value.update(part)
            count += len(part)
    last = safe(path).stat()
    require((first.st_dev, first.st_ino, first.st_nlink, first.st_size, first.st_mtime_ns)
            == (last.st_dev, last.st_ino, last.st_nlink, last.st_size, last.st_mtime_ns)
            and count == first.st_size, 'Input changed during hash')
    before(deadline)
    return count, value.hexdigest()


def descriptor(row, deadline, *, candidate=False):
    require(type(row) is dict and set(row) in
            ({'path', 'bytes', 'sha256'}, {'path', 'bytes', 'sha256', 'absolute'}),
            'Exact descriptor fields required')
    require(type(row['path']) is str and type(row['bytes']) is int and row['bytes'] >= 0
            and type(row['sha256']) is str
            and re.fullmatch('[a-f0-9]{64}', row['sha256']) is not None,
            'Typed descriptor required')
    if 'absolute' in row:
        require(row['absolute'] is True, 'Only true absolute marker permitted')
    if candidate:
        require(row['path'] in NAMES and 'absolute' not in row, 'Fixed relative control file required')
        path = HERE / row['path']
    else:
        path = Path(row['path'])
        require(path.is_absolute(), 'Absolute runtime/input descriptor required')
    count, observed = digest(path, deadline)
    require(count == row['bytes'] and observed == row['sha256'], 'Pinned input changed: ' + str(path))
    return str(path).casefold(), count, observed


def save(path, value):
    with path.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, ensure_ascii=True, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def complete_terminal(state):
    return (type(state) is dict and state.get('terminal') is True
            and state.get('signaled') is True and type(state.get('exitCode')) is int
            and type(state.get('activeProcesses')) is int and state['activeProcesses'] == 0
            and type(state.get('creationFiletime')) is int and state['creationFiletime'] > 0
            and type(state.get('exitFiletime')) is int
            and state['exitFiletime'] >= state['creationFiletime']
            and finite(state.get('firstSignaledQpc'))
            and finite(state.get('firstCompleteTerminalQpc')))


def clear_name_inventory(value):
    if type(value) is not dict or set(value) != {'schemaVersion', 'provider', 'purpose', 'powerShellVersion',
                     'sampleStartedAtUtc', 'sampleFinishedAtUtc', 'enumerationSucceeded',
                     'providerErrors', 'rowCount', 'rows'}:
        return False
    if not (type(value['schemaVersion']) is int and value['schemaVersion'] == 1
            and value['provider'] == 'PowerShell7 Get-Process / System.Diagnostics.Process'
            and value['purpose'] == 'FULL_FRESH_NAME_INVENTORY_NOT_PROCESS_CONTROL_IDENTITY'
            and value['powerShellVersion'] == '7.6.5'
            and all(type(value[key]) is str and value[key].strip()
                    for key in ('sampleStartedAtUtc', 'sampleFinishedAtUtc'))
            and value['enumerationSucceeded'] is True
            and type(value['providerErrors']) is list and value['providerErrors'] == []
            and type(value['rowCount']) is int and value['rowCount'] > 0
            and type(value['rows']) is list and len(value['rows']) == value['rowCount']):
        return False
    seen = set()
    for row in value['rows']:
        if not (type(row) is dict and set(row) == {'pid', 'name', 'errors'}
                and type(row['pid']) is int and row['pid'] >= 0 and row['pid'] not in seen
                and type(row['name']) is str and row['name'].strip()
                and type(row['errors']) is list and row['errors'] == []):
            return False
        seen.add(row['pid'])
        lowered = row['name'].lower()
        stem = lowered[:-4] if lowered.endswith('.exe') else lowered
        if stem + '.exe' in SDK_NAMES or stem.endswith('.test'):
            return False
    return True


def same_json(left, right):
    # Canonical JSON keeps bool/int/float distinctions; NaN/Infinity are refused.
    return json.dumps(left, sort_keys=True, ensure_ascii=False, separators=(',', ':'), allow_nan=False) == json.dumps(
        right, sort_keys=True, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def reporter_inputs(inputs, deadline):
    code_row = inputs['reporterContractCode']
    contract_row = inputs['testCaseContract']
    for row in (code_row, contract_row):
        require(type(row) is dict and set(row) == {'path', 'bytes', 'sha256'}
                and type(row['bytes']) is int and row['bytes'] > 0,
                'Exact typed reporter code/contract descriptor required')
        descriptor(row, deadline)
    require(Path(code_row['path']) == HERE / 'reporter_contract.py',
            'Only the fixed pinned reporter helper may be imported')
    contract = json.loads(Path(contract_row['path']).read_bytes())
    spec = importlib.util.spec_from_file_location('guardian_browser13_host_reporter', Path(code_row['path']))
    reporter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reporter)
    descriptor(code_row, deadline)
    require(callable(getattr(reporter, 'validate_report', None)), 'Fixed reporter interface missing')
    before(deadline)
    return reporter, contract


def _chrome_roots_schema1_valid(value, inputs, command_state, start, end, attempt):
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


def chrome_evidence_valid(value, inputs, command_state, start, end, attempt):
    """Schema2: derive lifecycle closure while preserving unknown images as unknown."""
    import json
    import math
    import ntpath
    import re

    def exact(item, keys):
        return type(item) is dict and set(item) == set(keys.split())

    def uint(item, bits=64, positive=False):
        return type(item) is int and (0 < item if positive else 0 <= item) and item < (1 << bits)

    def qpc(item):
        return type(item) is float and math.isfinite(item)

    def path(item):
        if not (type(item) is str and 0 < len(item) <= 32766
                and re.match(r'^[A-Za-z]:[\\/]',item) and not any(ord(c)<32 for c in item)
                and '..' not in item.replace('/','\\').split('\\')):
            return False
        return ':' not in ntpath.splitdrive(item)[1]

    def pid_list(item):
        if not exact(item,'qpc complete assigned listed limit error pids'):
            return False
        pids=item['pids']
        return (qpc(item['qpc']) and start <= item['qpc'] < d
            and item['complete'] is True and type(item['error']) is int and item['error']==0
            and type(item['limit']) is int and item['limit']==32
            and type(pids) is list and len(pids)<=32
            and all(uint(pid,32,True) for pid in pids) and len(set(pids))==len(pids)
            and type(item['assigned']) is int and type(item['listed']) is int
            and item['assigned']==item['listed']==len(pids))

    def member(row):
        if type(row) is not dict or type(row.get('signaled')) is not bool:
            return False
        keys=set('pid openedFromOwnJobList verifiedOwnMembership retainedRootHandleUsed creationFiletime exitFiletime kernel100ns user100ns sampleQpc signaled'.split())
        keys.add('imagePath' if 'imagePath' in row else 'imageError')
        if row['signaled']:
            keys.add('exitCode')
        if not (set(row)==keys and uint(row['pid'],32,True)
                and row['openedFromOwnJobList'] is True and row['verifiedOwnMembership'] is True
                and type(row['retainedRootHandleUsed']) is bool
                and row['retainedRootHandleUsed']==(row['pid']==command_state['pid'])
                and uint(row['creationFiletime'],64,True)
                and row['creationFiletime']>=command_state['creationFiletime']
                and (row['pid']!=command_state['pid'] or row['creationFiletime']==command_state['creationFiletime'])
                and all(uint(row[key]) for key in ('exitFiletime','kernel100ns','user100ns'))
                and (row['exitFiletime']==0 or row['exitFiletime']>=row['creationFiletime'])
                and qpc(row['sampleQpc']) and start<=row['sampleQpc']<d):
            return False
        if row['signaled'] and not (row['exitFiletime']>0 and uint(row['exitCode'],32)):
            return False
        if 'imagePath' in row:
            return 'known' if path(row['imagePath']) else False
        return 'pending' if uint(row['imageError'],32) else False

    def snapshot(raw, empty=False):
        if not (exact(raw,'startedQpc deadlineQpc before identities after identityRowsLimitedByDeadline scope causeClassified')
                and raw['scope']=='This private Job only; read-only handles, no command line/environment, no PID termination'
                and raw['causeClassified'] is False and raw['identityRowsLimitedByDeadline'] is False
                and qpc(raw['startedQpc']) and qpc(raw['deadlineQpc'])
                and raw['deadlineQpc'] in (end,d)
                and pid_list(raw['before']) and pid_list(raw['after'])
                and raw['startedQpc']==raw['before']['qpc']<=raw['after']['qpc']<min(d,raw['deadlineQpc'])
                and type(raw['identities']) is list):
            return False
        if empty:
            return raw['deadlineQpc']==d and raw['before']['pids']==raw['after']['pids']==raw['identities']==[]
        rows=raw['identities']
        if not (all(type(row) is dict and uint(row.get('pid'),32,True) for row in rows)
                and sorted(row['pid'] for row in rows)==sorted(raw['before']['pids'])):
            return False
        return all(member(row) and raw['before']['qpc']<=row['sampleQpc']<=raw['after']['qpc'] for row in rows)

    def natural(state):
        return (exact(state,'pid creationFiletime firstSignaledQpc sampleQpc signaled exitCode exitFiletime kernel100ns user100ns jobAccountingObservedQpc firstCompleteTerminalQpc activeProcesses totalProcesses terminatedProcesses terminal')
            and uint(state['pid'],32,True) and uint(state['creationFiletime'],64,True)
            and state['pid']==command_state['pid'] and state['creationFiletime']==command_state['creationFiletime']
            and state['terminal'] is True and state['signaled'] is True
            and type(state['exitCode']) is int and state['exitCode']==0
            and type(state['activeProcesses']) is int and state['activeProcesses']==0
            and uint(state['totalProcesses'],32,True) and uint(state['terminatedProcesses'],32)
            and state['terminatedProcesses']<=state['totalProcesses']
            and uint(state['exitFiletime'],64,True) and state['exitFiletime']>=state['creationFiletime']
            and uint(state['kernel100ns']) and uint(state['user100ns'])
            and all(qpc(state[key]) for key in ('firstSignaledQpc','sampleQpc','jobAccountingObservedQpc','firstCompleteTerminalQpc'))
            and start<=state['firstSignaledQpc']<=state['sampleQpc']<=state['jobAccountingObservedQpc']<d
            and state['firstSignaledQpc']<=state['firstCompleteTerminalQpc']<=state['jobAccountingObservedQpc'])

    try:
        top='schemaVersion status chromeRoots problems sampleCalls pinnedBrowserPath temporaryRoot commandCreationFiletime observationDeadlineQpc commandLineSource debugBindingProof foreignCommandLinesRead processesTerminated environmentRead nativeReadPathQualificationSeparate observedProblems failureLedger terminalFinality'
        if not (exact(value,top) and type(value['schemaVersion']) is int and value['schemaVersion']==2
                and value['status']=='OWNED_CHROME_BOUNDARIES_OBSERVED' and value['problems']==[]
                and type(value['problems']) is list and type(value['observedProblems']) is list
                and uint(value['sampleCalls'],32,True) and value['sampleCalls']<=100000
                and qpc(start) and qpc(end) and start<end and type(command_state) is dict
                and qpc(command_state.get('firstSignaledQpc'))):
            return False
        d=min(end,command_state['firstSignaledQpc']+0.5)
        if not natural(command_state):
            return False
        final=value['terminalFinality']
        if not (exact(final,'schemaVersion source jobRootPid jobRootCreationFiletime originalCommandDeadlineQpc deadlineQpc naturalDrainSeconds A0 M A1 forceRequested closeFallback')
                and type(final['schemaVersion']) is int and final['schemaVersion']==1
                and final['source']=='SAME_COMMAND_OWNED_JOB'
                and type(final['jobRootPid']) is int and final['jobRootPid']==command_state['pid']
                and type(final['jobRootCreationFiletime']) is int and final['jobRootCreationFiletime']==command_state['creationFiletime']
                and qpc(final['originalCommandDeadlineQpc']) and final['originalCommandDeadlineQpc']==end
                and qpc(final['deadlineQpc']) and final['deadlineQpc']==d
                and type(final['naturalDrainSeconds']) is float and final['naturalDrainSeconds']==0.5
                and final['forceRequested'] is False and final['closeFallback'] is False
                and natural(final['A0']) and natural(final['A1']) and snapshot(final['M'],True)):
            return False
        a0,a1,m=final['A0'],final['A1'],final['M']
        stable=set(command_state)-{'sampleQpc','jobAccountingObservedQpc'}
        if not (all(a0[key]==command_state[key]==a1[key] for key in stable)
                and command_state['jobAccountingObservedQpc']<=a0['sampleQpc']
                and a0['jobAccountingObservedQpc']<=m['before']['qpc']<=m['after']['qpc']<=a1['sampleQpc']):
            return False
        ledger=value['failureLedger']
        ledger_keys='schemaVersion maximumFailureSnapshots maximumSerializedBytes totalFailureSnapshotsSeen storedFailureSnapshots droppedFailureSnapshots overflow snapshots firstIdentityObservations identityConflicts pendingOccurrences resolvedOccurrences fatalProblems'
        if not (exact(ledger,ledger_keys) and type(ledger['schemaVersion']) is int and ledger['schemaVersion']==1
                and type(ledger['maximumFailureSnapshots']) is int and ledger['maximumFailureSnapshots']==8
                and type(ledger['maximumSerializedBytes']) is int and ledger['maximumSerializedBytes']==262144
                and uint(ledger['totalFailureSnapshotsSeen'],32) and uint(ledger['storedFailureSnapshots'],32)
                and type(ledger['droppedFailureSnapshots']) is int and ledger['droppedFailureSnapshots']==0
                and ledger['overflow'] is False and ledger['identityConflicts']==[] and type(ledger['identityConflicts']) is list
                and ledger['fatalProblems']==[] and type(ledger['fatalProblems']) is list
                and all(type(ledger[key]) is list for key in ('snapshots','firstIdentityObservations','pendingOccurrences','resolvedOccurrences'))
                and ledger['totalFailureSnapshotsSeen']==ledger['storedFailureSnapshots']==len(ledger['snapshots'])<=8
                and len((json.dumps(ledger,ensure_ascii=True,indent=2,allow_nan=False)+'\n').encode('utf-8'))<=262144):
            return False
        first={}
        last_ordinal=0
        for observation in ledger['firstIdentityObservations']:
            if not (exact(observation,'sampleOrdinal pid creationFiletime rawRow')
                    and uint(observation['sampleOrdinal'],32,True)
                    and last_ordinal<=observation['sampleOrdinal']<=value['sampleCalls']
                    and uint(observation['pid'],32,True) and observation['pid'] not in first
                    and member(observation['rawRow'])
                    and observation['pid']==observation['rawRow']['pid']
                    and observation['rawRow']['sampleQpc']<=a0['sampleQpc']
                    and type(observation['creationFiletime']) is int
                    and observation['creationFiletime']==observation['rawRow']['creationFiletime']):
                return False
            first[observation['pid']]=observation
            last_ordinal=observation['sampleOrdinal']
        pending=[]
        raw_pending=[]
        last_ordinal=0
        for index,frame in enumerate(ledger['snapshots']):
            if not (exact(frame,'sampleOrdinal jobRootPid jobRootCreationFiletime rawSnapshot afterOnlyNotQueried')
                    and uint(frame['sampleOrdinal'],32,True) and last_ordinal<frame['sampleOrdinal']<=value['sampleCalls']
                    and type(frame['jobRootPid']) is int and frame['jobRootPid']==command_state['pid']
                    and type(frame['jobRootCreationFiletime']) is int and frame['jobRootCreationFiletime']==command_state['creationFiletime']
                    and snapshot(frame['rawSnapshot'])):
                return False
            raw=frame['rawSnapshot']
            if raw['after']['qpc']>a0['sampleQpc']:
                return False
            if any(observation['sampleOrdinal']==frame['sampleOrdinal']
                   and observation['rawRow'] not in raw['identities'] for observation in first.values()):
                return False
            after_only=sorted(set(raw['after']['pids'])-set(raw['before']['pids']))
            if not (type(frame['afterOnlyNotQueried']) is list and all(uint(pid,32,True) for pid in frame['afterOnlyNotQueried'])
                    and frame['afterOnlyNotQueried']==after_only):
                return False
            count_before=len(pending)
            for row_index,row in enumerate(raw['identities']):
                observation=first.get(row['pid'])
                if not (observation is not None and observation['creationFiletime']==row['creationFiletime']
                        and observation['sampleOrdinal']<=frame['sampleOrdinal']
                        and observation['rawRow']['sampleQpc']<=row['sampleQpc']):
                    return False
                if member(row)=='pending':
                    pending.append(dict(snapshotIndex=index,rowIndex=row_index,sampleOrdinal=frame['sampleOrdinal'],
                        pid=row['pid'],creationFiletime=row['creationFiletime']))
                    raw_pending.append((frame['sampleOrdinal'],row))
            if len(pending)==count_before:
                return False
            last_ordinal=frame['sampleOrdinal']
        for observation in first.values():
            if member(observation['rawRow'])=='pending' and not any(
                    ordinal==observation['sampleOrdinal'] and row==observation['rawRow'] for ordinal,row in raw_pending):
                return False
        if ledger['pendingOccurrences']!=pending:
            return False
        for entry in ledger['pendingOccurrences']:
            if not exact(entry,'snapshotIndex rowIndex sampleOrdinal pid creationFiletime') or not all(type(item) is int for item in entry.values()):
                return False
        resolved=[dict(entry,resolution='OWNED_MEMBER_CLOSED_IMAGE_UNKNOWN') for entry in pending]
        if ledger['resolvedOccurrences']!=resolved:
            return False
        for entry in ledger['resolvedOccurrences']:
            if not (exact(entry,'snapshotIndex rowIndex sampleOrdinal pid creationFiletime resolution')
                    and all(type(entry[key]) is int for key in ('snapshotIndex','rowIndex','sampleOrdinal','pid','creationFiletime'))
                    and type(entry['resolution']) is str):
                return False
        if value['observedProblems'] != (['OWN_JOB_MEMBER_IDENTITY_UNPROVED'] if pending else []):
            return False
        for root in value['chromeRoots']:
            observation=first.get(root['pid'])
            if (observation is None or observation['creationFiletime']!=root['creationFiletime']
                    or not qpc(root['observedQpc']) or root['observedQpc']>a0['sampleQpc']):
                return False
        old={key:item for key,item in value.items() if key not in ('observedProblems','failureLedger','terminalFinality')}
        old['schemaVersion']=1
        return _chrome_roots_schema1_valid(old,inputs,command_state,start,end,attempt)
    except (KeyError,TypeError,ValueError,AttributeError,OverflowError,RecursionError):
        return False


def worker_outcome(receipt, terminal, before_resume, attempt, inputs):
    if type(receipt) is not dict or not finite(before_resume) or not complete_terminal(terminal):
        return False
    start = receipt.get('workerStartQpc')
    finished = receipt.get('workerFinishedQpc')
    elapsed = receipt.get('elapsedCompleteSeconds')
    if not (finite(start) and finite(finished) and finite(elapsed)
            and before_resume <= start <= finished <= terminal['firstSignaledQpc']
            and 0.0 <= elapsed < 165.0 and elapsed == finished - start
            and receipt.get('workerDeadlineQpc') == start + 165.0
            and type(receipt.get('workerDeadlineQpc')) is float
            and receipt.get('commandDeadlineQpc') == start + 135.0
            and type(receipt.get('commandDeadlineQpc')) is float
            and receipt.get('commandCleanupDeadlineQpc') == start + 140.0
            and type(receipt.get('commandCleanupDeadlineQpc')) is float
            and terminal['firstCompleteTerminalQpc'] < start + 165.0):
        return False
    if not (type(receipt.get('sdkCalls')) is int and receipt['sdkCalls'] == 1
            and receipt.get('forcedTermination') is False
            and receipt.get('processNameProviderForced') is False
            and receipt.get('postflightSkipped') is False
            and receipt.get('commandCloseFallback') is False
            and receipt.get('commandNaturalCompleteBeforeDeadline') is True
            and receipt.get('exactTestReportAccepted') is True
            and type(receipt.get('reporterValidation')) is dict
            and receipt['reporterValidation'].get('status') == 'EXACT_BROWSER13_REPORT_ACCEPTED'
            and receipt.get('testsRun') is True and receipt.get('pubRun') is False
            and receipt.get('downloadsAllowed') is False and receipt.get('cacheCopied') is False
            and receipt.get('mainSourceWritten') is False
            and type(receipt.get('preflight')) is dict
            and receipt['preflight'].get('complete') is True
            and type(receipt.get('postflight')) is dict
            and receipt['postflight'].get('complete') is True
            and 'errorType' not in receipt
            and not any(name.endswith('Error') for name in receipt)):
        return False
    first = receipt.get('commandTerminalState')
    last = receipt.get('commandTerminalStateAfterPostflight')
    if not (complete_terminal(first) and complete_terminal(last)
            and first['exitCode'] == 0 and last['exitCode'] == 0
            and first['creationFiletime'] == last['creationFiletime']
            and first['firstSignaledQpc'] == last['firstSignaledQpc']
            and first['firstCompleteTerminalQpc'] == last['firstCompleteTerminalQpc']
            and start <= first['firstSignaledQpc'] <= first['firstCompleteTerminalQpc']
            < min(start + 135.0, first['firstSignaledQpc'] + 0.5)):
        return False
    gate = receipt.get('resourceAfter')
    if not (type(gate) is dict
            and gate.get('processNameProviderScriptSha256') == PROCESS_INVENTORY_SHA256
            and clear_name_inventory(gate.get('processNameInventory'))
            and type(gate.get('sdkProcesses')) is list
            and gate['sdkProcesses'] == [] and type(gate.get('unknownProcessNames')) is list
            and gate['unknownProcessNames'] == []
            and type(gate.get('availableRamBytes')) is int and gate['availableRamBytes'] >= 2**31
            and type(gate.get('diskFreeBytes')) is dict
            and set(gate['diskFreeBytes']) == {'C:/', 'D:/'}
            and all(type(v) is int and v >= 2**31 for v in gate['diskFreeBytes'].values())):
        return False
    chrome_pin = receipt.get('ownedChromeEvidencePin')
    if not (receipt.get('ownedChromeBoundariesAccepted') is True
            and same_json(receipt.get('ownedChromeEvidenceCodePin'), inputs['ownedChromeEvidenceCode'])
            and same_json(receipt.get('browserExecutablePin'), inputs['browserExecutable'])
            and type(chrome_pin) is dict
            and Path(chrome_pin.get('path', '')) == attempt / 'owned-chrome-evidence.json'):
        return False
    descriptor(chrome_pin, FINISH_END)
    require(chrome_pin['bytes'] <= 2 * 1024 * 1024, 'Bounded Chrome evidence required')
    chrome_raw = json.loads(Path(chrome_pin['path']).read_bytes())
    descriptor(chrome_pin, FINISH_END)
    for field, filename, embedded, maximum in (
            ('ownedMemberFailureLedgerPin', 'member-failure-ledger.json', 'failureLedger', 262144),
            ('commandJobFinalityPin', 'command-job-finality.json', 'terminalFinality', 65536)):
        raw_pin = receipt.get(field)
        if not (type(raw_pin) is dict and Path(raw_pin.get('path', '')) == attempt / filename):
            return False
        descriptor(raw_pin, FINISH_END)
        require(raw_pin['bytes'] <= maximum, 'Raw member artifact exceeds its fixed bound')
        raw_member = json.loads(Path(raw_pin['path']).read_bytes())
        descriptor(raw_pin, FINISH_END)
        if not same_json(raw_member, chrome_raw.get(embedded)):
            return False
        if embedded == 'terminalFinality' and not same_json(raw_member, receipt.get('commandFinalityCapture')):
            return False

    if not (same_json(chrome_raw, receipt.get('ownedChromeEvidence'))
            and chrome_evidence_valid(chrome_raw, inputs, first, start, start + 135.0, attempt)):
        return False
    log_pin = receipt.get('logPin')
    log = attempt / 'out/tests.jsonl'
    if type(log_pin) is not dict or Path(log_pin.get('path', '')) != log:
        return False
    descriptor(log_pin, FINISH_END)
    if not (same_json(receipt.get('reporterContractCodePin'), inputs['reporterContractCode'])
            and same_json(receipt.get('testCaseContractPin'), inputs['testCaseContract'])):
        return False
    validation_pin = receipt.get('reporterValidationPin')
    if (type(validation_pin) is not dict
            or Path(validation_pin.get('path', '')) != attempt / 'reporter-validation.json'):
        return False
    descriptor(validation_pin, FINISH_END)
    require(validation_pin['bytes'] <= 2 * 1024 * 1024, 'Bounded raw reporter proof required')
    raw_validation = json.loads(Path(validation_pin['path']).read_bytes())
    descriptor(validation_pin, FINISH_END)
    if not same_json(raw_validation, receipt['reporterValidation']):
        return False
    reporter, contract = reporter_inputs(inputs, FINISH_END)
    observed = reporter.validate_report(log, contract,
        HERE.parents[1] / '.cache/guardian-current-20261024-r16-typed-schedule-finder/src/apps/guardian')
    descriptor(log_pin, FINISH_END)
    descriptor(inputs['reporterContractCode'], FINISH_END)
    descriptor(inputs['testCaseContract'], FINISH_END)
    return (type(observed) is dict and observed.get('status') == 'EXACT_BROWSER13_REPORT_ACCEPTED'
            and same_json(observed.get('logPin'), log_pin)
            and same_json(observed, receipt['reporterValidation']))


def main():
    require(os.name == 'nt' and sys.version_info[:2] == (3, 13), 'Fixed Windows Python 3.13 only')
    require(sys.flags.isolated == 1 and sys.dont_write_bytecode, 'Host requires -I -B')
    require(Path(sys.executable).absolute() == PYTHON and HERE == EXPECTED_HERE,
            'Fixed host path and Python executable required')
    require(time.get_clock_info('monotonic').implementation == 'QueryPerformanceCounter()',
            'Shared Windows QPC required')
    require(len(sys.argv) == 3 and sys.argv[1] == 'analyze'
            and re.fullmatch('[a-f0-9]{64}', sys.argv[2]) is not None,
            'Only analyze exact-proposal-SHA interface')
    safe(HERE)
    proposal_path = HERE / 'proposal.json'
    require(digest(proposal_path, WORK_END)[1] == sys.argv[2], 'Approved proposal changed')
    proposal = json.loads(proposal_path.read_bytes())
    require(type(proposal) is dict and set(proposal) == {'schemaVersion', 'phase', 'sourceCommit',
            'inputs', 'candidateFiles', 'runtimePins', 'pythonExecutable', 'budgets'},
            'Exact fixed analysis proposal schema required')
    require(type(proposal['schemaVersion']) is int and proposal['schemaVersion'] == 1
            and proposal['phase'] == 'guardian-browser13' and proposal['sourceCommit'] == SOURCE_COMMIT
            and proposal['pythonExecutable'] == 'C:/Python313/python.exe', 'Fixed phase/source/runtime required')
    budgets = proposal['budgets']
    require(type(budgets) is dict and set(budgets) == set(BUDGETS)
            and all(type(budgets[k]) is int and budgets[k] == v for k, v in BUDGETS.items()),
            'Original absolute budget ceilings required')
    require(type(proposal['candidateFiles']) is list and len(proposal['candidateFiles']) == 6
            and {r.get('path') for r in proposal['candidateFiles'] if type(r) is dict} == NAMES,
            'Only five fixed controls allowed')
    for row in proposal['candidateFiles']:
        descriptor(row, WORK_END, candidate=True)
    descriptor(proposal['inputs'], WORK_END)
    require(proposal['inputs']['bytes'] == INPUT_BYTES
            and proposal['inputs']['sha256'] == INPUT_SHA256, 'Fixed BROWSER13 input descriptor required')
    require(Path(proposal['inputs']['path']) == HERE / 'inputs.json', 'Fixed input path required')
    inputs = json.loads((HERE / 'inputs.json').read_bytes())
    require(inputs['phase'] == 'guardian-browser13' and inputs['sourceCommit'] == SOURCE_COMMIT,
            'Input phase/source changed')
    code_row = inputs['reporterContractCode']
    require(type(code_row) is dict and set(code_row) == {'path', 'bytes', 'sha256'}
            and Path(code_row['path']) == HERE / 'reporter_contract.py',
            'Fixed input reporter helper descriptor required')
    reporter_row = next(row for row in proposal['candidateFiles'] if row['path'] == 'reporter_contract.py')
    descriptor(code_row, WORK_END)
    require(type(code_row['bytes']) is int and code_row['bytes'] == reporter_row['bytes']
            and code_row['sha256'] == reporter_row['sha256'],
            'Input reporter code must be the same fifth approved control')
    descriptor(inputs['testCaseContract'], WORK_END)
    require(type(proposal['runtimePins']) is list and proposal['runtimePins'], 'Runtime pins required')
    runtime_rows = [descriptor(r, WORK_END) for r in proposal['runtimePins']]
    input_runtime = [descriptor(r, WORK_END)
                     for r in inputs['controlRuntimeFiles'] + inputs['extraRuntimeFiles']]
    require(len(runtime_rows) == len(set(runtime_rows)) and set(runtime_rows) == set(input_runtime)
            and any(Path(r['path']) == PYTHON for r in proposal['runtimePins']),
            'Complete exact input runtime union required')
    attempt = HERE / 'attempt'
    require(not attempt.is_symlink() and not attempt.is_junction(), 'Linked attempt refused')
    attempt.mkdir()
    host_temp = attempt / 'host-tmp'
    host_temp.mkdir()
    save(attempt / 'request.json', {'approvedProposalSha256': sys.argv[2], 'qpcAnchor': ANCHOR,
         'workDeadlineQpc': WORK_END, 'cleanupDeadlineQpc': FINISH_END,
         'sourceCommit': SOURCE_COMMIT, 'phase': 'guardian-browser13'})
    spec = importlib.util.spec_from_file_location('guardian_analysis_owned_job', HERE / 'owned_job.py')
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    environment = os.environ.copy()
    environment.update(TEMP=str(host_temp), TMP=str(host_temp))
    job = None
    state = None
    events = []
    error = None
    drain_end = None
    first_signaled_state = None
    first_signaled_members = None
    final_members = None
    before_resume = None
    maximum_total = 0
    deadline_reached = False
    def event(name):
        if len(events) < 64:
            events.append({'stage': name, 'qpc': monotonic()})
    def capture_first(current, deadline):
        nonlocal first_signaled_state, first_signaled_members
        if current['signaled'] and first_signaled_state is None:
            first_signaled_state = dict(current)
            first_signaled_members = job.member_identities(deadline)
    try:
        before(WORK_END)
        job = native.OwnedJob()
        event('before-create-suspended')
        job.create_suspended([str(PYTHON), '-I', '-B', '-u', str(HERE / 'worker.py')],
                             HERE, attempt / 'worker-console.log', environment)
        before(WORK_END)
        paused = job.sample(0)
        require(not paused['signaled'] and paused['activeProcesses'] == 1,
                'Unexpected suspended worker membership')
        before_resume = monotonic()
        job.resume()
        event('after-resume')
        while True:
            sample_deadline = min(WORK_END, drain_end) if drain_end is not None else WORK_END
            remaining = sample_deadline - monotonic()
            state = job.sample(max(0, min(50, int(max(0.0, remaining) * 1000))))
            maximum_total = max(maximum_total, state['totalProcesses'])
            if state['signaled']:
                capture_first(state, min(WORK_END, state['firstSignaledQpc'] + 0.5))
            if state['terminal']:
                break
            if state['signaled']:
                if drain_end is None:
                    drain_end = min(WORK_END, state['firstSignaledQpc'] + 0.5)
                    event('natural-drain-started')
                if monotonic() < drain_end:
                    time.sleep(min(0.01, max(0.0, drain_end - monotonic())))
                    continue
                event('natural-drain-exhausted')
            if monotonic() >= WORK_END or (state['signaled'] and drain_end is not None
                                          and monotonic() >= drain_end):
                deadline_reached = monotonic() >= WORK_END
                state = job.sample(0)
                maximum_total = max(maximum_total, state['totalProcesses'])
                capture_first(state, WORK_END)
                if state['terminal']:
                    break
                job.terminate_owned()
                event('owned-termination-requested')
                break
        while state is not None and not state['terminal'] and monotonic() < FINISH_END:
            state = job.sample(max(0, min(50, int(max(0.0, FINISH_END - monotonic()) * 1000))))
            maximum_total = max(maximum_total, state['totalProcesses'])
            capture_first(state, FINISH_END)
    except Exception as failure:
        error = type(failure).__name__ + ': ' + str(failure)
        if job is not None and job.process is not None:
            job.terminate_owned()
            while monotonic() < FINISH_END:
                state = job.sample(max(0, min(50, int(max(0.0, FINISH_END - monotonic()) * 1000))))
                maximum_total = max(maximum_total, state['totalProcesses'])
                capture_first(state, FINISH_END)
                if state['terminal']:
                    break
    finally:
        forced = job.force_requested if job else False
        force_ok = job.force_succeeded if job else False
        close_fallback = not (state and state['terminal'])
        if job and job.process:
            try:
                final_members = job.member_identities(FINISH_END)
            except Exception as failure:
                error = error or type(failure).__name__ + ': ' + str(failure)
        if job:
            job.close()
    # All receipt/log/hash/output I/O is after monitoring, under the original 180 ceiling.
    pins_after = False
    receipt = None
    reported = False
    derived = False
    try:
        require(digest(proposal_path, FINISH_END)[1] == sys.argv[2], 'Proposal changed after launch')
        for row in proposal['candidateFiles']:
            descriptor(row, FINISH_END, candidate=True)
        descriptor(proposal['inputs'], FINISH_END)
        for row in proposal['runtimePins']:
            descriptor(row, FINISH_END)
        pins_after = True
        receipt_path = safe(attempt / 'receipt.json')
        require(receipt_path.is_file() and receipt_path.stat().st_size <= 2 * 1024 * 1024,
                'Bounded worker receipt missing')
        receipt = json.loads(receipt_path.read_bytes())
        reported = type(receipt) is dict and receipt.get('status') == 'GUARDIAN_BROWSER13_WORKER_PASSED'
        derived = worker_outcome(receipt, state, before_resume, attempt, inputs)
        if reported != derived:
            error = error or 'Worker reported/derived result mismatch'
    except Exception as failure:
        error = error or type(failure).__name__ + ': ' + str(failure)
    natural = (complete_terminal(state) and state['exitCode'] == 0
               and state['firstSignaledQpc'] <= state['firstCompleteTerminalQpc']
               < min(WORK_END, state['firstSignaledQpc'] + 0.5))
    accepted = bool(natural and not forced and not close_fallback and not deadline_reached
                    and error is None and pins_after and reported and derived
                    and monotonic() < FINISH_END)
    result = {'status': 'GUARDIAN_BROWSER13_HOST_OBSERVED' if accepted else 'NOT_ACCEPTED',
              'phase': 'guardian-browser13', 'sourceCommit': SOURCE_COMMIT,
              'approvedProposalSha256': sys.argv[2], 'qpcAnchor': ANCHOR,
              'workDeadlineQpc': WORK_END, 'cleanupDeadlineQpc': FINISH_END,
              'workerResumeBeforeQpc': before_resume, 'terminal': state,
              'firstSignaledState': first_signaled_state,
              'firstSignaledOwnJobMembers': first_signaled_members, 'finalOwnJobMembers': final_members,
              'maximumObservedJobTotal': maximum_total, 'naturalDrainLimitSeconds': 0.5,
              'naturalDrainDeadlineQpc': drain_end, 'naturalCompleteTerminalTimely': natural,
              'forcedCleanupRequested': forced, 'terminationCallSucceeded': force_ok,
              'closedWithLiveOrUnknownMembers': close_fallback, 'deadlineReached': deadline_reached,
              'candidateAndRuntimePinsMatchAfter': pins_after, 'workerReportedPassed': reported,
              'workerDerivedPassed': derived, 'workerReportedDerivedConsistent': reported == derived,
              'workerReceipt': receipt, 'error': error, 'events': events,
              'testAcceptedBeforeOutput': accepted, 'rootActualSameHandleExitStillRequired': True,
              'rootFullProcessReleaseStillRequired': True, 'sdkCalls': receipt.get('sdkCalls') if type(receipt) is dict else None,
              'testsRun': receipt.get('testsRun') is True if type(receipt) is dict else False,
              'entirePythonOrSdkInstallationPinned': False}
    result['observedBeforeOutputQpc'] = monotonic()
    result['elapsedBeforeOutputSeconds'] = result['observedBeforeOutputQpc'] - ANCHOR
    save(attempt / 'result.json', result)
    print(json.dumps({'status': result['status'], 'rootActualSameHandleExitStillRequired': True}), flush=True)
    return 0 if accepted and monotonic() < FINISH_END else 1


if __name__ == '__main__':
    try:
        code = main()
    except Exception as failure:
        print(json.dumps({'status': 'NOT_ACCEPTED', 'errorType': type(failure).__name__,
                          'reason': str(failure), 'rootActualSameHandleExitStillRequired': True}), flush=True)
        code = 1
    os._exit(code)
