"""Task-only Windows Job guard. Importing this module starts no process."""
import ctypes as C
from ctypes import wintypes as W
import subprocess
import time

H = W.HANDLE
P = C.c_void_p
S = C.c_size_t
D = W.DWORD
Q = C.c_ulonglong

class Limits(C.Structure):
    _fields_ = [('process_time', C.c_longlong), ('job_time', C.c_longlong),
                ('flags', D), ('min_working_set', S), ('max_working_set', S),
                ('active_limit', D), ('affinity', S), ('priority', D), ('scheduling', D)]

class Io(C.Structure):
    _fields_ = [(name, Q) for name in ['read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes']]

class ExtendedLimits(C.Structure):
    _fields_ = [('basic', Limits), ('io', Io), ('process_memory', S), ('job_memory', S),
                ('peak_process_memory', S), ('peak_job_memory', S)]

class Accounting(C.Structure):
    _fields_ = [(name, C.c_longlong) for name in ['user', 'kernel', 'period_user', 'period_kernel']] + [
        (name, D) for name in ['faults', 'total', 'active', 'terminated']]

class Startup(C.Structure):
    _fields_ = [('cb', D), ('reserved', W.LPWSTR), ('desktop', W.LPWSTR), ('title', W.LPWSTR),
                ('x', D), ('y', D), ('x_size', D), ('y_size', D), ('x_chars', D), ('y_chars', D),
                ('fill', D), ('flags', D), ('show', W.WORD), ('reserved_bytes', W.WORD),
                ('reserved_pointer', P), ('stdin', H), ('stdout', H), ('stderr', H)]

class StartupEx(C.Structure):
    _fields_ = [('startup', Startup), ('attributes', P)]

class ProcessInfo(C.Structure):
    _fields_ = [('process', H), ('thread', H), ('pid', D), ('tid', D)]

class Security(C.Structure):
    _fields_ = [('length', D), ('descriptor', P), ('inherit', W.BOOL)]

def api():
    k = C.WinDLL('kernel32', use_last_error=True)
    signatures = {
        'CreateJobObjectW': ([P, W.LPCWSTR], H),
        'SetInformationJobObject': ([H, C.c_int, P, D], W.BOOL),
        'QueryInformationJobObject': ([H, C.c_int, P, D, C.POINTER(D)], W.BOOL),
        'TerminateJobObject': ([H, W.UINT], W.BOOL),
        'InitializeProcThreadAttributeList': ([P, D, D, C.POINTER(S)], W.BOOL),
        'UpdateProcThreadAttribute': ([P, D, S, P, S, P, C.POINTER(S)], W.BOOL),
        'DeleteProcThreadAttributeList': ([P], None),
        'CreateProcessW': ([W.LPCWSTR, W.LPWSTR, P, P, W.BOOL, D, P, W.LPCWSTR, C.POINTER(Startup), C.POINTER(ProcessInfo)], W.BOOL),
        'ResumeThread': ([H], D),
        'WaitForSingleObject': ([H, D], D),
        'GetExitCodeProcess': ([H, C.POINTER(D)], W.BOOL),
        'CloseHandle': ([H], W.BOOL),
        'CreateFileW': ([W.LPCWSTR, D, D, C.POINTER(Security), D, D, H], H),
    }
    for name, (arguments, result) in signatures.items():
        fn = getattr(k, name)
        fn.argtypes, fn.restype = arguments, result
    return k

def checked(value, operation):
    if not value:
        raise C.WinError(C.get_last_error(), operation)
    return value

class Job:
    """Anonymous, non-inheritable Job; children enter it atomically at creation."""
    def __init__(self):
        self.k = api()
        self.handle = checked(self.k.CreateJobObjectW(None, None), 'CreateJobObjectW')
        self.process = None
        self.pid = None
        self.termination_requested = False
        self.termination_succeeded = False
        self.timed_out = False
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; no breakaway.
        try:
            checked(self.k.SetInformationJobObject(self.handle, 9, C.byref(limits), C.sizeof(limits)), 'SetInformationJobObject')
        except BaseException:
            self.close()
            raise

    def spawn(self, argv, cwd, log):
        if self.process is not None:
            raise RuntimeError('One root process per Job only.')
        security = Security(C.sizeof(Security), None, True)
        handles = []
        attributes = None
        attributes_ready = False
        thread = None
        try:
            # CREATE_NEW: no exists/open race and no replacement of previous evidence.
            output = self.k.CreateFileW(str(log), 0x40000000, 1, C.byref(security), 1, 0x80, None)
            if output == C.c_void_p(-1).value:
                raise C.WinError(C.get_last_error(), 'CreateNew log')
            handles.append(output)
            stdin = self.k.CreateFileW('NUL', 0x80000000, 3, C.byref(security), 3, 0x80, None)
            if stdin == C.c_void_p(-1).value:
                raise C.WinError(C.get_last_error(), 'Open NUL')
            handles.append(stdin)
            size = S()
            initialized = self.k.InitializeProcThreadAttributeList(None, 2, 0, C.byref(size))
            if initialized or C.get_last_error() != 122 or not size.value:
                raise RuntimeError('Unexpected attribute-list sizing result.')
            buffer = C.create_string_buffer(size.value)
            attributes = C.cast(buffer, P)
            checked(self.k.InitializeProcThreadAttributeList(attributes, 2, 0, C.byref(size)), 'InitializeProcThreadAttributeList')
            attributes_ready = True
            job_list = (H * 1)(self.handle)
            inherited = (H * len(handles))(*handles)
            # JOB_LIST requires Windows 10+. Fail closed; never fall back to post-create assignment.
            checked(self.k.UpdateProcThreadAttribute(attributes, 0, 0x2000D, C.cast(job_list, P), C.sizeof(job_list), None, None), 'Set atomic Job list')
            checked(self.k.UpdateProcThreadAttribute(attributes, 0, 0x20002, C.cast(inherited, P), C.sizeof(inherited), None, None), 'Set explicit inherited handles')
            startup = StartupEx()
            startup.startup.cb = C.sizeof(StartupEx)
            startup.startup.flags = 0x101  # STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW; SW_HIDE=0.
            startup.startup.stdin, startup.startup.stdout, startup.startup.stderr = stdin, output, output
            startup.attributes = attributes
            info = ProcessInfo()
            command = C.create_unicode_buffer(subprocess.list2cmdline([str(arg) for arg in argv]))
            flags = 0x80000 | 0x08000000 | 0x4  # EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_SUSPENDED.
            checked(self.k.CreateProcessW(str(argv[0]), command, None, None, True, flags, None,
                                           str(cwd), C.cast(C.byref(startup), C.POINTER(Startup)), C.byref(info)), 'CreateProcessW in Job')
            self.process, self.pid, thread = info.process, int(info.pid), info.thread
            if self.k.ResumeThread(thread) == 0xFFFFFFFF:
                raise C.WinError(C.get_last_error(), 'ResumeThread')
        finally:
            if thread:
                self.k.CloseHandle(thread)
            if attributes_ready:
                self.k.DeleteProcThreadAttributeList(attributes)
            for handle in handles:
                self.k.CloseHandle(handle)

    def snapshot(self):
        account = Accounting()
        checked(self.k.QueryInformationJobObject(self.handle, 1, C.byref(account), C.sizeof(account), None), 'QueryInformationJobObject')
        signaled = self.process is None
        code = None
        if self.process:
            result = self.k.WaitForSingleObject(self.process, 0)
            if result == 0xFFFFFFFF:
                raise C.WinError(C.get_last_error(), 'WaitForSingleObject')
            signaled = result == 0
            if signaled:
                value = D()
                checked(self.k.GetExitCodeProcess(self.process, C.byref(value)), 'GetExitCodeProcess')
                code = int(value.value)
        return dict(pid=self.pid, rootHandleSignaled=signaled, rootExitCode=code,
                    activeProcesses=int(account.active), totalProcesses=int(account.total),
                    terminatedProcesses=int(account.terminated), terminalVerified=signaled and account.active == 0,
                    timedOut=self.timed_out, terminationRequested=self.termination_requested,
                    terminationCallSucceeded=self.termination_succeeded)

    def terminate(self):
        self.termination_requested = True
        self.termination_succeeded = bool(self.k.TerminateJobObject(self.handle, 124))
        return self.termination_succeeded

    def wait(self, deadline, cleanup_deadline):
        while True:
            state = self.snapshot()
            if state['terminalVerified']:
                return state
            if time.monotonic() >= deadline:
                self.timed_out = True
                self.terminate()
                break
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
        while time.monotonic() < cleanup_deadline:
            state = self.snapshot()
            if state['terminalVerified']:
                return state
            time.sleep(min(0.1, max(0, cleanup_deadline - time.monotonic())))
        return self.snapshot()  # False terminalVerified is never upgraded from a successful terminate call.

    def close(self):
        if self.process:
            self.k.CloseHandle(self.process)
            self.process = None
        if self.handle:
            self.k.CloseHandle(self.handle)  # Kernel fallback kills only members of this private Job.
            self.handle = None
