"""Fixed file/hash/JSON and read-only-Git integration audit, not an SDK runner."""
from pathlib import Path
import hashlib
import io
import json
import subprocess

ROOT = Path(r'D:\codes\mobile\ai-manager')
OUT = ROOT / '.cache/guardian-action-ownership-post-commit-20261023-r1'
HEAD = 'bb93c0b0bacfea622e50828e635aa61d738f342b'
PARENT = 'ad9f967a802e0d57dcea0e5289bf76d4e55070af'
STAGE = ROOT / '.cache/guardian-action-ownership-application-20261023/stage-pins.json'
ARCHIVE = 'docs/evidence/guardian-action-ownership-20261023'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def describe(path):
    data = path.read_bytes()
    return {'path': str(path), 'bytes': len(data), 'sha256': sha(data)}

def read(path):
    assert not path.is_symlink() and not path.is_junction(), str(path)
    return path.read_bytes()

def load(path):
    return json.loads(read(path))

def pinned(path, row):
    data = read(path)
    assert len(data) == row['bytes'] and sha(data) == row['sha256'], str(path)
    if 'gitRawBlobSha1' in row:
        oid = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        assert oid == row['gitRawBlobSha1'], str(path)
    return data

def git(*args, input=None):
    assert args[0] in {'rev-parse', 'diff', 'diff-tree', 'ls-tree', 'cat-file'}
    return subprocess.run(['git', *args], cwd=ROOT, input=input, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

def tree(commit, paths):
    rows = {}
    for entry in git('ls-tree', '-rz', '--full-tree', commit, '--', *paths).split(b'\0'):
        if not entry:
            continue
        header, name = entry.split(b'\t', 1)
        mode, kind, oid = header.decode().split()
        assert kind == 'blob'
        rows[name.decode()] = {'mode': mode, 'oid': oid}
    return rows

assert git('rev-parse', 'HEAD').decode().strip() == HEAD
assert git('rev-parse', 'HEAD^').decode().strip() == PARENT
stage_bytes = read(STAGE)
assert sha(stage_bytes) == '1c4dbb9a6c756684d7f1434a31752bbc45601a6f9c12989be606bfdfd5012c37'
stage = json.loads(stage_bytes)
assert stage['parent'] == PARENT and len(stage['files']) == 54
rows = {row['path']: row for row in stage['files']}
assert len(rows) == 54
changes = git('diff-tree', '--no-commit-id', '--name-status', '-r', '-z', HEAD).split(b'\0')
assert changes.pop() == b'' and len(changes) == 108
changed = {changes[i + 1].decode(): changes[i].decode() for i in range(0, len(changes), 2)}
assert set(changed) == set(rows)
assert sorted(changed.values()) == ['A'] * 49 + ['M'] * 5
assert not git('diff', '--cached', '--name-only', '-z')
current_tree = tree(HEAD, list(rows))
assert set(current_tree) == set(rows)
production = {path for path in rows if path.startswith('apps/guardian/lib/')}
tests = {path for path in rows if path.startswith('apps/guardian/test/')}
assert production == {
    'apps/guardian/lib/ui/resource_page.dart',
    'apps/guardian/lib/ui/notifications_view.dart',
    'apps/guardian/lib/ui/audit_view.dart',
    'apps/guardian/lib/ui/device_management_dialog.dart'}
assert tests == {'apps/guardian/test/notification_help_scope_browser_test.dart'}
sources = production | tests
assert {path for path in rows if path.startswith('docs/reviews/')} == {'docs/reviews/guardian-action-ownership-20261023.md'}
archive_paths = {path for path in rows if path.startswith(ARCHIVE + '/')}
assert len(archive_paths) == 48
actual_archive = {p.relative_to(ROOT).as_posix() for p in (ROOT / ARCHIVE).iterdir() if p.is_file()}
assert actual_archive == archive_paths
assert not any(p.is_dir() for p in (ROOT / ARCHIVE).iterdir())
manifest = load(ROOT / ARCHIVE / 'manifest.json')
receipt = load(ROOT / ARCHIVE / 'application-receipt.json')
assert manifest['parent'] == receipt['parent'] == PARENT
assert manifest['selfExcluded'] == 'manifest.json'
assert len(manifest['files']) == 47
assert {r['path'] for r in manifest['files']} == archive_paths - {ARCHIVE + '/manifest.json'}
for row in manifest['files']:
    assert row == rows[row['path']]
    pinned(ROOT / row['path'], row)
assert len(receipt['archiveCopies']) == 46
assert {r['archived']['path'] for r in receipt['archiveCopies']} == archive_paths - {
    ARCHIVE + '/manifest.json', ARCHIVE + '/application-receipt.json'}
for copy in receipt['archiveCopies']:
    archived = copy['archived']
    assert archived == rows[archived['path']]
    value = pinned(ROOT / archived['path'], archived)
    assert read(ROOT / copy['original']) == value, copy['original']
assert {r['path'] for r in receipt['sourceChanges']} == sources
assert {r['path'] for r in receipt['sourceAfter']} == sources
for row in receipt['sourceAfter']:
    assert row == rows[row['path']]
parent_tree = tree(PARENT, sorted(sources))
requests = sorted({row['gitRawBlobSha1'] for row in rows.values()} | {r['oid'] for r in parent_tree.values()})
batch = io.BytesIO(git('cat-file', '--batch', input=''.join(oid + '\n' for oid in requests).encode()))
blobs = {}
for requested in requests:
    oid, kind, count = batch.readline().decode().strip().split()
    assert oid == requested and kind == 'blob'
    value = batch.read(int(count))
    assert batch.read(1) == b'\n'
    assert hashlib.sha1(b'blob ' + str(len(value)).encode() + b'\0' + value).hexdigest() == oid
    blobs[oid] = value
assert not batch.read()
for path, row in rows.items():
    assert current_tree[path]['oid'] == row['gitRawBlobSha1']
    value = pinned(ROOT / path, row)
    assert value == blobs[row['gitRawBlobSha1']], path
for change in receipt['sourceChanges']:
    path = change['path']
    before = blobs[parent_tree[path]['oid']]
    assert len(before) == change['beforeBytes'] and sha(before) == change['beforeSha256']
    after = read(Path(change['afterSource']))
    assert after == blobs[rows[path]['gitRawBlobSha1']]
    assert sha(after) == change['afterSha256'] == rows[path]['sha256']

# Exact three text replacements only. No Dart parsing or test name execution.
test = next(iter(tests))
test_before = blobs[parent_tree[test]['oid']].decode()
test_after = blobs[rows[test]['gitRawBlobSha1']].decode()
replacements = [(
    "    // A retained refresh can finish while B's read remains pending. With busy\n"
    "    // false again, only B's operation ownership prevents the held open action\n"
    "    // from dispatching a duplicate after A's finally block has run.\n",
    "    // Old refresh/open callbacks must not interrupt B's pending read. A's\n"
    "    // completion must not unlock them, and B's current operation must still\n"
    "    // open its request normally when its own receipt arrives.\n"), (
    "    expect(opened, isEmpty,\n"
    "        reason: 'The retained refresh superseded that read generation.');\n",
    "    expect(opened, [_requestId],\n"
    "        reason: 'An old refresh must not interrupt the current read.');\n"), (
    "    expect(opened, [_requestId]);\n    expect(find.text('0 条未读'), findsOneWidget);\n",
    "    expect(opened, [_requestId, _requestId]);\n    expect(find.text('0 条未读'), findsOneWidget);\n")]
expected = test_before
for before, after in replacements:
    assert expected.count(before) == 1
    assert 'testWidgets' not in before + after
    expected = expected.replace(before, after)
assert expected == test_after
assert len(test_before.splitlines()) == len(test_after.splitlines())
assert [line for line in test_before.splitlines() if 'testWidgets(' in line] == [
    line for line in test_after.splitlines() if 'testWidgets(' in line]
assert receipt['productionFilesChanged'] == 4 and receipt['existingTestSourcesChanged'] == 1
assert receipt['testCasesAddedOrRemoved'] == 0
assert receipt['existingTestCaseNamesAndSourceLineCountPreserved'] is True
assert receipt['applicationTestsRun'] is receipt['rendered'] is receipt['deployed'] is receipt['pushed'] is False
assert receipt['r8SourceFreezeNowHistorical'] is True
assert receipt['newExecutionInputBindingRequiredBeforeAnyFutureValidation'] is True
foreign = receipt['foreignTrackedWip']
assert foreign == {'path': 'docs/managed-publication-admission-plan.md',
                   'sha256': '4994781cf65a736611e648fe693d0bec9b5aef6cc4315b818a036447dff22d9d'}
foreign_paths = [p.decode() for p in git('diff', '--name-only', '-z').split(b'\0') if p]
assert foreign_paths == [foreign['path']]
assert sha(read(ROOT / foreign['path'])) == foreign['sha256']
assert foreign['path'] not in rows
assert not git('diff', '--cached', '--name-only', '-z')
assert git('rev-parse', 'HEAD').decode().strip() == HEAD
for path, row in rows.items():
    pinned(ROOT / path, row)
assert read(STAGE) == stage_bytes
result = {
    'status': 'EXACT_54_POST_COMMIT_INTEGRATION_MATCH_APPLICATION_SCENARIOS_UNRUN',
    'commit': HEAD, 'parent': PARENT, 'stagePins': describe(STAGE),
    'exactCommitPathSet': 54, 'modified': 5, 'added': 49,
    'mainBytesSha256RawGitBlobMatched': 54, 'indexEmpty': True,
    'productionChanged': sorted(production), 'existingTestChanged': sorted(tests),
    'testCasesAddedOrRemoved': 0, 'testTextEditsExactly': 3,
    'testLineCountBeforeAfter': [len(test_before.splitlines()), len(test_after.splitlines())],
    'testDeclarationLinesUnchanged': True,
    'archiveFiles': 48, 'manifestDescriptors': 47, 'archiveCopiesByteExactlyOriginals': 46,
    'manifest': describe(ROOT / ARCHIVE / 'manifest.json'),
    'applicationReceipt': describe(ROOT / ARCHIVE / 'application-receipt.json'),
    'sourceCandidateAfterBytesMatched': 5, 'sourceParentBeforeMatched': 5,
    'trackedForeignWipOnly': foreign, 'trackedWorktreeGloballyClean': False,
    'untrackedHistoricalEvidenceNotClaimedCleanOrAudited': True,
    'r8SourceFreezeHistorical': True, 'newSourceCopyOrExecutionBundleCreated': False,
    'allApplicationScenarios': 'UNRUN', 'rendered': False,
    'deployedOrPushedByThisTask': False,
    'sdkTestsAstCandidateBusinessPredicatesProcessInspectionNetworkInvoked': False,
    'mainGitOrOriginalArtifactsWritten': False,
    'scope': 'Integration bytes and evidence only; no repeated business review or execution qualification.'}
with (OUT / 'readback.json').open('x', encoding='utf-8', newline='\n') as stream:
    json.dump(result, stream, ensure_ascii=False, indent=2)
    stream.write('\n')
print(json.dumps(result, ensure_ascii=False))
