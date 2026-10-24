"""Exact raw QA commit: private index, shared-index lock, explicit parent ref CAS."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PHASE = ROOT / '.cache/guardian-qa-phase-commit-20261024-r2'
PLAN = PHASE / 'stage-pins.json'
INDEX, PRIVATE, LOCK = ROOT / '.git/index', PHASE / 'private.index', ROOT / '.git/index.lock'
MESSAGE = 'test: correct schedule retry button lookup and record validation'

def require(ok, reason):
    if not ok:
        raise RuntimeError(reason)

require(sys.flags.optimize == 0, 'Optimized invocation forbidden')
mode = sys.argv[1]
require(mode in {'stage', 'commit', 'readback'}, 'Unknown mode')
plan = json.loads(PLAN.read_bytes())
require(plan['status'] == 'READY_QA_STAGE_PLAN' and plan['ownLiveSdkHandle'] is False, 'Phase not ready')
require(plan['branchRef'] == 'refs/heads/dev', 'Unexpected branch')
rows = plan['files']
paths = [row['path'] for row in rows]
require(bool(paths) and len(paths) == len(set(paths)), 'Empty/duplicate paths')
require(all(p.startswith('docs/evidence/guardian-') or p in {
    'docs/reviews/guardian-vm35-20261024.md',
    'docs/reviews/guardian-analysis-and-browser13-20261024.md',
    'apps/guardian/test/editor_submit_guard_test.dart'} for p in paths), 'Out-of-scope path')

def git(*args, data=None, private=False):
    env = dict(os.environ)
    env['GIT_INDEX_FILE'] = str(PRIVATE if private else INDEX)
    return subprocess.check_output(['git', *args], cwd=ROOT, input=data, env=env)

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def pin(raw, row):
    require(len(raw) == row['bytes'] and sha(raw) == row['sha256'], 'Raw bytes/SHA: ' + row['path'])
    require(hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()
            == row['gitRawBlobSha1'], 'Raw OID: ' + row['path'])

for row in rows:
    p = ROOT / row['path']
    if row['path'] == 'apps/guardian/test/editor_submit_guard_test.dart':
        require(p.resolve(strict=True) == ROOT / 'apps/guardian/test/editor_submit_guard_test.dart',
                'Escaped fixed test path')
    else:
        require(p.resolve(strict=True).is_relative_to(ROOT / 'docs'), 'Escaped docs')
    require(not any(a.is_symlink() for a in [p, *p.parents] if a.is_relative_to(ROOT)), 'Linked path')
    pin(p.read_bytes(), row)
require(INDEX.is_file() and not INDEX.is_symlink() and not PRIVATE.is_symlink(), 'Invalid index')

def unchanged_head():
    require(git('symbolic-ref', 'HEAD').decode().strip() == plan['branchRef'], 'Branch changed')
    require(git('rev-parse', 'HEAD').decode().strip() == plan['parent'], 'HEAD changed')

def no_staged():
    require(not git('diff', '--cached', '--name-only', '-z'), 'Shared staged changes')

def tree_check(tree):
    changed = set(filter(None, git('diff-tree', '--no-commit-id', '--name-only', '-r', '-z',
                                   plan['parent'], tree).decode().split('\0')))
    require(changed == set(paths), 'Unexpected tree paths')
    for row in rows:
        pin(git('cat-file', 'blob', tree + ':' + row['path']), row)

receipt = dict(parent=plan['parent'], files=len(rows), totalBytes=sum(r['bytes'] for r in rows),
               applicationSourceChanges=0,
               testSourceChanges=sum(r['path'].startswith('apps/guardian/test/') for r in rows),
               testsRun=False, pushed=False, deployed=False)
if mode == 'stage':
    unchanged_head()
    no_staged()
    require(not PRIVATE.exists(), 'Private index exists')
    original = INDEX.read_bytes()
    git('read-tree', plan['parent'], private=True)
    updates = []
    for row in rows:
        existing = git('ls-tree', plan['parent'], '--', row['path'])
        if row['path'] == 'apps/guardian/test/editor_submit_guard_test.dart':
            before = row.get('beforeGitRawBlobSha1')
            require(type(before) is str and len(before) == 40 and
                    existing == f"100644 blob {before}\t{row['path']}\n".encode() and
                    before != row['gitRawBlobSha1'], 'Fixed prior test blob required')
        else:
            require(row.get('beforeGitRawBlobSha1') is None and not existing, 'Expected new QA path')
        oid = git('hash-object', '-w', '--stdin', data=(ROOT / row['path']).read_bytes()).decode().strip()
        require(oid == row['gitRawBlobSha1'], 'Written object mismatched plan')
        updates.append(f"100644 {oid}\t{row['path']}\0".encode())
    git('update-index', '-z', '--index-info', data=b''.join(updates), private=True)
    tree = git('write-tree', private=True).decode().strip()
    tree_check(tree)
    unchanged_head()
    require(INDEX.read_bytes() == original, 'Shared index changed during preparation')
    receipt.update(status='PRIVATE_INDEX_QA_STAGE_VERIFIED', tree=tree,
                   originalSharedIndexSha256=sha(original), privateIndexSha256=sha(PRIVATE.read_bytes()),
                   sharedIndexWritten=False)
elif mode == 'commit':
    staged = json.loads((PHASE / 'stage-receipt.json').read_bytes())
    require(sha(PRIVATE.read_bytes()) == staged['privateIndexSha256'], 'Private index changed')
    tree_check(staged['tree'])
    hook = subprocess.run(['git', 'config', '--get', 'core.hooksPath'], cwd=ROOT,
                          capture_output=True, check=False)
    require(hook.returncode == 1 and not hook.stdout, 'Configured hooks need separate handling')
    require(not [p for p in (ROOT / '.git/hooks').iterdir()
                 if p.is_file() and not p.name.endswith('.sample')], 'Active hooks present')
    signing = subprocess.run(['git', 'config', '--type=bool', '--get', 'commit.gpgsign'],
                             cwd=ROOT, capture_output=True, check=False)
    require(signing.returncode == 1 or
            (signing.returncode == 0 and signing.stdout.strip() == b'false'), 'Signing needs handling')
    cas_may_have_happened, lock_identity = False, None
    try:
        with LOCK.open('xb') as stream:
            stat = os.fstat(stream.fileno())
            lock_identity = (stat.st_dev, stat.st_ino)
            unchanged_head()
            no_staged()
            require(sha(INDEX.read_bytes()) == staged['originalSharedIndexSha256'], 'Shared index changed')
            raw = PRIVATE.read_bytes()
            require(sha(raw) == staged['privateIndexSha256'], 'Private index changed under lock')
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        require((LOCK.stat().st_dev, LOCK.stat().st_ino) == lock_identity and
                sha(LOCK.read_bytes()) == staged['privateIndexSha256'], 'Own lock changed')
        candidate = git('commit-tree', staged['tree'], '-p', plan['parent'], '-m', MESSAGE).decode().strip()
        require(git('rev-parse', candidate + '^').decode().strip() == plan['parent'], 'Wrong parent')
        tree_check(candidate)
        intent = dict(status='PREPARED_REF_CAS_INTENT', expectedParent=plan['parent'],
                      candidate=candidate, branchRef=plan['branchRef'], tree=staged['tree'],
                      originalSharedIndexSha256=staged['originalSharedIndexSha256'],
                      privateIndexSha256=staged['privateIndexSha256'],
                      lockDevice=lock_identity[0], lockInode=lock_identity[1],
                      stagePlanSha256=sha(PLAN.read_bytes()))
        with (PHASE / 'commit-intent.json').open('x', encoding='utf-8', newline='\n') as stream:
            json.dump(intent, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        # From here an interrupted child may have updated the ref even without a return value.
        cas_may_have_happened = True
        git('update-ref', '-m', MESSAGE, plan['branchRef'], candidate, plan['parent'])
        require((LOCK.stat().st_dev, LOCK.stat().st_ino) == lock_identity and
                sha(LOCK.read_bytes()) == staged['privateIndexSha256'], 'Own lock changed after CAS')
        os.replace(LOCK, INDEX)
        lock_identity = None
        require(git('rev-parse', plan['branchRef']).decode().strip() == candidate, 'Ref advanced after commit')
        no_staged()
        receipt.update(status='EXACT_QA_REF_CAS_COMMIT_VERIFIED', head=candidate,
                       tree=staged['tree'], sharedIndexWritten=True, explicitParentCas=True)
    finally:
        if lock_identity is not None and not cas_may_have_happened and LOCK.exists():
            stat = LOCK.stat()
            require((stat.st_dev, stat.st_ino) == lock_identity, 'Refuse changed lock cleanup')
            LOCK.unlink()
        # After a successful CAS, retain any unreplaced task lock for explicit recovery.
else:
    committed = json.loads((PHASE / 'commit-receipt.json').read_bytes())
    head = git('rev-parse', 'HEAD').decode().strip()
    require(head == committed['head'] and git('symbolic-ref', 'HEAD').decode().strip()
            == plan['branchRef'], 'HEAD/branch changed')
    require(git('rev-parse', 'HEAD^').decode().strip() == plan['parent'], 'Wrong parent')
    tree_check(head)
    no_staged()
    receipt.update(status='EXACT_QA_COMMIT_READBACK_VERIFIED', head=head, tree=committed['tree'])

with (PHASE / (mode + '-receipt.json')).open('x', encoding='utf-8', newline='\n') as stream:
    json.dump(receipt, stream, indent=2)
    stream.write('\n')
print(json.dumps(receipt))

