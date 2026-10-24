"""Read-only evidence from retained members of one exact private SDK Job.

Import and pure parsers perform no process/network/native calls. This module
never launches, signals, terminates or cleans up a process. The caller's f8 Job
and original deadlines remain the sole lifetime/acceptance authority.
"""
import ctypes as C
from ctypes import wintypes as W
import hashlib
import ipaddress
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
        if deadline_qpc is not None:
            demand(finite(deadline_qpc), 'INVALID_SAMPLE_DEADLINE')
            self.reader.deadline = min(self.deadline, float(deadline_qpc))
        self.samples += 1
        try:
            self.reader.check_deadline()
            snapshot = self.job.member_identities(float(self.reader.deadline))
            demand(snapshot['before']['complete'] and snapshot['after']['complete']
                   and not snapshot['identityRowsLimitedByDeadline'], 'OWN_JOB_INVENTORY_INCOMPLETE')
            for row in snapshot['identities']:
                if row.get('signaled') is True:
                    continue
                demand(row.get('verifiedOwnMembership') is True and type(row.get('imagePath')) is str
                       and type(row.get('creationFiletime')) is int, 'OWN_JOB_MEMBER_IDENTITY_UNPROVED')
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
            self.problems.add(str(failure))
        except Exception as failure:
            self.problems.add('OBSERVATION_API_ERROR_' + type(failure).__name__)

    def finish(self):
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
        return {'schemaVersion': 1,
                'status': 'OWNED_CHROME_BOUNDARIES_OBSERVED' if not self.problems else 'NOT_ACCEPTED',
                'chromeRoots': sorted(roots, key=lambda row: (row['pid'], row['creationFiletime'])),
                'problems': sorted(self.problems), 'sampleCalls': self.samples,
                'pinnedBrowserPath': self.executable, 'temporaryRoot': self.temporary,
                'commandCreationFiletime': self.job.identity, 'observationDeadlineQpc': self.deadline,
                'commandLineSource': 'SAME_RETAINED_HANDLE_PBI0_READPROCESSMEMORY',
                'debugBindingProof': 'PID_FILTERED_LISTEN_ROWS_BRACKETED_BY_SAME_HANDLE_IDENTITY',
                'foreignCommandLinesRead': False, 'processesTerminated': False,
                'environmentRead': False, 'nativeReadPathQualificationSeparate': True}
