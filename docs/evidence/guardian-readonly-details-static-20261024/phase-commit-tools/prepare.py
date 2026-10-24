from pathlib import Path
import hashlib
import json
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
phase = root / '.cache/guardian-readonly-details-phase-commit-20261024-r1'
helper = root / '.cache/guardian-readonly-details-exact-commit-20261024-r1.py'
parent = '4ba2fa3574b86d8364f2060a80c5256d9c9e32c6'
source_before = {
    'apps/guardian/lib/ui/resource_page.dart': 'ac3667fff335d8105c5e10e7e3b5b45dc0b5bbb8bc00eb0d94175ee432ed9ed3',
    'apps/guardian/lib/pages/console_pages.dart': '89fac14a4d5930b8398c29b5e0955a86740dce3fae8eaf59c955e989e31d0657',
    'apps/guardian/test/resource_page_resilience_test.dart': 'a003a75c83ef01e6347bfea7ee08801302267f0e97012534e455c57bbc7575f2',
}

def require(ok, message):
    if not ok:
        raise RuntimeError(message)

def digest(raw):
    return hashlib.sha256(raw).hexdigest()

def regular(path):
    require(path.resolve(strict=True) == path, 'Redirected path')
    require(not any(p.is_symlink() or p.is_junction() for p in [path, *path.parents]), 'Linked path')
    require(path.is_file(), 'Expected file')
    return path.read_bytes()

def git(*args):
    return subprocess.check_output(['git', *args], cwd=root)

mode = sys.argv[1]
if mode == 'helper':
    original = regular(root / '.cache/guardian-schedule-scope-exact-commit-20261024-r1.py')
    require(digest(original) == '406bd080c740d079de13cdeeffb38225354dfc1437914ecce085032e1585fc51', 'Parent helper drift')
    text = original.decode()
    changes = [
        ("PHASE = ROOT / '.cache/guardian-schedule-scope-phase-commit-20261024-r1'", "PHASE = ROOT / '.cache/guardian-readonly-details-phase-commit-20261024-r1'"),
        ("MESSAGE = 'feat: bind schedule editor to its opening workspace'", "MESSAGE = 'fix: preserve schedule list when closing read-only details'"),
        ("SOURCE_PATHS = {\n    'apps/guardian/lib/pages/editors.dart',\n    'apps/guardian/test/editor_submit_guard_test.dart',\n}",
         "SOURCE_PATHS = {\n    'apps/guardian/lib/ui/resource_page.dart',\n    'apps/guardian/lib/pages/console_pages.dart',\n    'apps/guardian/test/resource_page_resilience_test.dart',\n}"),
        ("'READY_SCOPE_STATIC_STAGE_PLAN'", "'READY_READONLY_STATIC_STAGE_PLAN'"),
        ("p == 'docs/reviews/guardian-schedule-scope-20261024.md' or\n            p.startswith(('docs/evidence/guardian-browser13-r5-current3cf-20261024/',\n                          'docs/evidence/guardian-browser13-r6-static-preparation-20261024/',\n                          'docs/evidence/guardian-services-recovery-20261024/',\n                          'docs/evidence/guardian-schedule-scope-static-20261024/'))",
         "p == 'docs/reviews/guardian-readonly-details-20261024.md' or\n            p.startswith('docs/evidence/guardian-readonly-details-static-20261024/')"),
    ]
    for before, after in changes:
        require(text.count(before) == 1, 'Unexpected parent helper text')
        text = text.replace(before, after, 1)
    with helper.open('xb') as stream:
        stream.write(text.encode())
    print(json.dumps(dict(helper=str(helper), bytes=helper.stat().st_size, sha256=digest(helper.read_bytes()), gitMutation=False)))
elif mode == 'archive-plan':
    require(git('rev-parse', 'HEAD').decode().strip() == parent, 'Parent changed')
    require(git('symbolic-ref', 'HEAD').decode().strip() == 'refs/heads/dev', 'Branch changed')
    require(not git('diff', '--cached', '--name-only', '-z'), 'Shared staged changes')
    require(not phase.exists(), 'Phase already exists')
    archive = root / 'docs/evidence/guardian-readonly-details-static-20261024'
    require(not archive.exists(), 'Archive already exists')
    sources = [
        ('.cache/guardian-readonly-details-review-20261024-r1/review.md', 'review.md'),
        ('.cache/guardian-readonly-details-review-20261024-r1/pins.json', 'review-pins.json'),
        ('.cache/guardian-readonly-details-test-static-20261024-r1.json', 'test-static.json'),
        (helper.relative_to(root).as_posix(), 'phase-commit-tools/exact-commit.py'),
        (Path(__file__).relative_to(root).as_posix(), 'phase-commit-tools/prepare.py'),
    ]
    pending = [(name, archived, regular(root / name)) for name, archived in sources]
    for name, expected in source_before.items():
        require(digest(git('cat-file', 'blob', parent + ':' + name)) == expected, 'Prior source drift')
    archive.mkdir()
    copies = []
    for name, archived, raw in pending:
        destination = archive / archived
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open('xb') as stream:
            stream.write(raw)
        require(regular(destination) == regular(root / name) == raw, 'Archive readback mismatch')
        copies.append(dict(path=archived, source=name, bytes=len(raw), sha256=digest(raw)))
    metadata = dict(schemaVersion=1, status='STATIC_ONLY_TWO_NEW_CASES_UNRUN', parent=parent,
                    newRuntimeAcceptance=False, sdkInvoked=False, newSourceDeployed=False, files=copies)
    with (archive / 'manifest.json').open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(metadata, stream, ensure_ascii=True, indent=2)
        stream.write('\n')
    paths = list(source_before) + ['docs/reviews/guardian-readonly-details-20261024.md']
    paths += [p.relative_to(root).as_posix() for p in sorted(archive.rglob('*')) if p.is_file()]
    rows = []
    for name in paths:
        raw = regular(root / name)
        before = None
        if name in source_before:
            old = git('cat-file', 'blob', parent + ':' + name)
            require(raw != old, 'Unchanged source')
            before = hashlib.sha1(b'blob ' + str(len(old)).encode() + b'\0' + old).hexdigest()
        else:
            require(not git('ls-tree', parent, '--', name), 'Expected new evidence')
        rows.append(dict(path=name, bytes=len(raw), sha256=digest(raw),
                         gitRawBlobSha1=hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest(),
                         beforeGitRawBlobSha1=before))
    plan = dict(status='READY_READONLY_STATIC_STAGE_PLAN', parent=parent, branchRef='refs/heads/dev',
                ownLiveSdkHandle=False, newTestsRun=False, files=rows)
    phase.mkdir()
    raw = (json.dumps(plan, indent=2) + '\n').encode()
    with (phase / 'stage-pins.json').open('xb') as stream:
        stream.write(raw)
    print(json.dumps(dict(files=len(rows), bytes=sum(r['bytes'] for r in rows), planSha256=digest(raw), gitMutation=False)))
else:
    raise RuntimeError('Unknown mode')
