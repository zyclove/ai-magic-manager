"""Seal prepared browser38 metadata only; no candidate imports or SDK calls."""
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
PREVIOUS = REPO / '.cache/guardian-browser31-20261023-r2'
PREVIOUS_SHA = 'e931d599edbdc2fc413ba2f156fcf592c165913ab00afff9b75fc148f71f501e'
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
    value = {'path': str(path), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
    if absolute:
        value['absolute'] = True
    return value


def verify(row, base=ROOT):
    path = Path(row['path']) if row.get('absolute') else base / row['path']
    actual = pin(path)
    assert actual['bytes'] == row['bytes'] and actual['sha256'] == row['sha256'], str(path)


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
    assert not (ROOT / 'attempt').exists() and not (ROOT / 'proposal.json').exists()
    assert pin(PREVIOUS / 'proposal.json')['sha256'] == PREVIOUS_SHA
    previous = json.loads(read(PREVIOUS / 'proposal.json'))
    inputs = json.loads(read(ROOT / 'inputs.json'))
    source = json.loads(read(Path(inputs['sourceManifest']['path'])))
    contract = json.loads(read(ROOT / 'expected-cases.json'))
    preparation = json.loads(read(ROOT / 'preparation-review.json'))
    fixtures = json.loads(read(ROOT / 'independent-metadata-review.json'))
    reporter_review = json.loads(read(ROOT / 'reporter-static-review.json'))
    assert inputs['sourceCommit'] == source['head'] == COMMIT and source['sourceCount'] == len(source['sourceFiles']) == 406
    assert inputs['phase'] == 'browser-38-guardian'
    assert contract['expectedPhysicalSuites'] == 4 and contract['expectedVisibleCases'] == len(contract['cases']) == 38
    assert [row['expectedVisibleCases'] for row in contract['selectedSources']] == [8, 4, 19, 7]
    assert len({(row['selector'], row['name']) for row in contract['cases']}) == 38
    assert fixtures['positiveReporterFixtures'] >= 1 and fixtures['positiveCacheFixtures'] >= 1 and fixtures['negativeFixtures'] >= 32
    assert fixtures['candidateModulesImported'] is False and fixtures['sdkStarted'] is False and fixtures['applicationTestsRun'] is False
    assert reporter_review.get('sdkStarted') is False or reporter_review.get('sdkCalls') == 0
    for row in previous['candidateFiles'] + previous['controlRuntimeFiles'] + previous['historicalMetadataFiles']:
        verify(row, PREVIOUS)
    for field in ['sourceManifest', 'dependencyLibraryPins', 'candidatePackageConfig', 'candidatePackageConfigTemplate',
                  'cacheManifest', 'browserCacheBaseManifest', 'chromeExecutablePin', 'chromeReadonlyObservation',
                  'expectedCaseContract', 'reporterContractCode', 'ownedChromeObserverCode', 'originalPackageConfig']:
        row = inputs[field]
        actual = pin(Path(row['path']))
        assert actual['bytes'] == row['bytes'] and actual['sha256'] == row['sha256']
    parsed = []
    for path in sorted(ROOT.glob('*.py')):
        ast.parse(read(path).decode('utf-8'), filename=str(path))
        parsed.append(pin(path))
    before_controller = read(PREVIOUS / 'controller.py').decode('utf-8')
    assert read(ROOT / 'controller.py').decode('utf-8') == before_controller.replace('GUARDIAN_BROWSER31', 'GUARDIAN_BROWSER38')
    for name in ['heap1536_windows_job.py', 'owned_chrome_observer.py']:
        assert read(ROOT / name) == read(PREVIOUS / name)
    assert read(ROOT / 'reporter_contract.py') == read(ROOT / 'reporter_contract_reviewed.py')
    input_pin = pin(ROOT / 'inputs.json')
    constants = {}
    worker_text = read(ROOT / 'worker.py').decode('utf-8')
    for node in ast.parse(worker_text).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            try:
                constants[node.targets[0].id] = ast.literal_eval(node.value)
            except (ValueError, TypeError):
                pass
    selectors = contract['selectors']
    assert len(selectors) == 4
    flags = ['--no-version-check', '--suppress-analytics', 'test', '--no-pub', '--platform=chrome', '--web-renderer=html', '--reporter=json', *selectors]
    assert constants['FLAGS'] == flags and constants['INPUT_SHA256'] == input_pin['sha256']
    assert constants['HELPER_SHA256'] == '4965e39eecfe70c7eeeb7ce317c0c06f4ae484d36f025706fff3a669cec4ab12'
    assert "FLAGS[-4:]" in worker_text and "'selectorCount': 4, 'expectedVisibleCases': 38" in worker_text
    assert "len(rows) == 406 and manifest['sourceCount'] == 406" in worker_text and 'len(expected) == 406' in worker_text
    expected_paths = {row['path'] for row in source['sourceFiles']}
    assert len(expected_paths) == 406
    for label, base, key in [('main', REPO, 'workingTreeRawSha256'), ('frozen', ROOT / 'src', 'sha256')]:
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
    git_result = subprocess.check_output([inputs['gitExecutable'], '-c', 'safe.directory=' + REPO.as_posix(),
        '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', 'rev-parse', 'HEAD', *['HEAD:' + root for root in roots]],
        cwd=REPO, env=environment, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW).decode('ascii').splitlines()
    assert len(git_result) == 8 and dict(zip(roots, git_result[1:])) == inputs['sevenRootGitTrees']
    original = json.loads(read(Path(inputs['originalPackageConfig']['path'])))
    expected_config = copy.deepcopy(original)
    changed = 0
    for row in expected_config['packages']:
        if row['name'] in inputs['internalPackageRoots']:
            row['rootUri'] = (ROOT / 'src' / inputs['internalPackageRoots'][row['name']]).as_uri()
            changed += 1
    assert len(expected_config['packages']) == 70 and changed == 7
    assert expected_config == json.loads(read(Path(inputs['candidatePackageConfig']['path']))) == json.loads(read(Path(inputs['candidatePackageConfigTemplate']['path'])))
    base = json.loads(read(Path(inputs['browserCacheBaseManifest']['path'])))
    derived = json.loads(read(Path(inputs['cacheManifest']['path'])))
    expected_cache = copy.deepcopy(base)
    chrome = inputs['chromeExecutablePin']
    indices = [i for i, row in enumerate(base['fixedFiles']) if Path(row['path']) == Path(chrome['path'])]
    assert len(indices) == 1
    row = expected_cache['fixedFiles'][indices[0]]
    expected_cache['totals']['bytes'] += chrome['bytes'] - row['bytes']
    row.update(bytes=chrome['bytes'], sha256=chrome['sha256'])
    if 'expectedSha256' in row:
        row['expectedSha256'] = chrome['sha256']
    expected_cache['status'] = 'BROWSER_CHROME_REFRESH_FROM_FIXED_BASE_NOT_RUNTIME_VALIDATION'
    expected_cache['browserChromeRefresh'] = derived['browserChromeRefresh']
    assert derived == expected_cache and derived['totals']['files'] == 3537 and len(derived['trees']) == 70 and len(derived['fixedFiles']) == 33
    review = {'status': 'STATIC_BROWSER38_SEAL_REVIEW_ONLY_RUNTIME_UNRUN', 'createdAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'sourceCommit': COMMIT, 'currentObservedHead': git_result[0], 'sevenRootGitTrees': inputs['sevenRootGitTrees'],
        'sourceFiles': 406, 'fullMainAndFrozenRawAndMembershipRechecked': True, 'mainLfMatchesCommitted': True,
        'packageRows': 70, 'internalUrisOnlyChanges': 7, 'unchangedExternalRows': 63,
        'cacheFiles': 3537, 'cacheMetadataChromeOnlyDerivationStillExact': True, 'runtimeCacheFileContentsNotRehashedDuringStaticSeal': True,
        'full3537PreflightAndPostflightRequired': True, 'expectedPhysicalSuites': 4, 'sourceExpandedCounts': [8, 4, 19, 7],
        'expectedVisibleCases': 38, 'actualCasesExecuted': None, 'original31NamesPreserved': True,
        'independentSyntheticMetadataReview': pin(ROOT / 'independent-metadata-review.json'),
        'reporterReview': pin(ROOT / 'reporter-static-review.json'), 'astParsedOnlyFiles': parsed,
        'nativeHelperAndChromeObserverByteIdenticalToR1R2': True, 'optionalPrivateJobDiagnosticNotAdded': True,
        'candidateImported': False, 'sdkCalls': 0, 'testsRun': False, 'browserStarted': False, 'networkUsed': False,
        'mainWritten': False, 'attemptExists': False, 'runtimeWatchdogOrBrowserVerified': False, 'executionApproved': False}
    create('static-review.json', review)
    files = ['controller.py', 'worker.py', 'heap1536_windows_job.py', 'reporter_contract_reviewed.py', 'reporter_contract.py',
        'owned_chrome_observer.py', 'source_name_contract.py', 'adapt_controls38.py', 'prepare_browser38.py', 'seal_browser38.py',
        'independent_metadata_review.py', 'README.md', 'mechanical-controller.py.diff', 'mechanical-worker.py.diff',
        'mechanical-native-helper.py.diff', 'mechanical-observer.py.diff', 'mechanical-reporter.py.diff', 'mechanical-name-contract.py.diff',
        'input-metadata-diff.json', 'preparation-review.json', 'preparation-receipt.json', 'independent-metadata-review.json',
        'reporter-static-review.json', 'static-review.json']
    proposal = copy.deepcopy(previous)
    for field in ['sourceSnapshotReusedFromR1', 'noFullSourceCopy', 'inheritedMetadataFixturesNotRerun', 'inheritedMetadataFixtureEvidence',
                  'priorAttemptStatusPreserved', 'priorAttemptBusinessCasesStarted', 'priorAttemptNotApplicationRedOrPass']:
        proposal.pop(field, None)
    proposal.update(status='STATIC_BROWSER38_CANDIDATE_ONLY_ROOT_REVIEW_REQUIRED', executionApproved=False, sdkCalls=0, testsRun=False,
        phase='browser-38-guardian', phaseScope='GUARDIAN_BROWSER38', sourceCommit=COMMIT, sourceFiles=406,
        sevenRootGitTrees=inputs['sevenRootGitTrees'], analysisInputs={**input_pin, 'absolute': True},
        command=['C:/Windows/System32/cmd.exe', '/d', '/v:off', '/c', 'D:/softwares/flutter/bin/flutter.bat ' + ' '.join(flags)],
        workingDirectory=str(ROOT / 'src/apps/guardian'), attemptDirectory=str(ROOT / 'attempt'), selectedTestFiles=selectors,
        expectedPhysicalSuites=4, expectedVisibleCases=38, actualCasesExecuted=None,
        preparationScript=pin(ROOT / 'prepare_browser38.py'), preparationRootApprovedCommit=COMMIT,
        frozenSourceSnapshotWrittenDuringPreparation=True, frozenSourceDirectory=str(ROOT / 'src'),
        mainSourceWrittenDuringPreparation=False, candidateModulesImportedDuringPreparation=False,
        onlyPureMetadataAstFixtureFunctionsEvaluated=True, runtimeWatchdogVerifiedForThisCandidate=False,
        cacheManifestSha256=inputs['cacheManifest']['sha256'], priorCandidateProposalSha256=PREVIOUS_SHA,
        original31NamesPreserved=True, notificationSevenAllRequiredIncludingSyntheticOptional=True,
        independentSyntheticMetadataFixtures=pin(ROOT / 'independent-metadata-review.json'),
        previousR1R2NotAcceptedPreserved=True, optionalPrivateJobDiagnosticNotAdded=True,
        allOriginalR2CandidateControlAndHistoricalPinsRetained=True)
    proposal['candidateFiles'] = [{**pin(ROOT / name), 'path': name} for name in files]
    historical = copy.deepcopy(previous['historicalMetadataFiles'])
    historical += [{**pin(PREVIOUS / row['path']), 'absolute': True} for row in previous['candidateFiles']]
    historical += [pin(PREVIOUS / name, True) for name in ['proposal.json', 'seal-receipt.json', 'postseal-independent-review.json']]
    historical += [pin(PREVIOUS / 'attempt' / name, True) for name in ['request.json', 'launch.json', 'receipt.json', 'result.json', 'external-observation-root.json', 'out/browser31.jsonl']]
    historical += [{**row, 'absolute': True} for row in [input_pin, *[inputs[field] for field in ['sourceManifest', 'dependencyLibraryPins',
        'candidatePackageConfig', 'candidatePackageConfigTemplate', 'cacheManifest', 'expectedCaseContract']]]]
    proposal['historicalMetadataFiles'] = historical
    for row in proposal['candidateFiles'] + proposal['controlRuntimeFiles'] + historical:
        verify(row)
    proposal_pin = create('proposal.json', proposal)
    assert not (ROOT / 'attempt').exists()
    receipt = {'status': 'STATIC_BROWSER38_SEALED_FOR_ROOT_REVIEW_RUNTIME_UNRUN', 'proposal': proposal_pin,
        'inputs': input_pin, 'sourceManifest': inputs['sourceManifest'], 'dependencyLibraryPins': inputs['dependencyLibraryPins'],
        'candidatePackageConfig': inputs['candidatePackageConfig'], 'cacheManifest': inputs['cacheManifest'],
        'expectedCaseContract': inputs['expectedCaseContract'], 'staticReview': pin(ROOT / 'static-review.json'),
        'candidateFiles': len(files), 'controlRuntimeFiles': len(proposal['controlRuntimeFiles']), 'historicalMetadataFiles': len(historical),
        'sourceFiles': 406, 'expectedPhysicalSuites': 4, 'expectedVisibleCases': 38, 'sdkCalls': 0, 'testsRun': False,
        'browserStarted': False, 'candidateImported': False, 'attemptExists': False}
    receipt_pin = create('seal-receipt.json', receipt)
    print(json.dumps({**receipt, 'receipt': receipt_pin}))


if __name__ == '__main__':
    main()
