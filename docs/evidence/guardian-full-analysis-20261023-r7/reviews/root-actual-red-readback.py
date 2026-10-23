"""Independent readback of actual failed r7; never starts/stops an SDK."""
from pathlib import Path
import datetime,hashlib,json,os,re
import psutil
REPO=Path(__file__).resolve().parents[1]
RUN=REPO/'.cache/guardian-analyze-20261023-r7'
load=lambda p:json.loads(p.read_bytes())
sha=lambda raw:hashlib.sha256(raw).hexdigest()
proposal=load(RUN/'proposal.json');inputs=load(RUN/'inputs.json')
result=load(RUN/'attempt/result.json');receipt=load(RUN/'attempt/receipt.json');launch=load(RUN/'attempt/launch.json')
assert result['status']==receipt['status']=='NOT_ACCEPTED' and result['workerExitCode']==1
assert result['workerReceipt']==receipt and receipt['sdkCalls']==1 and not receipt['testsRun']
assert not result['ownedCleanupPerformed'] and not result['watchdogExpired'] and not receipt['forcedTermination']
assert result['ownedJobActiveProcessesFinal']==result['ownedJobActiveProcesses']==0
bound=launch['workerElapsedAtLaunch']+launch['commandBudgetSeconds']
assert result['elapsedCompleteSeconds']<bound<180
terminal=receipt['commandTerminalStateAfterPostflight']
assert terminal['terminalVerified'] and terminal['rootExitCode']==1 and terminal['activeProcesses']==0
assert not terminal['timedOut'] and not terminal['terminationRequested']
for name in ('preflight-pins.json','postflight-pins.json'):
    p=load(RUN/'attempt'/name);assert p['complete']
    assert p['source']['mainRaw']['files']==p['source']['frozenRawGit']['files']==409
    assert p['packages']['packages']==70 and p['cache']['totals']=={'files':3536,'bytes':633817159}
for row in proposal['candidateFiles']+proposal['controlRuntimeFiles']+proposal['historicalMetadataFiles']:
    path=Path(row['path']) if row.get('absolute') else RUN/row['path'];raw=path.read_bytes()
    assert len(raw)==row['bytes'] and sha(raw)==row['sha256']
manifest=load(Path(inputs['sourceManifest']['path']))
for row in manifest['sourceFiles']:
    for base,size,digest in ((REPO,row['workingTreeRawBytes'],row['workingTreeRawSha256']),
       (Path(proposal['sharedSourceSnapshot']),row['bytes'],row['sha256'])):
        raw=(base/row['path']).read_bytes();assert len(raw)==size and sha(raw)==digest
cache=load(Path(inputs['cacheManifest']['path']));count=total=0
for tree in cache['trees']:
    base=Path(tree['root']);files=set();dirs={'.'}
    for directory,children,names in os.walk(base):
        p=Path(directory);assert not p.is_symlink() and not p.is_junction()
        for child in children:
            q=p/child;assert not q.is_symlink() and not q.is_junction();dirs.add(q.relative_to(base).as_posix())
        for name in names:files.add((p/name).relative_to(base).as_posix())
    assert files=={r['relativePath'] for r in tree['entries']} and dirs==set(tree['directories'])
    for row in tree['entries']:
        raw=(base/row['relativePath']).read_bytes();assert len(raw)==row['bytes'] and sha(raw)==row['sha256'];count+=1;total+=len(raw)
for row in cache['fixedFiles']:
    raw=Path(row['path']).read_bytes();assert len(raw)==row['bytes'] and sha(raw)==row['sha256'];count+=1;total+=len(raw)
assert count==3536 and total==633817159
log=(RUN/'attempt/out/analyze.log').read_bytes();assert sha(log)==receipt['logPin']['sha256']
diagnostics=re.findall(r'^\s*(info|warning|error) - (.+)$',log.decode(),re.M)
assert len(diagnostics)==1 and diagnostics[0][0]=='warning' and diagnostics[0][1].endswith('unnecessary_non_null_assertion')
assert 'No issues found!' not in log.decode()
assert not any(psutil.pid_exists(p) for p in [62388,3724])
value={'status':'R7_ANALYSIS_RED_INDEPENDENTLY_CONFIRMED_AWAIT_FRESH_SYSTEM_RELEASE',
 'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'actualSession':1854,
 'initialChunk':'804cf2','finalChunk':'dff5b1','naturalExitCode':1,'outerElapsedSeconds':result['elapsedCompleteSeconds'],
 'strictCompleteDeadlineSeconds':bound,'sourceCommit':proposal['sourceCommit'],'sourceFilesRehashedBothTrees':409,
 'cacheFilesRehashed':count,'cacheBytesRehashed':total,'pinsMatched':212,
 'diagnostics':{'errors':0,'warnings':1,'infos':0},'diagnosticLines':diagnostics,
 'rawLogSha256':sha(log),'ownedJobActiveProcesses':0,'knownOwnedPidsAbsent':[62388,3724],
 'forcedTermination':False,'testsRun':False,'browserRun':False,'analysisAccepted':False,'wholeProductAccepted':False}
with (RUN/'attempt/external-red-readback-root.json').open('x',encoding='utf-8') as stream:json.dump(value,stream,indent=2);stream.write('\n')
print(json.dumps(value))
