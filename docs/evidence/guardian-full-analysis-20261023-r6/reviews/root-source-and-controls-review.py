"""Independent static byte/AST review; never imports a candidate or starts an SDK."""
from pathlib import Path
import ast
import copy
import datetime
import hashlib
import json
import os
import subprocess

REPO = Path(__file__).resolve().parents[1]
NEW = REPO / '.cache/guardian-reports-current-20261023-r1'
OLD = REPO / '.cache/guardian-classification-current-20261023-r1'
R6 = REPO / '.cache/guardian-analyze-20261023-r6'
R5 = REPO / '.cache/guardian-analyze-20261023-r5'
env = dict(os.environ, GIT_OPTIONAL_LOCKS='0')

def read_json(path):
    return json.loads(path.read_bytes())

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def check_pin(base, row):
    path = Path(row['path']) if row.get('absolute') else base / row['path']
    raw = path.read_bytes()
    assert len(raw) == row['bytes'] and sha(raw) == row['sha256'], str(path)

def git(*args):
    return subprocess.check_output(['git', *args], cwd=REPO, env=env)

manifest = read_json(NEW / 'out/source-manifest.json')
assert git('rev-parse', 'HEAD').decode().strip() == manifest['head'] == '88871eb69f16012e04ad4d8aa58209edea791e4a'
rows = manifest['sourceFiles']
expected = {row['path'] for row in rows}
assert len(rows) == len(expected) == manifest['sourceCount'] == 408
raw_main_differences = []
for row in rows:
    raw = (NEW / 'src' / row['path']).read_bytes()
    assert len(raw) == row['bytes'] and sha(raw) == row['sha256'], row['path']
    blob = hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()
    assert blob == row['gitBlob'], row['path']
    main = (REPO / row['path']).read_bytes()
    assert len(main) == row['workingTreeRawBytes'] and sha(main) == row['workingTreeRawSha256']
    assert main.replace(b'\r\n', b'\n') == raw.replace(b'\r\n', b'\n')
    if main != raw:
        raw_main_differences.append(row['path'])

ex_dirs = {'.dart_tool', '.idea', 'build'}
ex_files = {'.flutter-plugins', '.flutter-plugins-dependencies', 'device_operations_showcase.iml', 'guardian.iml'}
for base in (REPO, NEW / 'src'):
    actual = set()
    for root in manifest['roots']:
        for directory, dirs, names in os.walk(base / root):
            assert not Path(directory).is_symlink()
            dirs[:] = [d for d in dirs if d not in ex_dirs]
            for name in names:
                if name in ex_files:
                    continue
                path = Path(directory) / name
                assert not path.is_symlink()
                actual.add(path.relative_to(base).as_posix())
    assert actual == expected, (str(base), sorted(actual ^ expected))

listing = git('ls-tree', '-r', '-z', manifest['head'], '--', *manifest['roots'])
git_rows = {}
for line in listing.split(b'\0'):
    if not line:
        continue
    meta, path = line.split(b'\t', 1)
    mode, kind, blob = meta.decode().split()
    assert kind == 'blob'
    git_rows[path.decode()] = (mode, blob)
assert set(git_rows) == expected
assert all(git_rows[r['path']] == (r['mode'], r['gitBlob']) for r in rows)
for root, tree in manifest['sevenRootGitTrees'].items():
    assert git('rev-parse', manifest['head'] + ':' + root).decode().strip() == tree

before = {r['path']: r for r in read_json(OLD / 'out/source-manifest.json')['sourceFiles']}
changed = sorted(r['path'] for r in rows if r['path'] in before and r['sha256'] != before[r['path']]['sha256'])
added = sorted(expected - set(before))
assert len(changed) == 7 and added == ['apps/guardian/test/usage_reports_scope_browser_test.dart']
assert not set(before) - expected
assert changed == sorted([
 'apps/guardian/lib/pages/console_pages.dart', 'apps/guardian/lib/pages/usage_reports_page.dart',
 'apps/guardian/lib/ui/owned_dialog_route.dart', 'apps/guardian/lib/ui/usage_report_device_picker.dart',
 'apps/guardian/lib/ui/usage_report_job_dialog.dart', 'apps/guardian/lib/ui/usage_report_jobs_view.dart',
 'apps/guardian/lib/ui/usage_reports_view.dart'])
for base in (NEW, OLD):
    for row in read_json(base / 'out/seal-static-source.json')['files']:
        check_pin(base, row)

original = read_json(NEW / 'generated/main-package_config-original.json')
rebased = read_json(NEW / 'generated/guardian-package_config.json')
assert len(original['packages']) == len(rebased['packages']) == 70
package_changes = []
for a, b in zip(original['packages'], rebased['packages']):
    if a == b:
        continue
    assert a['name'] == b['name']
    aa, bb = dict(a), dict(b)
    old_root, new_root = aa.pop('rootUri'), bb.pop('rootUri')
    assert aa == bb
    assert new_root.startswith(NEW.as_uri() + '/src/')
    package_changes.append(a['name'])
assert sorted(package_changes) == sorted(['guardian','audit_client','commerce_contracts','notification_client','device_operations','usage_reporting','usage_report_ui'])
aa, bb = dict(original), dict(rebased)
aa.pop('packages'); bb.pop('packages'); assert aa == bb
assert (NEW / 'generated/guardian-package_config.json').read_bytes() == (NEW / 'src/apps/guardian/.dart_tool/package_config.json').read_bytes()

old_cases = read_json(OLD / 'out/expected-cases.json')
cases = read_json(NEW / 'out/expected-cases.json')
assert cases['expectedVisibleCases'] == 67 and cases['expectedPhysicalSuites'] == 6
assert cases['sourceCaseCounts'] == [8,4,19,7,8,21]
assert cases['selectedSources'][:5] == old_cases['selectedSources']
assert cases['selectors'][:5] == old_cases['selectors']
for item in cases['selectedSources']:
    r = item['source']; raw = (NEW / 'src' / r['path']).read_bytes()
    assert len(raw) == r['bytes'] and sha(raw) == r['sha256']
    assert sum(len(d['expandedNames']) for d in item['declarations']) == item['expectedVisibleCases']

p6, p5 = read_json(R6 / 'proposal.json'), read_json(R5 / 'proposal.json')
pin6 = p6['candidateFiles'] + p6['controlRuntimeFiles'] + p6['historicalMetadataFiles']
pin5 = p5['candidateFiles'] + p5['controlRuntimeFiles'] + p5['historicalMetadataFiles']
assert len(pin6) == 156 and len(pin5) == 101
for row in pin6:
    check_pin(R6, row)
new_id = {(str((Path(r['path']) if r.get('absolute') else R6 / r['path']).resolve()).lower(), r['bytes'], r['sha256']) for r in pin6}
for r in pin5:
    key = (str((Path(r['path']) if r.get('absolute') else R5 / r['path']).resolve()).lower(), r['bytes'], r['sha256'])
    assert key in new_id, key[0]
for f in ('controller.py', 'heap1536_windows_job.py'):
    assert (R6 / f).read_bytes() == (R5 / f).read_bytes()
a, b = ast.parse((R5 / 'worker.py').read_text()), ast.parse((R6 / 'worker.py').read_text())
changed_nodes = []
assert len(a.body) == len(b.body)
for old_node, new_node in zip(a.body, b.body):
    if ast.dump(old_node) == ast.dump(new_node):
        continue
    if isinstance(old_node, ast.Assign):
        name = old_node.targets[0].id
        assert name in {'FROZEN', 'INPUT_SHA256'}
        changed_nodes.append(name)
    else:
        assert isinstance(old_node, ast.FunctionDef) and old_node.name == new_node.name == 'source_check'
        transformed = copy.deepcopy(new_node)
        for n in ast.walk(transformed):
            if isinstance(n, ast.Constant) and n.value == 408:
                n.value = 407
            elif isinstance(n, ast.Constant) and isinstance(n.value, str):
                n.value = n.value.replace('408', '407')
        assert ast.dump(old_node) == ast.dump(transformed)
        changed_nodes.append('source_check')
assert changed_nodes == ['FROZEN','INPUT_SHA256','source_check']
for k in ('outerBudgetSeconds','outerSoftCutoffSeconds','workerBudgetSeconds','commandCapSeconds','commandCleanupReserveSeconds','minimumPostflightReserveSeconds','minimumRamBytes','minimumEachDiskBytes','command','sdkNames'):
    assert p6[k] == p5[k], k
i6, i5 = read_json(R6 / 'inputs.json'), read_json(R5 / 'inputs.json')
check_pin(R6, p6['analysisInputs'])
assert Path(i6['cacheManifest']['path']).read_bytes() == Path(i5['cacheManifest']['path']).read_bytes()
assert not (R6 / 'attempt').exists()
result = {'status':'ROOT_INDEPENDENT_STATIC_REVIEW_MATCHED_EXECUTION_UNRUN',
 'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(), 'head':manifest['head'],
 'sourceFiles':408,'rawCommittedGitBlobsMatched':408,'mainAndFrozenMembershipMatched':True,
 'mainRawDifferencesOnlyCrLf':raw_main_differences,'modified':changed,'added':added,
 'packageRows':70,'internalRootsRebased':7,'original46CaseMetadataPreserved':True,
 'preparedCases':67,'physicalSuites':6,'r6PinsMatched':156,'r5PinsPreserved':101,
 'controllerNativeByteIdentical':True,'changedWorkerAstNodes':changed_nodes,
 'budgetUnchanged':True,'cacheProjectionByteIdentical':True,'sdkCalls':0,'testsRun':False,
 'dartParseRun':False,'runtimeAcceptance':False,'attemptCreated':False}
target = REPO / '.cache/guardian-reports-r6-root-review-20261023.json'
with target.open('x',encoding='utf-8') as stream:
    json.dump(result,stream,ensure_ascii=False,indent=2);stream.write('\n')
print(json.dumps(result))
