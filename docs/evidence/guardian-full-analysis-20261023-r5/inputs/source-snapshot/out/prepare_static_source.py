"""Prepare committed source and static metadata only. No SDK/control imports."""
from pathlib import Path
import ast
import copy
import datetime
import hashlib
import io
import json
import os
import stat
import subprocess

BASE = Path(__file__).absolute().parent.parent
REPO = BASE.parents[1]
PREVIOUS = REPO / '.cache/guardian-browser38-20261023-r1'
SOURCE = BASE / 'src'
OUT = BASE / 'out'
GENERATED = BASE / 'generated'
COMMIT = '1ca1f7fc4cddefca6f711bea0ae90f3cb8c89f9e'
OLD_COMMIT = 'fa2148954ccec749f7d58c38184a208085bfe181'
ROOTS = ['apps/guardian', 'packages/audit_client', 'packages/commerce_contracts',
         'packages/notification_client', 'packages/device_operations',
         'packages/usage_reporting', 'packages/usage_report_ui']
SELECTORS = ['test/workspace_flow_entry_browser_test.dart', 'test/audit_export_route_test.dart',
             'test/approval_help_flow_browser_test.dart', 'test/notification_help_scope_browser_test.dart',
             'test/application_classification_scope_browser_test.dart']
COUNTS = [8, 4, 19, 7, 8]
EXPECTED_CHANGES = {
    'apps/guardian/lib/pages/console_pages.dart': 'MODIFIED',
    'apps/guardian/lib/ui/application_classification_dialog.dart': 'MODIFIED',
    'apps/guardian/test/application_classification_scope_browser_test.dart': 'ADDED',
}


def safe(path):
    path = Path(path)
    for item in (path, *path.parents):
        if os.path.lexists(item):
            info = item.lstat()
            assert not stat.S_ISLNK(info.st_mode), str(item)
            assert not getattr(info, 'st_file_attributes', 0) & 0x400, str(item)
    return path


def read(path):
    path = safe(path)
    before = path.stat()
    assert stat.S_ISREG(before.st_mode)
    raw = path.read_bytes()
    after = path.stat()
    identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns)
    assert identity(before) == identity(after) and len(raw) == before.st_size, str(path)
    return raw


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def pin(path):
    raw = read(path)
    return {'path': str(path), 'bytes': len(raw), 'sha256': sha(raw)}


def verify(path, expected):
    actual = pin(path)
    assert actual['bytes'] == expected['bytes'] and actual['sha256'] == expected['sha256'], str(path)
    return actual


def create(path, raw):
    path = Path(path)
    assert path.is_relative_to(BASE) and path != BASE
    safe(path.parent).mkdir(parents=True, exist_ok=True)
    with path.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    assert read(path) == raw
    return pin(path)


def write_json(path, value):
    return create(path, (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))


def pure_names(path):
    # This exact reviewed module contains only re, literal configuration and pure
    # string/token functions. No old controller/worker/prepare module is imported.
    assert pin(path)['sha256'] == '7fe208bdb1cf46307185343fdc249a4e99fa2879dba44cff165d04675dc7f77b'
    tree = ast.parse(read(path).decode('utf-8'), filename=str(path))
    for node in tree.body:
        if isinstance(node, ast.Import):
            assert all(alias.name == 're' for alias in node.names)
        elif isinstance(node, ast.Assign):
            assert all(isinstance(t, ast.Name) and t.id in {'SELECTORS', 'COUNTS'} for t in node.targets)
            ast.literal_eval(node.value)
        elif isinstance(node, ast.FunctionDef):
            assert node.name in {'tokens', 'derive'} and not node.decorator_list
            assert not any(isinstance(c, (ast.Import, ast.ImportFrom, ast.Global, ast.Nonlocal)) for c in ast.walk(node))
            assert not any(isinstance(c, ast.Name) and c.id in {
                'open', 'exec', 'eval', 'compile', '__import__', 'subprocess', 'os', 'sys', 'Path'
            } for c in ast.walk(node))
        else:
            assert isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)
    namespace = {}
    exec(compile(tree, str(path) + ':pure-static-name-metadata', 'exec'), namespace)
    assert namespace['SELECTORS'] == SELECTORS[:4] and namespace['COUNTS'] == COUNTS[:4]
    namespace['SELECTORS'] = SELECTORS
    namespace['COUNTS'] = COUNTS
    return namespace


def membership(base, exclusions, expected):
    paths = set()
    def fail(error):
        raise error
    for root in ROOTS:
        for directory, folders, names in os.walk(safe(base / root), followlinks=False, onerror=fail):
            folders[:] = [name for name in folders if name not in exclusions['directories']]
            for name in folders:
                safe(Path(directory) / name)
            for name in names:
                if name not in exclusions['files']:
                    path = safe(Path(directory) / name)
                    assert path.is_file()
                    paths.add(path.relative_to(base).as_posix())
    assert paths == expected, ('Source membership drift', sorted(paths - expected), sorted(expected - paths))
    return {'files': len(paths), 'fullMembershipExact': True}


def main():
    assert not SOURCE.exists() and not GENERATED.exists()
    assert {p.name for p in OUT.iterdir()} == {'prepare_static_source.py'}
    old_input = json.loads(read(PREVIOUS / 'inputs.json'))
    assert pin(PREVIOUS / 'inputs.json')['sha256'] == '770589fea56a9578234eb728f7a1b98fcf2eb240f022c9a7098140ea5448e320'
    old_manifest_pin = verify(PREVIOUS / 'out/source-manifest.json', old_input['sourceManifest'])
    old_manifest = json.loads(read(PREVIOUS / 'out/source-manifest.json'))
    assert old_manifest['head'] == OLD_COMMIT and old_manifest['sourceCount'] == 406
    old_entries = {row['path']: row for row in old_manifest['sourceFiles']}
    assert len(old_entries) == 406
    verify(Path(old_input['originalPackageConfig']['path']), old_input['originalPackageConfig'])
    verify(Path(old_input['dependencyLibraryPins']['path']), old_input['dependencyLibraryPins'])
    verify(Path(old_input['expectedCaseContract']['path']), old_input['expectedCaseContract'])
    git_path = Path(old_input['gitExecutable'])
    git_pin = next(row for row in old_input['extraRuntimeFiles'] if row['path'] == str(git_path))
    verify(git_path, git_pin)
    environment = os.environ.copy()
    environment.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL')
    def git(*arguments, input=None):
        return subprocess.run([str(git_path), '-c', 'safe.directory=' + REPO.as_posix(),
            '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', *arguments], cwd=REPO,
            env=environment, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW).stdout
    parent = git('rev-parse', COMMIT + '^').decode('ascii').strip()
    trees = dict(zip(ROOTS, git('rev-parse', *[COMMIT + ':' + root for root in ROOTS]).decode('ascii').splitlines()))
    assert len(trees) == 7
    assert all(trees[root] == old_input['sevenRootGitTrees'][root] for root in ROOTS[1:])
    def current_head():
        rows = git('rev-parse', 'HEAD', *['HEAD:' + root for root in ROOTS]).decode('ascii').splitlines()
        assert len(rows) == 8 and dict(zip(ROOTS, rows[1:])) == trees
        return rows[0]
    observed_start = current_head()
    entries = []
    for raw in git('ls-tree', '-rz', COMMIT, '--', *ROOTS).split(b'\0'):
        if not raw:
            continue
        header, raw_path = raw.split(b'\t', 1)
        mode, kind, oid = header.decode('ascii').split()
        relative = raw_path.decode('utf-8')
        assert kind == 'blob' and mode in {'100644', '100755'}
        assert not Path(relative).is_absolute() and '..' not in Path(relative).parts and ':' not in relative
        entries.append({'path': relative, 'gitBlob': oid, 'mode': mode})
    expected = {row['path'] for row in entries}
    assert len(entries) == len(expected) == 407
    membership(REPO, old_input['generatedExclusions'], expected)
    batch = io.BytesIO(git('cat-file', '--batch', input=''.join(row['gitBlob'] + '\n' for row in entries).encode('ascii')))
    committed = {}
    for row in entries:
        oid, kind, size = batch.readline().decode('ascii').split()
        raw = batch.read(int(size))
        assert oid == row['gitBlob'] and kind == 'blob' and len(raw) == int(size) and batch.read(1) == b'\n'
        assert hashlib.sha1(b'blob ' + str(len(raw)).encode('ascii') + b'\0' + raw).hexdigest() == oid
        working = read(REPO / row['path'])
        row.update(bytes=len(raw), sha256=sha(raw), committedLfSha256=sha(raw.replace(b'\r\n', b'\n')),
            workingTreeRawBytes=len(working), workingTreeRawSha256=sha(working),
            workingTreeLfSha256=sha(working.replace(b'\r\n', b'\n')))
        assert row['committedLfSha256'] == row['workingTreeLfSha256'], row['path']
        committed[row['path']] = raw
    assert batch.read() == b''
    by_path = {row['path']: row for row in entries}
    deltas = []
    for path in sorted(set(old_entries) | expected):
        before, after = old_entries.get(path), by_path.get(path)
        if before is None or after is None or before['gitBlob'] != after['gitBlob']:
            change = 'ADDED' if before is None else 'DELETED' if after is None else 'MODIFIED'
            deltas.append({'path': path, 'change': change,
                'before': None if before is None else {k: before[k] for k in ['gitBlob', 'mode', 'bytes', 'sha256']},
                'after': None if after is None else {k: after[k] for k in ['gitBlob', 'mode', 'bytes', 'sha256']}})
    assert {row['path']: row['change'] for row in deltas} == EXPECTED_CHANGES
    assert len(expected & set(old_entries)) == 406
    # No old controller, worker, SDK or application code is evaluated here.
    names = pure_names(PREVIOUS / 'source_name_contract.py')
    cases, selected = [], []
    for selector, count in zip(SELECTORS, COUNTS):
        path = 'apps/guardian/' + selector
        expanded, declarations = names['derive'](committed[path].decode('utf-8'), selector)
        assert len(expanded) == count
        selected.append({'selector': selector, 'expectedVisibleCases': count,
            'source': {k: by_path[path][k] for k in ['path', 'gitBlob', 'bytes', 'sha256']},
            'declarations': declarations})
        cases.extend(expanded)
    old_contract = json.loads(read(Path(old_input['expectedCaseContract']['path'])))
    assert cases[:38] == old_contract['cases']
    assert len(cases) == len({(row['selector'], row['name']) for row in cases}) == 46
    config_original = read(Path(old_input['originalPackageConfig']['path']))
    config = json.loads(config_original)
    original_config = copy.deepcopy(config)
    internal = old_input['internalPackageRoots']
    assert len(internal) == 7 and set(internal.values()) == set(ROOTS)
    assert len(config['packages']) == len({r['name'] for r in config['packages']}) == 70
    seed = json.loads(read(Path(old_input['dependencyLibraryPins']['path'])))
    old_seed = copy.deepcopy(seed)
    assert len(seed['packageMappings']) == 70
    for row in config['packages']:
        if row['name'] in internal:
            row['rootUri'] = (SOURCE / internal[row['name']]).as_uri()
    for row in seed['packageMappings']:
        if row['name'] in internal:
            assert row['category'] == 'current-committed-repository-input'
            row['proposedCandidateRootUri'] = (SOURCE / internal[row['name']]).as_uri()
    for before, after in zip(original_config['packages'], config['packages']):
        expected_row = copy.deepcopy(before)
        if before['name'] in internal:
            expected_row['rootUri'] = (SOURCE / internal[before['name']]).as_uri()
        assert after == expected_row
    for before, after in zip(old_seed['packageMappings'], seed['packageMappings']):
        expected_row = copy.deepcopy(before)
        if before['name'] in internal:
            expected_row['proposedCandidateRootUri'] = (SOURCE / internal[before['name']]).as_uri()
        assert after == expected_row
    # Complete every preflight before creating a source copy.
    current_head()
    for row in entries:
        assert pin(REPO / row['path'])['sha256'] == row['workingTreeRawSha256']
    for row in entries:
        create(SOURCE / row['path'], committed[row['path']])
    canonical = ''.join(f"{r['path']}\0{r['bytes']}\0{r['sha256']}\n" for r in entries)
    manifest = {'status': 'STATIC_COMMITTED_SOURCE_SNAPSHOT_ALL_VALIDATION_UNRUN',
        'head': COMMIT, 'parent': parent, 'roots': ROOTS, 'sevenRootGitTrees': trees,
        'sourceCount': 407, 'sourceBytes': sum(r['bytes'] for r in entries),
        'sourceTreeSha256': sha(canonical.encode('utf-8')), 'sourceFiles': entries,
        'workingTreeRawDifferences': [r['path'] for r in entries if r['sha256'] != r['workingTreeRawSha256']],
        'workingTreeDifferencesAfterOnlyCrLfNormalization': [],
        'lineEndingComparisonLimit': 'Only CRLF-to-LF byte normalization was compared; no semantic equivalence or Dart compilation is claimed.'}
    manifest_pin = write_json(OUT / 'source-manifest.json', manifest)
    before_manifest_pin = create(OUT / 'source-before38-manifest.json', read(PREVIOUS / 'out/source-manifest.json'))
    seed_pin = write_json(OUT / 'dependency-library-pins.json', seed)
    config_pin = write_json(SOURCE / 'apps/guardian/.dart_tool/package_config.json', config)
    template_pin = write_json(GENERATED / 'guardian-package_config.json', config)
    original_config_pin = create(GENERATED / 'main-package_config-original.json', config_original)
    parser_pin = create(GENERATED / 'reference-source-name-contract-browser38.py', read(PREVIOUS / 'source_name_contract.py'))
    contract = {'status': 'STATIC_LITERAL_SOURCE_NAMES_NOT_RUNTIME_DISCOVERY', 'sourceCommit': COMMIT,
        'sourceFiles': 407, 'sourceTreeSha256': manifest['sourceTreeSha256'], 'selectors': SELECTORS,
        'expectedPhysicalSuites': 5, 'expectedVisibleCases': 46, 'sourceCaseCounts': COUNTS,
        'selectedSources': selected, 'cases': cases, 'sourceNameParser': parser_pin,
        'parserConfiguration': {'SELECTORS': SELECTORS, 'COUNTS': COUNTS,
            'change': 'Only in-memory literal selector/count configuration extends the unchanged reviewed pure parser.'},
        'original38VisibleNamesAndDeclarationMetadataPreservedExactly': True,
        'newClassificationCasesRequired': 8, 'runtimeDiscoveryPerformed': False,
        'dartParsingPerformed': False, 'sdkStarted': False, 'browserStarted': False}
    contract_pin = write_json(OUT / 'expected-cases.json', contract)
    delta_pin = write_json(OUT / 'delta-from-browser38.json', {'status': 'STATIC_SOURCE_DELTA',
        'beforeCommit': OLD_COMMIT, 'afterCommit': COMMIT, 'beforeFiles': 406, 'afterFiles': 407,
        'unchangedFiles': 404, 'modifiedFiles': 2, 'addedFiles': 1, 'deletedFiles': 0,
        'beforeSourceManifest': before_manifest_pin, 'deltas': deltas})
    directories = sorted(p.relative_to(SOURCE).as_posix() for p in SOURCE.rglob('*') if p.is_dir())
    directory_pin = write_json(OUT / 'source-directory-list.json', {'status': 'STATIC_DIRECTORY_INVENTORY',
        'sourceBase': str(SOURCE), 'directories': directories, 'directoryCount': len(directories),
        'trackedSourcePaths': sorted(expected),
        'generatedPathsOutsideTrackedSourceSet': ['apps/guardian/.dart_tool/package_config.json']})
    provenance = {'schema': 1, 'status': 'SOURCE_AND_METADATA_ONLY_NOT_EXECUTION_PROPOSAL',
        'sourceCommit': COMMIT, 'sourceParent': parent, 'observedHeadAtStart': observed_start,
        'observedHeadAtFinish': current_head(), 'sevenRootGitTrees': trees,
        'sourceManifest': manifest_pin, 'sourceDirectoryList': directory_pin,
        'deltaFromBrowser38': delta_pin, 'expectedCaseContract': contract_pin,
        'dependencyLibraryPins': seed_pin, 'candidatePackageConfig': config_pin,
        'candidatePackageConfigTemplate': template_pin, 'originalPackageConfig': original_config_pin,
        'internalPackageRoots': internal, 'packageRows': 70, 'rebasedInternalRoots': 7,
        'externalRowsAndAllOtherConfigMetadataPreserved': True,
        'sourceMembershipExclusions': old_input['generatedExclusions'],
        'sourceCopiesAreRawCommittedGitBlobs': True, 'everyGitBlobRecomputedFromRawBytes': True,
        'before38SourceManifestOriginal': old_manifest_pin,
        'preparationReferences': [pin(PREVIOUS / 'prepare_browser38.py'), pin(PREVIOUS / 'inputs.json'),
            pin(PREVIOUS / 'source_name_contract.py'), old_input['dependencyLibraryPins'], old_input['expectedCaseContract']],
        'dependencySeedLimit': 'Inherited historical dependency metadata, including historical access errors, is preserved byte-for-field except seven proposed internal roots. It is not a fresh external cache integrity check.',
        'noCacheContentCopyOrRehash': True, 'sdkCalls': 0, 'networkCalls': 0,
        'applicationTests': 'UNRUN', 'formatter': 'UNRUN', 'dartTypeCheck': 'UNRUN',
        'runtimeDiscovery': 'UNRUN', 'gitWrites': False, 'mainWrites': False,
        'controllerOrWorkerImported': False, 'validationWorkerCreated': False,
        'executionGrant': None, 'attemptDirectoryCreated': False}
    source_membership = membership(SOURCE, old_input['generatedExclusions'], expected)
    main_membership = membership(REPO, old_input['generatedExclusions'], expected)
    for row in entries:
        assert pin(SOURCE / row['path'])['sha256'] == row['sha256']
        assert pin(REPO / row['path'])['sha256'] == row['workingTreeRawSha256']
    verify(Path(old_input['originalPackageConfig']['path']), old_input['originalPackageConfig'])
    assert read(SOURCE / 'apps/guardian/.dart_tool/package_config.json') == read(GENERATED / 'guardian-package_config.json')
    provenance.update(mainMembership=main_membership, frozenMembership=source_membership)
    provenance_pin = write_json(OUT / 'preparation-review.json', provenance)
    inventory = []
    for path in sorted(BASE.rglob('*')):
        safe(path)
        if path.is_file():
            row = pin(path)
            row['path'] = path.relative_to(BASE).as_posix()
            inventory.append(row)
    inventory_pin = write_json(OUT / 'delivery-inventory.json', {'status': 'STATIC_DELIVERY_INVENTORY',
        'excludes': ['out/delivery-inventory.json', 'out/preparation-receipt.json'], 'files': inventory,
        'fileCount': len(inventory), 'bytes': sum(r['bytes'] for r in inventory)})
    receipt = {'status': provenance['status'], 'sourceCommit': COMMIT, 'sourceManifest': manifest_pin,
        'sourceTreeSha256': manifest['sourceTreeSha256'], 'sourceFiles': 407,
        'sourceBytes': manifest['sourceBytes'], 'mainRawDifferenceCount': len(manifest['workingTreeRawDifferences']),
        'old38NamesPreserved': True, 'expectedCases': 46, 'caseCounts': COUNTS,
        'expectedCaseContract': contract_pin, 'preparationReview': provenance_pin,
        'deliveryInventory': inventory_pin, 'sdkCalls': 0, 'testsRun': False,
        'controllerOrWorkerImported': False, 'validationWorkerCreated': False,
        'executionApproved': False, 'attemptExists': False}
    receipt_pin = write_json(OUT / 'preparation-receipt.json', receipt)
    assert not (BASE / 'attempt').exists()
    print(json.dumps({'receipt': receipt_pin, **receipt}, ensure_ascii=False))


if __name__ == '__main__':
    main()
