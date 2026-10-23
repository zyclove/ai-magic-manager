"""Independent failed-attempt byte readback; no candidate imports or SDK calls."""
from pathlib import Path
import datetime
import hashlib
import io
import json
import os
import stat
import subprocess

ROOT = Path('D:/codes/mobile/ai-manager')
OUT = Path(__file__).absolute().parent
CANDIDATE = ROOT / '.cache/guardian-analyze-20261023-r9'
FROZEN = ROOT / '.cache/guardian-current-20261023-r3-a2b5'
errors = []
reads = {}

def read(path):
    path = Path(path)
    for item in (path, *path.parents):
        if item.exists():
            info = item.lstat()
            if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
                raise ValueError('Reparse path: '+str(item))
    before = path.stat()
    if not stat.S_ISREG(before.st_mode):
        raise ValueError('Not regular file: '+str(path))
    data = path.read_bytes()
    after = path.stat()
    if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns) != (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns):
        raise ValueError('File changed while reading: '+str(path))
    return data

def pin(path):
    data = read(path)
    return {'path':str(path),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}

def load(path):
    return json.loads(read(path).decode('utf-8'))

def verify(row, base):
    path = Path(row['path'])
    if not path.is_absolute():
        path = base / path
    key = str(path.absolute()).casefold()
    if key not in reads:
        try:
            reads[key] = pin(path)
        except Exception as error:
            errors.append({'path':str(path),'error':type(error).__name__+': '+str(error)})
            return False
    actual = reads[key]
    if (actual['bytes'],actual['sha256']) != (row['bytes'],row['sha256']):
        errors.append({'path':str(path),'expected':row,'actual':actual})
        return False
    return True

proposal_pin = pin(CANDIDATE/'proposal.json')
seal_pin = pin(CANDIDATE/'seal-receipt.json')
assert proposal_pin['sha256'] == '8f106238ac96a77822fba2bdb596aba33aa27878ffc19a6e0ddd566ed863eecf'
assert seal_pin['sha256'] == '886d66b7223733f73b08713c497562274f8b82e2ca33f45b5a82034cfbadd79f'
proposal = load(CANDIDATE/'proposal.json')
groups = {name:proposal[name] for name in ('candidateFiles','controlRuntimeFiles','historicalMetadataFiles')}
assert [len(rows) for rows in groups.values()] == [12,11,306]
pin_results = {name:{'descriptors':len(rows),'matched':sum(verify(row,CANDIDATE) for row in rows)} for name,rows in groups.items()}
print(json.dumps({'checkpoint':'329_PROPOSAL_PINS_READ','groups':pin_results,'errors':errors}),flush=True)

source_seal_pin = pin(FROZEN/'out/seal-static-source.json')
assert source_seal_pin['sha256'] == '869a6c582e6de734a2d6b0220e00a09d8264aef7055c1ba4145e9c63ccb22adb'
source_seal = load(FROZEN/'out/seal-static-source.json')
assert len(source_seal['files']) == source_seal['fileCount'] == 423
snapshot_match = sum(verify(row,FROZEN) for row in source_seal['files'])
source = load(FROZEN/'out/source-manifest.json')
inputs = load(CANDIDATE/'inputs.json')
assert len(source['sourceFiles']) == source['sourceCount'] == 409
main_match = sum(verify({'path':row['path'],'bytes':row['workingTreeRawBytes'],'sha256':row['workingTreeRawSha256']},ROOT) for row in source['sourceFiles'])
expected = {row['path'] for row in source['sourceFiles']}
memberships = {}
for label,base in (('main',ROOT),('frozen',FROZEN/'src')):
    found = set()
    for source_root in source['roots']:
        for directory,folders,names in os.walk(base/source_root,followlinks=False,onerror=lambda e: (_ for _ in ()).throw(e)):
            folders[:] = [name for name in folders if name not in inputs['generatedExclusions']['directories']]
            for name in folders:
                item = Path(directory)/name
                info = item.lstat()
                assert not stat.S_ISLNK(info.st_mode) and not getattr(info,'st_file_attributes',0) & 0x400
            for name in names:
                if name not in inputs['generatedExclusions']['files']:
                    found.add((Path(directory)/name).relative_to(base).as_posix())
    memberships[label] = {'files':len(found),'exact':found==expected,'extra':sorted(found-expected),'missing':sorted(expected-found)}
    if found != expected:
        errors.append({'membership':label,'details':memberships[label]})
print(json.dumps({'checkpoint':'SOURCE_RAW_AND_MEMBERSHIP_READ','snapshot423Matched':snapshot_match,'main409Matched':main_match,'membership':memberships,'errors':errors}),flush=True)

env = os.environ.copy()
env.update(GIT_OPTIONAL_LOCKS='0',GIT_TERMINAL_PROMPT='0',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='NUL')
def git(*args, input=None):
    return subprocess.run([inputs['gitExecutable'],'-c','safe.directory='+ROOT.as_posix(),'-c','core.fsmonitor=false','-c','core.untrackedCache=false',*args],cwd=ROOT,env=env,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True,timeout=30,creationflags=subprocess.CREATE_NO_WINDOW).stdout

head_and_trees = git('rev-parse','HEAD',*['HEAD:'+root for root in source['roots']]).decode('ascii').splitlines()
assert len(head_and_trees) == 8
trees = dict(zip(source['roots'],head_and_trees[1:]))
if trees != source['sevenRootGitTrees']:
    errors.append({'gitTrees':trees,'expected':source['sevenRootGitTrees']})
git_rows = []
for item in git('ls-tree','-rz','HEAD','--',*source['roots']).split(b'\0'):
    if item:
        header,path = item.split(b'\t',1)
        mode,kind,oid = header.decode('ascii').split()
        assert kind == 'blob'
        git_rows.append({'path':path.decode('utf-8'),'mode':mode,'gitBlob':oid})
manifest_identity = [{k:row[k] for k in ('path','mode','gitBlob')} for row in source['sourceFiles']]
if git_rows != manifest_identity:
    errors.append({'gitIdentity':'Full409 membership/mode/blob mismatch'})
batch = io.BytesIO(git('cat-file','--batch',input=''.join(row['gitBlob']+'\n' for row in git_rows).encode('ascii')))
git_blob_matched = 0
manifest_by_path = {row['path']:row for row in source['sourceFiles']}
for row in git_rows:
    oid,kind,size = batch.readline().decode('ascii').split()
    data = batch.read(int(size))
    assert batch.read(1) == b'\n' and kind == 'blob'
    expected_row = manifest_by_path[row['path']]
    blob_sha = hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    if (oid,blob_sha,len(data),hashlib.sha256(data).hexdigest()) == (row['gitBlob'],row['gitBlob'],expected_row['bytes'],expected_row['sha256']):
        git_blob_matched += 1
    else:
        errors.append({'gitRawBlob':row['path']})
assert not batch.read()

attempt = CANDIDATE/'attempt'
attempt_names = sorted(path.relative_to(attempt).as_posix() for path in attempt.rglob('*') if path.is_file())
result = load(attempt/'result.json')
assert result['status'] == 'NOT_ACCEPTED' and result['errorType'] == 'TimeoutExpired'
assert result['ownedJobActiveProcessesFinal'] == 0
absent = [name for name in ['receipt.json','launch.json','initial-gate.json','launch-gate.json','preflight-pins.json','postflight-pins.json','postflight-gate.json','out/analyze.log'] if not (attempt/name).exists()]
readback = {'status':'FAILED_R9_POST_BYTES_READBACK_NOT_ACCEPTED_NO_RUNTIME_ACCEPTANCE','atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'actualSessionContextFromRoot':58699,'initialChunkContextFromRoot':'f8c394','finalChunkContextFromRoot':'720805','naturalOuterExitContextFromRoot':1,'actualResult':result,'actualResultPin':pin(attempt/'result.json'),'proposalPin':proposal_pin,'candidateSealPin':seal_pin,'proposalPinGroups':pin_results,'proposalDescriptors':329,'uniqueReadPathsAcrossPinsAndSources':len(reads),'sourceSnapshotSealPin':source_seal_pin,'sourceSealDescriptors':423,'sourceSealMatched':snapshot_match,'mainRaw409Matched':main_match,'sourceMembership':memberships,'currentHead':head_and_trees[0],'sevenRootGitTreesMatch':trees==source['sevenRootGitTrees'],'gitMembershipModeAndBlobIdentityMatch':git_rows==manifest_identity,'gitRawBlobsMatched':git_blob_matched,'attemptFiles':attempt_names,'absentWorkerArtifacts':absent,'workerConsoleBytes':len(read(attempt/'worker-console.log')),'workerPreflightOrLaunchRecorded':False,'sdkAnalysisStartedOrCompleted':'NOT_EVIDENCED; no worker preflight, launch, receipt or analyze log exists','cache3536FullContentReadbackPerformed':False,'cacheReason':'No worker preflight/command/cache check is recorded; no six-hundred-MB cache read was required or performed. This is not pre/post verification.','osProcessInventoryOrFormalReleasePerformed':False,'formalReleaseMustComeFromRoot':True,'sourceOrPinsDrift':bool(errors),'errors':errors,'actions':{'candidateImport':False,'sdkOrTestsOrFormatterOrCompiler':False,'processApiOrControl':False,'network':False,'gitWrites':False,'mainWrites':False}}
path = OUT/'readback.json'
with path.open('x',encoding='utf-8',newline='\n') as stream:
    json.dump(readback,stream,ensure_ascii=False,indent=2);stream.write('\n')
md = f'''# r9 failed-attempt post readback\n\nResult remains **NOT_ACCEPTED**. Root actual session58699 f8c394→720805 natural1 is supplied context; the raw candidate result reports TimeoutExpired and314.11633989999973s, exceeding its180s outer budget, with ownedJobActiveProcessesFinal0. That Job0 field is preserved evidence, not this reader's process observation.\n\n- Proposal329 descriptors: {sum(row['matched'] for row in pin_results.values())} matched (12candidate+11runtime+306history), including external runtime file hashes. No pin drift detected: {not bool(errors)}.\n- Source seal423 descriptors matched:{snapshot_match}; Main409 raw matched:{main_match}; Git raw409 blobs matched:{git_blob_matched}. Full Main/frozen409 membership,7trees and mode/blob identity match:{trees==source['sevenRootGitTrees'] and git_rows==manifest_identity}. Current HEAD:{head_and_trees[0]}.\n- Attempt contains only request.json, result.json and empty worker-console.log. No worker preflight, launch, receipt, postflight or analysis log exists. No successful analysis or complete source/cache/runtime pre/post can be claimed.\n- No full3536 cache-content readback was performed because no worker preflight/command/cache check is recorded. This report hashes requested metadata/runtime pins and source bytes only; it does not invent missing preflight evidence.\n- OS inventory, retained-process closure and formal shared-window release remain Root steps. No SDK/process API/network/control/candidate import/Main/Git mutation was performed. Original attempt and sealed artifacts were read only.\n'''
with (OUT/'readback.md').open('x',encoding='utf-8',newline='\n') as stream:stream.write(md)
report_pins = [pin(OUT/name) for name in ['readback.py','readback.json','readback.md']]
with (OUT/'report-pins.json').open('x',encoding='utf-8',newline='\n') as stream:
    json.dump(report_pins,stream,indent=2);stream.write('\n')
print(json.dumps({'checkpoint':'READBACK_COMPLETE','sourceOrPinsDrift':bool(errors),'errors':errors,'reportPins':report_pins,'reportPinFile':pin(OUT/'report-pins.json')}),flush=True)
