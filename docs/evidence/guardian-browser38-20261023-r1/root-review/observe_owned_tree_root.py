"""Read only previously observed descendants of this exact test command identity.

This adds diagnostics, never changes execution or acceptance and never stops a process.
Ancestry observations are not claimed as proof of Windows Job membership.
"""
from pathlib import Path
import datetime
import json
import sys
import time
import psutil

root = Path(__file__).resolve().parent
attempt = root / 'attempt'
worker_pid = int(sys.argv[1])
deadline = time.monotonic() + 520
seen = {}
snapshots = 0
last = None
problems = []
command_pid = None
command_created = None
output = (attempt/'root-owned-tree.jsonl').open('x',encoding='utf-8',newline='\n')

def fact(process):
    return {'pid':process.pid,'created':process.create_time(),'name':process.name(),'parent':process.ppid()}

try:
    while time.monotonic() < deadline:
        launch_path = attempt/'launch.json'
        if command_pid is None and launch_path.exists():
            try:
                launch = json.loads(launch_path.read_bytes())
                assert Path(launch['workingDirectory']).resolve()==(root/'src/apps/guardian').resolve()
                assert '--web-renderer=html' in launch['argv'][-1]
                process = psutil.Process(launch['pid'])
                row = fact(process)
                launched = datetime.datetime.fromisoformat(launch['utc']).timestamp()
                assert row['parent']==worker_pid and row['name'].lower()=='cmd.exe'
                assert abs(row['created']-launched)<3
                command_pid,command_created=row['pid'],row['created']
                seen[(row['pid'],row['created'])]=row
            except (json.JSONDecodeError,psutil.NoSuchProcess):
                pass
        if command_pid is not None:
            try:
                process=psutil.Process(command_pid)
                if process.create_time()==command_created:
                    for child in process.children(recursive=True):
                        try:
                            row=fact(child);seen[(row['pid'],row['created'])]=row
                        except psutil.NoSuchProcess:pass
            except psutil.NoSuchProcess:pass
        alive=[]
        for identity,row in seen.items():
            try:
                process=psutil.Process(row['pid'])
                if process.create_time()==row['created'] and process.is_running():alive.append(row)
            except psutil.NoSuchProcess:pass
        signature=tuple(sorted((row['pid'],row['created']) for row in alive))
        if signature!=last:
            output.write(json.dumps({'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'commandPid':command_pid,'rootStillAlive':any(row['pid']==command_pid for row in alive),
                'previouslyObservedDescendantsStillAlive':alive})+'\n')
            output.flush();snapshots+=1;last=signature
        if (attempt/'result.json').exists() and not alive:break
        time.sleep(0.25)
except Exception as error:
    problems.append(type(error).__name__+': '+str(error))
finally:
    output.close()
    receipt={'status':'READ_ONLY_OWNED_ANCESTRY_OBSERVATION_FINISHED',
        'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'workerPid':worker_pid,'commandPid':command_pid,'observedIdentities':list(seen.values()),
        'snapshots':snapshots,'problems':problems,'lastLiveIdentities':last,
        'osJobMembershipIndependentlyProven':False,'processesStartedOrStoppedByObserver':False,
        'sdkOrUserChromeStateChanged':False,'doesNotUpgradeRunAcceptance':True}
    with (attempt/'root-owned-tree-observation.json').open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(receipt,stream,ensure_ascii=False,indent=2);stream.write('\n')
    print(json.dumps({'status':receipt['status'],'observedIdentities':len(seen),'problems':problems,'lastLiveIdentities':last}))
