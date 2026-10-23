"""CreateNew analysis406 controls and metadata; no source copy or SDK import/run."""
from pathlib import Path
import ast
import copy
import datetime
import difflib
import hashlib
import json
import os
import re
import stat
import subprocess

ROOT = Path(__file__).absolute().parent
REPO = ROOT.parents[1]
TEMPLATE = REPO / '.cache/guardian-analyze-20261023-r3'
BROWSER = REPO / '.cache/guardian-browser38-20261023-r1'
TEMPLATE_SHA = '06b3c62694c4ff6abd87ea7ad37b3c13d1aba5b771ed9ffb1034783ed636593e'
BROWSER_SHA = 'f478063e573d445eb048e9a93ff87b7ae5f900499aab5f55d5730e4a7ba9447c'
COMMIT = 'fa2148954ccec749f7d58c38184a208085bfe181'


def read(path):
    path = Path(path)
    for item in (path, *path.parents):
        if os.path.lexists(item):
            info = item.lstat()
            assert not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400
    before = path.stat()
    raw = path.read_bytes()
    after = path.stat()
    assert (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    return raw


def pin(path, absolute=False):
    raw = read(path)
    row = {'path': str(path), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
    if absolute:
        row['absolute'] = True
    return row


def verify(row, base=None):
    path = Path(row['path']) if row.get('absolute') or base is None else base / row['path']
    current = pin(path)
    assert current['bytes'] == row['bytes'] and current['sha256'] == row['sha256'], str(path)


def create(name, raw):
    path = ROOT / name
    assert path.parent == ROOT
    with path.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    return pin(path)


def write_json(name, value):
    return create(name, (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))


def main():
    assert all(not (ROOT / name).exists() for name in ['attempt', 'src', 'inputs.json', 'controller.py', 'worker.py', 'proposal.json'])
    assert pin(TEMPLATE / 'proposal.json')['sha256'] == TEMPLATE_SHA
    assert pin(BROWSER / 'proposal.json')['sha256'] == BROWSER_SHA
    template = json.loads(read(TEMPLATE / 'proposal.json'))
    template_rows = template['candidateFiles'] + template['controlRuntimeFiles'] + template['historicalMetadataFiles']
    for row in template_rows:
        verify(row, TEMPLATE)
    old_input = json.loads(read(Path(template['analysisInputs']['path'])))
    browser_input = json.loads(read(BROWSER / 'inputs.json'))
    source = json.loads(read(Path(browser_input['sourceManifest']['path'])))
    assert source['head'] == browser_input['sourceCommit'] == COMMIT and source['sourceCount'] == len(source['sourceFiles']) == 406
    for field in ['sourceManifest', 'dependencyLibraryPins', 'candidatePackageConfig', 'candidatePackageConfigTemplate', 'originalPackageConfig']:
        verify(browser_input[field])
    expected = {row['path'] for row in source['sourceFiles']}
    for label, base, key in [('main', REPO, 'workingTreeRawSha256'), ('frozen', BROWSER / 'src', 'sha256')]:
        found = set()
        def fail(error):
            raise error
        for subroot in source['roots']:
            for directory, folders, names in os.walk(base / subroot, followlinks=False, onerror=fail):
                folders[:] = [name for name in folders if name not in browser_input['generatedExclusions']['directories']]
                for name in names:
                    if name not in browser_input['generatedExclusions']['files']:
                        found.add((Path(directory) / name).relative_to(base).as_posix())
        assert found == expected and len(found) == 406
        for row in source['sourceFiles']:
            raw = read(base / row['path'])
            assert hashlib.sha256(raw).hexdigest() == row[key], label + ': ' + row['path']
            if label == 'main':
                assert hashlib.sha256(raw.replace(b'\r\n', b'\n')).hexdigest() == row['committedLfSha256']
    environment = os.environ.copy()
    environment.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL')
    roots = source['roots']
    current = subprocess.check_output([old_input['gitExecutable'], '-c', 'safe.directory=' + REPO.as_posix(),
        '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', 'rev-parse', 'HEAD', *['HEAD:' + name for name in roots]],
        cwd=REPO, env=environment, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW).decode('ascii').splitlines()
    assert len(current) == 8 and dict(zip(roots, current[1:])) == browser_input['sevenRootGitTrees']
    projection_raw = read(Path(old_input['cacheManifest']['path']))
    assert hashlib.sha256(projection_raw).hexdigest() == '3ca7ed28e9778c69360245186c96110d1a86e6bf7c621c5ea1a56bd4b19a3e84'
    projection = json.loads(projection_raw)
    parent = json.loads(read(Path(old_input['cacheProjectionParentManifest']['path'])))
    browser_cache = json.loads(read(Path(browser_input['cacheManifest']['path'])))
    exclude = lambda row: Path(row['path']) == Path(browser_input['chromeExecutablePin']['path'])
    excluded_parent = [row for row in parent['fixedFiles'] if exclude(row)]
    excluded_browser = [row for row in browser_cache['fixedFiles'] if exclude(row)]
    assert len(excluded_parent) == len(excluded_browser) == 1
    assert projection['trees'] == parent['trees'] == browser_cache['trees']
    assert projection['fixedFiles'] == [row for row in parent['fixedFiles'] if not exclude(row)] == [row for row in browser_cache['fixedFiles'] if not exclude(row)]
    assert projection['excludedFixedFiles'] == excluded_parent
    assert projection['totals'] == {'files': 3536, 'bytes': 633817159}
    assert len(projection['fixedFiles']) == 32 and len(projection['trees']) == 70
    assert browser_cache['totals']['files'] - 1 == 3536 and browser_cache['totals']['bytes'] - excluded_browser[0]['bytes'] == 633817159
    projection_pin = create('cache-analysis-projection.json', projection_raw)
    inputs = copy.deepcopy(old_input)
    inputs.update(createdAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(), sourceCommit=COMMIT,
        sourceTreeSha256=source['sourceTreeSha256'], sourceManifest=browser_input['sourceManifest'],
        dependencyLibraryPins=browser_input['dependencyLibraryPins'], candidatePackageConfig=browser_input['candidatePackageConfig'],
        candidatePackageConfigTemplate=browser_input['candidatePackageConfigTemplate'], sevenRootGitTrees=browser_input['sevenRootGitTrees'],
        sourceMembershipCheck={'main': {'files': 406, 'fullMembershipExact': True}, 'frozen': {'files': 406, 'fullMembershipExact': True}},
        cacheManifest=projection_pin,
        scope='Full Guardian lib/test analysis of source fa21489/406 via the sealed browser38 snapshot; no test execution, pub, downloads, service changes or deployment.')
    input_pin = write_json('inputs.json', inputs)
    original_controller = read(TEMPLATE / 'controller.py').decode('utf-8')
    controller = re.sub(r'\b210\b', '180', original_controller)
    original_worker = read(TEMPLATE / 'worker.py').decode('utf-8')
    worker = re.sub(r'\b195\b', '165', original_worker)
    worker = re.sub(r'\b180\b', '150', worker)
    replacements = [
        ("FROZEN = REPO / '.cache/guardian-current-20261023-r3'", "FROZEN = REPO / '.cache/guardian-browser38-20261023-r1'"),
        ("INPUT = FROZEN / 'out/analysis-inputs-root.json'", "INPUT = CANDIDATE / 'inputs.json'"),
        (template['analysisInputs']['sha256'], input_pin['sha256']),
        ("len(rows) == 405 and manifest['sourceCount'] == 405", "len(rows) == 406 and manifest['sourceCount'] == 406"),
        ('Frozen seven-root/405 source boundary changed', 'Frozen seven-root/406 source boundary changed'),
        ('len(expected) == 405', 'len(expected) == 406')]
    for before, after in replacements:
        assert worker.count(before) == 1, before
        worker = worker.replace(before, after)
    for name, raw in [('controller.py', controller.encode('utf-8')), ('worker.py', worker.encode('utf-8')),
                      ('heap1536_windows_job.py', read(TEMPLATE / 'heap1536_windows_job.py'))]:
        ast.parse(raw.decode('utf-8'), filename=name)
        create(name, raw)
    for name, before, after in [('controller.py', original_controller, controller), ('worker.py', original_worker, worker)]:
        diff = ''.join(difflib.unified_diff(before.splitlines(keepends=True), after.splitlines(keepends=True),
            fromfile='clean-analysis-r3/' + name, tofile='analysis406-r4/' + name))
        create('mechanical-' + name + '.diff', diff.encode('utf-8'))
    create('mechanical-native-helper.py.diff', b'')
    before_functions = {node.name: ast.dump(node, include_attributes=False) for node in ast.parse(original_worker).body if isinstance(node, ast.FunctionDef)}
    after_functions = {node.name: ast.dump(node, include_attributes=False) for node in ast.parse(worker).body if isinstance(node, ast.FunctionDef)}
    assert {name for name in before_functions if before_functions[name] != after_functions[name]} == {'budget', 'source_check'}
    assert before_functions['cache_check'] == after_functions['cache_check']
    write_json('input-metadata-diff.json', {key: {'before': old_input.get(key), 'after': inputs.get(key)} for key in sorted(set(old_input) | set(inputs)) if old_input.get(key) != inputs.get(key)})
    readme = '''# Full Guardian analysis r4 — static executable candidate

This unexecuted candidate references the sealed browser38 source406 snapshot at commit fa2148954ccec749f7d58c38184a208085bfe181. All seven source roots, complete Main/frozen raw hashes, Git trees/blobs and70 package mappings are checked before and after execution. No source tree is copied. HEAD may advance outside those seven roots.

The sole proposed command is `flutter.bat --no-version-check --suppress-analytics analyze --no-pub --fatal-infos --fatal-warnings`, from the frozen Guardian package, with no file selectors. It is full analysis, not test execution. Earlier source080e zero-issues evidence does not cover the new source406.

Controls are mechanically adapted from the actually accepted analysis-r3 template. Root's requested180-second total is implemented as outer180 / soft174 / worker165 / commandcap150, retaining cleanup5 and complete postflight>=25 seconds. The dynamic command deadline is at most worker-relative135 seconds, and full preflight consumes part of that time; cleanup ends by worker-relative140 seconds. The underlying helper is unchanged. RAM and each C:/D: free-space minimum remain2GiB, with global SDK0/unknown0 before launch and after completion.

The existing strict analysis-only projection is copied byte-for-byte: parent0027 minus the one unused Chrome executable, preserving all70 trees,32 fixed files and every other3536 file pin (633817159 bytes). It is also exactly the current browser38 manifest after excluding that manifest's sole Chrome row. cache_check is AST-identical to the clean template. No cache contents were rebaselined or copied.

Acceptance requires natural native exit0 and No issues found!, fatal warnings/infos enabled, no timeout or forced termination, retained process handle terminal state, owned Job0, full source/package/cache/runtime postflight and resource gates, and actual outer natural zero. Root must additionally enforce the strict complete outer elapsed bound against launch.workerElapsedAtLaunch + launch.commandBudgetSeconds, or require additional actual terminal timing evidence. Cleanup never upgrades a result to passing.

Status is STATIC/UNRUN and executionApproved=false. There is no attempt directory, dependency resolution, SDK invocation, application test, browser, network use, service/deployment action or automatic chaining from Family/browser grants. The entire SDK/browser installation is not pinned. The separate earlier analysis plan remains historical; its210-second proposal was superseded by this180-total candidate and must not be treated as the active budget.
'''
    create('README.md', readme.encode('utf-8'))
    review = {'status': 'STATIC_ANALYSIS406_R4_PREPARATION_NOT_RUNTIME_ACCEPTANCE', 'createdAtUtc': inputs['createdAtUtc'],
        'sourceCommit': COMMIT, 'observedCurrentHead': current[0], 'sourceFiles': 406, 'sevenRootGitTrees': inputs['sevenRootGitTrees'],
        'sourceManifest': inputs['sourceManifest'], 'sharedSnapshot': str(BROWSER / 'src'), 'sourceCopied': False,
        'fullMainAndFrozenRawAndMembershipMatch': True, 'packageRows': 70, 'sharedCandidatePackageConfig': inputs['candidatePackageConfig'],
        'cacheProjection': projection_pin, 'parentCache': inputs['cacheProjectionParentManifest'], 'cacheFiles': 3536,
        'onlyUnusedChromeExcluded': True, 'browserManifestRemaining3536ExactlyMatch': True, 'cacheCheckFunctionAstUnchanged': True,
        'runtimeCacheContentsNotRehashedDuringPreparation': True, 'templatePinsMatched': len(template_rows),
        'outerBudgetSeconds': 180, 'outerSoftCutoffSeconds': 174, 'workerBudgetSeconds': 165, 'commandCapSeconds': 150,
        'commandCleanupReserveSeconds': 5, 'minimumCompletePostflightReserveSeconds': 25,
        'dynamicCommandDeadlineWorkerRelativeMaxSeconds': 135, 'dynamicCleanupWorkerRelativeMaxSeconds': 140,
        'nativeHelperByteIdentical': True, 'candidateImported': False, 'candidateExecuted': False,
        'sdkCalls': 0, 'testsRun': False, 'browserStarted': False, 'networkUsed': False, 'mainWritten': False, 'attemptExists': False}
    write_json('static-review.json', review)
    proposal = copy.deepcopy(template)
    proposal.update(sourceCommit=COMMIT, sourceFiles=406, sevenRootGitTrees=inputs['sevenRootGitTrees'],
        analysisInputs={**input_pin, 'absolute': True}, outerBudgetSeconds=180, outerSoftCutoffSeconds=174,
        workerBudgetSeconds=165, commandCapSeconds=150, workingDirectory=str(BROWSER / 'src/apps/guardian'),
        attemptDirectory=str(ROOT / 'attempt'), cacheManifestSha256=projection_pin['sha256'],
        frozenSourceSnapshotWrittenDuringPreparation=False, sharedSourceSnapshot=str(BROWSER / 'src'), sourceCopied=False,
        preparationScript=pin(ROOT / 'prepare_analysis_r4.py'), preparationRootApprovedCommit=COMMIT,
        executionApproved=False, sdkCalls=0, testsRun=False, runtimeWatchdogVerifiedForThisCandidate=False,
        rootActualExternalObservationRequired=True, independentGrantRequired=True, automaticChaining=False,
        externalStrictDeadlineBoundRequired='actual complete outer elapsed < launch.workerElapsedAtLaunch + launch.commandBudgetSeconds, otherwise additional actual terminal timing evidence is required',
        budgetSupersedesEarlierStaticPlan=True, dynamicCommandDeadlineWorkerRelativeMaxSeconds=135,
        dynamicCleanupWorkerRelativeMaxSeconds=140)
    files = ['controller.py', 'worker.py', 'heap1536_windows_job.py', 'prepare_analysis_r4.py', 'README.md',
        'mechanical-controller.py.diff', 'mechanical-worker.py.diff', 'mechanical-native-helper.py.diff', 'input-metadata-diff.json', 'static-review.json']
    proposal['candidateFiles'] = [{**pin(ROOT / name), 'path': name} for name in files]
    historical = copy.deepcopy(template['historicalMetadataFiles'])
    historical += [pin(TEMPLATE / row['path'], True) for row in template['candidateFiles']]
    historical += [pin(TEMPLATE / name, True) for name in ['proposal.json', 'root-static-review.json', 'attempt/result.json', 'attempt/receipt.json', 'attempt/external-observation-root.json']]
    historical += [pin(BROWSER / name, True) for name in ['proposal.json', 'seal-receipt.json']]
    historical += [{**row, 'absolute': True} for row in [input_pin, projection_pin, *[inputs[field] for field in
        ['sourceManifest', 'dependencyLibraryPins', 'candidatePackageConfig', 'candidatePackageConfigTemplate']]]]
    proposal['historicalMetadataFiles'] = historical
    for row in proposal['candidateFiles'] + proposal['controlRuntimeFiles'] + historical:
        verify(row, ROOT)
    proposal_pin = write_json('proposal.json', proposal)
    assert not (ROOT / 'attempt').exists() and not (ROOT / 'src').exists()
    receipt = {'status': 'STATIC_ANALYSIS406_R4_SEALED_ROOT_REVIEW_REQUIRED_UNRUN', 'proposal': proposal_pin, 'inputs': input_pin,
        'sourceManifest': inputs['sourceManifest'], 'candidatePackageConfig': inputs['candidatePackageConfig'], 'cacheManifest': projection_pin,
        'candidateFiles': len(files), 'controlRuntimeFiles': len(proposal['controlRuntimeFiles']), 'historicalMetadataFiles': len(historical),
        'sourceFiles': 406, 'cacheFiles': 3536, 'outerBudgetSeconds': 180, 'workerBudgetSeconds': 165, 'commandCapSeconds': 150,
        'sdkCalls': 0, 'testsRun': False, 'browserStarted': False, 'candidateImported': False, 'sourceCopied': False, 'attemptExists': False}
    receipt_pin = write_json('seal-receipt.json', receipt)
    print(json.dumps({**receipt, 'receipt': receipt_pin}))


if __name__ == '__main__':
    main()
