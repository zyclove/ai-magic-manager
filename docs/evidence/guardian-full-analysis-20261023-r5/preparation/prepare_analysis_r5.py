"""CreateNew r5 metadata/control adaptation only; no source/cache copy or SDK."""
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
TEMPLATE = REPO / '.cache/guardian-analyze-20261023-r4'
FROZEN = REPO / '.cache/guardian-classification-current-20261023-r1'
COMMIT = '1ca1f7fc4cddefca6f711bea0ae90f3cb8c89f9e'
TEMPLATE_SHA = 'ee65482a8f848e92d74d884379d971f2525b943989c06e04dc17aa7840c68779'
SNAPSHOT_SEAL_SHA = '576a2d5d0644b91967a4b2dec81b15eeabedaac3cbfbb70f8a235593daf9829d'


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
    assert len(expected) == len(source['sourceFiles']) == source['sourceCount'] == 407
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
    assert {p.name for p in BASE.iterdir()} == {'prepare_analysis_r5.py'}
    assert pin(TEMPLATE / 'proposal.json')['sha256'] == TEMPLATE_SHA
    template = json.loads(read(TEMPLATE / 'proposal.json'))
    old_rows = template['candidateFiles'] + template['controlRuntimeFiles'] + template['historicalMetadataFiles']
    assert len(old_rows) == 50
    for row in old_rows:
        verify(row, TEMPLATE)
    old_input = json.loads(read(Path(template['analysisInputs']['path'])))
    assert pin(FROZEN / 'out/seal-static-source.json')['sha256'] == SNAPSHOT_SEAL_SHA
    snapshot_seal = json.loads(read(FROZEN / 'out/seal-static-source.json'))
    assert snapshot_seal['sourceCommit'] == COMMIT and snapshot_seal['sourceFiles'] == 407
    assert len(snapshot_seal['files']) == snapshot_seal['fileCount'] == 421
    for row in snapshot_seal['files']:
        verify({**row, 'path': str(FROZEN / row['path'])})
    actual_snapshot = {p.relative_to(FROZEN).as_posix() for p in FROZEN.rglob('*') if p.is_file()}
    assert actual_snapshot == {r['path'] for r in snapshot_seal['files']} | {'out/seal-static-source.json'}
    source = json.loads(read(FROZEN / 'out/source-manifest.json'))
    assert source['head'] == COMMIT and source['sourceCount'] == 407
    observed_head = source_check_metadata(source, old_input)
    result = json.loads(read(TEMPLATE / 'attempt/result.json'))
    receipt = json.loads(read(TEMPLATE / 'attempt/receipt.json'))
    external = json.loads(read(TEMPLATE / 'attempt/external-observation-root.json'))
    launch = json.loads(read(TEMPLATE / 'attempt/launch.json'))
    assert result['status'] == 'FULL_GUARDIAN_ANALYZE_PASSED' and result['workerExitCode'] == 0
    assert result['ownedJobActiveProcessesFinal'] == 0 and not result['ownedCleanupPerformed'] and not result['watchdogExpired']
    assert receipt['status'] == 'FULL_GUARDIAN_ANALYZE_WORKER_PASSED' and not receipt['forcedTermination']
    assert external['status'] == 'FULL_GUARDIAN_ANALYZE_EXTERNALLY_ACCEPTED' and external['fullAnalysisAccepted']
    assert external['actualNaturalExitCode'] == 0 and external['candidateAndRuntimeMetadataPinsMatched'] == 50
    assert external['diagnostics'] == {'errors': 0, 'warnings': 0, 'infos': 0}
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
        sourceMembershipCheck={'main': {'files': 407, 'fullMembershipExact': True}, 'frozen': {'files': 407, 'fullMembershipExact': True}},
        cacheManifest=projection_pin,
        scope='Full Guardian lib/test analysis of committed 1ca1f7fc/407 via the sealed classification-current snapshot; fatal infos and warnings; no selectors, test execution, pub, downloads, service changes or deployment.')
    input_pin = write_json('inputs.json', inputs)
    original_worker = read(TEMPLATE / 'worker.py').decode('utf-8')
    worker = original_worker
    replacements = [
        ("FROZEN = REPO / '.cache/guardian-browser38-20261023-r1'", "FROZEN = REPO / '.cache/guardian-classification-current-20261023-r1'"),
        (template['analysisInputs']['sha256'], input_pin['sha256']),
        ("len(rows) == 406 and manifest['sourceCount'] == 406", "len(rows) == 407 and manifest['sourceCount'] == 407"),
        ('Frozen seven-root/406 source boundary changed', 'Frozen seven-root/407 source boundary changed'),
        ('len(expected) == 406', 'len(expected) == 407')]
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
            assert isinstance(before, ast.FunctionDef) and isinstance(after, ast.FunctionDef)
            assert before.name == after.name == 'source_check'
            class BoundaryOnly(ast.NodeTransformer):
                def visit_Constant(self, node):
                    if node.value == 406:
                        return ast.copy_location(ast.Constant(407), node)
                    if node.value == 'Frozen seven-root/406 source boundary changed':
                        return ast.copy_location(ast.Constant('Frozen seven-root/407 source boundary changed'), node)
                    return node
            expected_function = BoundaryOnly().visit(copy.deepcopy(before))
            assert ast.dump(expected_function, include_attributes=False) == ast.dump(after, include_attributes=False)
            changed_nodes.append('function:source_check')
    assert changed_nodes == ['assignment:FROZEN', 'assignment:INPUT_SHA256', 'function:source_check']
    for name in ['controller.py', 'heap1536_windows_job.py']:
        raw = read(TEMPLATE / name)
        ast.parse(raw.decode('utf-8'), filename=name)
        create(name, raw)
    create('worker.py', worker.encode('utf-8'))
    create('mechanical-controller.py.diff', b'')
    create('mechanical-native-helper.py.diff', b'')
    create('mechanical-worker.py.diff', ''.join(difflib.unified_diff(
        original_worker.splitlines(keepends=True), worker.splitlines(keepends=True),
        fromfile='accepted-analysis-r4/worker.py', tofile='analysis407-r5/worker.py')).encode('utf-8'))
    write_json('ast-diff-proof.json', {'status': 'PYTHON_AST_STATIC_PROOF_NO_CONTROL_IMPORT',
        'changedTopLevelNodes': changed_nodes, 'onlyChangedFunction': 'source_check',
        'sourceCheckDifference': 'Only three 406 integer literals and its 406 reason text become 407.',
        'allOtherWorkerNodesAstIdentical': True, 'allBudgetAndCleanupNodesUnchanged': True,
        'controllerByteIdentical': read(BASE / 'controller.py') == read(TEMPLATE / 'controller.py'),
        'nativeByteIdentical': read(BASE / 'heap1536_windows_job.py') == read(TEMPLATE / 'heap1536_windows_job.py'),
        'oldWorker': pin(TEMPLATE / 'worker.py'), 'newWorker': pin(BASE / 'worker.py')})
    changed_inputs = {key: {'before': old_input.get(key), 'after': inputs.get(key)} for key in sorted(set(old_input) | set(inputs)) if old_input.get(key) != inputs.get(key)}
    assert set(changed_inputs) == {'createdAtUtc', 'sourceCommit', 'sourceTreeSha256', 'sourceManifest',
        'dependencyLibraryPins', 'candidatePackageConfig', 'candidatePackageConfigTemplate',
        'sevenRootGitTrees', 'sourceMembershipCheck', 'cacheManifest', 'scope'}
    write_json('input-metadata-diff.json', changed_inputs)
    preserved = [absolute(row, TEMPLATE) for row in old_rows]
    write_json('template-r4-pin-preservation.json', {'status': 'ALL_FIFTY_TEMPLATE_PINS_RETAINED',
        'templateProposal': pin(TEMPLATE / 'proposal.json', True), 'originalRows': old_rows,
        'absoluteRowsForNewHistoricalList': preserved, 'count': 50,
        'pathResolutionOnlyChangedForHistoricalReference': True})
    readme = '''# Full Guardian analysis r5 — static candidate, UNRUN

This candidate reuses the sealed 407-file seven-root snapshot at commit
1ca1f7fc4cddefca6f711bea0ae90f3cb8c89f9e. It copies no source tree and no cache
contents. Full Main/frozen membership, raw SHA-256, Git trees and blobs, and all
70 package mappings remain required before and after the command.

The only command is flutter.bat --no-version-check --suppress-analytics analyze
--no-pub --fatal-infos --fatal-warnings, without file selectors, from the frozen
Guardian package. It analyzes the full Guardian source and tests; it executes no
application tests. The prior accepted r4 result covers source406 only. All new
source407 analysis and prepared browser46 cases remain UNRUN.

Controller and native helper are byte identical to actually accepted r4. Worker
AST differs only in FROZEN path, INPUT_SHA256, and the source_check boundary 406
to 407. Every other worker node, including budget, runtime/cache checks, command
and cleanup, is unchanged. This adaptation does not repeat any budget rewrites.

Budget remains outer180 / soft174 / worker165 / commandcap150 / cleanup5 and
complete postflight reserve25 seconds. The dynamic command deadline is at most
worker-relative135 seconds and cleanup at most140. Full preflight consumes part
of this allocation. RAM and each C:/D: minimum remain2GiB. Fresh SDK0/unknown0
and an explicit Root grant are required; a resource snapshot never grants a run.

The analysis-only cache projection is byte identical to r4: the historical parent
minus only Chrome unused by analyze, preserving70 trees,32 fixed files and3536
file pins /633817159 bytes. Projection metadata is copied; runtime contents are
not freshly rehashed during this preparation. Full pre/post rehash is mandatory
at execution. Historical dependency seed access errors remain historical facts.

All50 r4 proposal pins are retained as historical references, plus its proposal,
seal and actual result/receipt/launch/log/external observer evidence. The new
snapshot seal and every non-source metadata file under that seal are pinned too.
No inherited acceptance is claimed for this new candidate.

Acceptance requires natural native and worker/outer exit0, No issues found!,
fatal warnings/infos, no timeout or forced termination, retained process handle
terminal state, all private Jobs0, complete source/package/cache/runtime postflight
and fresh resource gates. Root must independently check actual terminal output
and the strict complete outer elapsed bound against launch.workerElapsedAtLaunch
+ launch.commandBudgetSeconds, or require actual terminal timing evidence.
Cleanup never upgrades a failed or timed-out result.

executionApproved=false; no attempt directory, candidate import, SDK call,
application test, browser, pub, download, network call, Main/Git write, service
change, deployment or automatic chaining occurred. Python AST parsing is not Dart
parsing, type checking or application test execution. Root independently reviews
and authorizes any later run.
'''
    create('README.md', readme.encode('utf-8'))
    source_metadata_rows = [absolute(row, FROZEN) for row in snapshot_seal['files'] if not row['path'].startswith('src/')]
    # The generated Guardian config under src/ is validated by worker.package_check.
    source_metadata_rows += [pin(FROZEN / 'src/apps/guardian/.dart_tool/package_config.json', True),
                             pin(FROZEN / 'out/seal-static-source.json', True)]
    actual_names = ['proposal.json', 'seal-receipt.json', 'external_observe_root.py',
        'attempt/result.json', 'attempt/receipt.json', 'attempt/external-observation-root.json',
        'attempt/launch.json', 'attempt/preflight-pins.json', 'attempt/postflight-pins.json',
        'attempt/postflight-gate.json', 'attempt/out/analyze.log']
    historical = preserved + [pin(TEMPLATE / name, True) for name in actual_names] + source_metadata_rows
    historical += [pin(BASE / 'inputs.json', True), pin(BASE / 'cache-analysis-projection.json', True)]
    review = {'status': 'STATIC_ANALYSIS407_R5_ROOT_REVIEW_REQUIRED_UNRUN', 'createdAtUtc': inputs['createdAtUtc'],
        'sourceCommit': COMMIT, 'sourceFiles': 407, 'sourceManifest': inputs['sourceManifest'],
        'sourceSnapshotSeal': pin(FROZEN / 'out/seal-static-source.json'), 'sourceTreeSha256': source['sourceTreeSha256'],
        'observedCurrentHead': observed_head, 'sharedSnapshot': str(FROZEN / 'src'),
        'fullMainAndFrozenRawAndMembershipMatch': True, 'packageRows': 70,
        'controllerByteIdentical': True, 'nativeHelperByteIdentical': True,
        'workerChangedFunctions': ['source_check'], 'workerChangedAssignments': ['FROZEN', 'INPUT_SHA256'],
        'allBudgetNodesUnchanged': True, 'cacheProjection': projection_pin,
        'cacheFiles': 3536, 'cacheBytes': 633817159, 'cacheTrees': 70, 'fixedRuntimeFiles': 32,
        'runtimeCacheContentsNotRehashedDuringPreparation': True, 'templatePinsMatched': 50,
        'templateActuallyAccepted': True, 'oldActualAcceptanceAppliesToThisCandidate': False,
        'outerBudgetSeconds': 180, 'outerSoftCutoffSeconds': 174, 'workerBudgetSeconds': 165,
        'commandCapSeconds': 150, 'commandCleanupReserveSeconds': 5, 'minimumPostflightReserveSeconds': 25,
        'dynamicCommandDeadlineWorkerRelativeMaxSeconds': 135, 'dynamicCleanupWorkerRelativeMaxSeconds': 140,
        'sourceCopied': False, 'cacheCopied': False, 'candidateImported': False,
        'sdkCalls': 0, 'testsRun': False, 'browserStarted': False, 'networkUsed': False,
        'mainWritten': False, 'gitWritten': False, 'attemptExists': False}
    write_json('static-review.json', review)
    proposal = copy.deepcopy(template)
    proposal.update(status='STATIC_ANALYSIS407_R5_CANDIDATE_ONLY_ROOT_REVIEW_REQUIRED',
        sourceCommit=COMMIT, sourceFiles=407, sevenRootGitTrees=inputs['sevenRootGitTrees'],
        analysisInputs={**input_pin, 'absolute': True}, workingDirectory=str(FROZEN / 'src/apps/guardian'),
        attemptDirectory=str(BASE / 'attempt'), sharedSourceSnapshot=str(FROZEN / 'src'),
        preparationScript=pin(BASE / 'prepare_analysis_r5.py'), preparationRootApprovedCommit=COMMIT,
        cacheManifestSha256=projection_pin['sha256'], actualAcceptedTemplate=pin(TEMPLATE / 'proposal.json', True),
        sourceSnapshotSeal=pin(FROZEN / 'out/seal-static-source.json', True), executionApproved=False,
        sdkCalls=0, testsRun=False, runtimeWatchdogVerifiedForThisCandidate=False)
    files = ['controller.py', 'worker.py', 'heap1536_windows_job.py', 'prepare_analysis_r5.py', 'README.md',
        'mechanical-controller.py.diff', 'mechanical-worker.py.diff', 'mechanical-native-helper.py.diff',
        'input-metadata-diff.json', 'ast-diff-proof.json', 'template-r4-pin-preservation.json', 'static-review.json']
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
    seal = {'status': 'STATIC_ANALYSIS407_R5_SEALED_ROOT_REVIEW_REQUIRED_UNRUN', 'proposal': proposal_pin,
        'inputs': input_pin, 'sourceManifest': inputs['sourceManifest'],
        'sourceSnapshotSeal': pin(FROZEN / 'out/seal-static-source.json'),
        'candidatePackageConfig': inputs['candidatePackageConfig'], 'cacheManifest': projection_pin,
        'candidateFiles': len(files), 'controlRuntimeFiles': len(proposal['controlRuntimeFiles']),
        'historicalMetadataFiles': len(historical), 'originalR4PinsPreserved': 50,
        'sourceFiles': 407, 'cacheFiles': 3536, 'outerBudgetSeconds': 180,
        'workerBudgetSeconds': 165, 'commandCapSeconds': 150, 'sdkCalls': 0,
        'testsRun': False, 'browserStarted': False, 'candidateImported': False,
        'sourceCopied': False, 'cacheCopied': False, 'executionApproved': False, 'attemptExists': False}
    seal_pin = write_json('seal-receipt.json', seal)
    assert not (BASE / 'attempt').exists() and not (BASE / 'src').exists()
    print(json.dumps({**seal, 'seal': seal_pin}, ensure_ascii=False))


if __name__ == '__main__':
    main()
