"""Qualification-only WinAPI primitive. Importing performs no native call."""
import ctypes as C
from ctypes import wintypes as W
import subprocess
import time

H=W.HANDLE; P=C.c_void_p; S=C.c_size_t; D=W.DWORD; Q=C.c_ulonglong
class Limits(C.Structure):
    _fields_=[('process_time',C.c_longlong),('job_time',C.c_longlong),('flags',D),('min_working_set',S),('max_working_set',S),('active_limit',D),('affinity',S),('priority',D),('scheduling',D)]
class Io(C.Structure):
    _fields_=[(n,Q) for n in ('read_ops','write_ops','other_ops','read_bytes','write_bytes','other_bytes')]
class ExtendedLimits(C.Structure):
    _fields_=[('basic',Limits),('io',Io),('process_memory',S),('job_memory',S),('peak_process_memory',S),('peak_job_memory',S)]
class Accounting(C.Structure):
    _fields_=[(n,C.c_longlong) for n in ('user','kernel','period_user','period_kernel')]+[(n,D) for n in ('faults','total','active','terminated')]
class Startup(C.Structure):
    _fields_=[('cb',D),('reserved',W.LPWSTR),('desktop',W.LPWSTR),('title',W.LPWSTR),('x',D),('y',D),('x_size',D),('y_size',D),('x_chars',D),('y_chars',D),('fill',D),('flags',D),('show',W.WORD),('reserved_bytes',W.WORD),('reserved_pointer',P),('stdin',H),('stdout',H),('stderr',H)]
class StartupEx(C.Structure):
    _fields_=[('startup',Startup),('attributes',P)]
class ProcessInfo(C.Structure):
    _fields_=[('process',H),('thread',H),('pid',D),('tid',D)]
class Security(C.Structure):
    _fields_=[('length',D),('descriptor',P),('inherit',W.BOOL)]

def api():
    k=C.WinDLL('kernel32',use_last_error=True)
    signatures={
        'CreateJobObjectW':([P,W.LPCWSTR],H),
        'SetInformationJobObject':([H,C.c_int,P,D],W.BOOL),
        'QueryInformationJobObject':([H,C.c_int,P,D,C.POINTER(D)],W.BOOL),
        'TerminateJobObject':([H,W.UINT],W.BOOL),
        'InitializeProcThreadAttributeList':([P,D,D,C.POINTER(S)],W.BOOL),
        'UpdateProcThreadAttribute':([P,D,S,P,S,P,C.POINTER(S)],W.BOOL),
        'DeleteProcThreadAttributeList':([P],None),
        'CreateProcessW':([W.LPCWSTR,W.LPWSTR,P,P,W.BOOL,D,P,W.LPCWSTR,C.POINTER(Startup),C.POINTER(ProcessInfo)],W.BOOL),
        'ResumeThread':([H],D),'WaitForSingleObject':([H,D],D),
        'GetExitCodeProcess':([H,C.POINTER(D)],W.BOOL),
        'GetProcessTimes':([H,C.POINTER(W.FILETIME),C.POINTER(W.FILETIME),C.POINTER(W.FILETIME),C.POINTER(W.FILETIME)],W.BOOL),
        'IsProcessInJob':([H,H,C.POINTER(W.BOOL)],W.BOOL),
        'CloseHandle':([H],W.BOOL),
        'CreateFileW':([W.LPCWSTR,D,D,C.POINTER(Security),D,D,H],H)}
    for name,(args,result) in signatures.items():
        f=getattr(k,name);f.argtypes=args;f.restype=result
    return k
def checked(value,label):
    if not value:raise C.WinError(C.get_last_error(),label)
    return value
def filetime(value):return (int(value.dwHighDateTime)<<32)|int(value.dwLowDateTime)

class OwnedJob:
    """One exact retained root handle, atomic Job entry, no PID lookup/kill."""
    def __init__(self):
        self.k=api();self.handle=checked(self.k.CreateJobObjectW(None,None),'CreateJobObjectW')
        self.process=None;self.thread=None;self.pid=None;self.identity=None
        self.first_signaled_qpc=None;self.force_requested=False;self.force_succeeded=False
        limit=ExtendedLimits();limit.basic.flags=0x2000
        try:checked(self.k.SetInformationJobObject(self.handle,9,C.byref(limit),C.sizeof(limit)),'Set kill-on-close')
        except BaseException:self.close();raise
    def times(self):
        values=[W.FILETIME() for _ in range(4)]
        checked(self.k.GetProcessTimes(self.process,*(C.byref(v) for v in values)),'GetProcessTimes exact handle')
        return dict(zip(('creationFiletime','exitFiletime','kernel100ns','user100ns'),map(filetime,values)))
    def create_suspended(self,argv,cwd,log,environment):
        if self.process:raise RuntimeError('Only one owned root')
        security=Security(C.sizeof(Security),None,True)
        handles=[];attributes=None;ready=False
        try:
            output=self.k.CreateFileW(str(log),0x40000000,1,C.byref(security),1,0x80,None)
            if output==C.c_void_p(-1).value:raise C.WinError(C.get_last_error(),'CreateNew fixture log')
            handles.append(output)
            stdin=self.k.CreateFileW('NUL',0x80000000,3,C.byref(security),3,0x80,None)
            if stdin==C.c_void_p(-1).value:raise C.WinError(C.get_last_error(),'Open NUL')
            handles.append(stdin);size=S()
            sized=self.k.InitializeProcThreadAttributeList(None,2,0,C.byref(size))
            if sized or C.get_last_error()!=122 or not size.value:raise RuntimeError('Attribute sizing failed')
            buffer=C.create_string_buffer(size.value);attributes=C.cast(buffer,P)
            checked(self.k.InitializeProcThreadAttributeList(attributes,2,0,C.byref(size)),'Initialize attributes');ready=True
            jobs=(H*1)(self.handle);allowed=(H*len(handles))(*handles)
            checked(self.k.UpdateProcThreadAttribute(attributes,0,0x2000D,C.cast(jobs,P),C.sizeof(jobs),None,None),'Atomic JOB_LIST required')
            checked(self.k.UpdateProcThreadAttribute(attributes,0,0x20002,C.cast(allowed,P),C.sizeof(allowed),None,None),'Explicit handles only')
            start=StartupEx();start.startup.cb=C.sizeof(StartupEx);start.startup.flags=0x101
            start.startup.stdin,start.startup.stdout,start.startup.stderr=stdin,output,output;start.attributes=attributes
            info=ProcessInfo();command=C.create_unicode_buffer(subprocess.list2cmdline([str(a) for a in argv]))
            env=C.create_unicode_buffer('\0'.join(k+'='+v for k,v in sorted(environment.items()))+'\0\0')
            checked(self.k.CreateProcessW(str(argv[0]),command,None,None,True,0x80000|0x08000000|0x4|0x400,C.cast(env,P),str(cwd),C.cast(C.byref(start),C.POINTER(Startup)),C.byref(info)),'Create suspended in private Job')
            self.process,self.thread,self.pid=info.process,info.thread,int(info.pid)
            member=W.BOOL();checked(self.k.IsProcessInJob(self.process,self.handle,C.byref(member)),'Exact Job membership')
            if not member.value:raise RuntimeError('Atomic Job membership missing')
            self.identity=self.times()['creationFiletime']
            if not self.identity:raise RuntimeError('Creation identity missing')
        finally:
            if ready:self.k.DeleteProcThreadAttributeList(attributes)
            for h in handles:self.k.CloseHandle(h)
    def resume(self):
        if not self.thread or self.times()['creationFiletime']!=self.identity:raise RuntimeError('Suspended identity changed')
        if self.k.ResumeThread(self.thread)==0xFFFFFFFF:raise C.WinError(C.get_last_error(),'ResumeThread')
        self.k.CloseHandle(self.thread);self.thread=None
    def sample(self,milliseconds):
        if not self.process:raise RuntimeError('No retained root handle')
        if type(milliseconds) is not int or not 0<=milliseconds<=50:raise ValueError('Finite bounded wait only')
        result=self.k.WaitForSingleObject(self.process,milliseconds)
        observed=time.monotonic()  # First observation BEFORE any further API or I/O.
        if result not in (0,258):raise C.WinError(C.get_last_error(),'WaitForSingleObject')
        signaled=result==0
        if signaled and self.first_signaled_qpc is None:self.first_signaled_qpc=observed
        times=self.times()
        if times['creationFiletime']!=self.identity:raise RuntimeError('Retained identity mismatch')
        code=None
        if signaled:
            value=D();checked(self.k.GetExitCodeProcess(self.process,C.byref(value)),'Exit code exact handle');code=int(value.value)
            if not times['exitFiletime']:raise RuntimeError('Signaled handle has no kernel exit time')
        account=Accounting();checked(self.k.QueryInformationJobObject(self.handle,1,C.byref(account),C.sizeof(account),None),'Job accounting')
        return {'pid':self.pid,'creationFiletime':self.identity,'firstSignaledQpc':self.first_signaled_qpc,
            'sampleQpc':observed,'signaled':signaled,'exitCode':code,**times,
            'activeProcesses':int(account.active),'totalProcesses':int(account.total),
            'terminatedProcesses':int(account.terminated),'terminal':signaled and account.active==0}
    def terminate_owned(self):
        if not self.force_requested:
            self.force_requested=True;self.force_succeeded=bool(self.k.TerminateJobObject(self.handle,124))
        return self.force_succeeded
    def close(self):
        # Closing this non-inherited Job is the exact-subtree kernel fallback.
        if self.handle:self.k.CloseHandle(self.handle);self.handle=None
        if self.thread:self.k.CloseHandle(self.thread);self.thread=None
        if self.process:self.k.CloseHandle(self.process);self.process=None
