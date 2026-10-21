from pathlib import Path
import datetime, hashlib, json, re
import psutil

root=Path(__file__).absolute().parent
attempt=root/'attempt'
proposal=json.loads((root/'proposal.json').read_bytes())
result=json.loads((attempt/'result.json').read_bytes())
receipt=json.loads((attempt/'receipt.json').read_bytes())
pre=json.loads((attempt/'preflight-pins.json').read_bytes())
post=json.loads((attempt/'postflight-pins.json').read_bytes())
assert result['status']==receipt['status']=='NOT_ACCEPTED'
assert result['workerExitCode']==1 and result['ownedJobActiveProcessesFinal']==0
assert not result['ownedCleanupPerformed'] and not result['watchdogExpired']
terminal=receipt['commandTerminalStateAfterPostflight']
assert terminal['terminalVerified'] and terminal['rootExitCode']==1 and terminal['activeProcesses']==0
assert not terminal['terminationRequested'] and not terminal['timedOut'] and not receipt['forcedTermination']
assert pre['complete'] and post['complete']
rows=proposal['candidateFiles']+proposal['controlRuntimeFiles']+proposal['historicalMetadataFiles']
for row in rows:
    path=Path(row['path']) if row.get('absolute') else root/row['path']
    raw=path.read_bytes()
    assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
log=(attempt/'out/analyze.log').read_bytes()
assert hashlib.sha256(log).hexdigest()==receipt['logPin']['sha256']
text=log.decode('utf-8')
issues=re.findall(r'^\s+(info|warning|error) - (.*)$',text,re.M)
assert len(issues)==17 and all(level=='info' and line.endswith('use_build_context_synchronously') for level,line in issues)
sdk_names=set(proposal['sdkNames'])
processes=list(psutil.process_iter(['pid','name'],ad_value=None))
sdk=[p.info for p in processes if (p.info['name'] or '').lower() in sdk_names]
unknown=[p.pid for p in processes if p.info['name'] is None and p.pid not in (0,4)]
assert not sdk and not unknown
known=[result['workerPid'],terminal['pid']]
assert not any(psutil.pid_exists(pid) for pid in known)
value={
 'status':'ANALYSIS_DIAGNOSTICS_OBSERVED_NOT_ACCEPTED',
 'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'actualToolSession':63918,'initialToolChunk':'a744af','finalToolChunk':'bbd415','actualNaturalExitCode':1,
 'outerElapsedSeconds':result['elapsedCompleteSeconds'],'ownedJobActiveProcesses':0,
 'knownOwnedPidsAbsent':known,'sdkProcesses':sdk,'unknownProcessNames':unknown,
 'availableRamBytes':psutil.virtual_memory().available,'fullAnalysisAccepted':False,
 'scope':'08a335a seven-root 403-file Guardian snapshot; entire Guardian analysis, no tests',
 'diagnostics':{'errors':0,'warnings':0,'infos':17,'rule':'use_build_context_synchronously'},
 'candidateAndRuntimeMetadataPinsMatched':len(rows),
 'preAndPost':{'complete':True,'sourceFiles':403,'cacheFiles':3537,'cacheBytes':638417631,'packageRows':70},
 'rawLogSha256':hashlib.sha256(log).hexdigest(),
 'forcedTermination':False,'pubRun':False,'downloadsAllowed':False,'testsRun':False,
 'mainOrFrozenSourceChangedByRunner':False,'servicesUpdated':False,
 'note':'The 17 analyzer infos made fatal-infos return 1; later source fixes require new validation.'
}
path=attempt/'external-observation-root.json'
with path.open('x',encoding='utf-8',newline='\n') as stream:json.dump(value,stream,ensure_ascii=False,indent=2);stream.write('\n')
print(json.dumps(value))
