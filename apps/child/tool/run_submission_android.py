"""Official-driver orchestration for an explicitly owned debug AVD.

Invoked by AndroidChildSubmissionJourneyTest while its real Spring server is
live. Uses the Python standard library, Flutter's integration_test driver and
adb. No secret is passed in an argument, logged, or compiled into the APK.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess
import time
import uuid
from urllib.parse import urlsplit

PACKAGE = 'com.aimanager.child.debug'
PHASES = {'enroll', 'submit', 'recover', 'cancel', 'cancel-recover', 'expired', 'offline', 'revoked', 'blocked', 'cleanup'}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def install_preserving_data(adb, metadata, apk):
    before = metadata()
    try:
        output = adb('install', '-r', str(apk))
        if b'Success' not in output:
            raise RuntimeError('Install did not succeed')
    except Exception:
        # Never delegate installation to Flutter's retry/uninstall fallback.
        raise RuntimeError('Preserving install failed; no uninstall or retry allowed') from None
    if metadata() != before:
        raise RuntimeError('Preserving installation identity changed')
    return before


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--phase', choices=sorted(PHASES), required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--flutter', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--expected-avd', required=True)
    parser.add_argument('--allow-owned-debug-avd', action='store_true')
    args = parser.parse_args()
    if not args.allow_owned_debug_avd or not re.fullmatch(r'emulator-[0-9]+', args.serial):
        raise RuntimeError('Explicit owned debug AVD authorization is required')
    app, fixture_path = args.app.resolve(), args.fixture.resolve()
    if '.local' not in fixture_path.parts or not fixture_path.parent.name.startswith('android-child-http-'):
        raise RuntimeError('Fixture must be in the JVM-created private run directory')
    fixture = json.loads(fixture_path.read_text(encoding='utf-8'))
    api = urlsplit(fixture['apiRoot'])
    if (api.scheme != 'http' or api.hostname != '127.0.0.1' or api.path != '/api/v1'
            or api.username or api.password or api.query or api.fragment or not api.port):
        raise RuntimeError('Only the JVM-owned loopback Spring endpoint is allowed')
    if fixture.get('schemaVersion') != 1:
        raise RuntimeError('Unsupported fixture schema')
    uuid.UUID(fixture['runId'])
    sources = ['integration_test/submission_http_test.dart', 'test_driver/submission_http_driver.dart', 'tool/run_submission_android.py',
               'lib/core/session.dart', 'lib/core/submission_receiver.dart', 'lib/ui/child_app.dart']
    source_sha = {name: digest(app / name) for name in sources}
    directory = fixture_path.parent / ('native-' + args.phase)
    directory.mkdir()
    # Non-secret recovery coordinates survive a failed phase. Never retain the
    # registration ticket, pairing code or credential in this manifest.
    manifest = {k: fixture[k] for k in ['schemaVersion', 'runId', 'tenantId', 'subjectId', 'apiRoot']}
    (fixture_path.parent / 'run-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    leaf = 'android-http-' + uuid.uuid4().hex + '.json'
    private_input, private_handoff = 'files/' + leaf, 'files/' + leaf + '.handoff'
    mapping = 'tcp:' + str(api.port)
    reverse_owned = False
    forward_owned = None
    process = None

    def adb(*command, check=True, payload=None):
        result = subprocess.run([args.adb, '-s', args.serial, *command], input=payload,
                                capture_output=True, timeout=30)
        if check and result.returncode:
            # Neither command output nor private file contents enter diagnostics.
            raise RuntimeError('Owned AVD command failed: ' + command[0])
        return result.stdout

    def text(*command, check=True):
        return adb(*command, check=check).decode('utf-8', errors='replace').strip()

    def stop_app():
        adb('shell', 'am', 'force-stop', PACKAGE)
        for _ in range(30):
            if not text('shell', 'pidof', PACKAGE, check=False):
                return
            time.sleep(.1)
        raise RuntimeError('Owned Android process did not stop')

    def stop_driver():
        if process is None or process.poll() is not None:
            return
        if os.name == 'nt':
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                           capture_output=True, timeout=15, check=False)
        else:
            import signal
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=15)

    def metadata():
        value = text('shell', 'dumpsys', 'package', PACKAGE)
        uid = re.search(r'\b(?:userId|appId)=([0-9]+)', value)
        installed = re.search(r'firstInstallTime=([^\r\n]+)', value)
        if not uid or not installed:
            raise RuntimeError('Install the ordinary owned debug application first')
        return {'uid': uid.group(1), 'firstInstallTime': installed.group(1).strip()}

    if text('emu', 'avd', 'name').splitlines()[0].strip() != args.expected_avd:
        raise RuntimeError('AVD ownership/name mismatch')
    if text('shell', 'getprop', 'sys.boot_completed') != '1':
        raise RuntimeError('Owned AVD has not finished booting')
    before = metadata()
    stop_app()
    existing = [line.split() for line in text('reverse', '--list').splitlines()]
    if any(mapping in values for values in existing):
        raise RuntimeError('Refuse to replace an existing adb reverse mapping')
    try:
        env = os.environ.copy()
        env['FLUTTER_TEST_OUTPUTS_DIR'] = str(directory)
        options = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {'start_new_session': True}
        build = [args.flutter, 'build', 'apk', '--debug', '--no-pub',
                 '--target=integration_test/submission_http_test.dart',
                 '--dart-define=ANDROID_HTTP_PHASE=' + args.phase,
                 '--dart-define=ANDROID_HTTP_INPUT=' + leaf]
        with (directory / 'build.log').open('wb') as log:
            process = subprocess.Popen(build, cwd=app, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, **options)
            if process.wait(timeout=240) != 0:
                raise RuntimeError('Native APK build failed; no installation attempted')
        apk = app / 'build/app/outputs/flutter-apk/app-debug.apk'
        assert install_preserving_data(adb, metadata, apk) == before
        if args.phase not in {'offline', 'blocked', 'cleanup'}:
            adb('reverse', mapping, mapping)
            reverse_owned = True
        adb('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'files')
        # The random basename contains no shell metacharacters; data is stdin.
        adb('shell', 'run-as', PACKAGE, 'sh', '-c', '"cat > ' + private_input + '"',
            payload=fixture_path.read_bytes())
        adb('shell', 'am', 'start', '-n', PACKAGE + '/com.aimanager.child.MainActivity',
            '--ez', 'start-paused', 'true', '--ez', 'enable-dart-profiling', 'true')
        deadline = time.monotonic() + 30
        vm = None
        while time.monotonic() < deadline:
            native_pid = text('shell', 'pidof', PACKAGE, check=False)
            if native_pid.isdigit():
                output = text('logcat', '-d', '--pid=' + native_pid, '-v', 'raw')
                match = re.search(r'(?:Dart VM service|Observatory)[^\r\n]*(http://127\.0\.0\.1:[0-9]+/[^\s]+)', output)
                if match:
                    vm = urlsplit(match.group(1))
                    break
            time.sleep(.1)
        if vm is None:
            raise RuntimeError('Paused native VM service discovery failed')
        forwarded = text('forward', 'tcp:0', 'tcp:' + str(vm.port))
        assert forwarded.isdigit()
        forward_owned = 'tcp:' + forwarded
        vm_uri = 'http://127.0.0.1:' + forwarded + vm.path
        command = [args.flutter, 'drive', '--no-pub', '--keep-app-running',
                   '--driver=test_driver/submission_http_driver.dart',
                   '--target=integration_test/submission_http_test.dart', '-d', args.serial,
                   '--use-existing-app=' + vm_uri]
        crash = args.phase in {'submit', 'cancel'}
        with (directory / 'driver.log').open('wb') as log:
            process = subprocess.Popen(command, cwd=app, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, **options)
            if crash:
                deadline = time.monotonic() + 300
                data = None
                while time.monotonic() < deadline:
                    output = (directory / 'driver.log').read_text(encoding='utf-8', errors='replace')
                    match = re.search(r'ANDROID_HTTP_CRASH_POINT (\{[^\r\n]+\})', output)
                    if match:
                        data = json.loads(match.group(1))
                        break
                    if process.poll() is not None:
                        raise RuntimeError('Android exited before committed-response checkpoint')
                    time.sleep(.1)
                if data is None:
                    raise RuntimeError('Committed-response checkpoint deadline exceeded')
                assert data['phase'] == args.phase and data['realResponseDrained']
                assert data['committedStatus'] == (201 if args.phase == 'submit' else 200)
                assert process.poll() is None
            else:
                code = process.wait(timeout=300)
                if code != 0:
                    raise RuntimeError('Android phase failed; inspect the private safe driver log')
                data = json.loads((directory / 'android_http_result.json').read_text(encoding='utf-8'))
                assert data['phase'] == args.phase and data['systemEnforced'] is False
        pids = text('shell', 'pidof', PACKAGE).split()
        assert len(pids) == 1 and int(pids[0]) == data['pid']
        after = metadata()
        assert before == after
        apk_path = text('shell', 'pm', 'path', PACKAGE).removeprefix('package:')
        assert re.fullmatch(r'/data/app/[A-Za-z0-9_~+=./-]+\.apk', apk_path) and '/../' not in apk_path
        installed_sha = text('shell', 'sha256sum', apk_path).split()[0]
        assert installed_sha == digest(app / 'build/app/outputs/flutter-apk/app-debug.apk')
        assert source_sha == {name: digest(app / name) for name in sources}
        assert not text('shell', 'run-as', PACKAGE, 'ls', private_input, check=False)
        if args.phase == 'enroll':
            handoff = adb('exec-out', 'run-as', PACKAGE, 'cat', private_handoff)
            private_result = json.loads(handoff)
            uuid.UUID(private_result['deviceId'])
            uuid.UUID(private_result['registrationId'])
            assert re.fullmatch(r'[A-Z0-9]{8}', private_result['pairingCode'])
            # A short-lived local private handoff, never printed or reportData.
            (fixture_path.parent / 'pairing.json').write_bytes(handoff)
            adb('shell', 'run-as', PACKAGE, 'rm', private_handoff)
        stop_app()
        if crash:
            stop_driver()
            assert not (directory / 'android_http_result.json').exists()
        data.update({'driverExitCode': process.returncode, 'deliberateInFlightTermination': crash,
                     'nativePidVerified': True, 'processStopped': True, 'installation': after,
                     'explicitPreservingInstallVerified': True, 'driverAttachedExistingApp': True,
                     'installedApkSha256': installed_sha, 'sourceSha256': source_sha,
                     'driverLogSha256': digest(directory / 'driver.log'),
                     'buildLogSha256': digest(directory / 'build.log')})
        (directory / 'host-result.json').write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
        print('Android real HTTP ' + args.phase + ': PASS; process stopped', flush=True)
    finally:
        # Losing the AVD must not prevent cleanup of this owned driver process.
        try:
            stop_app()
        finally:
            try:
                stop_driver()
            finally:
                # Exact owned names only; never clear app data or uninstall.
                try:
                    adb('shell', 'run-as', PACKAGE, 'rm', '-f', private_input, private_handoff, check=False)
                finally:
                    try:
                        if forward_owned is not None:
                            adb('forward', '--remove', forward_owned, check=False)
                    finally:
                        if reverse_owned:
                            adb('reverse', '--remove', mapping, check=False)


if __name__ == '__main__':
    main()
