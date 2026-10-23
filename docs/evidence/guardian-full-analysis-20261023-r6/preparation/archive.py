"""Preserve exact existing evidence; no SDK, Git mutation, binary or source copy."""
from pathlib import Path
import datetime, hashlib, json

REPO = Path(__file__).resolve().parents[1]
RUN = REPO / '.cache/guardian-analyze-20261023-r6'
SNAP = REPO / '.cache/guardian-reports-current-20261023-r1'
OUT = REPO / 'docs/evidence/guardian-full-analysis-20261023-r6'
PLAN = REPO / '.cache/guardian-analyze-r6-evidence-commit-20261023-plan.json'
sha = lambda value: hashlib.sha256(value).hexdigest()
load = lambda path: json.loads(path.read_bytes())
encode = lambda value: (json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode()

def raw(path):
    path = Path(path)
    assert not path.is_symlink() and not path.is_junction()
    return path.read_bytes()

def pinned(path,row):
    value=raw(path)
    assert len(value)==row['bytes'] and sha(value)==row['sha256'], str(path)
    return value

assert not OUT.exists() and not PLAN.exists()
proposal=load(RUN/'proposal.json')
assert sha(raw(RUN/'proposal.json'))=='b4cf7534705500f7a3dd1cd825a2c314bbb5654295e63aa21b007b496cffb7b5'
result=load(RUN/'attempt/result.json')
receipt=load(RUN/'attempt/receipt.json')
external=load(RUN/'attempt/external-observation-root.json')
gate=load(RUN/'attempt/root-final-system-gate.json')
assert gate['status']=='FULL_GUARDIAN_ANALYZE_EXTERNALLY_ACCEPTED' and gate['formalRelease']
assert gate['sdkCount']==gate['unknownProcessNameCount']==0
assert gate['actualSession']==external['actualToolSession']==35555
assert external['finalToolChunk']=='c6f353' and external['naturalExitCode']==0
assert result['status']=='FULL_GUARDIAN_ANALYZE_PASSED' and result['workerExitCode']==0
assert result['elapsedCompleteSeconds']==external['outerElapsedSeconds']<external['strictCompleteBoundSeconds']<180
assert external['cacheFilesIndependentlyRehashed']==3536 and external['sourceFilesIndependentlyRehashedBothTrees']==408
assert not receipt['forcedTermination'] and not receipt['testsRun']

copies={}
originals={}
def add(source,target,expected=None):
    source=Path(source)
    assert source.is_relative_to(REPO)
    value=pinned(source,expected) if expected else raw(source)
    assert len(value)<2*1024*1024
    if str(source) in originals:
        return OUT/originals[str(source)]
    assert target not in copies
    copies[target]=(value,str(source))
    originals[str(source)]=target
    return OUT/target

for row in proposal['candidateFiles']:
    add(RUN/row['path'],'candidate/'+row['path'],row)
for name in ('proposal.json','inputs.json','seal-receipt.json','external_observe_root.py'):
    add(RUN/name,'candidate/'+name)
for path in sorted((RUN/'attempt').rglob('*')):
    if path.is_file() and 'tmp' not in path.relative_to(RUN/'attempt').parts:
        add(path,'attempt/'+path.relative_to(RUN/'attempt').as_posix())
for source,target in (
 (REPO/'.cache/guardian-reports-r6-root-review-20261023.py','reviews/root-source-and-controls-review.py'),
 (REPO/'.cache/guardian-reports-r6-root-review-20261023.json','reviews/root-source-and-controls-review.json'),
 (Path(__file__),'preparation/archive.py')):
    add(source,target)
add(SNAP/'out/seal-static-source.json','inputs/source-snapshot-seal.json')
for row in load(SNAP/'out/seal-static-source.json')['files']:
    if not row['path'].startswith('src/'):
        add(SNAP/row['path'],'inputs/source-snapshot/'+row['path'],row)
inputs=load(RUN/'inputs.json')
for key in ('sourceManifest','dependencyLibraryPins','cacheManifest','originalPackageConfig','candidatePackageConfig','candidatePackageConfigTemplate'):
    row=inputs[key]
    add(Path(row['path']),'inputs/'+key+'.json',row)

existing=[]
for name in ('guardian-full-analysis-20261023-r5','guardian-full-analysis-20261023-r4',
             'guardian-full-analysis-20261023-r3','guardian-baseline-analysis-20261021',
             'guardian-browser38-20261023-r1'):
    base=REPO/'docs/evidence'/name
    inventory=load(base/'archive-inventory.json')
    for row in inventory['files']:
        existing.append((base/row['archivePath'],row))
    for row in inventory.get('durableHistoricalMetadataPins',[]):
        existing.append((REPO/row['durableArchivePath'],row))
runtime={str(Path(r['path'])).lower() for r in proposal['controlRuntimeFiles']}
history=[]
descriptors=[]
for index,row in enumerate(proposal['historicalMetadataFiles']):
    if str(Path(row['path'])).lower() in runtime:
        descriptors.append({'index':index,**row,'evidenceKind':'PIN_DESCRIPTOR_ONLY_NO_BINARY_COPY'})
        continue
    source=Path(row['path'])
    pinned(source,row)
    if str(source) in originals:
        target=OUT/originals[str(source)]
    else:
        match=next((p for p,r in existing if r['bytes']==row['bytes'] and r['sha256']==row['sha256']),None)
        if match:
            pinned(match,row);target=match
        else:
            target=add(source,f'historical/{index:03d}-'+source.name,row)
    history.append({'historicalIndex':index,'originalPath':str(source),
                    'durableArchivePath':target.relative_to(REPO).as_posix(),
                    'bytes':row['bytes'],'sha256':row['sha256']})
assert len(history)+len(descriptors)==133 and len(descriptors)==22
assert len({str(Path(r['path'])).lower() for r in descriptors})==11
facts={'status':'FULL_GUARDIAN_ANALYSIS_EXTERNALLY_ACCEPTED_BROWSER67_UNRUN',
 'sourceCommit':proposal['sourceCommit'],'sourceFiles':408,'scope':'Entire Guardian lib/test analysis without selectors; no application test execution',
 'actualSession':35555,'initialChunk':'7f7712','finalChunk':'c6f353','naturalExitCode':0,
 'outerElapsedSeconds':result['elapsedCompleteSeconds'],'strictCompleteDeadlineSeconds':external['strictCompleteBoundSeconds'],
 'diagnostics':external['diagnostics'],'sourceCacheIndependentReadbackChunk':'2311f6','finalSystemGateChunk':'7315e1',
 'sdkCountAtRelease':0,'unknownProcessNamesAtRelease':0,'ownedJobActiveProcesses':0,
 'fullSourcePrePost':408,'packageRows':70,'cacheFiles':3536,'cacheBytes':633817159,
 'candidateAndRuntimePins':156,'oldR5PinsPreserved':101,
 'browserCasesPrepared':67,'physicalSuitesPrepared':6,'browserCasesExecuted':0,
 'testsRun':False,'servicesUpdated':False,'wholeProductAccepted':False,
 'observerCorrection':'First external observer attempt cd3c9e failed on duplicated src path before creating a receipt; corrected observer 2311f6 independently rehashed successfully. Original controller result was unchanged.',
 'processNameQualification':'psutil reports blank name for PID172; final independent full Get-Process inventory resolved Secure System by OS API. No blank names or read failures were silently counted as zero.',
 'rawLogSha256':external['rawLogSha256']}
copies['summary.json']=(encode(facts),None)
copies['.gitattributes']=(b'* -text\n',None)
readme='''# Guardian full analysis — 2026-10-23 r6

Full Guardian analysis of committed source `88871eb69f16012e04ad4d8aa58209edea791e4a`
passed with **0 errors, 0 warnings, 0 infos**. Actual session35555 (7f7712 → c6f353)
exited naturally0 in60.3061589 seconds, below both outer180 and the conservative
135-second command boundary. No timeout or forced cleanup occurred; private Jobs0.

All408 source files across seven roots,70 package mappings,3536 existing cache
files (633817159 bytes) and156 candidate/runtime/historical pins matched before
and after execution. Root independently rehashed both source copies and all3536
cache files after the actual terminal return. The final full system API inventory
observed SDK0/unknown0,2GiB resource gates and owned PIDs absent before release.

The command used --no-pub --fatal-infos --fatal-warnings without file selectors.
The67 prepared browser cases in6 suites remain **UNRUN**. No browser tests,
provider/device acceptance or deployment is implied. The existing service was
not updated. Earlier Browser38 NOT_ACCEPTED and identity77/79 RED remain unchanged.

This archive preserves exact raw candidate, proposal, original static UNRUN seal,
input manifests, package maps, pre/post receipts, log, Root observers and source
snapshot metadata. Static preparation records remain verbatim. The inventory
resolves all133 historical descriptors to111 durable metadata references or22
runtime descriptor occurrences representing11 unique runtime files. Runtime
binaries/cache contents/source trees are not copied.
Archived tools retain original paths and are evidence, not a runnable relocation.

Root observer initially used an incorrect duplicate src path and failed before
writing its record; the corrected independent readback passed. A psutil blank name
for Secure System was resolved through a separate full OS API inventory. Neither
read failure was treated as a passing gate. See summary.json and raw final gate.
'''
copies['README.md']=(readme.encode(),None)
assert sum(len(value) for value,_ in copies.values())<8*1024*1024
inventory=[]
OUT.mkdir()
for target,(value,source) in sorted(copies.items()):
    path=OUT/target;path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('xb') as stream:stream.write(value)
    inventory.append({'archivePath':target,'bytes':len(value),'sha256':sha(value),'originalPath':source})
inv={'status':'RAW_METADATA_ARCHIVE_ONLY_NOT_EXECUTABLE',
 'createdAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'files':inventory,'durableHistoricalMetadataPins':history,'runtimePinDescriptorsOnly':descriptors,
 'historicalMetadataDescriptors':133,'historicalMetadataDurable':len(history),'runtimeContentsCopied':False}
with (OUT/'archive-inventory.json').open('xb') as stream:stream.write(encode(inv))
all_rows=[]
for path in sorted(OUT.rglob('*')):
    if path.is_file():
        value=path.read_bytes()
        all_rows.append({'path':path.relative_to(REPO).as_posix(),'bytes':len(value),'sha256':sha(value),
                         'gitRawBlobSha1':hashlib.sha1(b'blob '+str(len(value)).encode()+b'\0'+value).hexdigest()})
with PLAN.open('xb') as stream:
    stream.write(encode({'parent':proposal['sourceCommit'],'files':all_rows,'scope':'Exact r6 evidence only; foreign WIP excluded'}))
print(json.dumps({'status':'R6_EVIDENCE_PREPARED_NOT_COMMITTED','files':len(all_rows),
 'bytes':sum(r['bytes'] for r in all_rows),'rawCopies':sum(source is not None for _,source in copies.values()),
 'historicalDurable':len(history),'runtimeDescriptorsOnly':len(descriptors),'plan':str(PLAN)}))
