"""CreateNew static HTML browser31 candidate; no candidate imports or SDK calls."""
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
SOURCE = PREVIOUS / 'src'
GIT = Path('C:/Program Files/Git/cmd/git.exe')
PREVIOUS_SHA = 'd0ef7c05af1b6e9721e4fa6c4fcf0111a4cd9cef4785fc394feb62c771253c22'
SELECTORS = ['test/workspace_flow_entry_browser_test.dart',
             'test/audit_export_route_test.dart',
             'test/approval_help_flow_browser_test.dart']
FLAGS = ['--no-version-check', '--suppress-analytics', 'test', '--no-pub',
         '--platform=chrome', '--web-renderer=html', '--reporter=json', *SELECTORS]


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
    value = {'path': str(path), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
    if absolute:
        value['absolute'] = True
    return value


def verify(row, base=None):
    path = Path(row['path']) if row.get('absolute') or base is None else base / row['path']
    actual = pin(path)
    assert actual['bytes'] == row['bytes'] and actual['sha256'] == row['sha256'], str(path)


def create(name, raw):
    path = ROOT / name
    assert path.parent == ROOT
    with path.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    assert read(path) == raw
    return pin(path)


def write_json(name, value):
    return create(name, (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))


def git(*arguments):
    environment = os.environ.copy()
    environment.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0',
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL')
    return subprocess.check_output([str(GIT), '-c', 'safe.directory=' + REPO.as_posix(), '-c', 'core.fsmonitor=false',
        '-c', 'core.untrackedCache=false', *arguments], cwd=REPO, env=environment,
        timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)


def check_source(inputs):
    manifest = json.loads(read(Path(inputs['sourceManifest']['path'])))
    rows = manifest['sourceFiles']
    assert manifest['head'] == inputs['sourceCommit'] == '080e41c66a348d48d8ac313cde77e4dd8f36cc47'
    assert manifest['sourceCount'] == len(rows) == 405
    expected = {row['path'] for row in rows}
    assert len(expected) == 405
    for label, base, key in [('main', REPO, 'workingTreeRawSha256'), ('frozen', SOURCE, 'sha256')]:
        found = set()
        def fail(error):
            raise error
        for subroot in manifest['roots']:
            for directory, folders, names in os.walk(base / subroot, followlinks=False, onerror=fail):
                folders[:] = [name for name in folders if name not in inputs['generatedExclusions']['directories']]
                for name in names:
                    if name not in inputs['generatedExclusions']['files']:
                        found.add((Path(directory) / name).relative_to(base).as_posix())
        assert found == expected, label + ' membership drift'
        for row in rows:
            raw = read(base / row['path'])
            assert hashlib.sha256(raw).hexdigest() == row[key], label + ': ' + row['path']
            if label == 'main':
                assert hashlib.sha256(raw.replace(b'\r\n', b'\n')).hexdigest() == row['committedLfSha256']
    roots = manifest['roots']
    trees = dict(zip(roots, git('rev-parse', *['HEAD:' + name for name in roots]).decode('ascii').splitlines()))
    assert trees == inputs['sevenRootGitTrees']
    return {'sourceFiles': 405, 'fullMainAndFrozenMembershipAndRawHashesMatch': True,
            'mainLfMatchesCommitted': True, 'sevenRootGitTrees': trees,
            'observedHead': git('rev-parse', 'HEAD').decode('ascii').strip()}


def main():
    assert not (ROOT / 'attempt').exists()
    assert not any((ROOT / name).exists() for name in ('controller.py', 'worker.py', 'inputs.json', 'proposal.json'))
    previous = json.loads(read(PREVIOUS / 'proposal.json'))
    assert pin(PREVIOUS / 'proposal.json')['sha256'] == PREVIOUS_SHA
    previous_pins = previous['candidateFiles'] + previous['controlRuntimeFiles'] + previous['historicalMetadataFiles']
    for row in previous_pins:
        verify(row, PREVIOUS)
    old_input = json.loads(read(PREVIOUS / 'inputs.json'))
    source_review = check_source(old_input)
    prior = json.loads(read(PREVIOUS / 'attempt/external-observation-root.json'))
    assert prior['rawOriginalStatusPreserved'] == 'NOT_ACCEPTED' and prior['businessCasesStarted'] == prior['businessCasesPassed'] == 0
    assert prior['commandTimedOutAndOwnJobTerminated'] is True and prior['ownedJobsEmpty'] is True
    assert json.loads(read(PREVIOUS / 'attempt/result.json'))['status'] == 'NOT_ACCEPTED'
    copies = ['controller.py', 'heap1536_windows_job.py', 'reporter_contract_reviewed.py',
              'reporter_contract.py', 'owned_chrome_observer.py']
    copied = []
    for name in copies:
        copied.append({'name': name, 'from': pin(PREVIOUS / name), 'to': create(name, read(PREVIOUS / name))})
    inputs = copy.deepcopy(old_input)
    inputs['createdAtUtc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    inputs['reporterContractCode'] = pin(ROOT / 'reporter_contract_reviewed.py')
    inputs['ownedChromeObserverCode'] = pin(ROOT / 'owned_chrome_observer.py')
    inputs['scope'] = 'HTML renderer; same three Chrome selectors and 31 exact visible names; reuse r1 frozen source and existing generated cache; runtime unrun.'
    input_pin = write_json('inputs.json', inputs)
    before = read(PREVIOUS / 'worker.py').decode('utf-8')
    worker = before
    substitutions = [
        ('FROZEN = CANDIDATE', "FROZEN = REPO / '.cache/guardian-browser31-20261023-r1'"),
        (pin(PREVIOUS / 'inputs.json')['sha256'], input_pin['sha256']),
        ("'--platform=chrome', '--concurrency=1', '--reporter=json',", "'--platform=chrome', '--web-renderer=html', '--reporter=json',"),
    ]
    for old, new in substitutions:
        assert worker.count(old) == 1, old
        worker = worker.replace(old, new)
    ast.parse(worker, filename='worker.py')
    create('worker.py', worker.encode('utf-8'))
    create('mechanical-worker.py.diff', ''.join(difflib.unified_diff(before.splitlines(keepends=True), worker.splitlines(keepends=True),
        fromfile='browser31-r1/worker.py', tofile='browser31-html-r2/worker.py')).encode('utf-8'))
    for name in ['controller.py', 'native-helper.py', 'reporter.py', 'observer.py']:
        create('mechanical-' + name + '.diff', b'')
    input_diff = {key: {'before': old_input.get(key), 'after': inputs.get(key)}
                  for key in sorted(set(old_input) | set(inputs)) if old_input.get(key) != inputs.get(key)}
    assert set(input_diff) == {'createdAtUtc', 'reporterContractCode', 'ownedChromeObserverCode', 'scope'}
    write_json('input-metadata-diff.json', input_diff)
    rationale_paths = [REPO / 'apps/guardian/README.md', REPO / 'scripts/build-deployment.ps1', REPO / 'scripts/start-local.ps1',
                       Path('D:/softwares/flutter/packages/flutter_tools/lib/src/commands/test.dart')]
    rationale = [pin(path) for path in rationale_paths]
    assert '--web-renderer html' in read(rationale_paths[0]).decode('utf-8')
    assert "jobs = 1;" in read(rationale_paths[3]).decode('utf-8')
    contract = json.loads(read(Path(inputs['expectedCaseContract']['path'])))
    assert contract['selectors'] == SELECTORS and contract['expectedVisibleCases'] == 31
    assert [row['expectedVisibleCases'] for row in contract['selectedSources']] == [8, 4, 19]
    inherited = [pin(PREVIOUS / name) for name in ['independent-metadata-review.json', 'reporter-static-review.json',
                 'independent_metadata_review.py', 'pure_metadata_review.py', 'source_name_contract.py']]
    previous_attempt = [pin(PREVIOUS / 'attempt' / name) for name in ['request.json', 'launch.json', 'receipt.json', 'result.json',
                        'external-observation-root.json', 'out/browser31.jsonl']]
    review = {'status': 'STATIC_BROWSER31_HTML_R2_PREPARATION_ONLY_RUNTIME_UNRUN', 'createdAtUtc': inputs['createdAtUtc'],
        'sourceReview': source_review, 'inputs': input_pin, 'previousProposal': pin(PREVIOUS / 'proposal.json'),
        'previousPinnedValidationFilesAllMatched': len(previous_pins), 'copiedByteIdenticalFiles': copied,
        'sourceSnapshotReused': str(SOURCE), 'sourceSnapshotCopied': False, 'generatedBuildCacheReusedBySameModulePath': True,
        'workingDirectory': str(SOURCE / 'apps/guardian'), 'sourceManifest': inputs['sourceManifest'],
        'dependencyLibraryPins': inputs['dependencyLibraryPins'], 'packageConfig': inputs['candidatePackageConfig'],
        'packageConfigTemplate': inputs['candidatePackageConfigTemplate'], 'allOriginalSourceAndPackagePinsUnchanged': True,
        'packageRows': 70, 'internalRootUrisUnchangedFromR1': 7, 'cacheManifest': inputs['cacheManifest'],
        'cacheFiles': 3537, 'fullCachePreflightAndPostflightStillRequired': True, 'runtimeCacheContentNotRehashedDuringPreparation': True,
        'fixedCommandFlags': FLAGS, 'selectedCaseCounts': [8, 4, 19], 'expectedPhysicalSuites': 3, 'expectedVisibleCases': 31,
        'rendererRationaleSourcePins': rationale, 'webConcurrencyInternallyFixedToOne': True, 'concurrencyFlagOmitted': True,
        'inheritedMetadataFixtureEvidence': inherited, 'inheritedFixturesNotRerun': True,
        'previousAttemptEvidence': previous_attempt, 'previousAttemptRawNotAcceptedPreserved': True,
        'previousAttemptBusinessCasesStarted': 0, 'previousAttemptNotApplicationRedOrPass': True,
        'candidateModulesImported': False, 'candidateModulesExecuted': False, 'pureMetadataFixtureFunctionsEvaluated': False,
        'sdkCalls': 0, 'testsRun': False, 'browserStarted': False, 'networkUsed': False, 'mainWritten': False, 'attemptExists': False,
        'knownConservativeLimitations': ['Same-profile owned Chrome startup retries are rejected.',
            'Inherited Job polling checks terminal state before deadline; Root external total elapsed must be strictly less than launch.workerElapsedAtLaunch + launch.commandBudgetSeconds or require additional terminal timing evidence.'],
        'scopeLimit': 'This preparation does not prove browser loading, application success, watchdog operation, or whole SDK/browser installation integrity.'}
    write_json('preparation-review.json', review)
    readme = '''# Guardian browser31 HTML r2 static candidate

This candidate retains source commit `080e41c66a348d48d8ac313cde77e4dd8f36cc47`, all 405 files in the seven fixed roots, and exactly the same three physical suites with 8 + 4 + 19 = 31 expected visible names. It reuses the complete frozen `guardian-browser31-20261023-r1/src` and existing generated build cache. No source tree or package cache is copied. All source manifest, 70 package mappings, dependency seed, internal root URIs, and cache manifest pins stay identical to r1.

The one proposed application command is:

```text
C:/Windows/System32/cmd.exe /d /v:off /c D:/softwares/flutter/bin/flutter.bat --no-version-check --suppress-analytics test --no-pub --platform=chrome --web-renderer=html --reporter=json test/workspace_flow_entry_browser_test.dart test/audit_export_route_test.dart test/approval_help_flow_browser_test.dart
```

Project README and deployment/local startup scripts explicitly select HTML rendering. The r1 actual attempt timed out during loading, after local CanvasKit requests returned 404, with zero business cases started. Its original NOT_ACCEPTED status and evidence remain preserved. That result establishes no application pass or failure. Flutter 3.22.2 internally fixes web test concurrency to one; omitting the unsupported explicit concurrency flag removes its plain status notice.

The controller, retained native handle/Job helper, reporter validator, and owned Chrome observer are byte-identical to r1. The worker has only three necessary changes: HTML flag replacing unsupported concurrency, frozen source path referencing r1, and the new input hash. Input metadata changes only creation time, scope, and the paths of the identical local reporter and observer copies. Mechanical diffs record every difference.

Budgets remain outer 510 seconds, soft cutoff 504, worker 495, command cap 480, cleanup reserve 5, and full postflight reserve at least 25 seconds. Source405, all 70 package mappings, full 3537 runtime/cache files, control and historical metadata are required before and after execution. Global SDK0, unknown-process0, at least 2 GiB RAM and 2 GiB free on C:/D: remain required. Only one single-use attempt is permitted, with process-local TEMP/TMP, a new owned Chrome profile, headless arguments and a loopback test server target.

Acceptance still requires natural native zero, terminal retained handle and Job0, exact protocol 0.1.1 evidence for three Chrome suite paths and all 31 unique expected visible successful names, no failure/error/skip, complete postflight, and independent outer natural terminal observation. No suiteDone event is invented. The inherited native polling boundary requires Root's conservative external total elapsed to be strictly less than launch.workerElapsedAtLaunch + launch.commandBudgetSeconds, or additional actual terminal timing evidence. Same-profile Chrome startup recovery retries remain conservatively rejected; an observer rejection is never ignored.

The original 32-negative plus two-positive synthetic metadata fixtures are referenced with their original pins and were not rerun for r2. Preparation and sealing only read files/Git metadata, inspect ASTs, and write new metadata under this candidate. No candidate module, worker, helper, SDK, application, browser or network call is executed. There is no r2 attempt directory or execution authorization. The whole SDK and Chrome installation remain outside the pin claim.
'''
    create('README.md', readme.encode('utf-8'))
    check_source(inputs)
    for row in previous_pins:
        verify(row, PREVIOUS)
    assert not (ROOT / 'attempt').exists() and not (ROOT / 'src').exists()
    write_json('preparation-receipt.json', {'status': review['status'], 'inputs': input_pin,
        'preparationReview': pin(ROOT / 'preparation-review.json'), 'sourceManifest': inputs['sourceManifest'],
        'previousProposalSha256': PREVIOUS_SHA, 'sdkCalls': 0, 'candidateImported': False, 'attemptExists': False})
    print(json.dumps({'status': review['status'], 'inputs': input_pin, 'sourceManifest': inputs['sourceManifest'], 'sdkCalls': 0, 'attemptExists': False}))


if __name__ == '__main__':
    main()
