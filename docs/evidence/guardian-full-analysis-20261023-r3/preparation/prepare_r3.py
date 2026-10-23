"""Fixed r3 preparation only. Run only after Root supplies the exact new commit.

This file does not import or execute a candidate/SDK. It extracts committed blobs,
checks Main, and mechanically rebases the already exercised r1 analysis candidate.
All generated files are CreateNew. No retry, cleanup, dependency or service action.
"""
from pathlib import Path
import argparse
import ast
import copy
import datetime
import difflib
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess

REPO = Path('D:/codes/mobile/ai-manager')
TASK = REPO / '.cache/guardian-current-20261023-r3'
CANDIDATE = REPO / '.cache/guardian-analyze-20261023-r3'
OLD_TASK = REPO / '.cache/guardian-current-20261021-r1'
OLD_CANDIDATE = REPO / '.cache/guardian-analyze-20261021-r1'
SRC = TASK / 'src'
OUT = TASK / 'out'
GIT = Path('C:/Program Files/Git/cmd/git.exe')
ROOTS = ['apps/guardian', 'packages/audit_client', 'packages/commerce_contracts',
         'packages/notification_client', 'packages/device_operations',
         'packages/usage_reporting', 'packages/usage_report_ui']
OLD_PROPOSAL_SHA = 'fb2b0960dc62bc51614926a1a6e2748999bfda5a64204ad770faf8fc8d87174a'
OLD_INPUT_SHA = 'effa9742b264f85dac08217eca4a28517ce2b8bfb9782f902c2034a0e0e94cf9'
CACHE_SHA = '0027b4f8d65b9054e273b3c98a8b62f8de963fe9b59e054bf750eaae1cc6f3c2'
CONTROLLER_SHA = '9baa2f090040bcedb721bb344c7c12a1940bfc278d55361ff4c7f4711107b3ee'
WORKER_SHA = '72aa7b1ad0bb1be971b801ad7184b8ab06ac33ad3e7e1e912b3a25b9c098b34c'
HELPER_SHA = '4965e39eecfe70c7eeeb7ce317c0c06f4ae484d36f025706fff3a669cec4ab12'


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def safe(path):
    for part in (path, *path.parents):
        if not os.path.lexists(part):
            continue
        info = part.lstat()
        assert not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400, 'Linked path refused'
    return path


def read(path):
    safe(path)
    before = path.stat()
    assert stat.S_ISREG(before.st_mode), 'Expected regular input'
    raw = path.read_bytes()
    after = path.stat()
    assert (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns) == (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns)
    assert len(raw) == before.st_size
    return raw


def pin(path, absolute=False):
    raw = read(path)
    row = {'path':str(path),'bytes':len(raw),'sha256':sha(raw)}
    if absolute:
        row['absolute'] = True
    return row


def verify(row):
    actual = pin(Path(row['path']))
    assert actual['bytes'] == row['bytes'] and actual['sha256'] == row['sha256'], 'Pinned metadata/runtime changed: ' + row['path']


def create(path, raw):
    assert path.is_relative_to(TASK) or path.is_relative_to(CANDIDATE), 'Preparation output outside two fixed task directories'
    safe(path.parent)
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('xb') as output:
        output.write(raw)
        output.flush()
        os.fsync(output.fileno())
    assert read(path) == raw
    return pin(path)


def write_json(path, value):
    return create(path,(json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode('utf-8'))


def main():
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument('--commit',required=True,help='Full 40-hex commit explicitly supplied by Root after its phase commit')
    arguments.add_argument('--approved-script-sha256',required=True,help='Exact Root-reviewed preparation script digest')
    args = arguments.parse_args()
    assert re.fullmatch('[0-9a-f]{40}',args.commit), 'Exact full commit required'
    assert re.fullmatch('[0-9a-f]{64}',args.approved_script_sha256)
    assert sha(read(Path(__file__))) == args.approved_script_sha256, 'Preparation script differs from Root-reviewed bytes'
    assert args.commit == '080e41c66a348d48d8ac313cde77e4dd8f36cc47', 'r3 requires the exact Root-supplied new phase commit'
    assert all(not path.exists() for path in (SRC,OUT,TASK/'generated')), 'Existing preparation outputs preserved; no reuse'
    assert {path.name for path in TASK.iterdir()} <= {'prepare_r3.py','PREPARATION_NOT_RUN.md'}, 'Unknown active task input preserved'
    if CANDIDATE.exists():
        assert {path.name for path in CANDIDATE.iterdir()} <= {'PREPARATION_NOT_RUN.md'}, 'Existing candidate preserved; no reuse'
    assert shutil.disk_usage(REPO).free >= 2**31, 'At least 2GiB repository drive space required'

    old_proposal_raw = read(OLD_CANDIDATE/'proposal.json')
    old_input_raw = read(OLD_TASK/'out/analysis-inputs-root.json')
    assert sha(old_proposal_raw) == OLD_PROPOSAL_SHA and sha(old_input_raw) == OLD_INPUT_SHA
    old_proposal = json.loads(old_proposal_raw)
    old_input = json.loads(old_input_raw)
    for row in old_proposal['candidateFiles']:
        raw = read(OLD_CANDIDATE/row['path'])
        assert len(raw) == row['bytes'] and sha(raw) == row['sha256'], 'Historical candidate changed'
    for row in old_input['controlRuntimeFiles'] + old_input['extraRuntimeFiles']:
        verify(row)
    assert old_input['gitExecutable'] == str(GIT)
    assert old_input['cacheManifest']['sha256'] == CACHE_SHA
    verify(old_input['cacheManifest'])
    verify(old_input['originalPackageConfig'])
    verify(old_input['dependencyLibraryPins'])
    cache = json.loads(read(Path(old_input['cacheManifest']['path'])))
    assert cache['fullAllowlistCollected'] is True and cache['totals']['files'] == 3537
    assert len(cache['trees']) == 70 and len(cache['fixedFiles']) == 33

    # This is a phase projection of the historical content manifest, not a new
    # cache collection. The excluded Chrome executable is not used by analyze.
    chrome_path = 'C:/Program Files/Google/Chrome/Application/chrome.exe'
    def normalized_path(value):
        return value.replace(chr(92), '/').casefold()
    excluded = [row for row in cache['fixedFiles']
                if normalized_path(row['path']) == normalized_path(chrome_path)]
    assert len(excluded) == 1
    assert excluded[0]['bytes'] == 4600472 and excluded[0]['sha256'] == '36a30716f0994b377f1ce6b47cfe35399b9719e31d597fe0ea0d8f3b62aed532'
    projection = {
        'status': 'READ_ONLY_ANALYSIS_CACHE_PROJECTION_NOT_SDK_VALIDATION',
        'phase': 'analyze-all-guardian',
        'parentManifest': old_input['cacheManifest'],
        'excludedFixedFiles': excluded,
        'exclusionReason': 'The fixed Flutter analyze command does not consume Chrome. A browser test phase must independently pin its current browser executable.',
        'trees': copy.deepcopy(cache['trees']),
        'fixedFiles': [copy.deepcopy(row) for row in cache['fixedFiles'] if row not in excluded],
        'totals': {'files': cache['totals']['files'] - 1,
                   'bytes': cache['totals']['bytes'] - excluded[0]['bytes']},
        'allRemainingParentRowsPreserved': True,
        'cacheContentsRehashedDuringProjection': False,
        'sdkStarted': False, 'pubRun': False, 'browserStarted': False,
        'cacheCopied': False, 'entireSdkOrBrowserInstallationPinned': False}
    assert projection['trees'] == cache['trees'] and len(projection['fixedFiles']) == 32
    assert projection['totals'] == {'files': 3536, 'bytes': 633817159}
    # Hold projected bytes until source inventory passes; preparation is single-use.

    environment = os.environ.copy()
    environment.update(GIT_OPTIONAL_LOCKS='0',GIT_TERMINAL_PROMPT='0',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='NUL')
    def git(*argv,input=None,timeout=10):
        return subprocess.run([str(GIT),'-c','safe.directory='+REPO.as_posix(),
            '-c','core.fsmonitor=false','-c','core.untrackedCache=false',*argv],
            cwd=REPO,env=environment,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            check=True,timeout=timeout,creationflags=subprocess.CREATE_NO_WINDOW).stdout
    assert git('rev-parse','--verify',args.commit+'^{commit}').decode().strip() == args.commit
    git('merge-base','--is-ancestor',args.commit,'HEAD')
    trees = dict(zip(ROOTS,git('rev-parse',*[args.commit+':'+root for root in ROOTS]).decode().splitlines()))
    assert len(trees) == 7
    def current_trees():
        return dict(zip(ROOTS,git('rev-parse',*['HEAD:'+root for root in ROOTS]).decode().splitlines()))
    assert current_trees() == trees, 'Current HEAD source roots differ from supplied commit'

    entries=[]
    for raw in git('ls-tree','-rz',args.commit,'--',*ROOTS).split(b'\0'):
        if not raw:
            continue
        header,path = raw.split(b'\t',1)
        mode,kind,oid = header.decode('ascii').split()
        relative = path.decode('utf-8')
        parts = Path(relative).parts
        assert kind == 'blob' and mode in ('100644','100755'), 'Linked/submodule source refused'
        assert not Path(relative).is_absolute() and '..' not in parts and ':' not in relative
        assert not any(part == '.local' or part.startswith('.env') for part in parts), 'Private source refused'
        entries.append({'path':relative,'gitBlob':oid,'mode':mode})
    assert entries and len({row['path'] for row in entries}) == len(entries)
    count = len(entries)
    assert count == 405, 'Expected complete new 405-file source boundary'
    excluded_dirs = set(old_input['generatedExclusions']['directories'])
    excluded_files = set(old_input['generatedExclusions']['files'])
    expected = {row['path'] for row in entries}
    def membership(base):
        seen=set()
        def fail(error):
            raise error
        for root in ROOTS:
            for directory,folders,names in os.walk(safe(base/root),followlinks=False,onerror=fail):
                folders[:] = [name for name in folders if name not in excluded_dirs]
                for name in folders:
                    safe(Path(directory)/name)
                for name in names:
                    if name not in excluded_files:
                        path=safe(Path(directory)/name)
                        assert path.is_file()
                        seen.add(path.relative_to(base).as_posix())
        assert seen == expected, ('Complete source membership mismatch',sorted(seen-expected),sorted(expected-seen))
        return {'files':len(seen),'fullMembershipExact':True}
    main_membership = membership(REPO)
    batch = git('cat-file','--batch',input=''.join(row['gitBlob']+'\n' for row in entries).encode('ascii'),timeout=30)
    stream=io.BytesIO(batch)
    frozen=[]
    tests=[]
    for row in entries:
        oid,kind,size = stream.readline().decode('ascii').split()
        raw = stream.read(int(size))
        assert oid == row['gitBlob'] and kind == 'blob' and len(raw) == int(size) and stream.read(1) == b'\n'
        working = read(REPO/row['path'])
        row.update(bytes=len(raw),sha256=sha(raw),committedLfSha256=sha(raw.replace(b'\r\n',b'\n')),
                   workingTreeRawSha256=sha(working),workingTreeLfSha256=sha(working.replace(b'\r\n',b'\n')))
        assert row['committedLfSha256'] == row['workingTreeLfSha256'], 'Main semantic drift: ' + row['path']
        frozen.append((row['path'],raw))
        if '/test/' in row['path'] and row['path'].endswith('_test.dart'):
            text=raw.decode('utf-8')
            annotation=re.search(r'@TestOn\(([^)]*)\)',text)
            tests.append({'path':row['path'],'platform':'browser' if annotation and 'browser' in annotation.group(1) else 'vm-default',
                          'annotation':annotation.group(1) if annotation else None,
                          'staticDeclarations':len(re.findall(r'(?m)^\s*(?:test|testWidgets)\s*\(',text)),
                          'importsDartIo':bool(re.search(r"(?:import|export) ['\"]dart:io",text))})
    assert stream.read() == b''
    assert current_trees() == trees
    for row in entries:
        assert sha(read(REPO/row['path'])) == row['workingTreeRawSha256'], 'Main changed during inventory'
    assert membership(REPO) == main_membership

    # All source reads and ownership checks above finish before any snapshot write.
    for relative,raw in frozen:
        create(SRC/relative,raw)
    canonical=''.join(f"{row['path']}\0{row['bytes']}\0{row['sha256']}\n" for row in entries)
    source_manifest={'status':'STATIC_COMMITTED_SOURCE_SNAPSHOT_RUNTIME_UNRUN','head':args.commit,'roots':ROOTS,
       'sourceFiles':entries,'sourceCount':count,'sourceBytes':sum(row['bytes'] for row in entries),
       'sourceTreeSha256':sha(canonical.encode()),
       'workingTreeRawDifferences':[row['path'] for row in entries if row['sha256'] != row['workingTreeRawSha256']],
       'workingTreeSemanticDifferencesAfterCrLfNormalization':[]}
    source_pin=write_json(OUT/'source-manifest.json',source_manifest)
    scope={'status':'STATIC_DECLARATIONS_NOT_RUNTIME_DISCOVERY','testFiles':tests,'projects':[]}
    for root in ROOTS:
        rows=[row for row in tests if row['path'].startswith(root+'/')]
        scope['projects'].append({'root':root,'testFiles':len(rows),
            'vmDefaultFiles':sum(row['platform']=='vm-default' for row in rows),
            'browserFiles':sum(row['platform']=='browser' for row in rows),
            'staticDeclarations':sum(row['staticDeclarations'] for row in rows)})
    scope_pin=write_json(OUT/'test-scope.json',scope)
    seed=json.loads(read(Path(old_input['dependencyLibraryPins']['path'])))
    internal=old_input['internalPackageRoots']
    assert len(internal) == 7 and set(internal.values()) == set(ROOTS)
    updated=0
    for row in seed['packageMappings']:
        if row['name'] in internal:
            assert row['category'] == 'current-committed-repository-input'
            assert row['proposedCandidateRootUri'] == (OLD_TASK/'src'/internal[row['name']]).as_uri()
            row['proposedCandidateRootUri']=(SRC/internal[row['name']]).as_uri()
            updated+=1
    assert updated == 7 and len(seed['packageMappings']) == 70
    seed_pin=write_json(OUT/'dependency-library-pins.json',seed)
    original=json.loads(read(Path(old_input['originalPackageConfig']['path'])))
    config=copy.deepcopy(original)
    assert len(config['packages']) == 70 and len({row['name'] for row in config['packages']}) == 70
    for row in config['packages']:
        if row['name'] in internal:
            row['rootUri']=(SRC/internal[row['name']]).as_uri()
    config_pin=write_json(SRC/'apps/guardian/.dart_tool/package_config.json',config)
    template_pin=write_json(TASK/'generated/guardian-package_config.json',config)
    assert config_pin['sha256'] == template_pin['sha256']
    frozen_membership=membership(SRC)
    projection_pin=write_json(OUT/'cache-analysis-projection.json',projection)
    inputs=copy.deepcopy(old_input)
    inputs.update(createdAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(),sourceCommit=args.commit,
        sourceTreeSha256=source_manifest['sourceTreeSha256'],sourceManifest=source_pin,
        dependencyLibraryPins=seed_pin,candidatePackageConfig=config_pin,candidatePackageConfigTemplate=template_pin,
        sevenRootGitTrees=trees,cacheManifest=projection_pin,
        cacheProjectionParentManifest=old_input['cacheManifest'],
        sourceMembershipCheck={'frozen':frozen_membership,'main':main_membership})
    input_pin=write_json(OUT/'analysis-inputs-root.json',inputs)

    controller=read(OLD_CANDIDATE/'controller.py')
    worker=read(OLD_CANDIDATE/'worker.py')
    helper=read(OLD_CANDIDATE/'heap1536_windows_job.py')
    assert sha(controller) == CONTROLLER_SHA and sha(worker) == WORKER_SHA and sha(helper) == HELPER_SHA
    worker_text=worker.decode('utf-8')
    assert worker_text.count('guardian-current-20261021-r1') == 1
    assert worker_text.count(OLD_INPUT_SHA) == 1 and worker_text.count('403') == 4
    worker_text=worker_text.replace('guardian-current-20261021-r1','guardian-current-20261023-r3').replace(OLD_INPUT_SHA,input_pin['sha256']).replace('403',str(count))
    # Full runtime hashing still validates every retained parent entry pre/post.
    old_cache_gate = """    require(cache['status'] == 'READ_ONLY_CONTENT_COLLECTION_COMPLETE_NOT_SDK_VALIDATION'
            and cache['fullAllowlistCollected'] and len(cache['trees']) == 70
            and len(cache['fixedFiles']) == 33 and cache['totals']['files'] == 3537,
            'Complete collected cache boundary changed')
"""
    new_cache_gate = """    parent = load_pin(inputs['cacheProjectionParentManifest'])
    require(inputs['cacheProjectionParentManifest']['sha256'] == '0027b4f8d65b9054e273b3c98a8b62f8de963fe9b59e054bf750eaae1cc6f3c2'
            and parent['status'] == 'READ_ONLY_CONTENT_COLLECTION_COMPLETE_NOT_SDK_VALIDATION'
            and parent['fullAllowlistCollected'] and len(parent['trees']) == 70
            and len(parent['fixedFiles']) == 33 and parent['totals'] == {'files': 3537, 'bytes': 638417631},
            'Historical parent cache manifest changed')
    excluded = [row for row in parent['fixedFiles']
                if row['path'].replace(chr(92), '/').casefold()
                == 'c:/program files/google/chrome/application/chrome.exe']
    require(len(excluded) == 1 and excluded[0]['bytes'] == 4600472
            and excluded[0]['sha256'] == '36a30716f0994b377f1ce6b47cfe35399b9719e31d597fe0ea0d8f3b62aed532',
            'Only the known analysis-unused Chrome row may be excluded')
    require(cache == {
        'status': 'READ_ONLY_ANALYSIS_CACHE_PROJECTION_NOT_SDK_VALIDATION',
        'phase': 'analyze-all-guardian',
        'parentManifest': inputs['cacheProjectionParentManifest'],
        'excludedFixedFiles': excluded,
        'exclusionReason': 'The fixed Flutter analyze command does not consume Chrome. A browser test phase must independently pin its current browser executable.',
        'trees': parent['trees'],
        'fixedFiles': [row for row in parent['fixedFiles'] if row not in excluded],
        'totals': {'files': 3536, 'bytes': 633817159},
        'allRemainingParentRowsPreserved': True,
        'cacheContentsRehashedDuringProjection': False,
        'sdkStarted': False, 'pubRun': False, 'browserStarted': False,
        'cacheCopied': False, 'entireSdkOrBrowserInstallationPinned': False},
        'Complete analysis-only projection must preserve every remaining parent row')
"""
    assert worker_text.count(old_cache_gate) == 1
    assert worker_text.count("'fixedFiles': 33") == 1
    worker_text=worker_text.replace(old_cache_gate,new_cache_gate).replace("'fixedFiles': 33", "'fixedFiles': 32")
    worker2=worker_text.encode('utf-8')
    for name,raw in [('controller.py',controller),('worker.py',worker2),('heap1536_windows_job.py',helper)]:
        ast.parse(raw.decode('utf-8'),filename=name)
        create(CANDIDATE/name,raw)
    readme=read(OLD_CANDIDATE/'README.md').decode('utf-8').replace(OLD_INPUT_SHA,input_pin['sha256']).replace('guardian-current-20261021-r1','guardian-current-20261023-r3').replace('403-file',str(count)+'-file')
    readme=readme.replace('all 70 cache trees and 33 fixed runtime files (3,537 files)', 'all 70 cache trees and 32 fixed runtime files (3,536 files) in the exact analysis-only parent projection')
    readme+='\nThis r3 candidate is mechanically rebased from the actual r1 analysis candidate (session 63918, natural exit 1, 17 analyzer infos). That historical result did not accept the baseline and does not validate this new commit. The r3 controller and native helper are byte-identical to r1; the worker frozen-source directory, Root input digest, source count and analysis-only cache projection checks changed. The projection preserves 70 complete parent trees and 32 fixed rows (3536 files); only unused Chrome is excluded. Full runtime preflight and postflight still hash all 3536 files. The historical parent is preserved, not recollected.\n'
    create(CANDIDATE/'README.md',readme.encode('utf-8'))
    schema=json.loads(read(OLD_CANDIDATE/'expected-root-input-schema.json'))
    schema['fixedInputPath']=str(OUT/'analysis-inputs-root.json')
    schema['fields']['sourceManifest']=schema['fields']['sourceManifest'].replace('403',str(count))
    schema['fields']['cacheManifest']='pin row for cache-analysis-projection.json; exact historical parent minus only analysis-unused Chrome row'
    schema['fields']['cacheProjectionParentManifest']='pin row for unchanged complete parent manifest 0027b4f8d65b9054e273b3c98a8b62f8de963fe9b59e054bf750eaae1cc6f3c2; metadata read only'
    write_json(CANDIDATE/'expected-root-input-schema.json',schema)
    create(CANDIDATE/'mechanical-controller.py.diff',b'')
    diff=''.join(difflib.unified_diff(worker.decode('utf-8').splitlines(keepends=True),worker_text.splitlines(keepends=True),fromfile='r1/worker.py',tofile='r3/worker.py'))
    create(CANDIDATE/'mechanical-worker.py.diff',diff.encode('utf-8'))
    review={'status':'STATIC_PREPARATION_ONLY_R3_ANALYSIS_UNRUN','candidateImported':False,'candidateExecuted':False,
       'sdkCalls':0,'testsRun':False,'pubRun':False,'gitReadOnlyUsedForCommittedExtraction':True,
       'sourceCommit':args.commit,'sourceFiles':count,'sevenRootGitTrees':trees,
       'mainRawHashesRecorded':True,'mainCrLfNormalizedMatchesCommitted':True,'completeMainAndFrozenMembershipExact':True,
       'controllerByteIdenticalToR1':True,'controllerTemplateSha256':CONTROLLER_SHA,
       'nativeHelperByteIdenticalToR1':True,'nativeHelperSha256':HELPER_SHA,
       'workerChangesOnly':['frozen directory r1 to r3','Root input SHA','actual complete source count','phase cache exact parent projection validation excluding only unused Chrome'],
       'rootInputPin':input_pin,'packageRows':70,'rebasedInternalRows':7,'unchangedExternalRowsAndMetadata':63,
       'dependencySeedChangeOnlySevenProposedCandidateRootUris':True,'parentCacheManifestSha256':CACHE_SHA,'cacheProjection':projection_pin,
       'cacheTrees':70,'fixedRuntimeFiles':32,'cacheFiles':3536,'excludedFixedFiles':excluded,'cacheContentsNotRehashedDuringPreparation':True,
       'fullCacheContentsStillRequiredPreAndPostRuntime':True,'outerBudgetSeconds':210,'workerBudgetSeconds':195,
       'commandCapSeconds':180,'cleanupReserveSeconds':5,'postflightReserveSeconds':25,
       'astParsedOnly':['controller.py','worker.py','heap1536_windows_job.py'],
       'noCandidateOrSdkInvoked':True,'frozenSourceSnapshotWrittenDuringPreparation':True,'mainSourceWritten':False,
       'currentBranchOrIndexWritten':False,'runtimeWatchdogVerifiedForThisCandidate':False}
    write_json(CANDIDATE/'static-review.json',review)
    proposal=copy.deepcopy(old_proposal)
    proposal.update(sourceCommit=args.commit,sourceFiles=count,sevenRootGitTrees=trees,
       analysisInputs={**input_pin,'absolute':True},workingDirectory=str(SRC/'apps/guardian'),
       attemptDirectory=str(CANDIDATE/'attempt'),cacheManifestSha256=projection_pin['sha256'],
       parentCacheManifestSha256=CACHE_SHA,cacheTrees=70,fixedRuntimeFiles=32,cacheFiles=3536,
       cacheProjectionExclusion='only analysis-unused Chrome executable; all other parent row data unchanged')
    proposal['candidateFiles']=[]
    for row in old_proposal['candidateFiles']:
        observed=pin(CANDIDATE/row['path'])
        observed['path']=row['path']
        proposal['candidateFiles'].append(observed)
    proposal['historicalMetadataFiles']=[{**row,'absolute':True} for row in
        (input_pin,source_pin,seed_pin,old_input['cacheManifest'],projection_pin,old_input['originalPackageConfig'],config_pin,template_pin)]
    proposal.pop('sourceAndMainWrittenDuringPreparation',None)
    proposal.update(frozenSourceSnapshotWrittenDuringPreparation=True,mainSourceWrittenDuringPreparation=False,
                    preparationScript=pin(Path(__file__)),preparationRootApprovedCommit=args.commit)
    proposal_pin=write_json(CANDIDATE/'proposal.json',proposal)
    assert current_trees() == trees
    assert membership(REPO) == main_membership and membership(SRC) == frozen_membership
    for row in entries:
        assert sha(read(REPO/row['path'])) == row['workingTreeRawSha256']
        assert sha(read(SRC/row['path'])) == row['sha256']
    for row in proposal['candidateFiles']:
        raw=read(CANDIDATE/row['path'])
        assert len(raw) == row['bytes'] and sha(raw) == row['sha256']
    for row in proposal['controlRuntimeFiles']+proposal['historicalMetadataFiles']:
        verify(row)
    final={'status':'PREPARED_STATIC_CANDIDATE_ONLY_ROOT_REVIEW_REQUIRED','sourceCommit':args.commit,
      'sourceFiles':count,'sourceManifest':source_pin,'testScope':scope_pin,'input':input_pin,'proposal':proposal_pin,
      'controllerSha256':CONTROLLER_SHA,'workerSha256':sha(worker2),'helperSha256':HELPER_SHA,
      'sdkStarted':False,'analysisRun':False,'testsRun':False,'pubRun':False,'mainChanged':False,
      'runtimeAttemptExists':(CANDIDATE/'attempt').exists()}
    write_json(OUT/'preparation-result.json',final)
    print(json.dumps(final))


if __name__ == '__main__':
    main()
