import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

import psutil
import re

START = time.monotonic()
COMMAND_END, CLEANUP_END = START + 60, START + 65
ROOT = Path(__file__).resolve().parents[2]
MODE = __import__('sys').argv[1]
assert MODE in ('pub-guardian','format','analysis-guardian','vm-guardian')
BASE = Path(__file__).resolve().parent / MODE
BASE.mkdir()
MODULE = ROOT / 'apps/guardian'
SDK = Path('D:/softwares/flutter')
PWSH = Path('C:/Users/Administrator/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe')
HELPER = ROOT / 'scripts/verification/owned_job.py'
HELPER_SHA = '4fe9af9efda326986044163bb48ac1447813cab07730fdfaa689a9c7307ca5ec'
TESTS = ['device_group_change_test.dart', 'device_group_batch_picker_test.dart']
TARGETS = ['lib/core/device_group_change.dart', 'lib/pages/device_groups_page.dart',
    'lib/ui/device_group_batch_picker.dart', 'test/device_group_change_test.dart',
    'test/device_group_batch_picker_test.dart', 'test/device_group_flow_test.dart']
ANALYSIS_TARGETS = TARGETS
FORMAT_TARGETS = TARGETS
CORE_PATHS = ['apps/guardian/'+p for p in TARGETS] + [
    'apps/guardian/lib/core/api.dart', 'apps/guardian/lib/core/device_group_summary.dart',
    'apps/guardian/lib/core/session.dart', 'apps/guardian/lib/pages/device_subflow_scope.dart',
    'apps/guardian/lib/ui/design.dart', 'apps/guardian/lib/ui/resource_page.dart',
    'apps/guardian/lib/ui/resource_action_lease.dart', 'apps/guardian/lib/ui/owned_dialog_route.dart',
    'packages/schedule_contracts/lib/schedule_contracts.dart',
    'packages/schedule_contracts/pubspec.yaml', 'apps/guardian/pubspec.yaml']
INPUTS = [ROOT / p for p in CORE_PATHS]
if not MODE.startswith('pub-'):
    INPUTS += [ROOT / p for p in ['apps/guardian/pubspec.lock','apps/guardian/.dart_tool/package_config.json']]


def lock_blocks(path):
    blocks = {}
    current = None
    for line in path.read_text(encoding='utf-8').splitlines():
        found = re.fullmatch(r'  ([A-Za-z0-9_]+):', line)
        if found:
            current = found.group(1)
            blocks[current] = []
        elif line and not line.startswith(' '):
            current = None
        elif current is not None:
            blocks[current].append(line)
    return {name: '\n'.join(lines) for name, lines in blocks.items()}


def pin(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def inventory():
    code = r"""$ErrorActionPreference='Stop'; $p=@(Get-Process); [pscustomobject]@{sdk=@($p|Where-Object {$_.ProcessName -match '^(dart|dartaotruntime|flutter|flutter_tester|gen_snapshot|java|javac|gradle|gradlew|mvn|go|gofmt|compile|link|asm|cgo|vet|.+\.test)$'}|Select-Object -ExpandProperty ProcessName);unknown=@($p|Where-Object {[string]::IsNullOrWhiteSpace($_.ProcessName)}).Count}|ConvertTo-Json -Compress"""
    completed = subprocess.run([str(PWSH), '-NoLogo', '-NoProfile', '-Command', code],
        capture_output=True, text=True, encoding='utf-8', timeout=10, check=True)
    return json.loads(completed.stdout)

def resources():
    return {'ram': psutil.virtual_memory().available,
            'cFree': psutil.disk_usage('C:/').free, 'dFree': psutil.disk_usage('D:/').free}

receipt = {'status': 'NOT_RUN', 'sdkCalls': 0, 'tests': TESTS, 'forceRequested': False}
job = None
state = None
try:
    (BASE / 'tmp').mkdir()
    (BASE / 'out').mkdir()
    assert pin(HELPER) == HELPER_SHA, 'Qualified OwnedJob helper changed'
    receipt['head'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    before = {str(p.relative_to(ROOT)): pin(p) for p in INPUTS}
    lock_before = lock_blocks(MODULE / 'pubspec.lock') if MODE.startswith('pub-') else None
    receipt['resourcesBefore'] = resources()
    receipt['sdkBefore'] = inventory()
    assert min(receipt['resourcesBefore'].values()) >= 2**31, 'Original resource gate not met'
    assert not receipt['sdkBefore']['sdk'] and receipt['sdkBefore']['unknown'] == 0, 'SDKs busy or unknown names'
    spec = importlib.util.spec_from_file_location('qualified_owned_job', HELPER)
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    job = native.OwnedJob()
    env = os.environ.copy()
    env.update(TEMP=str(BASE / 'tmp'), TMP=str(BASE / 'tmp'),
        PATH=r'C:\Windows\System32;C:\Program Files\Git\cmd;D:\softwares\flutter\bin\cache\dart-sdk\bin',
        PUB_HOSTED_URL='http://127.0.0.1:9', FLUTTER_STORAGE_BASE_URL='http://127.0.0.1:9',
        FLUTTER_SUPPRESS_ANALYTICS='true', DART_SUPPRESS_ANALYTICS='true', CI='true',
        COMSPEC=r'C:\Windows\System32\cmd.exe', GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0',
        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL', GIT_CONFIG_COUNT='2',
        GIT_CONFIG_KEY_0='safe.directory', GIT_CONFIG_VALUE_0=ROOT.as_posix(),
        GIT_CONFIG_KEY_1='safe.directory', GIT_CONFIG_VALUE_1=SDK.as_posix())
    if MODE.startswith('pub-'):
        env['PUB_HOSTED_URL'] = 'https://pub.dev'
        command = str(SDK / 'bin/flutter.bat') + ' --no-version-check --suppress-analytics pub get --offline'
    elif MODE.startswith('analysis'):
        command = str(SDK / 'bin/flutter.bat') + ' analyze --no-pub --fatal-infos --fatal-warnings ' + ' '.join(ANALYSIS_TARGETS)
    elif MODE.startswith('format'):
        command = str(SDK / 'bin/cache/dart-sdk/bin/dart.exe') + ' format ' + ' '.join(FORMAT_TARGETS)
    else:
        command = str(SDK / 'bin/flutter.bat') + ' test --no-pub --concurrency=1 --machine ' + ' '.join('test/' + name for name in TESTS)

    assert not any(c in command for c in '&|<>^%!"\r\n'), 'Unsafe fixed command text'
    assert time.monotonic() + 1 < COMMAND_END, 'No original command budget remains'
    job.create_suspended([r'C:\Windows\System32\cmd.exe', '/d', '/v:off', '/c', command],
        MODULE, BASE / 'out/tests.jsonl', env)
    state = job.sample(0)
    assert not state['signaled'] and state['activeProcesses'] == 1, 'Suspended root is not exclusive'
    receipt.update(status='STARTED', sdkCalls=1, pid=job.pid, command=command)
    job.resume()
    print(json.dumps({'status': 'STARTED', 'pid': job.pid, 'files': len(TESTS)}), flush=True)
    while True:
        state = job.sample(50)
        if state['terminal']:
            break
        end = min(COMMAND_END, state['firstSignaledQpc'] + .5) if state['signaled'] else COMMAND_END
        if time.monotonic() >= end:
            job.terminate_owned()
            while not state['terminal'] and time.monotonic() < CLEANUP_END:
                state = job.sample(50)
            break
    receipt['terminal'] = state
    receipt['forceRequested'] = job.force_requested
    receipt['naturalZero'] = bool(state['terminal'] and state['exitCode'] == 0 and not job.force_requested
        and START <= state['firstSignaledQpc'] <= state['firstCompleteTerminalQpc']
        < min(COMMAND_END, state['firstSignaledQpc'] + .5))
    events = []
    for line in (BASE / 'out/tests.jsonl').read_text(encoding='utf-8-sig').splitlines():
        try:
            event = json.loads(line)
            if isinstance(event, dict): events.append(event)
        except json.JSONDecodeError:
            pass
    endings = [e for e in events if e.get('type') == 'testDone' and e.get('hidden') is False]
    suites = [e['suite'] for e in events if e.get('type') == 'suite']
    expected = {str((MODULE / 'test' / name).resolve()).casefold() for name in TESTS}
    actual = {str(Path(s['path']).resolve()).casefold() for s in suites}
    receipt.update(passed=sum(e.get('result') == 'success' and not e.get('skipped') for e in endings),
        failed=sum(e.get('result') != 'success' for e in endings),
        skipped=sum(bool(e.get('skipped')) for e in endings),
        reporterDone=any(e.get('type') == 'done' and e.get('success') is True for e in events),
        suiteFilesMatch=actual == expected and len(suites) == len(TESTS),
        sourceUnchanged=before == {str(p.relative_to(ROOT)): pin(p) for p in INPUTS})
    receipt['sourcePins'] = before
    receipt['sdkAfter'] = inventory()
    receipt['appTestsPassed'] = bool(receipt['naturalZero'] and receipt['reporterDone'] and len(endings) == 5
        and not receipt['failed'] and not receipt['skipped'] and receipt['suiteFilesMatch'] and receipt['sourceUnchanged'])
    receipt['windowReleased'] = not receipt['sdkAfter']['sdk'] and receipt['sdkAfter']['unknown'] == 0
    if MODE.startswith('pub-'):
        after = lock_blocks(MODULE / 'pubspec.lock')
        added = sorted(set(after)-set(lock_before))
        removed = sorted(set(lock_before)-set(after))
        changed = sorted(name for name in set(after)&set(lock_before) if after[name] != lock_before[name])
        receipt['lockDelta'] = {'added':added,'removed':removed,'changed':changed}
        local = after.get('schedule_contracts','')
        receipt['onlyLocalDependencyAdded'] = added == ['schedule_contracts'] and not removed and not changed and 'source: path' in local and '../../packages/schedule_contracts' in local and 'version: "1.0.0"' in local
        receipt['status'] = 'PASSED' if receipt['naturalZero'] and receipt['windowReleased'] and receipt['sourceUnchanged'] and receipt['onlyLocalDependencyAdded'] else 'NOT_ACCEPTED'
    elif (MODE.startswith('analysis') or MODE.startswith('format')):
        output = (BASE / 'out/tests.jsonl').read_text(encoding='utf-8-sig')
        receipt['analysisNoIssues'] = 'No issues found!' in output if MODE.startswith('analysis') else None
        receipt['formatCompleted'] = 'Formatted 6 files' in output if MODE.startswith('format') else None
        receipt['status'] = 'PASSED' if receipt['naturalZero'] and receipt['windowReleased'] and (receipt['analysisNoIssues'] if MODE.startswith('analysis') else receipt['formatCompleted']) and (receipt['sourceUnchanged'] or MODE.startswith('format')) else 'NOT_ACCEPTED'
    else:
        receipt['status'] = 'PASSED' if receipt['appTestsPassed'] and receipt['windowReleased'] else 'NOT_ACCEPTED'
except BaseException as error:
    receipt['error'] = str(error)
    receipt['status'] = 'NOT_ACCEPTED' if receipt['sdkCalls'] else 'NO_START'
finally:
    if job is not None:
        if job.process is not None:
            state = job.sample(0)
            if state['activeProcesses']:
                job.terminate_owned()
                while time.monotonic() < CLEANUP_END:
                    state = job.sample(50)
                    if state['terminal']: break
            receipt['forceRequested'] = job.force_requested
            receipt['finalOwnedState'] = state
        job.close()
    receipt['elapsedSeconds'] = time.monotonic() - START
    with (BASE / 'result.json').open('x', encoding='utf-8') as stream:
        json.dump(receipt, stream, ensure_ascii=True, indent=2)
    print(json.dumps({k: v for k, v in receipt.items() if k in
        ('status','sdkCalls','passed','failed','skipped','error','forceRequested','elapsedSeconds')}), flush=True)
raise SystemExit(0 if receipt['status'] == 'PASSED' else 1)
