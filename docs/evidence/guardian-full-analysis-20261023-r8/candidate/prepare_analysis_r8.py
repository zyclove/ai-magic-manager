"""CreateNew r8 metadata/control adaptation only; no source/cache copy or SDK."""
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
TEMPLATE = REPO / '.cache/guardian-analyze-20261023-r7'
ACCEPTED_LINEAGE = REPO / '.cache/guardian-analyze-20261023-r6'
FROZEN = REPO / '.cache/guardian-observation-current-20261023-r2'
COMMIT = '45950b88a270e2fded2409e333fb126851b6f861'
TEMPLATE_SHA = '2c1c4e32c0255b3a3eaa4272058ef5eb5f2e5388e5eb58b45d5a1ceb6d37ef36'
SNAPSHOT_SEAL_SHA = 'cb7b531b176433c2b1e8ed5154d49710a53a642268f9296816a9af07f8139957'


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
    assert {p.name for p in BASE.iterdir()} == {'prepare_analysis_r8.py'}
    assert pin(TEMPLATE / 'proposal.json')['sha256'] == TEMPLATE_SHA
    template = json.loads(read(TEMPLATE / 'proposal.json'))
    old_rows = template['candidateFiles'] + template['controlRuntimeFiles'] + template['historicalMetadataFiles']
    assert len(old_rows) == 212
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
    # R7 is the mechanically reviewed baseline but its actual analysis is RED.
    result = json.loads(read(TEMPLATE / 'attempt/result.json'))
    receipt = json.loads(read(TEMPLATE / 'attempt/receipt.json'))
    external = json.loads(read(TEMPLATE / 'attempt/external-red-readback-root.json'))
    final_gate = json.loads(read(TEMPLATE / 'attempt/root-final-system-gate.json'))
    launch = json.loads(read(TEMPLATE / 'attempt/launch.json'))
    assert result['status'] == receipt['status'] == 'NOT_ACCEPTED'
    assert result['workerExitCode'] == 1 and result['ownedJobActiveProcessesFinal'] == 0
    assert not result['ownedCleanupPerformed'] and not result['watchdogExpired']
    assert not receipt['forcedTermination'] and not receipt['noIssuesFound']
    assert external['status'] == 'R7_ANALYSIS_RED_INDEPENDENTLY_CONFIRMED_AWAIT_FRESH_SYSTEM_RELEASE'
    assert external['actualSession'] == final_gate['actualSession'] == 1854
    assert external['finalChunk'] == final_gate['actualFinalChunk'] == 'dff5b1'
    assert external['naturalExitCode'] == final_gate['naturalExitCode'] == 1
    assert external['pinsMatched'] == 212 and external['analysisAccepted'] is False
    assert external['diagnostics'] == {'errors': 0, 'warnings': 1, 'infos': 0}
    assert final_gate['status'] == 'R7_ANALYSIS_RED_WINDOW_FORMALLY_RELEASED'
    assert final_gate['formalRelease'] and final_gate['analysisAccepted'] is False
    assert final_gate['sdkCount'] == final_gate['unknownProcessNameCount'] == final_gate['ownedJobActiveProcesses'] == 0
    assert result['elapsedCompleteSeconds'] < launch['workerElapsedAtLaunch'] + launch['commandBudgetSeconds']

    # Actual accepted lineage is separately verified from r6, never inherited from RED r7.
    accepted_result = json.loads(read(ACCEPTED_LINEAGE / 'attempt/result.json'))
    accepted_receipt = json.loads(read(ACCEPTED_LINEAGE / 'attempt/receipt.json'))
    accepted_gate = json.loads(read(ACCEPTED_LINEAGE / 'attempt/root-final-system-gate.json'))
    assert accepted_result['status'] == 'FULL_GUARDIAN_ANALYZE_PASSED' and accepted_result['workerExitCode'] == 0
    assert accepted_result['ownedJobActiveProcessesFinal'] == 0 and not accepted_result['ownedCleanupPerformed']
    assert not accepted_result['watchdogExpired'] and not accepted_receipt['forcedTermination']
    assert accepted_receipt['status'] == 'FULL_GUARDIAN_ANALYZE_WORKER_PASSED'
    assert accepted_gate['status'] == 'FULL_GUARDIAN_ANALYZE_EXTERNALLY_ACCEPTED' and accepted_gate['formalRelease']
    assert accepted_gate['actualSession'] == 35555 and accepted_gate['actualFinalChunk'] == 'c6f353'
    assert accepted_gate['naturalExitCode'] == accepted_gate['sdkCount'] == accepted_gate['unknownProcessNameCount'] == 0
    assert accepted_gate['ownedJobActiveProcesses'] == 0
    assert pin(ACCEPTED_LINEAGE / 'proposal.json')['sha256'] == 'b4cf7534705500f7a3dd1cd825a2c314bbb5654295e63aa21b007b496cffb7b5'
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
        scope='Full Guardian lib/test analysis of committed 45950b88/409 via the corrected sealed observation-current r2 snapshot; fatal infos and warnings; no selectors, test execution, pub, downloads, service changes or deployment.')
    input_pin = write_json('inputs.json', inputs)
    original_worker = read(TEMPLATE / 'worker.py').decode('utf-8')
    worker = original_worker
    replacements = [
        ("FROZEN = REPO / '.cache/guardian-observation-current-20261023-r1'", "FROZEN = REPO / '.cache/guardian-observation-current-20261023-r2'"),
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
            raise AssertionError('R8 may change only the two fixed worker assignments')
    assert changed_nodes == ['assignment:FROZEN', 'assignment:INPUT_SHA256']
    before_source_check = next(n for n in old_tree.body if isinstance(n, ast.FunctionDef) and n.name == 'source_check')
    after_source_check = next(n for n in new_tree.body if isinstance(n, ast.FunctionDef) and n.name == 'source_check')
    assert ast.dump(before_source_check, include_attributes=False) == ast.dump(after_source_check, include_attributes=False)
    for name in ['controller.py', 'heap1536_windows_job.py']:
        raw = read(TEMPLATE / name)
        assert raw == read(ACCEPTED_LINEAGE / name), 'Controls differ from actually accepted r6'
        ast.parse(raw.decode('utf-8'), filename=name)
        create(name, raw)
    create('worker.py', worker.encode('utf-8'))
    create('mechanical-controller.py.diff', b'')
    create('mechanical-native-helper.py.diff', b'')
    create('mechanical-worker.py.diff', ''.join(difflib.unified_diff(
        original_worker.splitlines(keepends=True), worker.splitlines(keepends=True),
        fromfile='red-analysis-r7/worker.py', tofile='corrected-analysis409-r8/worker.py')).encode('utf-8'))
    write_json('ast-diff-proof.json', {'status': 'PYTHON_AST_STATIC_PROOF_NO_CONTROL_IMPORT',
        'changedTopLevelNodes': changed_nodes, 'onlyChangedFunction': None,
        'sourceCheckDifference': 'None; source_check remains exactly the r7 409-file boundary.',
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
    write_json('template-r7-pin-preservation.json', {'status': 'ALL_212_TEMPLATE_PINS_RETAINED',
        'templateProposal': pin(TEMPLATE / 'proposal.json', True), 'originalRows': old_rows,
        'absoluteRowsForNewHistoricalList': preserved, 'count': 212,
        'pathResolutionOnlyChangedForHistoricalReference': True})
    readme = '# Full Guardian analysis r8 — corrected source, static candidate UNRUN\n\nThis candidate directly reuses the sealed 409-file observation-current r2 snapshot\nat commit45950b88a270e2fded2409e333fb126851b6f861. Relative to the original a558\n409-file source, exactly one redundant ! was removed; the other408 files and all80\ncase/7 selected-source declaration metadata are unchanged. No source or cache\ncontents are copied by this analysis preparer. Only seven internal package roots\nare rebound; all70 mappings and63 external rows remain required.\n\nR7 is the mechanical control baseline and remains actual NOT_ACCEPTED: one\nunnecessary_non_null_assertion warning, natural1, no timeout/forced cleanup.\nIts complete212 proposal pins, actual RED receipts/readback/formal release and\ncommitted fix provenance are preserved. It is never called actually accepted.\nThe actually accepted control lineage is r6 (actual35555/c6f353 natural0).\nController/native bytes are identical to both r6 and r7. Relative to r7, worker\nchanges only FROZEN and INPUT_SHA256; source_check409 and every other AST node,\ncommand, guard, deadline and cleanup are unchanged. New r8 acceptance is UNRUN.\n\nThe sole command is flutter.bat --no-version-check --suppress-analytics analyze\n--no-pub --fatal-infos --fatal-warnings without selectors. It analyzes the entire\nGuardian lib/test source but runs no application tests. All80 browser cases in7\nsuites remain UNRUN; prior accepted analysis never substitutes for those cases.\n\nBudgets stay outer180/soft174/worker165/commandcap150/cleanup5/postflight25.\nDynamic worker-relative command deadline is at most135 and cleanup at most140.\nThe analysis cache projection remains byte-identical3536 files/633817159 bytes,\n70 trees/32 fixed files; only metadata is copied, not cache contents. This is not\na browser cache projection (browser needs its separately pinned Chrome row).\nHistorical seed access errors remain historical, not a new cache acceptance.\n\nFull source/Main membership and raw pins, Git trees/blobs, package mappings,\nruntime/bootstrap, cache pre/post and RAM/C:/D:2GiB gates still apply. Root must\nindependently review, obtain fresh SDK0/unknown0 and grant this exact proposal.\nNo resource snapshot or previous r7/browser grant authorizes execution.\n\nRequire natural native/worker/outer0, No issues found!, no timeout/forced action,\nall private Jobs0, complete pre/post and actual external terminal observation.\nThe complete outer elapsed must be below launch.workerElapsedAtLaunch plus\nlaunch.commandBudgetSeconds, or additional actual terminal proof is required.\nCleanup never upgrades a failed result. ExecutionApproved=false; no attempt,\ncandidate imports, SDK/browser/test/pub/network/download/service/Git/Main writes\nor automatic chaining occurred. Python AST work is not Dart parsing or testing.\n'
    create('README.md', readme.encode('utf-8'))
    source_metadata_rows = [absolute(row, FROZEN) for row in snapshot_seal['files'] if not row['path'].startswith('src/')]
    # The generated Guardian config under src/ is validated by worker.package_check.
    source_metadata_rows += [pin(FROZEN / 'src/apps/guardian/.dart_tool/package_config.json', True),
                             pin(FROZEN / 'out/seal-static-source.json', True)]
    actual_names = ['proposal.json', 'seal-receipt.json',
        'attempt/result.json', 'attempt/receipt.json', 'attempt/external-red-readback-root.json',
        'attempt/root-final-system-gate.json', 'attempt/launch.json',
        'attempt/preflight-pins.json', 'attempt/postflight-pins.json',
        'attempt/postflight-gate.json', 'attempt/out/analyze.log',
        'root-static-review.json', 'attempt/request.json', 'attempt/initial-gate.json',
        'attempt/launch-gate.json']
    historical = preserved + [pin(TEMPLATE / name, True) for name in actual_names] + source_metadata_rows
    for name in ['.cache/guardian-analyze-r7-red-readback-root-20261023.py',
                 'docs/evidence/guardian-full-analysis-20261023-r7/archive-inventory.json',
                 'docs/evidence/guardian-full-analysis-20261023-r7/summary.json',
                 'docs/evidence/guardian-full-analysis-20261023-r7/fix/root-one-character-fix-receipt.json',
                 'docs/evidence/guardian-full-analysis-20261023-r7/fix/independent-static-review.md',
                 'docs/evidence/guardian-full-analysis-20261023-r7/fix/independent-static-review.json']:
        historical.append(pin(REPO / name, True))
    historical += [pin(BASE / 'inputs.json', True), pin(BASE / 'cache-analysis-projection.json', True)]
    review = {'status': 'STATIC_ANALYSIS409_R8_ROOT_REVIEW_REQUIRED_UNRUN', 'createdAtUtc': inputs['createdAtUtc'],
        'sourceCommit': COMMIT, 'sourceFiles': 409, 'sourceManifest': inputs['sourceManifest'],
        'sourceSnapshotSeal': pin(FROZEN / 'out/seal-static-source.json'), 'sourceTreeSha256': source['sourceTreeSha256'],
        'observedCurrentHead': observed_head, 'sharedSnapshot': str(FROZEN / 'src'),
        'fullMainAndFrozenRawAndMembershipMatch': True, 'packageRows': 70,
        'controllerByteIdentical': True, 'nativeHelperByteIdentical': True,
        'workerChangedFunctions': [], 'workerChangedAssignments': ['FROZEN', 'INPUT_SHA256'],
        'allBudgetNodesUnchanged': True, 'cacheProjection': projection_pin,
        'cacheFiles': 3536, 'cacheBytes': 633817159, 'cacheTrees': 70, 'fixedRuntimeFiles': 32,
        'runtimeCacheContentsNotRehashedDuringPreparation': True, 'templatePinsMatched': 212,
        'mechanicalTemplateActuallyAccepted': False, 'mechanicalTemplateActualStatus': 'NOT_ACCEPTED',
        'actualAcceptedControlLineage': 'r6', 'acceptedControlLineageActuallyAccepted': True,
        'oldActualAcceptanceAppliesToThisCandidate': False,
        'r7RedEvidence': {'observerStatus': external['status'],
            'finalSystemGate': pin(TEMPLATE / 'attempt/root-final-system-gate.json'),
            'actualSession': final_gate['actualSession'], 'finalChunk': final_gate['actualFinalChunk'],
            'naturalExitCode': 1, 'analysisAccepted': False, 'formalRelease': final_gate['formalRelease']},
        'acceptedR6Evidence': {'proposal': pin(ACCEPTED_LINEAGE / 'proposal.json'),
            'result': pin(ACCEPTED_LINEAGE / 'attempt/result.json'),
            'finalSystemGate': pin(ACCEPTED_LINEAGE / 'attempt/root-final-system-gate.json'),
            'actualSession': 35555, 'finalChunk': 'c6f353', 'naturalExitCode': 0},
        'outerBudgetSeconds': 180, 'outerSoftCutoffSeconds': 174, 'workerBudgetSeconds': 165,
        'commandCapSeconds': 150, 'commandCleanupReserveSeconds': 5, 'minimumPostflightReserveSeconds': 25,
        'dynamicCommandDeadlineWorkerRelativeMaxSeconds': 135, 'dynamicCleanupWorkerRelativeMaxSeconds': 140,
        'sourceCopied': False, 'cacheCopied': False, 'candidateImported': False,
        'sdkCalls': 0, 'testsRun': False, 'browserStarted': False, 'networkUsed': False,
        'mainWritten': False, 'gitWritten': False, 'attemptExists': False}
    write_json('static-review.json', review)
    proposal = copy.deepcopy(template)
    proposal.update(status='STATIC_ANALYSIS409_R8_CANDIDATE_ONLY_ROOT_REVIEW_REQUIRED',
        sourceCommit=COMMIT, sourceFiles=409, sevenRootGitTrees=inputs['sevenRootGitTrees'],
        analysisInputs={**input_pin, 'absolute': True}, workingDirectory=str(FROZEN / 'src/apps/guardian'),
        attemptDirectory=str(BASE / 'attempt'), sharedSourceSnapshot=str(FROZEN / 'src'),
        preparationScript=pin(BASE / 'prepare_analysis_r8.py'), preparationRootApprovedCommit=COMMIT,
        cacheManifestSha256=projection_pin['sha256'], actualAcceptedTemplate=pin(ACCEPTED_LINEAGE / 'proposal.json', True),
        mechanicalControlTemplate=pin(TEMPLATE / 'proposal.json', True),
        mechanicalTemplateActualStatus='NOT_ACCEPTED',
        sourceSnapshotSeal=pin(FROZEN / 'out/seal-static-source.json', True), executionApproved=False,
        sdkCalls=0, testsRun=False, runtimeWatchdogVerifiedForThisCandidate=False)
    files = ['controller.py', 'worker.py', 'heap1536_windows_job.py', 'prepare_analysis_r8.py', 'README.md',
        'mechanical-controller.py.diff', 'mechanical-worker.py.diff', 'mechanical-native-helper.py.diff',
        'input-metadata-diff.json', 'ast-diff-proof.json', 'template-r7-pin-preservation.json', 'static-review.json']
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
    seal = {'status': 'STATIC_ANALYSIS409_R8_SEALED_ROOT_REVIEW_REQUIRED_UNRUN', 'proposal': proposal_pin,
        'inputs': input_pin, 'sourceManifest': inputs['sourceManifest'],
        'sourceSnapshotSeal': pin(FROZEN / 'out/seal-static-source.json'),
        'candidatePackageConfig': inputs['candidatePackageConfig'], 'cacheManifest': projection_pin,
        'candidateFiles': len(files), 'controlRuntimeFiles': len(proposal['controlRuntimeFiles']),
        'historicalMetadataFiles': len(historical), 'originalR7PinsPreserved': 212,
        'mechanicalR7AnalysisAccepted': False, 'actualAcceptedControlLineage': 'r6',
        'sourceFiles': 409, 'cacheFiles': 3536, 'outerBudgetSeconds': 180,
        'workerBudgetSeconds': 165, 'commandCapSeconds': 150, 'sdkCalls': 0,
        'testsRun': False, 'browserStarted': False, 'candidateImported': False,
        'sourceCopied': False, 'cacheCopied': False, 'executionApproved': False, 'attemptExists': False}
    seal_pin = write_json('seal-receipt.json', seal)
    assert not (BASE / 'attempt').exists() and not (BASE / 'src').exists()
    print(json.dumps({**seal, 'seal': seal_pin}, ensure_ascii=False))


if __name__ == '__main__':
    main()
