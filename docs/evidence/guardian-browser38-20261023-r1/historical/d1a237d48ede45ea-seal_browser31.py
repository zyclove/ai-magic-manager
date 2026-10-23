"""Seal only already-prepared static files; never imports candidate or starts SDK."""
from pathlib import Path
import ast
import copy
import datetime
import hashlib
import json
import os
import stat

ROOT=Path(__file__).absolute().parent
REPO=ROOT.parents[1]
TEMPLATE=REPO/'.cache/guardian-analyze-20261021-r2'
COMMIT='080e41c66a348d48d8ac313cde77e4dd8f36cc47'
BASE_SHA='0027b4f8d65b9054e273b3c98a8b62f8de963fe9b59e054bf750eaae1cc6f3c2'


def read(path):
    for item in (path,*path.parents):
        if os.path.lexists(item):
            info=item.lstat()
            assert not stat.S_ISLNK(info.st_mode) and not getattr(info,'st_file_attributes',0)&0x400
    before=path.stat()
    data=path.read_bytes()
    after=path.stat()
    assert (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)==(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns)
    return data


def pin(path,absolute=False):
    raw=read(path)
    row={'path':str(path),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
    if absolute:
        row['absolute']=True
    return row


def verify(row):
    seen=pin(Path(row['path']))
    assert seen['bytes']==row['bytes'] and seen['sha256']==row['sha256'], 'Pin drift: '+row['path']


def create(name,value):
    target=ROOT/name
    assert target.parent==ROOT
    with target.open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(value,stream,ensure_ascii=False,indent=2)
        stream.write('\n');stream.flush();os.fsync(stream.fileno())
    return pin(target)


def main():
    assert not (ROOT/'attempt').exists() and not (ROOT/'proposal.json').exists()
    template=json.loads(read(TEMPLATE/'proposal.json'))
    assert pin(TEMPLATE/'proposal.json')['sha256']=='5a321054ee020199025e7c40ab062f5577a0ecf3ade5ec899a131bacdce80490'
    inputs=json.loads(read(ROOT/'inputs.json'))
    source=json.loads(read(Path(inputs['sourceManifest']['path'])))
    preparation=json.loads(read(ROOT/'preparation-review.json'))
    fixtures=json.loads(read(ROOT/'independent-metadata-review.json'))
    contract=json.loads(read(ROOT/'expected-cases.json'))
    assert inputs['sourceCommit']==source['head']==COMMIT and source['sourceCount']==405
    assert [row['expectedVisibleCases'] for row in contract['selectedSources']]==[8,4,19]
    assert len(contract['cases'])==31 and len(contract['selectors'])==3
    assert fixtures['positiveReporterFixtures']==fixtures['positiveCacheFixtures']==1 and fixtures['negativeFixtures']>=30
    assert fixtures['candidateModulesImported'] is False and fixtures['sdkStarted'] is False
    for field in ('sourceManifest','dependencyLibraryPins','candidatePackageConfig','candidatePackageConfigTemplate','cacheManifest',
                  'browserCacheBaseManifest','chromeExecutablePin','chromeReadonlyObservation','expectedCaseContract','reporterContractCode','ownedChromeObserverCode','originalR2AnalysisInput'):
        verify(inputs[field])
    for row in inputs['controlRuntimeFiles']+inputs['extraRuntimeFiles']+preparation['originalFourFilesPreserved']:
        verify(row)
    for row in source['sourceFiles']:
        assert pin(ROOT/'src'/row['path'])['sha256']==row['sha256']
        working=read(REPO/row['path'])
        assert hashlib.sha256(working).hexdigest()==row['workingTreeRawSha256']
        assert hashlib.sha256(working.replace(b'\r\n',b'\n')).hexdigest()==row['committedLfSha256']
    helper=pin(ROOT/'heap1536_windows_job.py')
    assert helper['sha256']=='4965e39eecfe70c7eeeb7ce317c0c06f4ae484d36f025706fff3a669cec4ab12'
    parsed=[]
    for path in sorted(ROOT.glob('*.py')):
        ast.parse(read(path).decode('utf-8'),filename=str(path))
        parsed.append(pin(path))
    # Independent metadata comparison; no reporter or preparation module import.
    base=json.loads(read(Path(inputs['browserCacheBaseManifest']['path'])))
    derived=json.loads(read(Path(inputs['cacheManifest']['path'])))
    expected=copy.deepcopy(base)
    chrome=inputs['chromeExecutablePin']
    indices=[i for i,row in enumerate(base['fixedFiles']) if Path(row['path'])==Path(chrome['path'])]
    assert len(indices)==1
    row=expected['fixedFiles'][indices[0]]
    delta=chrome['bytes']-row['bytes']
    row.update(bytes=chrome['bytes'],sha256=chrome['sha256'])
    if 'expectedSha256' in row:
        row['expectedSha256']=chrome['sha256']
    expected['totals']['bytes']+=delta
    expected['status']='BROWSER_CHROME_REFRESH_FROM_FIXED_BASE_NOT_RUNTIME_VALIDATION'
    expected['browserChromeRefresh']=derived['browserChromeRefresh']
    assert derived==expected and derived['totals']['files']==3537 and len(derived['trees'])==70 and len(derived['fixedFiles'])==33
    original=json.loads(read(Path(inputs['originalPackageConfig']['path'])))
    rebased=copy.deepcopy(original)
    internal=inputs['internalPackageRoots']
    changed=0
    for row in rebased['packages']:
        if row['name'] in internal:
            row['rootUri']=(ROOT/'src'/internal[row['name']]).as_uri();changed+=1
    assert changed==7 and len(rebased['packages'])==70
    assert rebased==json.loads(read(Path(inputs['candidatePackageConfig']['path'])))
    review={'status':'STATIC_BROWSER31_SEAL_REVIEW_ONLY_RUNTIME_UNRUN','createdAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
       'sourceCommit':COMMIT,'sourceFiles':405,'sevenRootGitTrees':inputs['sevenRootGitTrees'],'astOnlyParsedFiles':parsed,
       'expectedPhysicalSuites':3,'sourceExpandedVisibleCases':[8,4,19],'expectedVisibleCases':31,'actualCasesExecuted':None,
       'full405MainAndFrozenRawHashesRechecked':True,'mainNormalizedMatchesCommitted':True,
       'packageRows':70,'internalRootUriChangesOnly':7,'externalRowsPreserved':63,
       'baseCacheManifestSha256':BASE_SHA,'chromeOnlyDerivedManifestExact':True,'originalOtherPinsPreserved':3536,
       'cacheFileHashesNotRecheckedDuringStaticReview':True,'full3537PreflightAndPostflightRequiredAtRuntime':True,
       'nativeHelperByteIdenticalToR2':True,'nativeHelperSha256':helper['sha256'],
       'fourPreExistingFilesPreserved':True,'independentSyntheticMetadataFixtures':pin(ROOT/'independent-metadata-review.json'),
       'reporterReviewEvidence':pin(ROOT/'reporter-static-review.json'),'candidateImported':False,'candidateExecuted':False,
       'sdkCalls':0,'testsRun':False,'chromeStarted':False,'networkUsed':False,'attemptExists':False,
       'runtimeWatchdogOrBrowserVerified':False,'formalExecutionAcceptanceExists':False}
    review_pin=create('static-review.json',review)
    # Candidate file list is fixed before writing the final proposal to avoid circular pins.
    files=['controller.py','worker.py','heap1536_windows_job.py','reporter_contract_reviewed.py','owned_chrome_observer.py',
           'source_name_contract.py','prepare_browser31.py','seal_browser31.py','independent_metadata_review.py',
           'reporter_contract.py','pure_metadata_review.py','README.md','mechanical-controller.py.diff','mechanical-worker.py.diff',
           'mechanical-native-helper.py.diff','mechanical-reporter.py.diff','preparation-review.json','preparation-receipt.json',
           'independent-metadata-review.json','reporter-static-review.json','static-review.json']
    proposal=copy.deepcopy(template)
    input_pin=pin(ROOT/'inputs.json')
    proposal.update(status='STATIC_BROWSER31_CANDIDATE_ONLY_ROOT_REVIEW_REQUIRED',executionApproved=False,sdkCalls=0,testsRun=False,
       phase='browser-31-guardian',phaseScope='GUARDIAN_BROWSER31',sourceCommit=COMMIT,sourceFiles=405,sevenRootGitTrees=inputs['sevenRootGitTrees'],
       analysisInputs={**input_pin,'absolute':True},outerBudgetSeconds=510,outerSoftCutoffSeconds=504,workerBudgetSeconds=495,commandCapSeconds=480,
       workingDirectory=str(ROOT/'src/apps/guardian'),attemptDirectory=str(ROOT/'attempt'),noSelectors=False,
       selectedTestFiles=contract['selectors'],expectedPhysicalSuites=3,expectedVisibleCases=31,actualCasesExecuted=None,
       cacheManifestSha256=inputs['cacheManifest']['sha256'],originalCacheBaseManifestSha256=BASE_SHA,
       cacheRefreshOnlyChromeExecutable=True,otherCacheEntriesNotRebaselined=3536,
       naturalZeroAndExactReporterRequired=True,naturalZeroAndNoIssuesLogRequired=False,
       ownedChromeActualChildArgumentsRequired=True,ownedChromeNewProfileAndLoopbackTargetRequired=True,
       chromeExecutable=chrome,entireChromeInstallationPinned=False,wholeUiOrAllBrowserFilesVerified=False,
       preparationScript=pin(ROOT/'prepare_browser31.py'),preparationRootApprovedCommit=COMMIT,
       frozenSourceSnapshotWrittenDuringPreparation=True,mainSourceWrittenDuringPreparation=False,
       candidateModulesImportedDuringPreparation=False,onlyPureMetadataAstFixtureFunctionsEvaluated=True,
       wrapperTerminalStateIndependentlyRequired=True,runtimeWatchdogVerifiedForThisCandidate=False)
    flags=['--no-version-check','--suppress-analytics','test','--no-pub','--platform=chrome','--concurrency=1','--reporter=json',*contract['selectors']]
    proposal['command']=['C:/Windows/System32/cmd.exe','/d','/v:off','/c','D:/softwares/flutter/bin/flutter.bat '+' '.join(flags)]
    proposal['candidateFiles']=[{**pin(ROOT/name),'path':name} for name in files]
    historical=[{**pin(TEMPLATE/row['path']),'absolute':True} for row in template['candidateFiles']]
    historical+=copy.deepcopy(template['historicalMetadataFiles'])
    historical+=[pin(TEMPLATE/'proposal.json',True)]
    historical+=[{**row,'absolute':True} for row in [input_pin,*[inputs[field] for field in ('sourceManifest','dependencyLibraryPins','candidatePackageConfig',
       'candidatePackageConfigTemplate','cacheManifest','expectedCaseContract','chromeReadonlyObservation')]]]
    historical += [{**row,'absolute':True} for row in inputs['launcherSourcePins']]
    proposal['historicalMetadataFiles']=historical
    proposal['allOriginal26TemplatePinsRetained']=True
    proposal['template26PinsScope']='r2 candidate8 + controlRuntime11 + historicalMetadata7; original files unchanged'
    proposal_pin=create('proposal.json',proposal)
    for row in proposal['candidateFiles']+proposal['controlRuntimeFiles']+proposal['historicalMetadataFiles']:
        path=Path(row['path']) if row.get('absolute') else ROOT/row['path']
        current=pin(path)
        assert current['bytes']==row['bytes'] and current['sha256']==row['sha256']
    assert not (ROOT/'attempt').exists()
    receipt={'status':'STATIC_BROWSER31_SEALED_FOR_ROOT_REVIEW_RUNTIME_UNRUN','proposal':proposal_pin,'inputs':input_pin,
       'sourceManifest':inputs['sourceManifest'],'cacheManifest':inputs['cacheManifest'],'expectedCaseContract':inputs['expectedCaseContract'],
       'staticReview':review_pin,'candidateFiles':len(proposal['candidateFiles']),'sdkCalls':0,'chromeStarted':False,'attemptExists':False}
    receipt_pin=create('seal-receipt.json',receipt)
    print(json.dumps({**receipt,'receipt':receipt_pin}))


if __name__=='__main__':
    main()
