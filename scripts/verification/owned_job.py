"""Owned WinAPI primitive. Importing performs no native call.

Baseline: f8b44764ed30d638781b7dc913e651fbbc6311b8f0945cc0d71b67c65abc141b
from guardian-browser13-20261024-r6-owned-member-finality/owned_job.py.
Only member-handle retention and its cleanup differ from that qualified source.
"""
import ctypes as C
from ctypes import wintypes as W
import subprocess
import time
import math

H=W.HANDLE; P=C.c_void_p; S=C.c_size_t; D=W.DWORD; Q=C.c_ulonglong
MEMBER_HANDLE_LIMIT=256
MEMBER_QUERY_ACCESS=0x1000|0x100000  # QUERY_LIMITED_INFORMATION | SYNCHRONIZE
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
class ProcessIds32(C.Structure):
    _fields_=[('assigned',D),('listed',D),('ids',S*32)]

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
        'OpenProcess':([D,W.BOOL,D],H),
        'QueryFullProcessImageNameW':([H,D,W.LPWSTR,C.POINTER(D)],W.BOOL),
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
        self.k=None;self.handle=None
        self.process=None;self.thread=None;self.pid=None;self.identity=None
        self.first_signaled_qpc=None;self.first_complete_terminal_qpc=None
        self.force_requested=False;self.force_succeeded=False
        self._member_handles={};self._member_rejected=set()
        self._member_opens=0;self._member_reuses=0
        self._member_capacity_failures=0;self._member_close_errors=0
        try:
            self.k=api();self.handle=checked(self.k.CreateJobObjectW(None,None),'CreateJobObjectW')
            limit=ExtendedLimits();limit.basic.flags=0x2000
            checked(self.k.SetInformationJobObject(self.handle,9,C.byref(limit),C.sizeof(limit)),'Set kill-on-close')
        except BaseException:self.close();raise
    @property
    def member_cache_stats(self):
        """Detached counters only; no native calls, PIDs or handle disclosure."""
        return {'limit':MEMBER_HANDLE_LIMIT,'opens':self._member_opens,
            'reuses':self._member_reuses,'retained':len(self._member_handles),
            'rejected':len(self._member_rejected),'capacityFailures':self._member_capacity_failures,
            'closeErrors':self._member_close_errors}
    def _close_handles(self,handles):
        failure=None
        for handle in handles:
            if not handle:continue
            try:
                if not self.k.CloseHandle(handle):self._member_close_errors+=1
            except BaseException as error:
                self._member_close_errors+=1
                if failure is None:failure=error
        if failure is not None:raise failure
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
        accounting_observed=time.monotonic()  # AFTER the complete accounting query, not the root wait.
        terminal=signaled and account.active==0
        if terminal and self.first_complete_terminal_qpc is None:self.first_complete_terminal_qpc=accounting_observed
        return {'pid':self.pid,'creationFiletime':self.identity,'firstSignaledQpc':self.first_signaled_qpc,
            'sampleQpc':observed,'signaled':signaled,'exitCode':code,**times,
            'jobAccountingObservedQpc':accounting_observed,'firstCompleteTerminalQpc':self.first_complete_terminal_qpc,
            'activeProcesses':int(account.active),'totalProcesses':int(account.total),
            'terminatedProcesses':int(account.terminated),'terminal':terminal}
    def terminate_owned(self):
        if not self.force_requested:
            self.force_requested=True;self.force_succeeded=bool(self.k.TerminateJobObject(self.handle,124))
        return self.force_succeeded
    def member_identities(self,deadline):
        """Bounded diagnostics from this Job only; handles have no kill rights.

        A PID is never trusted on its own. Membership, creation identity and
        wait state come from one read-only opened/retained handle. A proved
        child's handle remains open until close(), preventing a later lookup
        of a vanished/reused PID. Failed proofs never permit reopening by PID.
        """
        if type(deadline) is not float or not math.isfinite(deadline):raise ValueError('Finite existing deadline required')
        if not self.handle:raise RuntimeError('Owned Job is closed')
        def listing():
            if time.monotonic()>=deadline:
                return {'qpc':time.monotonic(),'complete':False,'skippedDueDeadline':True,'pids':[]}
            data=ProcessIds32();returned=D()
            okay=bool(self.k.QueryInformationJobObject(self.handle,3,C.byref(data),C.sizeof(data),C.byref(returned)))
            error=0 if okay else C.get_last_error()
            count=min(int(data.listed),32)
            complete=okay and int(data.assigned)<=32 and int(data.listed)<=32
            return {'qpc':time.monotonic(),'complete':complete,'assigned':int(data.assigned),
                'listed':int(data.listed),'limit':32,'error':error,
                'pids':[int(data.ids[i]) for i in range(count)]}
        before=listing();identities=[]
        for pid in before['pids']:
            if time.monotonic()>=deadline:break
            row={'pid':pid,'openedFromOwnJobList':True,'verifiedOwnMembership':False}
            if pid==0:
                row['invalidZeroPid']=True;identities.append(row);continue
            retained=pid==self.pid
            row['retainedRootHandleUsed']=retained
            previous=None
            if retained:
                handle=self.process
            elif pid in self._member_handles:
                handle,previous=self._member_handles[pid];self._member_reuses+=1
            else:
                if pid in self._member_rejected:
                    raise RuntimeError('Member identity was not proved on first observation')
                if len(self._member_handles)+len(self._member_rejected)>=MEMBER_HANDLE_LIMIT:
                    self._member_capacity_failures+=1
                    raise RuntimeError('Retained member handle limit (256) reached')
                self._member_opens+=1
                handle=self.k.OpenProcess(MEMBER_QUERY_ACCESS,False,pid)
            if not handle:
                if not retained:self._member_rejected.add(pid)
                row['openError']=C.get_last_error();identities.append(row);continue
            try:
                member=W.BOOL()
                if not self.k.IsProcessInJob(handle,self.handle,C.byref(member)):
                    row['membershipQueryError']=C.get_last_error();continue
                row['verifiedOwnMembership']=bool(member.value)
                # A reused PID outside this Job supplies no trusted identity.
                if not member.value:
                    row['membershipRaceOrChange']=True;continue
                times=[W.FILETIME() for _ in range(4)]
                if not self.k.GetProcessTimes(handle,*(C.byref(v) for v in times)):
                    row['timesError']=C.get_last_error();continue
                row.update(dict(zip(('creationFiletime','exitFiletime','kernel100ns','user100ns'),map(filetime,times))))
                creation=row['creationFiletime']
                if ((retained and creation!=self.identity)
                    or (previous is not None and creation!=previous)
                    or creation<=0 or creation<self.identity):
                    row['retainedIdentityMismatch']=True;continue
                if not retained and previous is None:
                    self._member_handles[pid]=(handle,creation)
                result=self.k.WaitForSingleObject(handle,0);row['sampleQpc']=time.monotonic()
                row['signaled']=result==0
                if result not in (0,258):row['waitError']=C.get_last_error()
                if result==0:
                    value=D()
                    if self.k.GetExitCodeProcess(handle,C.byref(value)):row['exitCode']=int(value.value)
                    else:row['exitCodeError']=C.get_last_error()
                image=C.create_unicode_buffer(1024);size=D(1024)
                if self.k.QueryFullProcessImageNameW(handle,0,image,C.byref(size)):
                    row['imagePath']=image.value
                else:row['imageError']=C.get_last_error()
            finally:
                identities.append(row)
                if not retained and pid not in self._member_handles:
                    self._member_rejected.add(pid)
                    self._close_handles([handle])
        return {'startedQpc':before['qpc'],'deadlineQpc':deadline,'before':before,'identities':identities,'after':listing(),
            'identityRowsLimitedByDeadline':len(identities)<len(before['pids']),
            'scope':'This private Job only; read-only handles, no command line/environment, no PID termination',
            'causeClassified':False}
    def close(self):
        # Closing this non-inherited Job is the exact-subtree kernel fallback.
        handles=[self.handle]
        handles.extend(handle for handle,_ in self._member_handles.values())
        handles.extend([self.thread,self.process])
        self.handle=self.thread=self.process=None
        self._member_handles.clear();self._member_rejected.clear()
        if self.k is not None:self._close_handles(handles)
