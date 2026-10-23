"""Independent prelaunch/after-tool timing evidence. Never starts or stops SDKs."""
import datetime, json, os, sys, time
from pathlib import Path

base = Path(__file__).resolve().parent
anchor_path = base / 'guardian-browser80-r2-root-prelaunch-20261023.json'
now = time.monotonic()
utc = datetime.datetime.now(datetime.timezone.utc).isoformat()
assert time.get_clock_info('monotonic').implementation == 'QueryPerformanceCounter()'
if sys.argv[1] == 'anchor':
    value = {'status':'ROOT_PRELAUNCH_QPC_ANCHOR_NO_SDK_STARTED', 'utc':utc,
             'monotonic':now, 'clockImplementation':time.get_clock_info('monotonic').implementation,
             'grant':'guardian-browser80-r2-root-20261023',
             'proposalSha256':'a9951961c2d4a933567bd38446228bb177cc469cdbe23a8d9b42b816f11857be',
             'sourceCommit':'45950b88a270e2fded2409e333fb126851b6f861', 'outerHardSeconds':300}
    target = anchor_path
elif sys.argv[1] == 'terminal':
    anchor = json.loads(anchor_path.read_bytes())
    elapsed = now - anchor['monotonic']
    value = {'status':'ACTUAL_EXEC_SESSION_TERMINAL_OBSERVED', 'utc':utc, 'monotonic':now,
             'anchorToAfterToolTerminalSeconds':elapsed,
             'conservativeActualOuterTerminalBefore300':0 < elapsed < 300,
             'actualSession':int(sys.argv[2]),'initialChunk':sys.argv[3],
             'finalChunk':sys.argv[4], 'naturalExitCode':int(sys.argv[5]),
             'basis':'Anchor precedes controller launch; this observation follows same exec-session terminal return.',
             'candidateReceiptElapsedNotUsedAsOuterExitProof':True}
    target = base / 'guardian-browser80-r2-root-actual-terminal-20261023.json'
else:
    raise SystemExit('anchor or terminal required')
with target.open('x',encoding='utf-8',newline='\n') as stream:
    json.dump(value,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
print(json.dumps(value))
