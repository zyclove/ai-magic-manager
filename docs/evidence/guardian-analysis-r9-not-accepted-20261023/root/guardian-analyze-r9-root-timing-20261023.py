"""Independent QPC timing, outside the sealed candidate; no SDK actions."""
from pathlib import Path
import datetime,json,os,sys,time
base=Path(__file__).resolve().parent
anchor=base/'guardian-analyze-r9-root-prelaunch-20261023.json'
now=time.monotonic()
assert time.get_clock_info('monotonic').implementation=='QueryPerformanceCounter()'
value={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'monotonic':now}
if sys.argv[1]=='anchor':
    value.update(status='ROOT_R9_PRELAUNCH_QPC_NO_SDK',grant='guardian-analyze-r9-root-20261023',clock='QueryPerformanceCounter()',sourceCommit='a2b5ca6ef2398397e4208065090b7c1d65992358')
    target=anchor
else:
    before=json.loads(anchor.read_bytes());elapsed=now-before['monotonic']
    value.update(status='ROOT_R9_ACTUAL_SAME_SESSION_TERMINAL_OBSERVED',actualSession=int(sys.argv[2]),initialChunk=sys.argv[3],finalChunk=sys.argv[4],naturalExitCode=int(sys.argv[5]),anchorToAfterTerminalSeconds=elapsed,actualOuterTerminalBefore180=0<elapsed<180,conservativeActualCompleteBefore135=0<elapsed<135,preIoReceiptElapsedNotUsedAsExitProof=True)
    target=base/'guardian-analyze-r9-root-actual-terminal-20261023.json'
with target.open('x',encoding='utf-8',newline='\n') as stream:json.dump(value,stream,ensure_ascii=True,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
print(json.dumps(value,ensure_ascii=True))
