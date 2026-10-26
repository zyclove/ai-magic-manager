"""Read-only evidence from retained members of one exact private SDK Job.

Import and pure parsers perform no process/network/native calls. This module
never launches, signals, terminates or cleans up a process. The caller's f8 Job
and original deadlines remain the sole lifetime/acceptance authority.
"""
import ctypes as C
from ctypes import wintypes as W
import hashlib
import ipaddress
import json
import math
import ntpath
from pathlib import Path
import re
import stat
import time

MAX_COMMAND_BYTES = 65532
MAX_MEM_BYTES = 65536


class EvidenceRejected(RuntimeError):
    pass


def demand(condition, code):
    if not condition:
        raise EvidenceRejected(code)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def normalized_path(value):
    demand(type(value) is str and 0 < len(value) <= 32766
           and not any(ord(c) < 32 for c in value), 'INVALID_PATH')
    demand(re.match(r'^[A-Za-z]:[\\/]', value) is not None, 'NON_LOCAL_ABSOLUTE_PATH')
    demand('..' not in value.replace('/', '\\').split('\\'), 'PARENT_PATH_COMPONENT')
    return ntpath.normcase(ntpath.normpath(value))


def parse_chrome_argv(argv, executable, temporary_root):
    demand(type(argv) is list and 1 <= len(argv) <= 256
           and all(type(arg) is str and len(arg) <= 32766 and '\0' not in arg
                   for arg in argv), 'INVALID_ARGV')
    demand(normalized_path(argv[0]) == normalized_path(executable), 'ARGV_IMAGE_MISMATCH')
    kinds = [arg for arg in argv if arg.startswith('--type=')]
    if kinds:
        demand(len(kinds) == 1 and len(kinds[0]) > len('--type='), 'INVALID_CHROME_CHILD_TYPE')
        return None
    profiles = [arg.split('=', 1)[1] for arg in argv if arg.startswith('--user-data-dir=')]
    ports = [arg.split('=', 1)[1] for arg in argv if arg.startswith('--remote-debugging-port=')]
    demand(len(profiles) == len(ports) == 1, 'PRIVATE_PROFILE_OR_DEBUG_PORT_NOT_UNIQUE')
    profile, temporary = normalized_path(profiles[0]), normalized_path(temporary_root)
    demand(profile.startswith(temporary.rstrip('\\') + '\\'), 'PROFILE_OUTSIDE_TASK_TEMP')
    demand(len(profile.split('\\')) <= 64, 'PROFILE_PATH_TOO_DEEP')
    demand(re.fullmatch('[0-9]{1,5}', ports[0]) is not None and 0 < int(ports[0]) < 65536,
           'INVALID_DEBUG_PORT')
    demand(sum(arg == '--headless' for arg in argv) == 1
           and not any(arg.startswith('--headless=') for arg in argv), 'HEADLESS_REQUIRED')
    origins, targets = [], []
    for arg in argv[1:]:
        if re.match('(?i)^https?://', arg):
            # urllib.parse is local parsing; this never resolves/connects.
            from urllib.parse import urlsplit, parse_qs
            try:
                uri = urlsplit(arg)
                port = uri.port
            except ValueError:
                raise EvidenceRejected('INVALID_TEST_TARGET') from None
            demand(uri.scheme == 'http' and uri.hostname in ('localhost', '127.0.0.1', '::1')
                   and port is not None and 0 < port < 65536
                   and uri.username is None and uri.password is None, 'NON_LOOPBACK_TEST_TARGET')
            demand(uri.path == '/static/index.html' and not uri.fragment, 'FLUTTER_TEST_TARGET_REQUIRED')
            try:
                query = parse_qs(uri.query, keep_blank_values=True, strict_parsing=True)
            except ValueError:
                raise EvidenceRejected('INVALID_FLUTTER_TEST_QUERY') from None
            demand(set(query) == {'managerUrl', 'debug'} and query['debug'] == ['false']
                   and len(query['managerUrl']) == 1, 'FLUTTER_TEST_QUERY_REQUIRED')
            try:
                manager = urlsplit(query['managerUrl'][0])
                manager_port = manager.port
            except ValueError:
                raise EvidenceRejected('INVALID_FLUTTER_MANAGER_TARGET') from None
            demand(manager.scheme == 'ws' and manager.hostname == uri.hostname
                   and manager_port == port and manager.path.startswith('/')
                   and len(manager.path) > 1 and manager.username is None and manager.password is None
                   and not manager.query and not manager.fragment, 'NON_LOOPBACK_FLUTTER_MANAGER')
            origins.append(uri.scheme + '://' + uri.netloc)
            targets.append({'scheme': uri.scheme, 'host': uri.hostname, 'port': port,
                            'path': uri.path, 'urlSha256': hashlib.sha256(arg.encode('utf-8')).hexdigest()})
        elif not arg.startswith('--'):
            raise EvidenceRejected('UNEXPECTED_CHROME_POSITIONAL_TARGET')
    demand(len(targets) == 1, 'ONE_LOOPBACK_FLUTTER_TEST_TARGET_REQUIRED')
    return {'imagePath': normalized_path(executable), 'profile': profile,
            'debuggingPort': int(ports[0]), 'testServerOrigins': sorted(set(origins)),
            'managerTarget': {'scheme': manager.scheme, 'host': manager.hostname, 'port': manager_port},
            'testTargets': targets, 'headless': True, 'argvTestTargetLoopback': True,
            'flutterManagerTargetSameLoopbackOrigin': True}


def parse_listener_rows(rows, port):
    """Accept only the already PID/port-filtered local LISTEN summaries."""
    demand(type(port) is int and 0 < port < 65536 and type(rows) is list
           and len(rows) <= 32, 'INVALID_LISTENER_INPUT')
    result = []
    for row in rows:
        demand(type(row) is dict and set(row) == {'address', 'port', 'family', 'status'},
               'INVALID_LISTENER_ROW_SCHEMA')
        demand(type(row['port']) is int and row['port'] == port and row['status'] == 'LISTEN'
               and row['family'] in ('AF_INET', 'AF_INET6')
               and type(row['address']) is str and len(row['address']) <= 64,
               'INVALID_LISTENER_ROW')
        try:
            address = ipaddress.ip_address(row['address'])
        except ValueError:
            raise EvidenceRejected('INVALID_LISTENER_ADDRESS') from None
        demand(address.is_loopback and
               ((address.version == 4 and row['family'] == 'AF_INET') or
                (address.version == 6 and row['family'] == 'AF_INET6')),
               'NON_LOOPBACK_DEBUG_LISTENER')
        result.append({'address': str(address), 'port': port,
                       'family': row['family'], 'status': 'LISTEN'})
    return sorted({(r['address'], r['port'], r['family'], r['status']) for r in result})


def checked_read_span(address, count):
    demand(type(address) is int and address > 0 and type(count) is int
           and 0 < count <= MAX_MEM_BYTES and address <= (1 << 64) - 1 - count,
           'INVALID_REMOTE_READ_SPAN')


def checked_unicode(length, maximum, address):
    demand(type(length) is int and type(maximum) is int and 0 < length <= MAX_COMMAND_BYTES
           and length % 2 == 0 and length <= maximum <= 65534 and maximum % 2 == 0,
           'INVALID_COMMAND_LENGTH')
    checked_read_span(address, length)


class UnicodeString(C.Structure):
    _fields_ = [('length', W.USHORT), ('maximum', W.USHORT), ('buffer', C.c_void_p)]


class ProcessBasicInformation(C.Structure):
    _fields_ = [('reserved1', C.c_void_p), ('peb', C.c_void_p),
                ('reserved2', C.c_void_p * 2), ('pid', C.c_size_t), ('reserved3', C.c_void_p)]


class PebPrefix(C.Structure):
    _fields_ = [('reserved1', W.BYTE * 2), ('being_debugged', W.BYTE),
                ('reserved2', W.BYTE), ('reserved3', C.c_void_p * 2),
                ('ldr', C.c_void_p), ('parameters', C.c_void_p)]


class UserParametersPrefix(C.Structure):
    _fields_ = [('reserved1', W.BYTE * 16), ('reserved2', C.c_void_p * 10),
                ('image', UnicodeString), ('command', UnicodeString)]


class RetainedJobReader:
    """Same-handle readonly PBI0/PEB reads, never a PID-based cmdline read."""
    def __init__(self, job, deadline):
        demand(finite(deadline), 'INVALID_OBSERVATION_DEADLINE')
        self.job, self.deadline = job, float(deadline)
        self.rpm_calls = 0
        self.command_line_reads = 0
        self.k = C.WinDLL('kernel32', use_last_error=True)
        self.n = C.WinDLL('ntdll')
        self.shell = C.WinDLL('shell32', use_last_error=True)
        self.rpm = self.k.ReadProcessMemory
        self.rpm.argtypes = [W.HANDLE, C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t)]
        self.rpm.restype = W.BOOL
        self.wow64 = self.k.IsWow64Process2
        self.wow64.argtypes = [W.HANDLE, C.POINTER(W.USHORT), C.POINTER(W.USHORT)]
        self.wow64.restype = W.BOOL
        self.query = self.n.NtQueryInformationProcess
        self.query.argtypes = [W.HANDLE, C.c_int, C.c_void_p, W.ULONG, C.POINTER(W.ULONG)]
        self.query.restype = W.LONG
        self.argv = self.shell.CommandLineToArgvW
        self.argv.argtypes = [W.LPCWSTR, C.POINTER(C.c_int)]
        self.argv.restype = C.POINTER(W.LPWSTR)
        self.free = self.k.LocalFree
        self.free.argtypes = [C.c_void_p]
        self.free.restype = C.c_void_p
        demand(C.sizeof(C.c_void_p) == 8 and C.sizeof(C.c_wchar) == 2
               and C.sizeof(ProcessBasicInformation) == 48
               and PebPrefix.parameters.offset == 32
               and UserParametersPrefix.command.offset == 112, 'UNSUPPORTED_STRUCT_ABI')

    def check_deadline(self):
        demand(time.monotonic() < self.deadline, 'ORIGINAL_OBSERVATION_DEADLINE')

    def verify(self, handle, expected_creation, expected_image):
        self.check_deadline()
        member = W.BOOL()
        demand(self.job.k.IsProcessInJob(handle, self.job.handle, C.byref(member))
               and member.value, 'NOT_A_MEMBER_OF_THIS_JOB')
        times = [W.FILETIME() for _ in range(4)]
        demand(self.job.k.GetProcessTimes(handle, *(C.byref(t) for t in times)), 'MEMBER_TIMES_FAILED')
        creation = int(times[0].dwHighDateTime) << 32 | int(times[0].dwLowDateTime)
        demand(creation == expected_creation and creation >= self.job.identity,
               'MEMBER_CREATION_MISMATCH')
        image = C.create_unicode_buffer(32768)
        size = W.DWORD(32768)
        demand(self.job.k.QueryFullProcessImageNameW(handle, 0, image, C.byref(size)), 'MEMBER_IMAGE_FAILED')
        demand(normalized_path(image.value) == normalized_path(expected_image), 'MEMBER_IMAGE_MISMATCH')
        demand(self.job.k.WaitForSingleObject(handle, 0) == 258, 'MEMBER_NOT_LIVE')
        self.check_deadline()

    def read_exact(self, handle, address, count):
        checked_read_span(address, count)
        self.check_deadline()
        data = C.create_string_buffer(count)
        read = C.c_size_t()
        self.rpm_calls += 1
        demand(self.rpm(handle, C.c_void_p(address), data, count, C.byref(read))
               and read.value == count, 'SAME_HANDLE_MEMORY_READ_FAILED')
        self.check_deadline()
        return bytes(data.raw)

    def command_line(self, handle, pid, creation, image):
        self.verify(handle, creation, image)
        process_machine, native_machine = W.USHORT(), W.USHORT()
        demand(self.wow64(handle, C.byref(process_machine), C.byref(native_machine))
               and process_machine.value == 0 and native_machine.value == 0x8664,
               'UNSUPPORTED_MEMBER_ARCHITECTURE')
        basic, size = ProcessBasicInformation(), W.ULONG()
        demand(self.query(handle, 0, C.byref(basic), C.sizeof(basic), C.byref(size)) == 0
               and size.value == C.sizeof(basic) and basic.pid == pid and basic.peb,
               'SAME_HANDLE_PBI0_FAILED')
        self.verify(handle, creation, image)
        before_qpc = time.monotonic()
        peb = PebPrefix.from_buffer_copy(self.read_exact(handle, int(basic.peb), C.sizeof(PebPrefix)))
        demand(peb.parameters, 'PROCESS_PARAMETERS_MISSING')
        parameters_raw = self.read_exact(handle, int(peb.parameters), C.sizeof(UserParametersPrefix))
        parameters = UserParametersPrefix.from_buffer_copy(parameters_raw)
        descriptor = (parameters.command.length, parameters.command.maximum, parameters.command.buffer)
        checked_unicode(*descriptor)
        raw = self.read_exact(handle, int(descriptor[2]), descriptor[0])
        again = UserParametersPrefix.from_buffer_copy(
            self.read_exact(handle, int(peb.parameters), C.sizeof(UserParametersPrefix)))
        demand(descriptor == (again.command.length, again.command.maximum, again.command.buffer),
               'COMMAND_DESCRIPTOR_CHANGED')
        demand(raw == self.read_exact(handle, int(descriptor[2]), descriptor[0]), 'COMMAND_CONTENT_CHANGED')
        self.verify(handle, creation, image)
        after_qpc = time.monotonic()
        try:
            text = raw.decode('utf-16-le', errors='strict')
        except UnicodeError:
            raise EvidenceRejected('COMMAND_UTF16_INVALID') from None
        demand('\0' not in text, 'EMBEDDED_COMMAND_NUL')
        count = C.c_int()
        values = self.argv(text, C.byref(count))
        demand(values, 'WINDOWS_COMMAND_ARGV_FAILED')
        try:
            demand(1 <= count.value <= 256, 'WINDOWS_COMMAND_ARGV_COUNT')
            arguments = [values[i] for i in range(count.value)]
        finally:
            demand(not self.free(C.cast(values, C.c_void_p)), 'COMMAND_ARGV_FREE_FAILED')
        self.command_line_reads += 1
        return arguments, {'commandLineUtf16Sha256': hashlib.sha256(raw).hexdigest(),
                           'commandLineReadBeforeQpc': before_qpc, 'commandLineReadAfterQpc': after_qpc}

    def open_member(self, pid, creation, image):
        demand(type(pid) is int and pid > 0 and type(creation) is int and creation > 0,
               'INVALID_MEMBER_IDENTITY')
        self.check_deadline()
        handle = self.job.k.OpenProcess(0x1000 | 0x100000 | 0x10, False, pid)
        demand(handle, 'READONLY_MEMBER_OPEN_FAILED')
        try:
            self.verify(handle, creation, image)
        except BaseException:
            self.job.k.CloseHandle(handle)
            raise
        return handle


class OwnedChromeEvidence:
    def __init__(self, command_job, chrome_executable_path, task_temp_root, command_deadline_qpc):
        self.job = command_job
        self.executable = normalized_path(str(chrome_executable_path))
        self.temporary = normalized_path(str(task_temp_root))
        self.deadline = float(command_deadline_qpc)
        self.reader = RetainedJobReader(command_job, self.deadline)
        self.problems, self.checked, self.pending, self.complete = set(), set(), {}, {}
        self.samples = 0
        self._initialize_diagnostics()
        self._initialize_acceptance()

    def _initialize_acceptance(self):
        self._failure_snapshots = []
        self._failure_snapshots_seen = 0
        self._failure_snapshots_dropped = 0
        self._acceptance_overflow = False
        self._first_identities = []
        self._identity_map = {}
        self._identity_conflicts = []
        self._pending_occurrences = []
        self._resolved_occurrences = []
        self._member_fatal = set()
        self._observed_problems = set()

    @staticmethod
    def _json_copy(value):
        return json.loads(json.dumps(value, ensure_ascii=True, allow_nan=False))

    def _failure_ledger(self):
        return {'schemaVersion': 1, 'maximumFailureSnapshots': 8,
                'maximumSerializedBytes': 262144,
                'totalFailureSnapshotsSeen': self._failure_snapshots_seen,
                'storedFailureSnapshots': len(self._failure_snapshots),
                'droppedFailureSnapshots': self._failure_snapshots_dropped,
                'overflow': self._acceptance_overflow,
                'snapshots': self._failure_snapshots,
                'firstIdentityObservations': self._first_identities,
                'identityConflicts': self._identity_conflicts,
                'pendingOccurrences': self._pending_occurrences,
                'resolvedOccurrences': self._resolved_occurrences,
                'fatalProblems': sorted(self._member_fatal)}

    def _fatal(self, code):
        self._member_fatal.add(code)
        self._observed_problems.add(code)
        self.problems.add(code)

    def _ledger_append(self, destination, value):
        if self._acceptance_overflow:
            return False
        destination.append(self._json_copy(value))
        if self._diagnostic_bytes(self._failure_ledger()) > 261120:
            destination.pop()
            self._acceptance_overflow = True
            self._fatal('MEMBER_ACCEPTANCE_LEDGER_OVERFLOW')
            return False
        return True

    def _member_row_kind(self, row, before_qpc, after_qpc):
        base = {'pid', 'openedFromOwnJobList', 'verifiedOwnMembership', 'retainedRootHandleUsed',
                'creationFiletime', 'exitFiletime', 'kernel100ns', 'user100ns', 'sampleQpc', 'signaled'}
        if type(row) is not dict:
            return 'fatal'
        signaled = row.get('signaled')
        image = 'imagePath' if 'imagePath' in row else 'imageError'
        wanted = base | {image} | ({'exitCode'} if signaled is True else set())
        if set(row) != wanted or type(signaled) is not bool:
            return 'fatal'
        if not (type(row['pid']) is int and row['pid'] > 0
                and row['openedFromOwnJobList'] is True and row['verifiedOwnMembership'] is True
                and type(row['retainedRootHandleUsed']) is bool
                and row['retainedRootHandleUsed'] == (row['pid'] == self.job.pid)
                and type(row['creationFiletime']) is int
                and self.job.identity <= row['creationFiletime'] < (1 << 64)
                and all(type(row[key]) is int and 0 <= row[key] < (1 << 64)
                        for key in ('exitFiletime', 'kernel100ns', 'user100ns'))
                and type(row['sampleQpc']) is float and finite(row['sampleQpc'])
                and before_qpc <= row['sampleQpc'] <= after_qpc):
            return 'fatal'
        if signaled and not (type(row['exitCode']) is int and 0 <= row['exitCode'] < (1 << 32)):
            return 'fatal'
        if image == 'imageError':
            return 'pending' if type(row['imageError']) is int and 0 <= row['imageError'] < (1 << 32) else 'fatal'
        if not (type(row['imagePath']) is str and 0 < len(row['imagePath']) <= 32766):
            return 'fatal'
        try:
            normalized_path(row['imagePath'])
        except EvidenceRejected:
            return 'fatal'
        return 'complete'

    def _snapshot_kinds(self, snapshot):
        demand(type(snapshot) is dict and set(snapshot) == {
            'startedQpc', 'deadlineQpc', 'before', 'identities', 'after',
            'identityRowsLimitedByDeadline', 'scope', 'causeClassified'}, 'MEMBER_SNAPSHOT_SCHEMA_INVALID')
        demand(snapshot['scope'] == 'This private Job only; read-only handles, no command line/environment, no PID termination'
               and snapshot['causeClassified'] is False and snapshot['identityRowsLimitedByDeadline'] is False,
               'OWN_JOB_INVENTORY_INCOMPLETE')
        for listing in (snapshot['before'], snapshot['after']):
            demand(type(listing) is dict and set(listing) == {'qpc', 'complete', 'assigned', 'listed', 'limit', 'error', 'pids'}
                   and listing['complete'] is True and type(listing['limit']) is int and listing['limit'] == 32
                   and type(listing['error']) is int and listing['error'] == 0
                   and type(listing['pids']) is list and len(listing['pids']) <= 32
                   and all(type(pid) is int and pid > 0 for pid in listing['pids'])
                   and len(set(listing['pids'])) == len(listing['pids'])
                   and type(listing['assigned']) is int and type(listing['listed']) is int
                   and listing['assigned'] == listing['listed'] == len(listing['pids'])
                   and type(listing['qpc']) is float and finite(listing['qpc']),
                   'OWN_JOB_INVENTORY_INCOMPLETE')
        demand(type(snapshot['startedQpc']) is float and type(snapshot['deadlineQpc']) is float
               and snapshot['startedQpc'] == snapshot['before']['qpc']
               and snapshot['deadlineQpc'] == self.reader.deadline
               and snapshot['before']['qpc'] <= snapshot['after']['qpc'] < self.reader.deadline,
               'MEMBER_SNAPSHOT_TIME_INVALID')
        rows = snapshot['identities']
        demand(type(rows) is list and len(rows) == len(snapshot['before']['pids'])
               and all(type(row) is dict and type(row.get('pid')) is int for row in rows)
               and len({row['pid'] for row in rows}) == len(rows)
               and {row['pid'] for row in rows} == set(snapshot['before']['pids']),
               'MEMBER_BEFORE_IDENTITY_COVERAGE_INVALID')
        return [self._member_row_kind(row, snapshot['before']['qpc'], snapshot['after']['qpc']) for row in rows]

    def _store_failure_snapshot(self, snapshot, kinds):
        self._failure_snapshots_seen += 1
        if len(self._failure_snapshots) >= 8:
            self._failure_snapshots_dropped += 1
            self._acceptance_overflow = True
            self._fatal('MEMBER_ACCEPTANCE_LEDGER_OVERFLOW')
            return
        before = snapshot.get('before', {}) if type(snapshot) is dict else {}
        after = snapshot.get('after', {}) if type(snapshot) is dict else {}
        before_pids, after_pids = before.get('pids'), after.get('pids')
        comparable = (type(before_pids) is list and type(after_pids) is list
                      and all(type(pid) is int for pid in before_pids + after_pids))
        frame = {'sampleOrdinal': self.samples, 'jobRootPid': self.job.pid,
                 'jobRootCreationFiletime': self.job.identity, 'rawSnapshot': snapshot,
                 'afterOnlyNotQueried': sorted(set(after_pids) - set(before_pids)) if comparable else []}
        index = len(self._failure_snapshots)
        if not self._ledger_append(self._failure_snapshots, frame):
            self._failure_snapshots_dropped += 1
            return
        for row_index, kind in enumerate(kinds):
            if kind == 'pending':
                row = snapshot['identities'][row_index]
                self._ledger_append(self._pending_occurrences, {
                    'snapshotIndex': index, 'rowIndex': row_index, 'sampleOrdinal': self.samples,
                    'pid': row['pid'], 'creationFiletime': row['creationFiletime']})

    def _collect_snapshot(self, snapshot):
        try:
            kinds = self._snapshot_kinds(snapshot)
        except EvidenceRejected as failure:
            self._fatal(str(failure))
            self._store_failure_snapshot(snapshot, [])
            self._failed_sample_calls += 1
            return [], True
        failed = False
        for index, (row, kind) in enumerate(zip(snapshot['identities'], kinds)):
            if kind == 'fatal':
                self._fatal('OWN_JOB_MEMBER_HARD_ERROR')
                failed = True
            else:
                pid, creation = row['pid'], row['creationFiletime']
                previous = self._identity_map.get(pid)
                if previous is None:
                    record = {'sampleOrdinal': self.samples, 'pid': pid,
                              'creationFiletime': creation, 'rawRow': row}
                    if self._ledger_append(self._first_identities, record):
                        self._identity_map[pid] = creation
                    else:
                        failed = True
                elif previous != creation:
                    self._ledger_append(self._identity_conflicts, {
                        'sampleOrdinal': self.samples, 'pid': pid,
                        'expectedCreationFiletime': previous, 'observedCreationFiletime': creation,
                        'rawRow': row})
                    self._fatal('OWN_JOB_MEMBER_CREATION_CONFLICT')
                    failed = True
            if kind == 'pending':
                self._observed_problems.add('OWN_JOB_MEMBER_IDENTITY_UNPROVED')
                failed = True
            if kind != 'complete':
                self._record_unknown_member(row, snapshot)
        if failed:
            self._store_failure_snapshot(snapshot, kinds)
            self._failed_sample_calls += 1
        return kinds, failed

    def _finality_valid(self, value):
        try:
            if not (type(value) is dict and set(value) == {
                    'schemaVersion', 'source', 'jobRootPid', 'jobRootCreationFiletime',
                    'originalCommandDeadlineQpc', 'deadlineQpc', 'naturalDrainSeconds',
                    'A0', 'M', 'A1', 'forceRequested', 'closeFallback'}
                    and type(value['schemaVersion']) is int and value['schemaVersion'] == 1
                    and value['source'] == 'SAME_COMMAND_OWNED_JOB'
                    and type(value['jobRootPid']) is int and value['jobRootPid'] == self.job.pid
                    and type(value['jobRootCreationFiletime']) is int and value['jobRootCreationFiletime'] == self.job.identity
                    and type(value['originalCommandDeadlineQpc']) is float and value['originalCommandDeadlineQpc'] == self.deadline
                    and type(value['naturalDrainSeconds']) is float and value['naturalDrainSeconds'] == .5
                    and value['forceRequested'] is False and value['closeFallback'] is False
                    and self.job.force_requested is False):
                return False
            a0, middle, a1 = value['A0'], value['M'], value['A1']
            state_keys = {'pid', 'creationFiletime', 'firstSignaledQpc', 'sampleQpc', 'signaled', 'exitCode',
                          'exitFiletime', 'kernel100ns', 'user100ns', 'jobAccountingObservedQpc',
                          'firstCompleteTerminalQpc', 'activeProcesses', 'totalProcesses', 'terminatedProcesses', 'terminal'}
            for state in (a0, a1):
                if not (type(state) is dict and set(state) == state_keys
                        and type(state['pid']) is int and state['pid'] == self.job.pid
                        and type(state['creationFiletime']) is int and state['creationFiletime'] == self.job.identity
                        and state['signaled'] is True and state['terminal'] is True
                        and type(state['exitCode']) is int and state['exitCode'] == 0
                        and type(state['activeProcesses']) is int and state['activeProcesses'] == 0
                        and all(type(state[key]) is int and 0 <= state[key] < (1 << 64) for key in
                                ('exitFiletime', 'kernel100ns', 'user100ns', 'totalProcesses', 'terminatedProcesses'))
                        and state['exitFiletime'] > 0
                        and all(type(state[key]) is float and finite(state[key]) for key in
                                ('firstSignaledQpc', 'firstCompleteTerminalQpc', 'sampleQpc', 'jobAccountingObservedQpc'))):
                    return False
            anchors = ('firstSignaledQpc', 'firstCompleteTerminalQpc', 'exitFiletime', 'totalProcesses', 'terminatedProcesses')
            if any(a0[key] != a1[key] for key in anchors):
                return False
            if (a0['firstSignaledQpc'] != self.job.first_signaled_qpc
                    or a0['firstCompleteTerminalQpc'] != self.job.first_complete_terminal_qpc):
                return False
            end = min(self.deadline, a0['firstSignaledQpc'] + .5)
            if not (type(value['deadlineQpc']) is float and value['deadlineQpc'] == end
                    and type(middle) is dict and set(middle) == {'startedQpc', 'deadlineQpc', 'before', 'identities',
                        'after', 'identityRowsLimitedByDeadline', 'scope', 'causeClassified'}
                    and middle['identities'] == [] and type(middle['identities']) is list
                    and middle['identityRowsLimitedByDeadline'] is False and middle['causeClassified'] is False
                    and middle['scope'] == 'This private Job only; read-only handles, no command line/environment, no PID termination'
                    and type(middle['deadlineQpc']) is float and middle['deadlineQpc'] == end
                    and type(middle['startedQpc']) is float and middle['startedQpc'] == middle['before']['qpc']):
                return False
            for listing in (middle['before'], middle['after']):
                if not (type(listing) is dict and set(listing) == {'qpc', 'complete', 'assigned', 'listed', 'limit', 'error', 'pids'}
                        and listing['complete'] is True and listing['pids'] == [] and type(listing['pids']) is list
                        and all(type(listing[key]) is int and listing[key] == 0 for key in ('assigned', 'listed', 'error'))
                        and type(listing['limit']) is int and listing['limit'] == 32
                        and type(listing['qpc']) is float and finite(listing['qpc'])):
                    return False
            return (0 <= a0['firstSignaledQpc'] <= a0['firstCompleteTerminalQpc'] <= a0['sampleQpc']
                    <= a0['jobAccountingObservedQpc'] <= middle['before']['qpc'] <= middle['after']['qpc']
                    <= a1['sampleQpc'] <= a1['jobAccountingObservedQpc'] < end)
        except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
            return False

    def _initialize_diagnostics(self):
        self._member_diagnostic_records = []
        self._member_diagnostic_attempts = 0
        self._member_diagnostic_dropped = 0
        self._member_diagnostic_errors = 0
        self._member_identity_failure_count = 0
        self._failed_sample_calls = 0
        self._sample_elapsed_total = 0.0
        self._sample_elapsed_maximum = 0.0
        self._first_member_failure_qpc = None
        self._last_member_failure_qpc = None
        self._member_diagnostic_resamples = 0

    @staticmethod
    def _diagnostic_row(row):
        # Never stringify unknown values or save a full image path/argv/env.
        if type(row) is not dict:
            return {'rowShapeValid': False}
        result = {'rowShapeValid': True}
        integers = {'pid', 'creationFiletime', 'exitFiletime', 'exitCode', 'openError',
                    'membershipQueryError', 'timesError', 'waitError', 'imageError', 'exitCodeError'}
        booleans = {'openedFromOwnJobList', 'verifiedOwnMembership', 'retainedRootHandleUsed',
                    'signaled', 'membershipRaceOrChange', 'retainedIdentityMismatch', 'invalidZeroPid'}
        for key in sorted(integers):
            value = row.get(key)
            if type(value) is int and 0 <= value < (1 << 64):
                result[key] = value
        for key in sorted(booleans):
            if type(row.get(key)) is bool:
                result[key] = row[key]
        if finite(row.get('sampleQpc')):
            result['sampleQpc'] = row['sampleQpc']
        image = row.get('imagePath')
        if row.get('verifiedOwnMembership') is True and type(image) is str and len(image) <= 32766:
            result['imageBaseName'] = ''.join(c if ord(c) >= 32 and not 0xD800 <= ord(c) <= 0xDFFF else '?'
                                             for c in ntpath.basename(image))[:260]
            result['imagePathSha256'] = hashlib.sha256(image.encode('utf-8', errors='surrogatepass')).hexdigest()
        return result

    @staticmethod
    def _diagnostic_listing(value):
        value = value if type(value) is dict else {}
        result = {}
        for key in ('assigned', 'listed', 'limit', 'error'):
            item = value.get(key)
            result[key] = item if type(item) is int and 0 <= item < (1 << 32) else None
        result['qpc'] = value.get('qpc') if finite(value.get('qpc')) else None
        result['complete'] = value.get('complete') if type(value.get('complete')) is bool else None
        pids = value.get('pids')
        valid = type(pids) is list and all(type(pid) is int and 0 <= pid < (1 << 32) for pid in pids[:32])
        result['pids'] = pids[:32] if valid else []
        result['pidsTruncatedOrInvalid'] = not valid or len(pids) > 32
        return result

    @classmethod
    def _diagnostic_snapshot(cls, value):
        value = value if type(value) is dict else {}
        return {'before': cls._diagnostic_listing(value.get('before')),
                'after': cls._diagnostic_listing(value.get('after')),
                'identityRowsLimitedByDeadline': value.get('identityRowsLimitedByDeadline')
                    if type(value.get('identityRowsLimitedByDeadline')) is bool else None}

    def _diagnostic_value(self, records=None):
        return {'schemaVersion': 1, 'status': 'DIAGNOSTIC_ONLY_NOT_ACCEPTANCE',
                'maximumRecords': 8, 'maximumSerializedBytes': 32768,
                'sampleCalls': self.samples, 'failedSampleCalls': self._failed_sample_calls,
                'memberIdentityFailureCount': self._member_identity_failure_count,
                'sampleElapsedTotalSeconds': self._sample_elapsed_total,
                'sampleElapsedMaximumSeconds': self._sample_elapsed_maximum,
                'firstMemberFailureQpc': self._first_member_failure_qpc,
                'lastMemberFailureQpc': self._last_member_failure_qpc,
                'originalCommandDeadlineQpc': self.deadline,
                'recordsAttempted': self._member_diagnostic_attempts,
                'resampleCalls': self._member_diagnostic_resamples,
                'recordsDropped': self._member_diagnostic_dropped,
                'internalDiagnosticErrors': self._member_diagnostic_errors,
                'records': list(self._member_diagnostic_records if records is None else records),
                'nativeOrNetworkQueriesPerformedByDiagnosticsMethod': False,
                'acceptanceRulesChanged': False}

    @staticmethod
    def _diagnostic_bytes(value):
        # Worst case for either normal ensure_ascii setting used by the writer.
        return len((json.dumps(value, ensure_ascii=True, indent=2, allow_nan=False) + '\n').encode('utf-8'))

    def _record_unknown_member(self, row, snapshot):
        self._member_identity_failure_count += 1
        observed = time.monotonic()
        if self._first_member_failure_qpc is None:
            self._first_member_failure_qpc = observed
        self._last_member_failure_qpc = observed
        if self._member_diagnostic_attempts >= 8:
            self._member_diagnostic_dropped += 1
            return
        self._member_diagnostic_attempts += 1
        try:
            record = {'sampleOrdinal': self.samples, 'observedQpc': observed,
                      'originalObservationDeadlineQpc': self.reader.deadline,
                      'failedRow': self._diagnostic_row(row),
                      'firstSnapshot': self._diagnostic_snapshot(snapshot),
                      'resample': {'status': 'NOT_USED_SCHEMA2'}}
            if self._diagnostic_bytes(self._diagnostic_value(self._member_diagnostic_records + [record])) <= 30720:
                self._member_diagnostic_records.append(record)
            else:
                self._member_diagnostic_dropped += 1
        except Exception:
            self._member_diagnostic_errors += 1
            self._member_diagnostic_dropped += 1

    def diagnostics(self):
        # Pure aggregation only: no Job/API/process/socket/file call here.
        value = self._diagnostic_value()
        while self._diagnostic_bytes(value) > 32768 and value['records']:
            value['records'].pop()
            value['recordsDropped'] += 1
        return json.loads(json.dumps(value, ensure_ascii=True, allow_nan=False))

    def _profile_unlinked(self, profile):
        path, temporary = Path(profile), Path(self.temporary)
        for index in range(65):
            demand(time.monotonic() < self.reader.deadline, 'ORIGINAL_OBSERVATION_DEADLINE')
            try:
                info = path.lstat()
            except FileNotFoundError:
                info = None
            demand(info is None or (not stat.S_ISLNK(info.st_mode)
                   and not getattr(info, 'st_file_attributes', 0) & 0x400), 'PROFILE_LINK_REFUSED')
            if normalized_path(str(path)) == self.temporary:
                return
            demand(path != path.parent, 'PROFILE_ANCESTRY_ESCAPED')
            path = path.parent
        raise EvidenceRejected('PROFILE_PATH_TOO_DEEP')

    def _listeners(self, pid, port, handle, creation):
        # Installed, pinned psutil's PID-filtered API; no connect/bind/send call.
        import psutil
        import socket
        self.reader.verify(handle, creation, self.executable)
        before = time.monotonic()
        connections = psutil.Process(pid).net_connections(kind='tcp')
        self.reader.verify(handle, creation, self.executable)
        after = time.monotonic()
        rows = []
        for row in connections:
            if row.status != 'LISTEN' or not row.laddr or row.laddr.port != port:
                continue
            demand(row.type == socket.SOCK_STREAM and row.family in (socket.AF_INET, socket.AF_INET6),
                   'UNEXPECTED_DEBUG_LISTENER_KIND')
            rows.append({'address': row.laddr.ip, 'port': row.laddr.port, 'status': 'LISTEN',
                         'family': 'AF_INET' if row.family == socket.AF_INET else 'AF_INET6'})
        parsed = parse_listener_rows(rows, port)
        return ([dict(zip(('address', 'port', 'family', 'status'), row)) for row in parsed], before, after)

    def sample(self, deadline_qpc=None):
        sample_started = time.monotonic()
        if deadline_qpc is not None:
            demand(finite(deadline_qpc), 'INVALID_SAMPLE_DEADLINE')
            self.reader.deadline = min(self.deadline, float(deadline_qpc))
        self.samples += 1
        snapshot, kinds, frame_failed = None, [], False
        try:
            self.reader.check_deadline()
            snapshot = self.job.member_identities(float(self.reader.deadline))
            kinds, frame_failed = self._collect_snapshot(snapshot)
            for row, kind in zip(snapshot.get('identities', []), kinds):
                if kind != 'complete' or row['signaled'] is True:
                    continue
                if normalized_path(row['imagePath']) != self.executable:
                    continue
                identity = (row['pid'], row['creationFiletime'])
                if identity in self.checked and identity not in self.pending:
                    continue
                handle = self.reader.open_member(row['pid'], row['creationFiletime'], self.executable)
                try:
                    if identity not in self.checked:
                        argv, proof = self.reader.command_line(handle, row['pid'], row['creationFiletime'], self.executable)
                        parsed = parse_chrome_argv(argv, self.executable, self.temporary)
                        self.checked.add(identity)
                        if parsed is None:
                            continue
                        self._profile_unlinked(parsed['profile'])
                        self.pending[identity] = {**parsed, **proof, 'pid': row['pid'],
                            'creationFiletime': row['creationFiletime'],
                            'commandCreationFiletime': self.job.identity,
                            'sameReadHandleVerified': True, 'ownedMembershipVerifiedBeforeAndAfter': True,
                            'liveBeforeAndAfter': True}
                    pending = self.pending[identity]
                    listeners, before, after = self._listeners(row['pid'], pending['debuggingPort'], handle, row['creationFiletime'])
                    if listeners:
                        pending.update(observedQpc=after, debugListenerAddresses=listeners,
                            listenerReadBeforeQpc=before, listenerReadAfterQpc=after,
                            listenerSameHandleIdentityVerifiedBeforeAndAfter=True,
                            debugBindingLoopbackObserved=True)
                        self.complete[identity] = self.pending.pop(identity)
                finally:
                    self.job.k.CloseHandle(handle)
        except EvidenceRejected as failure:
            self._fatal(str(failure))
            if not frame_failed:
                self._failed_sample_calls += 1
                self._store_failure_snapshot(snapshot, kinds)
        except Exception as failure:
            self._fatal('OBSERVATION_API_ERROR_' + type(failure).__name__)
            if not frame_failed:
                self._failed_sample_calls += 1
                self._store_failure_snapshot(snapshot, kinds)
        finally:
            elapsed = time.monotonic() - sample_started
            if math.isfinite(elapsed) and elapsed >= 0:
                self._sample_elapsed_total += elapsed
                self._sample_elapsed_maximum = max(self._sample_elapsed_maximum, elapsed)
            else:
                self._member_diagnostic_errors += 1

    def finish(self, terminal_finality=None):
        valid_finality = self._finality_valid(terminal_finality)
        if valid_finality:
            try:
                a0_qpc = terminal_finality['A0']['sampleQpc']
                valid_finality = (all(row['rawRow']['sampleQpc'] <= a0_qpc for row in self._first_identities)
                    and all(frame['rawSnapshot']['after']['qpc'] <= a0_qpc for frame in self._failure_snapshots)
                    and all(row['observedQpc'] <= a0_qpc for row in self.complete.values()))
            except (KeyError, TypeError, ValueError, AttributeError):
                valid_finality = False
        if not valid_finality:
            self.problems.add('COMMAND_JOB_FINALITY_UNPROVED')
        if valid_finality and not self._member_fatal and not self._acceptance_overflow and not self._identity_conflicts:
            self._resolved_occurrences = [dict(row, resolution='OWNED_MEMBER_CLOSED_IMAGE_UNKNOWN')
                                          for row in self._pending_occurrences]
            if self._diagnostic_bytes(self._failure_ledger()) > 262144:
                self._resolved_occurrences = []
                self._acceptance_overflow = True
                self._fatal('MEMBER_ACCEPTANCE_LEDGER_OVERFLOW')
        if len(self._resolved_occurrences) != len(self._pending_occurrences):
            self.problems.add('OWN_JOB_MEMBER_IDENTITY_UNPROVED')
        # No native/process/network call here: only aggregate prior observations.
        if self.pending:
            self.problems.add('CHROME_ROOT_LISTENER_UNOBSERVED')
        roots = list(self.complete.values())
        if not roots:
            self.problems.add('NO_COMPLETE_OWNED_CHROME_ROOT')
        if len({row['profile'] for row in roots}) != len(roots):
            self.problems.add('CHROME_ROOT_PROFILE_REUSED')
        if len({row['debuggingPort'] for row in roots}) != len(roots):
            self.problems.add('CHROME_ROOT_DEBUG_PORT_REUSED')
        return {'schemaVersion': 2,
                'status': 'OWNED_CHROME_BOUNDARIES_OBSERVED' if not self.problems else 'NOT_ACCEPTED',
                'chromeRoots': sorted(roots, key=lambda row: (row['pid'], row['creationFiletime'])),
                'problems': sorted(self.problems), 'sampleCalls': self.samples,
                'pinnedBrowserPath': self.executable, 'temporaryRoot': self.temporary,
                'commandCreationFiletime': self.job.identity, 'observationDeadlineQpc': self.deadline,
                'commandLineSource': 'SAME_RETAINED_HANDLE_PBI0_READPROCESSMEMORY',
                'debugBindingProof': 'PID_FILTERED_LISTEN_ROWS_BRACKETED_BY_SAME_HANDLE_IDENTITY',
                'foreignCommandLinesRead': False, 'processesTerminated': False,
                'environmentRead': False, 'nativeReadPathQualificationSeparate': True,
                'observedProblems': sorted(self._observed_problems | self.problems),
                'failureLedger': self._json_copy(self._failure_ledger()),
                'terminalFinality': self._json_copy(terminal_finality)}
