"""Seal prepared r2 metadata only; no candidate imports, fixtures, or SDK calls."""
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

ROOT = Path(__file__).absolute().parent
REPO = ROOT.parents[1]
PREVIOUS = REPO / '.cache/guardian-browser31-20261023-r1'
PREVIOUS_SHA = 'd0ef7c05af1b6e9721e4fa6c4fcf0111a4cd9cef4785fc394feb62c771253c22'


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
    value = {'path': str(path), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
    if absolute:
        value['absolute'] = True
    return value


def verify(row, base=ROOT):
    path = Path(row['path']) if row.get('absolute') else base / row['path']
    current = pin(path)
    assert current['bytes'] == row['bytes'] and current['sha256'] == row['sha256'], str(path)


def create(name, value):
    path = ROOT / name
    assert path.parent == ROOT
    with path.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    return pin(path)


def main():
    assert not (ROOT / 'attempt').exists() and not (ROOT / 'src').exists() and not (ROOT / 'proposal.json').exists()
    assert pin(PREVIOUS / 'proposal.json')['sha256'] == PREVIOUS_SHA
    previous = json.loads(read(PREVIOUS / 'proposal.json'))
    inputs = json.loads(read(ROOT / 'inputs.json'))
    before_inputs = json.loads(read(PREVIOUS / 'inputs.json'))
    preparation = json.loads(read(ROOT / 'preparation-review.json'))
    input_pin = pin(ROOT / 'inputs.json')
    changed = {key for key in inputs if inputs[key] != before_inputs[key]}
    assert changed == {'createdAtUtc', 'scope', 'reporterContractCode', 'ownedChromeObserverCode'}
    assert set(inputs) == set(before_inputs)
    inherited_pins = previous['candidateFiles'] + previous['controlRuntimeFiles'] + previous['historicalMetadataFiles']
    for row in inherited_pins:
        verify(row, PREVIOUS)
    for row in [inputs[field] for field in ['sourceManifest', 'dependencyLibraryPins', 'candidatePackageConfig',
                'candidatePackageConfigTemplate', 'cacheManifest', 'expectedCaseContract', 'browserCacheBaseManifest',
                'originalPackageConfig', 'chromeReadonlyObservation', 'reporterContractCode', 'ownedChromeObserverCode']]:
        actual = pin(Path(row['path']))
        assert actual['bytes'] == row['bytes'] and actual['sha256'] == row['sha256']
    parsed = []
    for path in sorted(ROOT.glob('*.py')):
        ast.parse(read(path).decode('utf-8'), filename=str(path))
        parsed.append(pin(path))
    worker_raw = read(ROOT / 'worker.py')
    worker_text = worker_raw.decode('utf-8')
    original_worker = read(PREVIOUS / 'worker.py').decode('utf-8')
    expected_worker = original_worker.replace('FROZEN = CANDIDATE', "FROZEN = REPO / '.cache/guardian-browser31-20261023-r1'")
    expected_worker = expected_worker.replace(pin(PREVIOUS / 'inputs.json')['sha256'], input_pin['sha256'])
    expected_worker = expected_worker.replace("'--platform=chrome', '--concurrency=1', '--reporter=json',",
                                            "'--platform=chrome', '--web-renderer=html', '--reporter=json',")
    assert worker_text == expected_worker
    actual_diff = ''.join(difflib.unified_diff(original_worker.splitlines(keepends=True), worker_text.splitlines(keepends=True),
        fromfile='browser31-r1/worker.py', tofile='browser31-html-r2/worker.py'))
    assert read(ROOT / 'mechanical-worker.py.diff').decode('utf-8') == actual_diff
    for name in ['controller.py', 'heap1536_windows_job.py', 'reporter_contract_reviewed.py', 'reporter_contract.py', 'owned_chrome_observer.py']:
        assert read(ROOT / name) == read(PREVIOUS / name)
    for name in ['controller.py', 'native-helper.py', 'reporter.py', 'observer.py']:
        assert read(ROOT / ('mechanical-' + name + '.diff')) == b''
    constants = {}
    for node in ast.parse(worker_text).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            try:
                constants[node.targets[0].id] = ast.literal_eval(node.value)
            except (ValueError, TypeError):
                pass
    selectors = json.loads(read(Path(inputs['expectedCaseContract']['path'])))['selectors']
    flags = ['--no-version-check', '--suppress-analytics', 'test', '--no-pub', '--platform=chrome', '--web-renderer=html', '--reporter=json', *selectors]
    assert constants['FLAGS'] == flags and constants['INPUT_SHA256'] == input_pin['sha256']
    assert constants['HELPER_SHA256'] == '4965e39eecfe70c7eeeb7ce317c0c06f4ae484d36f025706fff3a669cec4ab12'
    source = json.loads(read(Path(inputs['sourceManifest']['path'])))
    assert source['head'] == inputs['sourceCommit'] == '080e41c66a348d48d8ac313cde77e4dd8f36cc47'
    assert source['sourceCount'] == len(source['sourceFiles']) == 405
    expected_paths = {row['path'] for row in source['sourceFiles']}
    assert len(expected_paths) == 405
    for label, base, key in [('main', REPO, 'workingTreeRawSha256'), ('frozen', PREVIOUS / 'src', 'sha256')]:
        found = set()
        def fail(error):
            raise error
        for subroot in source['roots']:
            for directory, folders, names in os.walk(base / subroot, followlinks=False, onerror=fail):
                folders[:] = [name for name in folders if name not in inputs['generatedExclusions']['directories']]
                for name in names:
                    if name not in inputs['generatedExclusions']['files']:
                        found.add((Path(directory) / name).relative_to(base).as_posix())
        assert found == expected_paths, label
        for row in source['sourceFiles']:
            raw = read(base / row['path'])
            assert hashlib.sha256(raw).hexdigest() == row[key], label + ': ' + row['path']
            if label == 'main':
                assert hashlib.sha256(raw.replace(b'\r\n', b'\n')).hexdigest() == row['committedLfSha256']
    environment = os.environ.copy()
    environment.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL')
    roots = source['roots']
    git_arguments = [inputs['gitExecutable'], '-c', 'safe.directory=' + REPO.as_posix(), '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', 'rev-parse', 'HEAD', *['HEAD:' + root for root in roots]]
    git_result = subprocess.check_output(git_arguments, cwd=REPO, env=environment, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW).decode('ascii').splitlines()
    assert dict(zip(roots, git_result[1:])) == inputs['sevenRootGitTrees'] and len(git_result) == 8
    base_cache = json.loads(read(Path(inputs['browserCacheBaseManifest']['path'])))
    derived_cache = json.loads(read(Path(inputs['cacheManifest']['path'])))
    expected_cache = copy.deepcopy(base_cache)
    chrome = inputs['chromeExecutablePin']
    matches = [i for i, row in enumerate(expected_cache['fixedFiles']) if Path(row['path']) == Path(chrome['path'])]
    assert len(matches) == 1
    row = expected_cache['fixedFiles'][matches[0]]
    expected_cache['totals']['bytes'] += chrome['bytes'] - row['bytes']
    row.update(bytes=chrome['bytes'], sha256=chrome['sha256'])
    if 'expectedSha256' in row:
        row['expectedSha256'] = chrome['sha256']
    expected_cache['status'] = 'BROWSER_CHROME_REFRESH_FROM_FIXED_BASE_NOT_RUNTIME_VALIDATION'
    expected_cache['browserChromeRefresh'] = derived_cache['browserChromeRefresh']
    assert expected_cache == derived_cache and derived_cache['totals']['files'] == 3537
    original_config = json.loads(read(Path(inputs['originalPackageConfig']['path'])))
    expected_config = copy.deepcopy(original_config)
    for row in expected_config['packages']:
        if row['name'] in inputs['internalPackageRoots']:
            row['rootUri'] = (PREVIOUS / 'src' / inputs['internalPackageRoots'][row['name']]).as_uri()
    assert len(expected_config['packages']) == 70
    assert expected_config == json.loads(read(Path(inputs['candidatePackageConfig']['path'])))
    fixtures = json.loads(read(PREVIOUS / 'independent-metadata-review.json'))
    assert fixtures['positiveReporterFixtures'] == fixtures['positiveCacheFixtures'] == 1 and fixtures['negativeFixtures'] == 32
    review = {'status': 'STATIC_HTML_R2_AST_AND_PIN_REVIEW_ONLY_RUNTIME_UNRUN', 'createdAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'proposalParentSha256': PREVIOUS_SHA, 'sourceCommit': inputs['sourceCommit'], 'observedHead': git_result[0],
        'sevenRootGitTrees': inputs['sevenRootGitTrees'], 'sourceFiles': 405, 'sourceMainAndFrozenMembershipAndRawHashesMatch': True,
        'sourceSnapshotReusedWithoutCopy': str(PREVIOUS / 'src'), 'packageRows': 70, 'allPackagePinsUnchangedFromR1': True,
        'cacheManifestUnchangedFromR1': inputs['cacheManifest'], 'cacheFiles': 3537, 'fullRuntimeFilePreflightAndPostflightRequired': True,
        'runtimeCacheFilesNotRehashedDuringStaticPreparation': True, 'allR1PinnedValidationFilesPreserved': len(inherited_pins),
        'astParsedFilesOnly': parsed, 'workerDiffOnlyFlagsFrozenPathAndInputSha': True, 'controllerAndHelperAndReporterAndObserverByteIdenticalToR1': True,
        'inputMetadataChangedKeysOnly': sorted(changed), 'expectedPhysicalSuites': 3, 'expectedVisibleCases': 31, 'sourceCaseCounts': [8, 4, 19],
        'inheritedFixtureEvidence': pin(PREVIOUS / 'independent-metadata-review.json'), 'inheritedNegativeFixtures': 32, 'inheritedPositiveFixtures': 2,
        'fixturesRerunForR2': False, 'candidateModulesImported': False, 'candidateCodeEvaluated': False,
        'sdkCalls': 0, 'testsRun': False, 'browserStarted': False, 'networkUsed': False, 'mainWritten': False, 'attemptExists': False,
        'watchdogOrBrowserRuntimeVerifiedForR2': False, 'executionApproved': False}
    create('static-review.json', review)
    files = ['controller.py', 'worker.py', 'heap1536_windows_job.py', 'reporter_contract_reviewed.py', 'reporter_contract.py',
             'owned_chrome_observer.py', 'prepare_html_browser31.py', 'seal_html_browser31.py', 'README.md',
             'mechanical-controller.py.diff', 'mechanical-worker.py.diff', 'mechanical-native-helper.py.diff',
             'mechanical-reporter.py.diff', 'mechanical-observer.py.diff', 'input-metadata-diff.json',
             'preparation-review.json', 'preparation-receipt.json', 'static-review.json',
             'preparation-code-review.json', 'preparation-code-review-v2.json']
    proposal = copy.deepcopy(previous)
    proposal.update(status='STATIC_BROWSER31_HTML_R2_CANDIDATE_ONLY_ROOT_REVIEW_REQUIRED', executionApproved=False,
        sdkCalls=0, testsRun=False, actualCasesExecuted=None, analysisInputs={**input_pin, 'absolute': True},
        command=['C:/Windows/System32/cmd.exe', '/d', '/v:off', '/c', 'D:/softwares/flutter/bin/flutter.bat ' + ' '.join(flags)],
        workingDirectory=str(PREVIOUS / 'src/apps/guardian'), attemptDirectory=str(ROOT / 'attempt'),
        preparationScript=pin(ROOT / 'prepare_html_browser31.py'), frozenSourceSnapshotWrittenDuringPreparation=False,
        mainSourceWrittenDuringPreparation=False, candidateModulesImportedDuringPreparation=False,
        onlyPureMetadataAstFixtureFunctionsEvaluated=False, runtimeWatchdogVerifiedForThisCandidate=False,
        sourceSnapshotReusedFromR1=True, frozenSourceDirectory=str(PREVIOUS / 'src'), noFullSourceCopy=True,
        webRenderer='html', explicitConcurrencyFlag=False, webConcurrencyInternallyFixedToOne=True,
        inheritedMetadataFixturesNotRerun=True, inheritedMetadataFixtureEvidence=pin(PREVIOUS / 'independent-metadata-review.json'),
        priorCandidateProposalSha256=PREVIOUS_SHA, priorAttemptStatusPreserved='NOT_ACCEPTED',
        priorAttemptBusinessCasesStarted=0, priorAttemptNotApplicationRedOrPass=True,
        allOriginalR1CandidateControlAndHistoricalPinsRetained=True,
        externalStrictDeadlineBoundRequired='actual complete outer elapsed < launch.workerElapsedAtLaunch + launch.commandBudgetSeconds, otherwise additional actual terminal timing evidence is required',
        conservativeSameProfileChromeRetryRejectionRetained=True)
    proposal['candidateFiles'] = [{**pin(ROOT / name), 'path': name} for name in files]
    historical = copy.deepcopy(previous['historicalMetadataFiles'])
    historical += [{**pin(PREVIOUS / row['path']), 'absolute': True} for row in previous['candidateFiles']]
    historical += [pin(PREVIOUS / 'proposal.json', True), pin(PREVIOUS / 'seal-receipt.json', True)]
    historical += [{**row, 'absolute': True} for row in preparation['inheritedMetadataFixtureEvidence']
                   + preparation['previousAttemptEvidence'] + preparation['rendererRationaleSourcePins']]
    historical += [pin(ROOT / 'inputs.json', True)]
    proposal['historicalMetadataFiles'] = historical
    for row in proposal['candidateFiles'] + proposal['controlRuntimeFiles'] + proposal['historicalMetadataFiles']:
        verify(row)
    proposal_pin = create('proposal.json', proposal)
    assert not (ROOT / 'attempt').exists() and not (ROOT / 'src').exists()
    receipt = {'status': 'STATIC_BROWSER31_HTML_R2_SEALED_FOR_ROOT_REVIEW_RUNTIME_UNRUN', 'proposal': proposal_pin,
        'inputs': input_pin, 'sourceManifest': inputs['sourceManifest'], 'dependencyLibraryPins': inputs['dependencyLibraryPins'],
        'candidatePackageConfig': inputs['candidatePackageConfig'], 'cacheManifest': inputs['cacheManifest'],
        'expectedCaseContract': inputs['expectedCaseContract'], 'staticReview': pin(ROOT / 'static-review.json'),
        'candidateFiles': len(proposal['candidateFiles']), 'controlRuntimeFiles': len(proposal['controlRuntimeFiles']),
        'historicalMetadataFiles': len(historical), 'sdkCalls': 0, 'testsRun': False, 'browserStarted': False,
        'candidateImported': False, 'attemptExists': False, 'sourceCopied': False}
    receipt_pin = create('seal-receipt.json', receipt)
    print(json.dumps({**receipt, 'receipt': receipt_pin}))


if __name__ == '__main__':
    main()
