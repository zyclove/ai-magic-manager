"""CreateNew r9 metadata/control adaptation only; no source/cache copy or SDK."""
from pathlib import Path
import ast
import copy
import datetime
import difflib
import hashlib
import json
import os
import stat
import subprocess

BASE = Path(__file__).absolute().parent
REPO = BASE.parents[1]
TEMPLATE = REPO / '.cache/guardian-analyze-20261023-r8'
ACCEPTED_LINEAGE = TEMPLATE
FROZEN = REPO / '.cache/guardian-current-20261023-r3-a2b5'
COMMIT = 'a2b5ca6ef2398397e4208065090b7c1d65992358'
TEMPLATE_SHA = 'f6f9a00027a9b070a2b289e5560a34d31c3314e2137a40cd75a8b1dd76e03ae1'
SNAPSHOT_SEAL_SHA = '869a6c582e6de734a2d6b0220e00a09d8264aef7055c1ba4145e9c63ccb22adb'


def read(path):
    path = Path(path)
    for item in (path, *path.parents):
        if os.path.lexists(item):
            info = item.lstat()
            assert not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400
    before = path.stat()
    assert stat.S_ISREG(before.st_mode)
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


def absolute(row, base):
    result = copy.deepcopy(row)
    result['path'] = str(Path(row['path']) if row.get('absolute') or Path(row['path']).is_absolute() else base / row['path'])
    result['absolute'] = True
    return result


def verify(row, base=None):
    path = Path(row['path']) if row.get('absolute') or base is None else base / row['path']
    # Historical external runtime descriptors are inherited, not freshly rebaselined.
    if not path.absolute().is_relative_to(REPO):
        return
    got = pin(path)
    assert got['bytes'] == row['bytes'] and got['sha256'] == row['sha256'], str(path)


def create(name, raw):
    path = BASE / name
    assert path.parent == BASE
    with path.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    assert read(path) == raw
    return pin(path)


def write_json(name, value):
    return create(name, (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))


def source_check_metadata(source, inputs):
    expected = {row['path'] for row in source['sourceFiles']}
    assert len(expected) == len(source['sourceFiles']) == source['sourceCount'] == 409
    for label, base, hash_key in [('main', REPO, 'workingTreeRawSha256'), ('frozen', FROZEN / 'src', 'sha256')]:
        found = set()
        def fail(error):
            raise error
        for root in source['roots']:
            for directory, folders, names in os.walk(base / root, followlinks=False, onerror=fail):
                folders[:] = [name for name in folders if name not in inputs['generatedExclusions']['directories']]
                for name in folders:
                    item = Path(directory) / name
                    info = item.lstat()
                    assert not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400
                for name in names:
                    if name not in inputs['generatedExclusions']['files']:
                        found.add((Path(directory) / name).relative_to(base).as_posix())
        assert found == expected
        for row in source['sourceFiles']:
            raw = read(base / row['path'])
            assert hashlib.sha256(raw).hexdigest() == row[hash_key], label + ': ' + row['path']
    environment = os.environ.copy()
    environment.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL')
    current = subprocess.check_output([inputs['gitExecutable'], '-c', 'safe.directory=' + REPO.as_posix(),
        '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', 'rev-parse', 'HEAD',
        *['HEAD:' + root for root in source['roots']]], cwd=REPO, env=environment,
        timeout=30, creationflags=subprocess.CREATE_NO_WINDOW).decode('ascii').splitlines()
    assert len(current) == 8 and dict(zip(source['roots'], current[1:])) == source['sevenRootGitTrees']
    return current[0]


def main():
    assert {p.name for p in BASE.iterdir()} == {'prepare_analysis_r9.py'}
    assert pin(TEMPLATE / 'proposal.json')['sha256'] == TEMPLATE_SHA
    template = json.loads(read(TEMPLATE / 'proposal.json'))
    old_rows = template['candidateFiles'] + template['controlRuntimeFiles'] + template['historicalMetadataFiles']
    assert len(old_rows) == 273
    for row in old_rows:
        verify(row, TEMPLATE)
    old_input = json.loads(read(Path(template['analysisInputs']['path'])))
    assert pin(FROZEN / 'out/seal-static-source.json')['sha256'] == SNAPSHOT_SEAL_SHA
    snapshot_seal = json.loads(read(FROZEN / 'out/seal-static-source.json'))
    assert snapshot_seal['sourceCommit'] == COMMIT and snapshot_seal['sourceFiles'] == 409
    assert len(snapshot_seal['files']) == snapshot_seal['fileCount'] == 423
    for row in snapshot_seal['files']:
        verify({**row, 'path': str(FROZEN / row['path'])})
    actual_snapshot = {p.relative_to(FROZEN).as_posix() for p in FROZEN.rglob('*') if p.is_file()}
    assert actual_snapshot == {r['path'] for r in snapshot_seal['files']} | {'out/seal-static-source.json'}
    source = json.loads(read(FROZEN / 'out/source-manifest.json'))
    assert source['head'] == COMMIT and source['sourceCount'] == 409
    observed_head = source_check_metadata(source, old_input)
    # R8 actually passed its old source; that acceptance never applies to r9.
    result = json.loads(read(TEMPLATE / 'attempt/result.json'))
    receipt = json.loads(read(TEMPLATE / 'attempt/receipt.json'))
    external = json.loads(read(TEMPLATE / 'attempt/external-observation-root.json'))
    final_gate = json.loads(read(TEMPLATE / 'attempt/root-final-system-gate.json'))
    launch = json.loads(read(TEMPLATE / 'attempt/launch.json'))
    assert result['status'] == 'FULL_GUARDIAN_ANALYZE_PASSED'
    assert receipt['status'] == 'FULL_GUARDIAN_ANALYZE_WORKER_PASSED'
    assert result['workerExitCode'] == 0 and result['ownedJobActiveProcessesFinal'] == 0
    assert not result['ownedCleanupPerformed'] and not result['watchdogExpired']
    assert not receipt['forcedTermination'] and receipt['noIssuesFound']
    assert external['actualToolSession'] == final_gate['actualSession'] == 95689
    assert external['finalToolChunk'] == final_gate['actualFinalChunk'] == 'af189a'
    assert external['naturalExitCode'] == final_gate['naturalExitCode'] == 0
    assert external['candidateAndRuntimeMetadataPinsMatched'] == 273
    assert external['diagnostics'] == {'errors': 0, 'warnings': 0, 'infos': 0}
    assert final_gate['status'] == 'FULL_GUARDIAN_ANALYZE_EXTERNALLY_ACCEPTED'
    assert final_gate['formalRelease'] and not final_gate['wholeProductAccepted']
    assert final_gate['sdkCount'] == final_gate['unknownProcessNameCount'] == final_gate['ownedJobActiveProcesses'] == 0
    assert result['elapsedCompleteSeconds'] < launch['workerElapsedAtLaunch'] + launch['commandBudgetSeconds']
    projection_raw = read(Path(old_input['cacheManifest']['path']))
    assert hashlib.sha256(projection_raw).hexdigest() == '3ca7ed28e9778c69360245186c96110d1a86e6bf7c621c5ea1a56bd4b19a3e84'
    projection = json.loads(projection_raw)
    verify(old_input['cacheProjectionParentManifest'])
    parent = json.loads(read(Path(old_input['cacheProjectionParentManifest']['path'])))
    excluded = projection['excludedFixedFiles']
    assert len(excluded) == 1 and Path(excluded[0]['path']) == Path(r'C:\Program Files\Google\Chrome\Application\chrome.exe')
    assert projection['trees'] == parent['trees'] and len(projection['trees']) == 70
    assert projection['fixedFiles'] == [row for row in parent['fixedFiles'] if row not in excluded]
    assert len(projection['fixedFiles']) == 32 and projection['totals'] == {'files': 3536, 'bytes': 633817159}
    projection_pin = create('cache-analysis-projection.json', projection_raw)
    inputs = copy.deepcopy(old_input)
    inputs.update(createdAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(), sourceCommit=COMMIT,
        sourceTreeSha256=source['sourceTreeSha256'], sourceManifest=pin(FROZEN / 'out/source-manifest.json'),
        dependencyLibraryPins=pin(FROZEN / 'out/dependency-library-pins.json'),
        candidatePackageConfig=pin(FROZEN / 'src/apps/guardian/.dart_tool/package_config.json'),
        candidatePackageConfigTemplate=pin(FROZEN / 'generated/guardian-package_config.json'),
        sevenRootGitTrees=source['sevenRootGitTrees'],
        sourceMembershipCheck={'main': {'files': 409, 'fullMembershipExact': True}, 'frozen': {'files': 409, 'fullMembershipExact': True}},
        cacheManifest=projection_pin,
        scope='Full Guardian lib/test analysis of committed a2b5ca6/409 via sealed current-r3-a2b5 snapshot; two test scheduling changes only; fatal infos and warnings; no selectors, test execution, pub, downloads, service changes or deployment.')
    input_pin = write_json('inputs.json', inputs)
    original_worker = read(TEMPLATE / 'worker.py').decode('utf-8')
    worker = original_worker
    replacements = [
        ("FROZEN = REPO / '.cache/guardian-observation-current-20261023-r2'", "FROZEN = REPO / '.cache/guardian-current-20261023-r3-a2b5'"),
        (template['analysisInputs']['sha256'], input_pin['sha256'])]
    for before, after in replacements:
        assert worker.count(before) == 1, before
        worker = worker.replace(before, after)
    old_tree, new_tree = ast.parse(original_worker), ast.parse(worker)
    assert len(old_tree.body) == len(new_tree.body)
    changed_nodes = []
    for before, after in zip(old_tree.body, new_tree.body):
        if ast.dump(before, include_attributes=False) == ast.dump(after, include_attributes=False):
            continue
        if isinstance(before, ast.Assign):
            assert len(before.targets) == len(after.targets) == 1
            assert isinstance(before.targets[0], ast.Name) and isinstance(after.targets[0], ast.Name)
            name = before.targets[0].id
            assert name == after.targets[0].id and name in {'FROZEN', 'INPUT_SHA256'}
            changed_nodes.append('assignment:' + name)
        else:
            raise AssertionError('R9 may change only the two fixed worker assignments')
    assert changed_nodes == ['assignment:FROZEN', 'assignment:INPUT_SHA256']
    before_source_check = next(n for n in old_tree.body if isinstance(n, ast.FunctionDef) and n.name == 'source_check')
    after_source_check = next(n for n in new_tree.body if isinstance(n, ast.FunctionDef) and n.name == 'source_check')
    assert ast.dump(before_source_check, include_attributes=False) == ast.dump(after_source_check, include_attributes=False)
    for name in ['controller.py', 'heap1536_windows_job.py']:
        raw = read(TEMPLATE / name)
        assert raw == read(ACCEPTED_LINEAGE / name), 'Controls differ from actually accepted r8'
        ast.parse(raw.decode('utf-8'), filename=name)
        create(name, raw)
    create('worker.py', worker.encode('utf-8'))
    create('mechanical-controller.py.diff', b'')
    create('mechanical-native-helper.py.diff', b'')
    create('mechanical-worker.py.diff', ''.join(difflib.unified_diff(
        original_worker.splitlines(keepends=True), worker.splitlines(keepends=True),
        fromfile='accepted-analysis-r8/worker.py', tofile='current-analysis409-r9/worker.py')).encode('utf-8'))
    write_json('ast-diff-proof.json', {'status': 'PYTHON_AST_STATIC_PROOF_NO_CONTROL_IMPORT',
        'changedTopLevelNodes': changed_nodes, 'onlyChangedFunction': None,
        'sourceCheckDifference': 'None; source_check remains exactly the r8 409-file boundary.',
        'allOtherWorkerNodesAstIdentical': True, 'allBudgetAndCleanupNodesUnchanged': True,
        'controllerByteIdentical': read(BASE / 'controller.py') == read(TEMPLATE / 'controller.py'),
        'nativeByteIdentical': read(BASE / 'heap1536_windows_job.py') == read(TEMPLATE / 'heap1536_windows_job.py'),
        'oldWorker': pin(TEMPLATE / 'worker.py'), 'newWorker': pin(BASE / 'worker.py')})
    changed_inputs = {key: {'before': old_input.get(key), 'after': inputs.get(key)} for key in sorted(set(old_input) | set(inputs)) if old_input.get(key) != inputs.get(key)}
    assert set(changed_inputs) == {'createdAtUtc', 'sourceCommit', 'sourceTreeSha256', 'sourceManifest',
        'dependencyLibraryPins', 'candidatePackageConfig', 'candidatePackageConfigTemplate',
        'sevenRootGitTrees', 'cacheManifest', 'scope'}
    write_json('input-metadata-diff.json', changed_inputs)
    preserved = [absolute(row, TEMPLATE) for row in old_rows]
    write_json('template-r8-pin-preservation.json', {'status': 'ALL_273_TEMPLATE_DESCRIPTORS_RETAINED',
        'templateProposal': pin(TEMPLATE / 'proposal.json', True), 'count': 273,
        'originalDescriptorListsRetainedVerbatimIn': str(TEMPLATE / 'proposal.json'),
        'absoluteHistoricalRowsInNewProposal': True, 'rawHistoricalCopiesCreated': 0,
        'externalRuntimeRehashPerformed': False})
    readme = '# Full Guardian analysis r9 — current source, static candidate UNRUN\n\nUses the new sealed409-file current-r3-a2b5 snapshot at a2b5ca6ef2398397e4208065090b7c1d65992358.\nRelative to old45950b88, exactly two test files changed by eight submission-scheduling adjustments;\n407 other source files stay exact. All80 literal names/7selectors and loop bindings stay exact;\nonly those two source pins and declaration lines were rebound. No source or cache copy is made here.\nOnly7internal roots among70packages rebase;63external rows and other metadata remain exact.\n\nR8 is actually accepted for its own older source (95689/af428c->af189a natural0, no diagnostics).\nR7 remains RED; original Browser80-r2 remains NOT_ACCEPTED. R8 static preparation UNRUN seals\nremain historical. No prior acceptance applies to r9 or to a future browser batch.\nController/native are byte exact r8. Worker differs only in FROZEN and INPUT_SHA256 AST assignments;\nall functions, source_check409, command, guards, environment and budgets are unchanged.\nAll273old descriptor occurrences are retained as absolute historical references, not copied raw.\nHistorical external runtime descriptors are not rehashed in this metadata preparation.\n\nSole command: flutter.bat --no-version-check --suppress-analytics analyze --no-pub --fatal-infos\n--fatal-warnings, no selectors/application tests. Outer180/soft174/worker165/commandcap150,\ncleanup5/postflight25 and dynamic strict worker-relative135/cleanup140 remain unchanged.\nAnalysis projection is byte exact3536files/633817159B/70trees/32fixedfiles; no cache content readback.\nFull source/package/cache/runtime pre/post and fresh Root resource gates are still mandatory at run.\nRequire natural native/worker/outer0, No issues found!, no forced actions, all private Jobs0 and\nindependent actual terminal/complete-bound proof. Cleanup cannot upgrade failure.\n\nThis preparer only reads Git/source/metadata, uses Python AST statically and writes this new cache.\nNo candidate import, SDK/Dart parser/compiler/formatter/test/browser/process-API/network/Main/Git\nmutation or attempt/grant occurred. Root independent review and new explicit grant are required.\nThe future Browser80-r3 is not sealed here; await actual current r9 PASS and formal release first.\n'
    create('README.md', readme.encode('utf-8'))
    source_metadata_rows = [absolute(row, FROZEN) for row in snapshot_seal['files'] if not row['path'].startswith('src/')]
    # The generated Guardian config under src/ is validated by worker.package_check.
    source_metadata_rows += [pin(FROZEN / 'src/apps/guardian/.dart_tool/package_config.json', True),
                             pin(FROZEN / 'out/seal-static-source.json', True)]
    actual_names = ['proposal.json', 'seal-receipt.json',
        'attempt/result.json', 'attempt/receipt.json', 'attempt/external-observation-root.json',
        'attempt/root-final-system-gate.json', 'attempt/launch.json',
        'attempt/preflight-pins.json', 'attempt/postflight-pins.json',
        'attempt/postflight-gate.json', 'attempt/out/analyze.log',
        'attempt/request.json', 'attempt/initial-gate.json',
        'attempt/launch-gate.json']
    historical = preserved + [pin(TEMPLATE / name, True) for name in actual_names] + source_metadata_rows
    for name in ['docs/evidence/guardian-full-analysis-20261023-r8/archive-inventory.json',
                 'docs/evidence/guardian-full-analysis-20261023-r8/summary.json']:
        historical.append(pin(REPO / name, True))
    historical += [pin(BASE / 'inputs.json', True), pin(BASE / 'cache-analysis-projection.json', True)]
    review = {'status': 'STATIC_ANALYSIS409_R9_ROOT_REVIEW_REQUIRED_UNRUN', 'createdAtUtc': inputs['createdAtUtc'],
        'sourceCommit': COMMIT, 'sourceFiles': 409, 'sourceManifest': inputs['sourceManifest'],
        'sourceSnapshotSeal': pin(FROZEN / 'out/seal-static-source.json'), 'sourceTreeSha256': source['sourceTreeSha256'],
        'observedCurrentHead': observed_head, 'sharedSnapshot': str(FROZEN / 'src'),
        'fullMainAndFrozenRawAndMembershipMatch': True, 'packageRows': 70,
        'controllerByteIdentical': True, 'nativeHelperByteIdentical': True,
        'workerChangedFunctions': [], 'workerChangedAssignments': ['FROZEN', 'INPUT_SHA256'],
        'allBudgetNodesUnchanged': True, 'cacheProjection': projection_pin,
        'cacheFiles': 3536, 'cacheBytes': 633817159, 'cacheTrees': 70, 'fixedRuntimeFiles': 32,
        'runtimeCacheContentsNotRehashedDuringPreparation': True, 'templateDescriptorsPreserved': 273,
        'mechanicalTemplateActuallyAccepted': True, 'mechanicalTemplateActualStatus': 'FULL_GUARDIAN_ANALYZE_PASSED',
        'actualAcceptedControlLineage': 'r8', 'acceptedControlLineageActuallyAccepted': True,
        'oldActualAcceptanceAppliesToThisCandidate': False,
        'acceptedR8Evidence': {'proposal': pin(TEMPLATE / 'proposal.json'),
            'result': pin(TEMPLATE / 'attempt/result.json'),
            'externalReadback': pin(TEMPLATE / 'attempt/external-observation-root.json'),
            'finalSystemGate': pin(TEMPLATE / 'attempt/root-final-system-gate.json'),
            'actualSession': 95689, 'finalChunk': 'af189a', 'naturalExitCode': 0},
        'priorR7RemainsNotAccepted': True, 'priorBrowser80R2RemainsNotAccepted': True,
        'outerBudgetSeconds': 180, 'outerSoftCutoffSeconds': 174, 'workerBudgetSeconds': 165,
        'commandCapSeconds': 150, 'commandCleanupReserveSeconds': 5, 'minimumPostflightReserveSeconds': 25,
        'dynamicCommandDeadlineWorkerRelativeMaxSeconds': 135, 'dynamicCleanupWorkerRelativeMaxSeconds': 140,
        'sourceCopied': False, 'cacheCopied': False, 'candidateImported': False,
        'sdkCalls': 0, 'testsRun': False, 'browserStarted': False, 'networkUsed': False,
        'mainWritten': False, 'gitWritten': False, 'attemptExists': False}
    write_json('static-review.json', review)
    proposal = copy.deepcopy(template)
    proposal.update(status='STATIC_ANALYSIS409_R9_CANDIDATE_ONLY_ROOT_REVIEW_REQUIRED',
        sourceCommit=COMMIT, sourceFiles=409, sevenRootGitTrees=inputs['sevenRootGitTrees'],
        analysisInputs={**input_pin, 'absolute': True}, workingDirectory=str(FROZEN / 'src/apps/guardian'),
        attemptDirectory=str(BASE / 'attempt'), sharedSourceSnapshot=str(FROZEN / 'src'),
        preparationScript=pin(BASE / 'prepare_analysis_r9.py'), preparationRootApprovedCommit=COMMIT,
        cacheManifestSha256=projection_pin['sha256'], actualAcceptedTemplate=pin(ACCEPTED_LINEAGE / 'proposal.json', True),
        mechanicalControlTemplate=pin(TEMPLATE / 'proposal.json', True),
        mechanicalTemplateActualStatus='FULL_GUARDIAN_ANALYZE_PASSED',
        sourceSnapshotSeal=pin(FROZEN / 'out/seal-static-source.json', True), executionApproved=False,
        sdkCalls=0, testsRun=False, runtimeWatchdogVerifiedForThisCandidate=False)
    files = ['controller.py', 'worker.py', 'heap1536_windows_job.py', 'prepare_analysis_r9.py', 'README.md',
        'mechanical-controller.py.diff', 'mechanical-worker.py.diff', 'mechanical-native-helper.py.diff',
        'input-metadata-diff.json', 'ast-diff-proof.json', 'template-r8-pin-preservation.json', 'static-review.json']
    proposal['candidateFiles'] = [{**pin(BASE / name), 'path': name} for name in files]
    proposal['historicalMetadataFiles'] = historical
    assert proposal['controlRuntimeFiles'] == template['controlRuntimeFiles']
    budget_keys = ['outerBudgetSeconds', 'terminationReserveSeconds', 'outerSoftCutoffSeconds',
        'workerBudgetSeconds', 'commandCapSeconds', 'commandCleanupReserveSeconds',
        'minimumPostflightReserveSeconds', 'minimumRamBytes', 'minimumEachDiskBytes',
        'dynamicCommandDeadlineWorkerRelativeMaxSeconds', 'dynamicCleanupWorkerRelativeMaxSeconds']
    assert all(proposal[key] == template[key] for key in budget_keys)
    assert proposal['command'] == template['command'] and proposal['noSelectors'] and proposal['noPub']
    for row in proposal['candidateFiles'] + proposal['controlRuntimeFiles'] + historical:
        verify(row, BASE)
    assert source_check_metadata(source, inputs)
    proposal_pin = write_json('proposal.json', proposal)
    seal = {'status': 'STATIC_ANALYSIS409_R9_SEALED_ROOT_REVIEW_REQUIRED_UNRUN', 'proposal': proposal_pin,
        'inputs': input_pin, 'sourceManifest': inputs['sourceManifest'],
        'sourceSnapshotSeal': pin(FROZEN / 'out/seal-static-source.json'),
        'candidatePackageConfig': inputs['candidatePackageConfig'], 'cacheManifest': projection_pin,
        'candidateFiles': len(files), 'controlRuntimeFiles': len(proposal['controlRuntimeFiles']),
        'historicalMetadataFiles': len(historical), 'originalR8DescriptorsPreserved': 273,
        'mechanicalR8AnalysisAccepted': True, 'actualAcceptedControlLineage': 'r8',
        'oldAcceptanceAppliesToCurrentSource': False, 'priorR7RemainsNotAccepted': True,
        'sourceFiles': 409, 'cacheFiles': 3536, 'outerBudgetSeconds': 180,
        'workerBudgetSeconds': 165, 'commandCapSeconds': 150, 'sdkCalls': 0,
        'testsRun': False, 'browserStarted': False, 'candidateImported': False,
        'sourceCopied': False, 'cacheCopied': False, 'executionApproved': False, 'attemptExists': False}
    seal_pin = write_json('seal-receipt.json', seal)
    assert not (BASE / 'attempt').exists() and not (BASE / 'src').exists()
    print(json.dumps({**seal, 'seal': seal_pin}, ensure_ascii=False))


if __name__ == '__main__':
    main()
