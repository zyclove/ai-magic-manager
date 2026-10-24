from pathlib import Path
import hashlib
import json
import subprocess

root = Path(__file__).resolve().parents[1]
parent = '3cfbf535099ade86234661556d9e92db9069743a'
phase = root / '.cache/guardian-schedule-scope-phase-commit-20261024-r1'
source_before = {
    'apps/guardian/lib/pages/editors.dart':
        '208926fbdc201d66fc5bf3e261465d9d76488141c27ed1b30bcbf40a4d0ff957',
    'apps/guardian/test/editor_submit_guard_test.dart':
        '0e0a0d3f2392bddf6f94f6cbc42dcc93bfcc9b2d3f2fb1aeef8c3044b03fb99b',
}
directories = [
    'docs/evidence/guardian-browser13-r5-current3cf-20261024',
    'docs/evidence/guardian-browser13-r6-static-preparation-20261024',
    'docs/evidence/guardian-services-recovery-20261024',
    'docs/evidence/guardian-schedule-scope-static-20261024',
]

def git(*args):
    return subprocess.check_output(['git', *args], cwd=root)

def check(ok, message):
    if not ok:
        raise RuntimeError(message)

check(git('rev-parse', 'HEAD').decode().strip() == parent, 'Parent changed')
check(git('symbolic-ref', 'HEAD').decode().strip() == 'refs/heads/dev', 'Branch changed')
check(not git('diff', '--cached', '--name-only', '-z'), 'Foreign staged changes')
check(not phase.exists(), 'Phase plan already exists')
paths = list(source_before) + ['docs/reviews/guardian-schedule-scope-20261024.md']
for name in directories:
    directory = root / name
    check(directory.is_dir() and not directory.is_symlink(), 'Missing archive: ' + name)
    for path in sorted(directory.rglob('*')):
        check(not path.is_symlink(), 'Linked archive entry')
        if path.is_file():
            paths.append(path.relative_to(root).as_posix())
check(len(paths) == len(set(paths)), 'Duplicate phase paths')
rows = []
for name in paths:
    path = root / name
    check(path.resolve(strict=True) == path, 'Escaped phase path')
    check(not any(p.is_symlink() for p in [path, *path.parents]), 'Linked phase path')
    raw = path.read_bytes()
    before = None
    if name in source_before:
        old = git('cat-file', 'blob', parent + ':' + name)
        check(hashlib.sha256(old).hexdigest() == source_before[name], 'Prior source drift')
        check(raw != old, 'Source has no change')
        before = hashlib.sha1(b'blob ' + str(len(old)).encode() + b'\0' + old).hexdigest()
    else:
        check(not git('ls-tree', parent, '--', name), 'Expected a new evidence path')
    rows.append(dict(path=name, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(),
                     gitRawBlobSha1=hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest(),
                     beforeGitRawBlobSha1=before))
plan = dict(status='READY_SCOPE_STATIC_STAGE_PLAN', parent=parent,
            branchRef='refs/heads/dev', ownLiveSdkHandle=False,
            verificationMode='STATIC_ONLY_NEW_RUNTIME_CHECKS_DEFERRED',
            priorR5EntireRunAccepted=False, newCasesPrepared=14, expandedFileCases=27,
            pushed=False, newSourceDeployed=False, files=rows)
phase.mkdir()
raw = (json.dumps(plan, ensure_ascii=True, indent=2) + '\n').encode()
with (phase / 'stage-pins.json').open('xb') as stream:
    stream.write(raw)
print(json.dumps(dict(plan=str(phase / 'stage-pins.json'), planSha256=hashlib.sha256(raw).hexdigest(),
                     files=len(rows), bytes=sum(r['bytes'] for r in rows),
                     applicationSourceChanges=1, testSourceChanges=1, gitMutation=False)))
