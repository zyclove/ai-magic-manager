"""Fixed no-SDK fixtures. SOURCE ONLY; no import-time process/native actions."""
from pathlib import Path
import importlib.util,json,os,sys,time

HERE=Path(__file__).resolve().parent
CASES={'natural-zero','natural-nonzero','deadline','nested-owned-child'}
def run(mode):
    if mode=='owned-leaf':
        while True:time.sleep(1)
    if mode=='natural-zero':return 0
    if mode=='natural-nonzero':return 7
    if mode=='deadline':
        while True:time.sleep(1)
    if mode!='nested-owned-child':raise ValueError('Fixed fixture mode required')
    spec=importlib.util.spec_from_file_location('guardian_fixture_owned_job',HERE/'owned_job.py')
    native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
    OwnedJob=native.OwnedJob
    task=HERE/'qualification-attempts'/mode
    child=OwnedJob()
    try:
        env={k:os.environ[k] for k in ('SystemRoot','WINDIR','PATH','TEMP','TMP','COMSPEC')}
        child.create_suspended([sys.executable,'-I','-B','-u',str(HERE/'fixtures.py'),'owned-leaf'],HERE,task/'owned-leaf.log',env)
        suspended=child.sample(0)
        child.resume()
        state=child.sample(0)
        proof={'status':'OWNED_NESTED_JOB_CHILD_STARTED','childPid':child.pid,
            'childCreationFiletime':child.identity,'atomicMembershipCheckedBeforeResume':True,
            'suspendedActive':suspended['activeProcesses'],'innerJobActive':state['activeProcesses'],
            'innerJobTotal':state['totalProcesses'],'childSignaled':state['signaled']}
        with (task/'nested-proof.json').open('x',encoding='utf-8') as f:json.dump(proof,f)
        while True:time.sleep(1)
    finally:
        child.close()
if __name__=='__main__':
    if len(sys.argv)!=2 or sys.argv[1] not in CASES|{'owned-leaf'}:raise SystemExit('Fixed fixture only')
    raise SystemExit(run(sys.argv[1]))
