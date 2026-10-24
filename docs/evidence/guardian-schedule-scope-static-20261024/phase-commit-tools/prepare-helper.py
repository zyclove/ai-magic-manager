from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1]
source = root / '.cache/guardian-qa-exact-commit-20261024-r2.py'
raw = source.read_bytes()
if hashlib.sha256(raw).hexdigest() != 'f028a6b7ca53e8317730fa73b5949d312fbf25b4d53802925ad7e65765d08071':
    raise RuntimeError('Qualified parent helper drift')
text = raw.decode('utf-8')
changes = [
    ("PHASE = ROOT / '.cache/guardian-qa-phase-commit-20261024-r2'",
     "PHASE = ROOT / '.cache/guardian-schedule-scope-phase-commit-20261024-r1'"),
    ("MESSAGE = 'test: correct schedule retry button lookup and record validation'",
     "MESSAGE = 'feat: bind schedule editor to its opening workspace'\nSOURCE_PATHS = {\n    'apps/guardian/lib/pages/editors.dart',\n    'apps/guardian/test/editor_submit_guard_test.dart',\n}"),
    ("plan['status'] == 'READY_QA_STAGE_PLAN'", "plan['status'] == 'READY_SCOPE_STATIC_STAGE_PLAN'"),
    ("require(all(p.startswith('docs/evidence/guardian-') or p in {\n    'docs/reviews/guardian-vm35-20261024.md',\n    'docs/reviews/guardian-analysis-and-browser13-20261024.md',\n    'apps/guardian/test/editor_submit_guard_test.dart'} for p in paths), 'Out-of-scope path')",
     "require(all(p in SOURCE_PATHS or p == 'docs/reviews/guardian-schedule-scope-20261024.md' or\n            p.startswith(('docs/evidence/guardian-browser13-r5-current3cf-20261024/',\n                          'docs/evidence/guardian-browser13-r6-static-preparation-20261024/',\n                          'docs/evidence/guardian-services-recovery-20261024/',\n                          'docs/evidence/guardian-schedule-scope-static-20261024/'))\n            for p in paths), 'Out-of-scope path')"),
    ("if row['path'] == 'apps/guardian/test/editor_submit_guard_test.dart':\n        require(p.resolve(strict=True) == ROOT / 'apps/guardian/test/editor_submit_guard_test.dart',\n                'Escaped fixed test path')",
     "if row['path'] in SOURCE_PATHS:\n        require(p.resolve(strict=True) == ROOT / row['path'], 'Escaped fixed source path')"),
    ("applicationSourceChanges=0,", "applicationSourceChanges=sum(r['path'].startswith('apps/guardian/lib/') for r in rows),\n               verificationMode='STATIC_ONLY_NEW_RUNTIME_CHECKS_DEFERRED',"),
    ("if row['path'] == 'apps/guardian/test/editor_submit_guard_test.dart':\n            before = row.get('beforeGitRawBlobSha1')",
     "if row['path'] in SOURCE_PATHS:\n            before = row.get('beforeGitRawBlobSha1')"),
    ("'Fixed prior test blob required'", "'Fixed prior source blob required'"),
]
for old, new in changes:
    if text.count(old) != 1:
        raise RuntimeError('Unexpected parent helper text: ' + old[:60])
    text = text.replace(old, new, 1)
destination = root / '.cache/guardian-schedule-scope-exact-commit-20261024-r1.py'
with destination.open('xb') as stream:
    stream.write(text.encode('utf-8'))
print(str(destination))
print(hashlib.sha256(destination.read_bytes()).hexdigest())
