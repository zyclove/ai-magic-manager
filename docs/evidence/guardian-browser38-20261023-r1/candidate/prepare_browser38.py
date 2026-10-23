"""CreateNew committed 406-source browser38 metadata; no SDK/candidate imports."""
from pathlib import Path
import ast
import copy
import datetime
import difflib
import hashlib
import io
import json
import os
import stat
import subprocess

ROOT = Path(__file__).absolute().parent
REPO = ROOT.parents[1]
PREVIOUS = REPO / '.cache/guardian-browser31-20261023-r2'
PREVIOUS_SHA = 'e931d599edbdc2fc413ba2f156fcf592c165913ab00afff9b75fc148f71f501e'
COMMIT = 'fa2148954ccec749f7d58c38184a208085bfe181'
PARENT = 'a99b40233fcc7c2b01828b8eb45c3477c4a90249'
SOURCE = ROOT / 'src'
ROOTS = ['apps/guardian', 'packages/audit_client', 'packages/commerce_contracts',
         'packages/notification_client', 'packages/device_operations',
         'packages/usage_reporting', 'packages/usage_report_ui']
SELECTORS = ['test/workspace_flow_entry_browser_test.dart', 'test/audit_export_route_test.dart',
             'test/approval_help_flow_browser_test.dart', 'test/notification_help_scope_browser_test.dart']
COUNTS = [8, 4, 19, 7]


def safe(path):
    path = Path(path)
    for item in (path, *path.parents):
        if os.path.lexists(item):
            info = item.lstat()
            assert not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400
    return path


def read(path):
    path = safe(path)
    before = path.stat()
    assert stat.S_ISREG(before.st_mode)
    raw = path.read_bytes()
    after = path.stat()
    assert (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    assert len(raw) == before.st_size
    return raw


def pin(path, absolute=False):
    raw = read(path)
    value = {'path': str(path), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
    if absolute:
        value['absolute'] = True
    return value


def verify(row, base=None):
    path = Path(row['path']) if row.get('absolute') or base is None else base / row['path']
    actual = pin(path)
    assert actual['bytes'] == row['bytes'] and actual['sha256'] == row['sha256'], str(path)


def create(path, raw):
    path = Path(path)
    assert path.is_relative_to(ROOT)
    safe(path.parent)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    assert read(path) == raw
    return pin(path)


def write_json(path, value):
    return create(path, (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))


def pure_names(path):
    tree = ast.parse(read(path).decode('utf-8'), filename=str(path))
    kept = []
    for node in tree.body:
        if isinstance(node, ast.Import):
            assert all(alias.name == 're' for alias in node.names)
            kept.append(node)
        elif isinstance(node, ast.Assign):
            assert all(isinstance(target, ast.Name) and target.id in {'SELECTORS', 'COUNTS'} for target in node.targets)
            ast.literal_eval(node.value)
            kept.append(node)
        elif isinstance(node, ast.FunctionDef):
            assert node.name in {'tokens', 'derive'} and not node.decorator_list
            assert not any(isinstance(child, (ast.Import, ast.ImportFrom, ast.Global, ast.Nonlocal)) for child in ast.walk(node))
            assert not any(isinstance(child, ast.Name) and child.id in {'open', 'exec', 'eval', 'compile', '__import__', 'subprocess', 'os', 'sys', 'Path'} for child in ast.walk(node))
            kept.append(node)
        else:
            assert isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)
    values = {}
    exec(compile(ast.Module(body=kept, type_ignores=[]), str(path) + ':pure-metadata-AST', 'exec'), values)
    return values


def membership(base, inputs, expected):
    found = set()
    def fail(error):
        raise error
    for root in ROOTS:
        for directory, folders, names in os.walk(safe(base / root), followlinks=False, onerror=fail):
            folders[:] = [name for name in folders if name not in inputs['generatedExclusions']['directories']]
            for name in folders:
                safe(Path(directory) / name)
            for name in names:
                if name not in inputs['generatedExclusions']['files']:
                    path = safe(Path(directory) / name)
                    assert path.is_file()
                    found.add(path.relative_to(base).as_posix())
    assert found == expected, ('Full source membership drift', sorted(found - expected), sorted(expected - found))
    return {'files': len(found), 'fullMembershipExact': True}


def main():
    assert not (ROOT / 'attempt').exists()
    assert all(not (ROOT / name).exists() for name in ['src', 'out', 'generated', 'inputs.json', 'worker.py', 'proposal.json'])
    assert pin(PREVIOUS / 'proposal.json')['sha256'] == PREVIOUS_SHA
    previous = json.loads(read(PREVIOUS / 'proposal.json'))
    prior_pins = previous['candidateFiles'] + previous['controlRuntimeFiles'] + previous['historicalMetadataFiles']
    for row in prior_pins:
        verify(row, PREVIOUS)
    old_input = json.loads(read(PREVIOUS / 'inputs.json'))
    for row in old_input['controlRuntimeFiles'] + old_input['extraRuntimeFiles']:
        verify(row)
    verify(old_input['chromeExecutablePin'])
    environment = os.environ.copy()
    environment.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL')
    def git(*arguments, input=None):
        return subprocess.run([old_input['gitExecutable'], '-c', 'safe.directory=' + REPO.as_posix(),
            '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', *arguments], cwd=REPO, env=environment,
            input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=30,
            creationflags=subprocess.CREATE_NO_WINDOW).stdout
    assert git('rev-parse', COMMIT + '^').decode('ascii').strip() == PARENT
    trees = dict(zip(ROOTS, git('rev-parse', *[COMMIT + ':' + root for root in ROOTS]).decode('ascii').splitlines()))
    assert len(trees) == 7
    def current_trees():
        actual = git('rev-parse', 'HEAD', *['HEAD:' + root for root in ROOTS]).decode('ascii').splitlines()
        assert len(actual) == 8 and dict(zip(ROOTS, actual[1:])) == trees
        return actual[0]
    observed_head = current_trees()
    entries = []
    for raw in git('ls-tree', '-rz', COMMIT, '--', *ROOTS).split(b'\0'):
        if not raw:
            continue
        header, path = raw.split(b'\t', 1)
        mode, kind, oid = header.decode('ascii').split()
        relative = path.decode('utf-8')
        assert kind == 'blob' and mode in ('100644', '100755')
        assert not Path(relative).is_absolute() and '..' not in Path(relative).parts and ':' not in relative
        entries.append({'path': relative, 'gitBlob': oid, 'mode': mode})
    expected = {row['path'] for row in entries}
    assert len(entries) == len(expected) == 406
    main_membership = membership(REPO, old_input, expected)
    stream = io.BytesIO(git('cat-file', '--batch', input=''.join(row['gitBlob'] + '\n' for row in entries).encode('ascii')))
    for row in entries:
        oid, kind, size = stream.readline().decode('ascii').split()
        raw = stream.read(int(size))
        assert oid == row['gitBlob'] and kind == 'blob' and len(raw) == int(size) and stream.read(1) == b'\n'
        working = read(REPO / row['path'])
        sha = hashlib.sha256(raw).hexdigest()
        lf = hashlib.sha256(raw.replace(b'\r\n', b'\n')).hexdigest()
        row.update(bytes=len(raw), sha256=sha, committedLfSha256=lf,
            workingTreeRawBytes=len(working), workingTreeRawSha256=hashlib.sha256(working).hexdigest(),
            workingTreeLfSha256=hashlib.sha256(working.replace(b'\r\n', b'\n')).hexdigest())
        assert lf == row['workingTreeLfSha256'], row['path']
        create(SOURCE / row['path'], raw)
    assert stream.read() == b''
    current_trees()
    assert membership(REPO, old_input, expected) == main_membership
    frozen_membership = membership(SOURCE, old_input, expected)
    canonical = ''.join(f"{row['path']}\0{row['bytes']}\0{row['sha256']}\n" for row in entries)
    manifest = {'status': 'STATIC_COMMITTED_SOURCE_SNAPSHOT_BROWSER_UNRUN', 'head': COMMIT, 'parent': PARENT,
        'roots': ROOTS, 'sourceCount': 406, 'sourceBytes': sum(row['bytes'] for row in entries),
        'sourceTreeSha256': hashlib.sha256(canonical.encode('utf-8')).hexdigest(), 'sourceFiles': entries,
        'workingTreeRawDifferences': [row['path'] for row in entries if row['sha256'] != row['workingTreeRawSha256']],
        'workingTreeSemanticDifferencesAfterCrLfNormalization': []}
    source_pin = write_json(ROOT / 'out/source-manifest.json', manifest)
    internal = old_input['internalPackageRoots']
    assert len(internal) == 7 and set(internal.values()) == set(ROOTS)
    seed = json.loads(read(Path(old_input['dependencyLibraryPins']['path'])))
    before_seed = copy.deepcopy(seed)
    count = 0
    for row in seed['packageMappings']:
        if row['name'] in internal:
            assert row['category'] == 'current-committed-repository-input'
            row['proposedCandidateRootUri'] = (SOURCE / internal[row['name']]).as_uri()
            count += 1
    assert count == 7 and len(seed['packageMappings']) == 70
    for before, after in zip(before_seed['packageMappings'], seed['packageMappings']):
        expected_row = copy.deepcopy(before)
        if before['name'] in internal:
            expected_row['proposedCandidateRootUri'] = (SOURCE / internal[before['name']]).as_uri()
        assert after == expected_row
    seed_pin = write_json(ROOT / 'out/dependency-library-pins.json', seed)
    config = json.loads(read(Path(old_input['originalPackageConfig']['path'])))
    assert len(config['packages']) == len({row['name'] for row in config['packages']}) == 70
    for row in config['packages']:
        if row['name'] in internal:
            row['rootUri'] = (SOURCE / internal[row['name']]).as_uri()
    config_pin = write_json(SOURCE / 'apps/guardian/.dart_tool/package_config.json', config)
    template_pin = write_json(ROOT / 'generated/guardian-package_config.json', config)
    cache_pin = create(ROOT / 'cache-content-chrome-refreshed.json', read(Path(old_input['cacheManifest']['path'])))
    assert cache_pin['sha256'] == old_input['cacheManifest']['sha256']
    names = pure_names(ROOT / 'source_name_contract.py')
    assert names['SELECTORS'] == SELECTORS and names['COUNTS'] == COUNTS
    cases, selected = [], []
    for selector, count in zip(SELECTORS, COUNTS):
        raw = read(SOURCE / 'apps/guardian' / selector)
        expanded, declarations = names['derive'](raw.decode('utf-8'), selector)
        assert len(expanded) == count
        row = next(row for row in entries if row['path'] == 'apps/guardian/' + selector)
        selected.append({'selector': selector, 'expectedVisibleCases': count,
            'file': pin(SOURCE / 'apps/guardian' / selector), 'gitBlob': row['gitBlob'], 'declarations': declarations})
        cases.extend(expanded)
    assert len(cases) == len({(row['selector'], row['name']) for row in cases}) == 38
    previous_cases = json.loads(read(Path(old_input['expectedCaseContract']['path'])))['cases']
    assert {(row['selector'], row['name']) for row in cases if row['selector'] in SELECTORS[:3]} == {(row['selector'], row['name']) for row in previous_cases}
    contract = {'status': 'STATIC_LITERAL_SOURCE_NAMES_NOT_RUNTIME_DISCOVERY', 'sourceCommit': COMMIT, 'sourceFiles': 406,
        'selectors': SELECTORS, 'expectedPhysicalSuites': 4, 'expectedVisibleCases': 38, 'selectedSources': selected, 'cases': cases,
        'sourceNameParser': pin(ROOT / 'source_name_contract.py'), 'cacheBaseManifest': old_input['browserCacheBaseManifest'],
        'approvedChromeExecutable': old_input['chromeExecutablePin'], 'protocolVersion': '0.1.1', 'testCoreVersion': '0.6.0',
        'suiteDoneEventExists': False, 'runtimeDiscoveryPerformed': False, 'sdkStarted': False, 'browserStarted': False,
        'original31VisibleNamesPreserved': True, 'notificationSevenIncludingSyntheticOptionalAreRequired': True}
    contract_pin = write_json(ROOT / 'expected-cases.json', contract)
    inputs = copy.deepcopy(old_input)
    inputs.update(status='STATIC_BROWSER38_INPUTS_RUNTIME_UNRUN', phase='browser-38-guardian',
        createdAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(), sourceCommit=COMMIT,
        sourceTreeSha256=manifest['sourceTreeSha256'], sourceManifest=source_pin, dependencyLibraryPins=seed_pin,
        candidatePackageConfig=config_pin, candidatePackageConfigTemplate=template_pin, sevenRootGitTrees=trees,
        sourceMembershipCheck={'main': main_membership, 'frozen': frozen_membership}, cacheManifest=cache_pin,
        expectedCaseContract=contract_pin, reporterContractCode=pin(ROOT / 'reporter_contract_reviewed.py'),
        ownedChromeObserverCode=pin(ROOT / 'owned_chrome_observer.py'),
        scope='Only four exact HTML Chrome selectors and 38 literal expanded visible names; all 31 previous names retained plus 7 required notification cases; runtime unrun.')
    input_pin = write_json(ROOT / 'inputs.json', inputs)
    before_worker = read(PREVIOUS / 'worker.py').decode('utf-8')
    worker = before_worker
    replacements = [
        ("FROZEN = REPO / '.cache/guardian-browser31-20261023-r1'", 'FROZEN = CANDIDATE'),
        (pin(PREVIOUS / 'inputs.json')['sha256'], input_pin['sha256']),
        ('len(rows) == 405 and manifest[\'sourceCount\'] == 405', 'len(rows) == 406 and manifest[\'sourceCount\'] == 406'),
        ('Frozen seven-root/405 source boundary changed', 'Frozen seven-root/406 source boundary changed'),
        ('len(expected) == 405', 'len(expected) == 406'),
        ("         'test/approval_help_flow_browser_test.dart']", "         'test/approval_help_flow_browser_test.dart',\n         'test/notification_help_scope_browser_test.dart']"),
        ("expected_cases['selectors'] == FLAGS[-3:] and expected_cases['expectedVisibleCases'] == 31", "expected_cases['selectors'] == FLAGS[-4:] and expected_cases['expectedVisibleCases'] == 38"),
        ("'selectorCount': 3, 'expectedVisibleCases': 31", "'selectorCount': 4, 'expectedVisibleCases': 38"),
    ]
    for old, new in replacements:
        assert worker.count(old) == 1, old
        worker = worker.replace(old, new)
    worker = worker.replace('GUARDIAN_BROWSER31', 'GUARDIAN_BROWSER38').replace('guardian_browser31', 'guardian_browser38')
    worker = worker.replace('browser-31-guardian', 'browser-38-guardian').replace('31-case', '38-case')
    worker = worker.replace('browser31.jsonl', 'browser38.jsonl').replace('EXACT_BROWSER31', 'EXACT_BROWSER38')
    ast.parse(worker, filename='worker.py')
    create(ROOT / 'worker.py', worker.encode('utf-8'))
    diff = ''.join(difflib.unified_diff(before_worker.splitlines(keepends=True), worker.splitlines(keepends=True),
        fromfile='browser31-html-r2/worker.py', tofile='browser38/worker.py'))
    create(ROOT / 'mechanical-worker.py.diff', diff.encode('utf-8'))
    changed_inputs = {key: {'before': old_input.get(key), 'after': inputs.get(key)}
        for key in sorted(set(old_input) | set(inputs)) if old_input.get(key) != inputs.get(key)}
    write_json(ROOT / 'input-metadata-diff.json', changed_inputs)
    report = {'status': 'STATIC_BROWSER38_PREPARATION_ONLY_RUNTIME_UNRUN', 'sourceCommit': COMMIT, 'sourceParent': PARENT,
        'observedHeadAtStart': observed_head, 'observedHeadAtFinish': current_trees(), 'sevenRootGitTrees': trees,
        'sourceFiles': 406, 'sourceManifest': source_pin, 'sourceTreeSha256': manifest['sourceTreeSha256'],
        'allMainAndFrozenRawHashesAndMembershipMatch': True, 'mainLfMatchesCommitted': True,
        'sourceSnapshotCopiedFromCommittedGitBlobs': True, 'packageRows': 70, 'rebasedInternalRoots': 7,
        'externalRowsAndAllOtherMetadataPreserved': True, 'dependencyLibraryPins': seed_pin,
        'candidatePackageConfig': config_pin, 'cacheManifest': cache_pin, 'cacheFiles': 3537,
        'cacheRuntimeContentsNotRehashedDuringPreparation': True, 'all3537PreflightAndPostflightRequired': True,
        'oldBrowserR2ValidationPinsMatched': len(prior_pins), 'original31NamesPreserved': True,
        'sourceCaseCounts': COUNTS, 'expectedPhysicalSuites': 4, 'expectedVisibleCases': 38, 'actualCasesExecuted': None,
        'nativeHelperByteIdenticalToR1R2': True, 'optionalPrivateJobDiagnosticNotAdded': True,
        'onlyPureNameMetadataASTFunctionsEvaluated': True, 'candidateModuleImported': False, 'candidateControlExecuted': False,
        'sdkCalls': 0, 'testsRun': False, 'browserStarted': False, 'networkUsed': False, 'mainWritten': False, 'attemptExists': False}
    for row in entries:
        assert pin(REPO / row['path'])['sha256'] == row['workingTreeRawSha256']
        assert pin(SOURCE / row['path'])['sha256'] == row['sha256']
    assert membership(REPO, old_input, expected) == main_membership and membership(SOURCE, old_input, expected) == frozen_membership
    for row in prior_pins:
        verify(row, PREVIOUS)
    write_json(ROOT / 'preparation-review.json', report)
    write_json(ROOT / 'preparation-receipt.json', {'status': report['status'], 'inputs': input_pin,
        'sourceManifest': source_pin, 'preparationReview': pin(ROOT / 'preparation-review.json'), 'sdkCalls': 0, 'attemptExists': False})
    assert not (ROOT / 'attempt').exists()
    print(json.dumps({'status': report['status'], 'inputs': input_pin, 'sourceManifest': source_pin,
        'expectedCaseContract': contract_pin, 'caseCounts': COUNTS, 'sdkCalls': 0, 'attemptExists': False}))


if __name__ == '__main__':
    main()
