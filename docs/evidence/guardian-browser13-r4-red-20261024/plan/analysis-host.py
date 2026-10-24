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
EXPECTED_HERE = Path(r'D:\codes\mobile\ai-manager\.cache\guardian-browser13-20261024-r4-canonical-git')
PYTHON = Path(r'C:\Python313\python.exe')
SOURCE_COMMIT = '006ee45850c9b6b0f90570d9478bced3beb0e0fe'
INPUT_BYTES = 20240
INPUT_SHA256 = '906ca7d4c49602b8cb59fb9bb3cdd058f6bd1a0c6f1e10dae363c4a64fc17311'
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
        json.dump(value, stream, ensure_ascii=False, indent=2)
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
        HERE.parents[1] / '.cache/guardian-current-20261024-r15-login-schedule/src/apps/guardian')
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
