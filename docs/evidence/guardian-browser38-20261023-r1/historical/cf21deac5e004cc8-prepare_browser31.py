"""Offline browser31 preparation. Never imports candidate/SDK or creates attempt.

Read-only Git plumbing, literal source metadata, CreateNew snapshot/artifact writes,
and Windows FileVersionInfo observation are the only subprocess/file actions.
"""
from pathlib import Path
import ast
import copy
import datetime
import difflib
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess

REPO = Path('D:/codes/mobile/ai-manager')
TASK = REPO / '.cache/guardian-browser31-20261023-r1'
SRC = TASK / 'src'
OUT = TASK / 'out'
TEMPLATE = REPO / '.cache/guardian-analyze-20261021-r2'
OLD_INPUT = REPO / '.cache/guardian-current-20261021-r2/out/analysis-inputs-root.json'
COMMIT = '080e41c66a348d48d8ac313cde77e4dd8f36cc47'
PARENT = '18f270cb6664b9cec92677a1c55d315546e22b4a'
TEMPLATE_SHA = '5a321054ee020199025e7c40ab062f5577a0ecf3ade5ec899a131bacdce80490'
OLD_INPUT_SHA = '87ef567e9d14a94c9672e1c672720a5e2da636e4091eaa751959ed6c6a7dd323'
CACHE_SHA = '0027b4f8d65b9054e273b3c98a8b62f8de963fe9b59e054bf750eaae1cc6f3c2'
GIT = Path('C:/Program Files/Git/cmd/git.exe')
CHROME = Path('C:/Program Files/Google/Chrome/Application/chrome.exe')
ROOTS = ['apps/guardian', 'packages/audit_client', 'packages/commerce_contracts',
         'packages/notification_client', 'packages/device_operations',
         'packages/usage_reporting', 'packages/usage_report_ui']
SELECTORS = ['test/workspace_flow_entry_browser_test.dart', 'test/audit_export_route_test.dart',
             'test/approval_help_flow_browser_test.dart']


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def safe(path):
    path = Path(path)
    for item in (path, *path.parents):
        if os.path.lexists(item):
            mode = item.lstat()
            assert not stat.S_ISLNK(mode.st_mode) and not getattr(mode, 'st_file_attributes', 0) & 0x400, 'Linked input/output refused'
    return path


def read(path):
    safe(path)
    before = path.stat()
    assert stat.S_ISREG(before.st_mode), 'Regular input required'
    raw = path.read_bytes()
    after = path.stat()
    assert (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    assert len(raw) == before.st_size
    return raw


def pin(path, absolute=False):
    raw = read(path)
    result = {'path': str(path), 'bytes': len(raw), 'sha256': sha(raw)}
    if absolute:
        result['absolute'] = True
    return result


def verify(row):
    current = pin(Path(row['path']))
    assert current['bytes'] == row['bytes'] and current['sha256'] == row['sha256'], 'Pinned input changed: ' + row['path']


def create(path, raw):
    path = Path(path)
    assert path.is_relative_to(TASK), 'Only exact browser31 directory is writable'
    safe(path.parent)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as output:
        output.write(raw)
        output.flush()
        os.fsync(output.fileno())
    assert read(path) == raw
    return pin(path)


def write_json(path, value):
    return create(path, (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))


def pure_functions(path, imports, assignments, functions):
    """Evaluate only explicitly named pure metadata AST nodes; no module import."""
    tree = ast.parse(read(path).decode('utf-8'), filename=str(path))
    kept = []
    for node in tree.body:
        if isinstance(node, ast.Import):
            assert all(alias.name in imports for alias in node.names), 'Unexpected metadata import'
            kept.append(node)
        elif isinstance(node, ast.Assign):
            assert all(isinstance(target, ast.Name) and target.id in assignments for target in node.targets)
            ast.literal_eval(node.value)
            kept.append(node)
        elif isinstance(node, ast.FunctionDef):
            assert node.name in functions and not node.decorator_list
            assert not any(isinstance(child, (ast.Import, ast.ImportFrom, ast.Global, ast.Nonlocal)) for child in ast.walk(node))
            assert not any(isinstance(child, ast.Name) and child.id in {'open','exec','eval','compile','__import__','subprocess','os','sys','Path'} for child in ast.walk(node))
            kept.append(node)
        elif isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            pass
        else:
            raise AssertionError('Non-pure candidate metadata AST node refused')
    namespace = {}
    exec(compile(ast.Module(body=kept, type_ignores=[]), str(path) + ':pure-metadata-AST', 'exec'), namespace)
    return namespace


def main():
    assert not (TASK / 'attempt').exists(), 'No attempt permitted during preparation'
    assert all(not (TASK / name).exists() for name in ('src','out','generated','inputs.json','proposal.json','controller.py','worker.py')), 'Existing outputs preserved; preparation is CreateNew'
    assert shutil.disk_usage(REPO).free >= 2**31, 'At least 2GiB repository drive space required'
    original_names = ['reporter_contract.py','owned_chrome_observer.py','pure_metadata_review.py','source_name_contract.py']
    originals = [pin(TASK / name) for name in original_names]
    template_raw = read(TEMPLATE / 'proposal.json')
    input_raw = read(OLD_INPUT)
    assert sha(template_raw) == TEMPLATE_SHA and sha(input_raw) == OLD_INPUT_SHA
    template, old_input = json.loads(template_raw), json.loads(input_raw)
    assert template['sourceCommit'] == PARENT and template['sourceFiles'] == 404
    for row in template['candidateFiles']:
        observed = pin(TEMPLATE / row['path'])
        assert observed['sha256'] == row['sha256'] and observed['bytes'] == row['bytes']
    for row in template['controlRuntimeFiles'] + template['historicalMetadataFiles']:
        verify(row)
    assert old_input['cacheManifest']['sha256'] == CACHE_SHA
    base = json.loads(read(Path(old_input['cacheManifest']['path'])))
    assert base['fullAllowlistCollected'] is True and len(base['trees']) == 70 and len(base['fixedFiles']) == 33 and base['totals']['files'] == 3537
    environment = os.environ.copy()
    environment.update(GIT_OPTIONAL_LOCKS='0',GIT_TERMINAL_PROMPT='0',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='NUL')
    def git(*arguments, input=None):
        return subprocess.run([str(GIT),'-c','safe.directory='+REPO.as_posix(),'-c','core.fsmonitor=false','-c','core.untrackedCache=false',*arguments],
            cwd=REPO,env=environment,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True,timeout=30,creationflags=subprocess.CREATE_NO_WINDOW).stdout
    assert git('rev-parse','HEAD').decode().strip() == COMMIT, 'Only explicit new HEAD accepted'
    assert git('rev-parse',COMMIT+'^').decode().strip() == PARENT
    trees = dict(zip(ROOTS,git('rev-parse',*[COMMIT+':'+root for root in ROOTS]).decode().splitlines()))
    assert len(trees) == 7
    entries=[]
    for raw in git('ls-tree','-rz',COMMIT,'--',*ROOTS).split(b'\0'):
        if not raw:
            continue
        header, path = raw.split(b'\t',1)
        mode, kind, oid = header.decode('ascii').split()
        relative = path.decode('utf-8')
        assert kind == 'blob' and mode in ('100644','100755')
        assert not Path(relative).is_absolute() and '..' not in Path(relative).parts and ':' not in relative
        assert not any(part == '.local' or part.startswith('.env') for part in Path(relative).parts)
        entries.append({'path':relative,'gitBlob':oid,'mode':mode})
    assert len(entries) == 405 and len({row['path'] for row in entries}) == 405, 'Full seven-root committed boundary must be 405'
    expected = {row['path'] for row in entries}
    def membership(base_dir):
        seen=set()
        def fail(error):
            raise error
        for root in ROOTS:
            for directory,folders,names in os.walk(safe(base_dir/root),followlinks=False,onerror=fail):
                folders[:] = [name for name in folders if name not in old_input['generatedExclusions']['directories']]
                for name in folders:
                    safe(Path(directory)/name)
                for name in names:
                    if name not in old_input['generatedExclusions']['files']:
                        path=safe(Path(directory)/name)
                        assert path.is_file()
                        seen.add(path.relative_to(base_dir).as_posix())
        assert seen == expected, ('Full membership differs',sorted(seen-expected),sorted(expected-seen))
        return {'files':len(seen),'fullMembershipExact':True}
    main_membership = membership(REPO)
    batch = git('cat-file','--batch',input=''.join(row['gitBlob']+'\n' for row in entries).encode('ascii'))
    stream=io.BytesIO(batch)
    frozen=[]
    for row in entries:
        oid,kind,size=stream.readline().decode('ascii').split()
        raw=stream.read(int(size))
        assert oid == row['gitBlob'] and kind == 'blob' and len(raw) == int(size) and stream.read(1) == b'\n'
        working=read(REPO/row['path'])
        row.update(bytes=len(raw),sha256=sha(raw),committedLfSha256=sha(raw.replace(b'\r\n',b'\n')),
            workingTreeRawBytes=len(working),workingTreeRawSha256=sha(working),workingTreeLfSha256=sha(working.replace(b'\r\n',b'\n')))
        assert row['committedLfSha256'] == row['workingTreeLfSha256'], 'Main source semantic drift: '+row['path']
        frozen.append((row['path'],raw))
    assert stream.read() == b''
    assert git('rev-parse','HEAD').decode().strip() == COMMIT and membership(REPO) == main_membership
    for row in entries:
        assert sha(read(REPO/row['path'])) == row['workingTreeRawSha256']
    for relative,raw in frozen:
        create(SRC/relative,raw)
    canonical=''.join(f"{row['path']}\0{row['bytes']}\0{row['sha256']}\n" for row in entries)
    manifest={'status':'STATIC_COMMITTED_SOURCE_SNAPSHOT_BROWSER_UNRUN','head':COMMIT,'parent':PARENT,'roots':ROOTS,
       'sourceCount':405,'sourceBytes':sum(row['bytes'] for row in entries),'sourceTreeSha256':sha(canonical.encode()),'sourceFiles':entries,
       'workingTreeRawDifferences':[row['path'] for row in entries if row['sha256'] != row['workingTreeRawSha256']],
       'workingTreeSemanticDifferencesAfterCrLfNormalization':[]}
    source_pin=write_json(OUT/'source-manifest.json',manifest)
    internal=old_input['internalPackageRoots']
    assert len(internal) == 7 and set(internal.values()) == set(ROOTS)
    seed=json.loads(read(Path(old_input['dependencyLibraryPins']['path'])))
    old_seed=copy.deepcopy(seed)
    count=0
    for row in seed['packageMappings']:
        if row['name'] in internal:
            assert row['category'] == 'current-committed-repository-input'
            row['proposedCandidateRootUri']=(SRC/internal[row['name']]).as_uri()
            count+=1
    assert count == 7 and len(seed['packageMappings']) == 70
    for before,after in zip(old_seed['packageMappings'],seed['packageMappings']):
        expected_row=copy.deepcopy(before)
        if before['name'] in internal:
            expected_row['proposedCandidateRootUri']=(SRC/internal[before['name']]).as_uri()
        assert after == expected_row
    seed_pin=write_json(OUT/'dependency-library-pins.json',seed)
    config=json.loads(read(Path(old_input['originalPackageConfig']['path'])))
    assert len(config['packages']) == 70 and len({row['name'] for row in config['packages']}) == 70
    for row in config['packages']:
        if row['name'] in internal:
            row['rootUri']=(SRC/internal[row['name']]).as_uri()
    config_pin=write_json(SRC/'apps/guardian/.dart_tool/package_config.json',config)
    config_template=write_json(TASK/'generated/guardian-package_config.json',config)
    assert config_pin['sha256'] == config_template['sha256']
    frozen_membership=membership(SRC)
    chrome=pin(CHROME)
    ps=Path('C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe')
    observation_script="$i = Get-Item -LiteralPath 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe'; [pscustomobject]@{FileVersion=$i.VersionInfo.FileVersion;ProductVersion=$i.VersionInfo.ProductVersion;CompanyName=$i.VersionInfo.CompanyName;OriginalFilename=$i.VersionInfo.OriginalFilename} | ConvertTo-Json -Compress"
    version=json.loads(subprocess.run([str(ps),'-NoProfile','-NonInteractive','-Command',observation_script],stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True,timeout=15,creationflags=subprocess.CREATE_NO_WINDOW).stdout)
    assert pin(CHROME) == chrome, 'Chrome changed during file-version observation'
    assert version['OriginalFilename'].lower() == 'chrome.exe' and version['CompanyName'] == 'Google LLC'
    observation={'status':'FRESH_FILE_VERSION_INFO_ONLY_EXISTING_CHROME_NOT_EXECUTED','observedAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
       'file':chrome,'versionInfo':version,'versionInfoBoundToSameContentHash':chrome['sha256'],'observationExecutable':pin(ps),
       'browserStarted':False,'installedOrUpdatedByTask':False,'entireChromeInstallationPinned':False}
    chrome_observation=write_json(TASK/'chrome-readonly-observation.json',observation)
    derived=copy.deepcopy(base)
    matches=[index for index,row in enumerate(base['fixedFiles']) if Path(row['path']) == CHROME]
    assert len(matches) == 1
    chrome_index=matches[0]
    old_chrome=copy.deepcopy(derived['fixedFiles'][chrome_index])
    derived['fixedFiles'][chrome_index].update(bytes=chrome['bytes'],sha256=chrome['sha256'])
    if 'expectedSha256' in derived['fixedFiles'][chrome_index]:
        derived['fixedFiles'][chrome_index]['expectedSha256']=chrome['sha256']
    derived['totals']['bytes']+=chrome['bytes']-old_chrome['bytes']
    derived['status']='BROWSER_CHROME_REFRESH_FROM_FIXED_BASE_NOT_RUNTIME_VALIDATION'
    derived['browserChromeRefresh']={'baseManifestSha256':CACHE_SHA,'onlyExistingChromeExecutableRowRefreshed':True,
       'otherPinnedFilesKeptWithoutRebaseline':3536,'originalChromeRow':old_chrome,'approvedChromeExecutable':chrome}
    cache_pin=write_json(TASK/'cache-content-chrome-refreshed.json',derived)
    names=pure_functions(TASK/'source_name_contract.py',{'re'},{'SELECTORS','COUNTS'},{'tokens','derive'})
    cases=[]
    selected=[]
    for selector,count in zip(SELECTORS,[8,4,19]):
        raw=read(SRC/'apps/guardian'/selector)
        case_rows,declarations=names['derive'](raw.decode('utf-8'),selector)
        assert len(case_rows) == count
        row=next(row for row in entries if row['path'] == 'apps/guardian/'+selector)
        selected.append({'selector':selector,'expectedVisibleCases':count,'file':pin(SRC/'apps/guardian'/selector),'gitBlob':row['gitBlob'],'declarations':declarations})
        cases.extend(case_rows)
    contract={'status':'STATIC_LITERAL_SOURCE_NAMES_NOT_RUNTIME_DISCOVERY','sourceCommit':COMMIT,'sourceFiles':405,
       'selectors':SELECTORS,'expectedPhysicalSuites':3,'expectedVisibleCases':31,'selectedSources':selected,'cases':cases,
       'sourceNameParser':pin(TASK/'source_name_contract.py'),'cacheBaseManifest':old_input['cacheManifest'],'approvedChromeExecutable':chrome,
       'protocolVersion':'0.1.1','testCoreVersion':'0.6.0','suiteDoneEventExists':False,
       'runtimeDiscoveryPerformed':False,'sdkStarted':False,'browserStarted':False}
    contract_pin=write_json(TASK/'expected-cases.json',contract)
    launcher_sources=[Path('D:/softwares/flutter/packages/flutter_tools/lib/src/web/chrome.dart'),Path('D:/softwares/flutter/packages/flutter_tools/lib/src/test/flutter_web_platform.dart')]
    launcher_pins=[pin(path) for path in launcher_sources]
    assert "createTempSync('flutter_tools_chrome_device.')" in read(launcher_sources[0]).decode()
    assert 'debugPort ?? await _operatingSystemUtils.findFreePort()' in read(launcher_sources[0]).decode()
    assert 'headless: headless,' in read(launcher_sources[1]).decode()
    flutter_version=Path('D:/softwares/flutter/bin/cache/flutter.version.json')
    dart_version=Path('D:/softwares/flutter/bin/cache/dart-sdk/version')
    assert json.loads(read(flutter_version))['frameworkVersion'] == '3.22.2'
    assert read(dart_version).decode().strip() == '3.4.3'
    version_pins=[pin(flutter_version),pin(dart_version)]
    inputs=copy.deepcopy(old_input)
    inputs.update(status='STATIC_BROWSER31_INPUTS_RUNTIME_UNRUN',phase='browser-31-guardian',createdAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
       sourceCommit=COMMIT,sourceTreeSha256=manifest['sourceTreeSha256'],sourceManifest=source_pin,
       dependencyLibraryPins=seed_pin,candidatePackageConfig=config_pin,candidatePackageConfigTemplate=config_template,
       sevenRootGitTrees=trees,sourceMembershipCheck={'main':main_membership,'frozen':frozen_membership},cacheManifest=cache_pin,
       browserCacheBaseManifest=old_input['cacheManifest'],chromeExecutablePin=chrome,chromeReadonlyObservation=chrome_observation,
       expectedCaseContract=contract_pin,reporterContractCode=pin(TASK/'reporter_contract_reviewed.py'),
       ownedChromeObserverCode=pin(TASK/'owned_chrome_observer.py'),launcherSourcePins=launcher_pins,versionFilePins=version_pins,
       originalR2AnalysisInput=pin(OLD_INPUT),scope='Only three exact Chrome selectors and 31 literal expanded visible names; runtime unrun.')
    inputs['extraRuntimeFiles'] += launcher_pins
    input_pin=write_json(TASK/'inputs.json',inputs)
    old_controller=read(TEMPLATE/'controller.py').decode('utf-8').replace('\r\n','\n')
    old_worker=read(TEMPLATE/'worker.py').decode('utf-8').replace('\r\n','\n')
    helper=read(TEMPLATE/'heap1536_windows_job.py')
    controller=re.sub(r'\b210\b','510',old_controller).replace('FULL_GUARDIAN_ANALYZE','GUARDIAN_BROWSER31').replace('GUARDIAN_ANALYZE','GUARDIAN_BROWSER31')
    worker=re.sub(r'\b195\b','495',old_worker)
    worker=re.sub(r'\b180\b','480',worker)
    worker=worker.replace("FROZEN = REPO / '.cache/guardian-current-20261021-r2'","FROZEN = CANDIDATE")
    worker=worker.replace("INPUT = FROZEN / 'out/analysis-inputs-root.json'","INPUT = CANDIDATE / 'inputs.json'")
    worker=worker.replace(OLD_INPUT_SHA,input_pin['sha256']).replace('404','405')
    worker=worker.replace('one fixed full Guardian analysis','one fixed 31-case Guardian browser regression')
    old_flags="FLAGS = ['--no-version-check', '--suppress-analytics', 'analyze', '--no-pub',\n         '--fatal-infos', '--fatal-warnings']"
    assert old_flags in worker
    worker=worker.replace(old_flags,"FLAGS = ['--no-version-check', '--suppress-analytics', 'test', '--no-pub',\n         '--platform=chrome', '--concurrency=1', '--reporter=json',\n         'test/workspace_flow_entry_browser_test.dart',\n         'test/audit_export_route_test.dart',\n         'test/approval_help_flow_browser_test.dart']")
    worker=worker.replace('FULL_GUARDIAN_ANALYZE','GUARDIAN_BROWSER31')
    worker=worker.replace("'testsRun': False, 'pubRun': False","'testsRequested': True, 'reportedVisibleTests': None, 'pubRun': False")
    worker=worker.replace('command_launched = False','command_launched = False\nprotocol = chrome_observer = None')
    worker=worker.replace("inputs['phase'] == 'analyze-all-guardian', 'Only one fixed Guardian analysis phase'","inputs['phase'] == 'browser-31-guardian', 'Only the fixed 31-case browser phase'")
    worker=worker.replace("cache['status'] == 'READ_ONLY_CONTENT_COLLECTION_COMPLETE_NOT_SDK_VALIDATION'","cache['status'] == 'BROWSER_CHROME_REFRESH_FROM_FIXED_BASE_NOT_RUNTIME_VALIDATION'")
    marker="    totals = {'files': 0, 'bytes': 0}"
    assert worker.count(marker) == 1
    worker=worker.replace(marker,"    base = load_pin(inputs['browserCacheBaseManifest'])\n    protocol.validate_cache_refresh(base, cache, inputs['chromeExecutablePin'])\n"+marker)
    marker='    first = resources()'
    assert worker.count(marker) == 1
    worker=worker.replace(marker,"    for field, name in [('reporterContractCode', 'guardian_browser31_runtime_contract'),\n                        ('ownedChromeObserverCode', 'guardian_browser31_owned_chrome')]:\n        verify_pin(inputs[field])\n        module_spec = importlib.util.spec_from_file_location(name, inputs[field]['path'])\n        module_value = importlib.util.module_from_spec(module_spec)\n        module_spec.loader.exec_module(module_value)\n        if field == 'reporterContractCode':\n            protocol = module_value\n        else:\n            observer_module = module_value\n    expected_cases = load_pin(inputs['expectedCaseContract'])\n    require(expected_cases['selectors'] == FLAGS[-3:] and expected_cases['expectedVisibleCases'] == 31,\n            'Frozen browser selector/name contract changed')\n"+marker)
    worker=worker.replace("CI='true', COMSPEC=str(CMD)","CI='true', CHROME_EXECUTABLE=inputs['chromeExecutablePin']['path'], COMSPEC=str(CMD)")
    worker=worker.replace("ATTEMPT / 'out/analyze.log'","ATTEMPT / 'out/browser31.jsonl'")
    worker=worker.replace("'selectorCount': 0","'selectorCount': 3, 'expectedVisibleCases': 31")
    marker='    state = command_job.wait(deadline, cleanup_deadline)'
    assert worker.count(marker) == 1
    worker=worker.replace(marker,"    chrome_observer = observer_module.OwnedChromeObserver(\n        command_job.pid, inputs['chromeExecutablePin']['path'], ATTEMPT / 'tmp')\n    chrome_observer.start()\n"+marker)
    marker='finally:\n    if inputs is not None:'
    assert worker.count(marker) == 1
    worker=worker.replace(marker,"finally:\n    if chrome_observer is not None:\n        try:\n            receipt['ownedChromeObservation'] = chrome_observer.finish()\n            save('owned-chrome-observation.json', receipt['ownedChromeObservation'])\n        except Exception as observer_error:\n            receipt['chromeObserverError'] = type(observer_error).__name__ + ': ' + str(observer_error)\n    if inputs is not None:")
    old_report="            receipt['noIssuesFound'] = 'No issues found!' in log.read_text('utf-8', errors='replace')"
    assert old_report in worker
    worker=worker.replace(old_report,"            report = protocol.validate_report(log.read_bytes(), expected_cases, str(MODULE),\n                receipt.get('commandTerminalStateAfterPostflight', {}).get('rootExitCode'))\n            receipt['reporterValidation'] = report\n            receipt['reportedVisibleTests'] = report['visibleTests']\n            save('reporter-validation.json', report)")
    worker=worker.replace("            receipt['logPin'] = pin(log)","            require(log.stat().st_size <= 16 * 1024**2, 'Browser reporter log exceeds 16MiB')\n            receipt['logPin'] = pin(log)")
    worker=worker.replace("receipt.get('noIssuesFound') is True","receipt.get('reporterValidation', {}).get('status') == 'EXACT_BROWSER31_REPORT_ACCEPTED'\n              and receipt.get('ownedChromeObservation', {}).get('status') == 'OWNED_CHROME_ARGUMENTS_OBSERVED'")
    for name,raw in [('controller.py',controller.encode()),('worker.py',worker.encode()),('heap1536_windows_job.py',helper)]:
        ast.parse(raw.decode('utf-8'),filename=name)
        create(TASK/name,raw)
    for name,before,after in [('controller.py',old_controller,controller),('worker.py',old_worker,worker)]:
        diff=''.join(difflib.unified_diff(before.splitlines(keepends=True),after.splitlines(keepends=True),fromfile='r2-analysis/'+name,tofile='browser31/'+name))
        create(TASK/('mechanical-'+name+'.diff'),diff.encode())
    create(TASK/'mechanical-native-helper.py.diff',b'')
    preparation={'status':'STATIC_BROWSER31_PREPARATION_ONLY_RUNTIME_UNRUN','sourceCommit':COMMIT,'sourceFiles':405,
       'sevenRootGitTrees':trees,'sourceManifest':source_pin,'mainFullRawHashesRecorded':True,'mainCrLfNormalizedMatchesCommitted':True,
       'fullMainAndFrozenMembershipExact':True,'packageRows':70,'changedInternalRootUris':7,'externalRowsUnchanged':63,
       'originalCacheBaseSha256':CACHE_SHA,'cacheManifest':cache_pin,'cacheTrees':70,'fixedFiles':33,'cacheFiles':3537,
       'otherCachePinsUnchanged':3536,'onlyChromeExecutableRefreshed':True,'fullCacheContentsNotRehashedDuringPreparation':True,
       'fullRuntimePreflightAndPostflightRequired':True,'sourceNameCases':[8,4,19],'actualCasesExecuted':None,
       'outerBudgetSeconds':510,'outerSoftCutoffSeconds':504,'workerBudgetSeconds':495,'commandCapSeconds':480,
       'commandCleanupReserveSeconds':5,'minimumPostflightReserveSeconds':25,'controllerWorkerEolNormalizedToLf':True,'nativeHelperByteIdenticalToR2':True,
       'nativeHelperSha256':sha(helper),'originalFourFilesPreserved':originals,'original26TemplatePinsRetained':True,
       'pureNameParserASTFunctionsOnlyEvaluated':True,'candidateImported':False,'candidateExecuted':False,
       'sdkCalls':0,'testsRun':False,'chromeStarted':False,'networkUsed':False,'mainWritten':False,'attemptExists':False}
    review_pin=write_json(TASK/'preparation-review.json',preparation)
    # Validate everything again before the final CreateNew proposal; no attempt exists.
    assert git('rev-parse','HEAD').decode().strip() == COMMIT and membership(REPO) == main_membership and membership(SRC) == frozen_membership
    for row in entries:
        assert sha(read(REPO/row['path'])) == row['workingTreeRawSha256']
        assert sha(read(SRC/row['path'])) == row['sha256']
    for row in originals:
        verify(row)
    assert pin(CHROME) == chrome and not (TASK/'attempt').exists()
    result={'status':preparation['status'],'inputs':input_pin,'preparationReview':review_pin,'sourceFiles':405,
            'sourceTreeSha256':manifest['sourceTreeSha256'],'expectedVisibleCases':31,'SDKStarted':False,'ChromeStarted':False}
    write_json(TASK/'preparation-receipt.json',result)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
