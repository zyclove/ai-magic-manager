"""Prepare exact helper now; archive/plan only with Root's final descriptor file."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
PARENT='794df6d5e2267174d9b30fc4592a0026a51ba611'
PHASE=ROOT/'.cache/guardian-schedule-details-phase-commit-20261025-r1'
HELPER=ROOT/'.cache/guardian-schedule-details-exact-commit-20261025-r1.py'
ARCHIVE=ROOT/'docs/evidence/guardian-schedule-details-static-20261025'
REVIEW='docs/reviews/guardian-schedule-details-20261025.md'
SOURCES={'apps/guardian/lib/pages/console_pages.dart','apps/guardian/test/policy_details_scope_test.dart'}

def require(value,message):
    if not value:raise RuntimeError(message)

def digest(raw):return hashlib.sha256(raw).hexdigest()

def regular(path):
    require(path.resolve(strict=True)==path,'Redirected path')
    require(not any(item.is_symlink() or item.is_junction() for item in (path,*path.parents)),'Linked path')
    require(path.is_file(),'Expected regular file')
    return path.read_bytes()

def git(*args):return subprocess.check_output(['git',*args],cwd=ROOT)

def derived_helper():
    raw=regular(ROOT/'.cache/guardian-readonly-details-exact-commit-20261024-r1.py')
    require(digest(raw)=='4ecfd24ecea5687594a46a006519cd34ef674fc043841c037d6883ac16555289','Qualified parent helper drift')
    text=raw.decode('utf-8')
    changes=[
        ("PHASE = ROOT / '.cache/guardian-readonly-details-phase-commit-20261024-r1'","PHASE = ROOT / '.cache/guardian-schedule-details-phase-commit-20261025-r1'"),
        ("MESSAGE = 'fix: preserve schedule list when closing read-only details'","MESSAGE = 'fix: keep schedule details within their opening scope'"),
        ("SOURCE_PATHS = {\n    'apps/guardian/lib/ui/resource_page.dart',\n    'apps/guardian/lib/pages/console_pages.dart',\n    'apps/guardian/test/resource_page_resilience_test.dart',\n}",
         "SOURCE_PATHS = {\n    'apps/guardian/lib/pages/console_pages.dart',\n    'apps/guardian/test/policy_details_scope_test.dart',\n}"),
        ("'READY_READONLY_STATIC_STAGE_PLAN'","'READY_SCHEDULE_DETAILS_STATIC_STAGE_PLAN'"),
        ("p == 'docs/reviews/guardian-readonly-details-20261024.md' or\n            p.startswith('docs/evidence/guardian-readonly-details-static-20261024/')",
         "p == 'docs/reviews/guardian-schedule-details-20261025.md' or\n            p.startswith('docs/evidence/guardian-schedule-details-static-20261025/')"),
    ]
    for before,after in changes:
        require(text.count(before)==1,'Unexpected parent helper literal')
        text=text.replace(before,after,1)
    return text.encode('utf-8')

mode=sys.argv[1]
if mode=='helper':
    raw=derived_helper()
    with HELPER.open('xb') as stream:stream.write(raw)
    print(json.dumps({'status':'HELPER_ONLY_NO_PLAN_OR_GIT_WRITE','path':str(HELPER),'bytes':len(raw),'sha256':digest(regular(HELPER))}))
elif mode=='archive-plan':
    # Root supplies final sourcePins, evidencePins, reviewDocPin only after both authors seal.
    require(len(sys.argv)==3,'Final descriptor JSON path required')
    specification=json.loads(regular(Path(sys.argv[2]).absolute()))
    require(specification['parent']==PARENT,'Fixed parent mismatch')
    require(git('rev-parse','HEAD').decode().strip()==PARENT,'Current parent changed')
    require(git('symbolic-ref','HEAD').decode().strip()=='refs/heads/dev','Branch changed')
    require(not git('diff','--cached','--name-only','-z'),'Shared staged changes')
    require(not PHASE.exists() and not ARCHIVE.exists(),'Single-use archive/plan exists')
    require(regular(HELPER)==derived_helper(),'Derived helper changed')
    source_pins=specification['sourcePins']
    require(len(source_pins)==2 and {row['path'] for row in source_pins}==SOURCES,'Exact source pins required')
    review=specification['reviewDocPin'];require(review['path']==REVIEW,'Unexpected review document')
    require({row['path'] for row in specification['evidencePins']}=={
        '.cache/guardian-schedule-details-review-20261025-r1/review.md',
        '.cache/guardian-schedule-details-review-20261025-r1/pins.json',
        '.cache/guardian-schedule-details-test-static-20261025-r1.json'},'Exact final review/test evidence required')
    pending=[];targets=set()
    for row in specification['evidencePins']:
        source=Path(row['path']);target=Path(row['archived'])
        require(not source.is_absolute() and source.parts[:1]==('.cache',),'Task evidence path required')
        require(not target.is_absolute() and not target.drive and '..' not in target.parts and target.parts and target.as_posix()!='manifest.json','Unsafe archive target')
        require(source.suffix in {'.md','.json','.patch'} and 'credential' not in source.name.lower(),'Non-evidence input')
        require(target.as_posix() not in targets,'Duplicate evidence target');targets.add(target.as_posix())
        raw=regular(ROOT/source);require(len(raw)==row['bytes'] and digest(raw)==row['sha256'],'Final evidence pin drift')
        pending.append((source.as_posix(),target,raw))
    for name,archived in [(HELPER.name,'phase-commit-tools/exact-commit.py'),(Path(__file__).name,'phase-commit-tools/prepare.py')]:
        require(archived not in targets,'Reserved tool archive target')
        pending.append(('.cache/'+name,Path(archived),regular(ROOT/'.cache'/name)))
    for row in source_pins+[review]:
        raw=regular(ROOT/row['path']);require(len(raw)==row['bytes'] and digest(raw)==row['sha256'],'Final source/review pin drift')
    old_sources={name:git('cat-file','blob',PARENT+':'+name) for name in SOURCES}
    ARCHIVE.mkdir();copies=[]
    for source,target,raw in pending:
        destination=ARCHIVE/target;destination.parent.mkdir(parents=True,exist_ok=True)
        with destination.open('xb') as stream:stream.write(raw)
        require(regular(destination)==regular(ROOT/source)==raw,'Archive byte readback mismatch')
        copies.append({'path':target.as_posix(),'source':source,'bytes':len(raw),'sha256':digest(raw)})
    metadata={'schemaVersion':1,'status':'STATIC_ONLY_ALL_NEW_CASES_UNRUN','parent':PARENT,'files':copies,
              'testsRun':False,'sdkInvoked':False,'pushed':False,'deployed':False}
    with (ARCHIVE/'manifest.json').open('x',encoding='utf-8',newline='\n') as stream:json.dump(metadata,stream,indent=2);stream.write('\n')
    paths=sorted(SOURCES)+[REVIEW]+[path.relative_to(ROOT).as_posix() for path in sorted(ARCHIVE.rglob('*')) if path.is_file()]
    rows=[]
    for name in paths:
        raw=regular(ROOT/name);before=None
        if name in SOURCES:
            prior=old_sources[name];require(raw!=prior,'Unchanged source')
            before=hashlib.sha1(b'blob '+str(len(prior)).encode()+b'\0'+prior).hexdigest()
        else:require(not git('ls-tree',PARENT,'--',name),'Expected new evidence path')
        rows.append({'path':name,'bytes':len(raw),'sha256':digest(raw),
                     'gitRawBlobSha1':hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest(),
                     'beforeGitRawBlobSha1':before})
    plan={'status':'READY_SCHEDULE_DETAILS_STATIC_STAGE_PLAN','parent':PARENT,'branchRef':'refs/heads/dev',
          'ownLiveSdkHandle':False,'newTestsRun':False,'pushed':False,'deployed':False,'files':rows}
    PHASE.mkdir();raw=(json.dumps(plan,indent=2)+'\n').encode()
    with (PHASE/'stage-pins.json').open('xb') as stream:stream.write(raw)
    print(json.dumps({'status':'ARCHIVE_AND_PLAN_ONLY_NO_STAGE_OR_COMMIT','files':len(rows),'bytes':sum(row['bytes'] for row in rows),'planSha256':digest(raw)}))
else:raise RuntimeError('Unknown mode')
