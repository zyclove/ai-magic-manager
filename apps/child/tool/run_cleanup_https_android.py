"""Attach the official driver to a dedicated owned Android HTTPS cleanup test.

The JVM owns the loopback TLS server and private input. No ticket, credential,
proof or pairing code is passed as an argument or included in public reports.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import urlsplit
import uuid
from run_cleanup_android import PACKAGE, parse_installation, validate_apk, validate_target

PHASES = {'negative', 'enroll', 'active', 'cleanup', 'verify'}
INPUT = 'files/cleanup-https-input.json'
HANDOFF = 'files/cleanup-https-handoff.json'


def validate_fixture(value):
    common = {'schemaVersion', 'runId', 'tenantId', 'subjectId', 'phase',
              'apiRoot', 'serverCertificateDerBase64'}
    phase = value.get('phase')
    required = common | ({'ticket'} if phase == 'enroll' else set())
    if phase in {'active', 'cleanup', 'verify'}:
        required |= {'deviceId', 'registrationId'}
    if phase in {'cleanup', 'verify'}:
        required |= {'operationId', 'commandHash'}
    if value.keys() != required or type(value.get('schemaVersion')) is not int or value['schemaVersion'] != 1 or phase not in PHASES:
        raise ValueError('Unsupported or ambiguous private fixture')
    for name in required & {'runId', 'tenantId', 'subjectId', 'deviceId', 'registrationId', 'operationId'}:
        uuid.UUID(value[name])
    api = urlsplit(value['apiRoot'])
    if (api.scheme != 'https' or api.hostname != '127.0.0.1' or not api.port
            or api.username or api.password or api.query or api.fragment or api.path != '/api/v1'):
        raise ValueError('Only the JVM-owned loopback HTTPS endpoint is allowed')
    cert = base64.b64decode(value['serverCertificateDerBase64'], validate=True)
    if not cert or len(cert) > 16384:
        raise ValueError('One bounded public test certificate required')
    if phase == 'enroll':
        ticket = value['ticket']
        if (not isinstance(ticket, dict) or ticket.keys() != {'tenantId', 'id', 'token', 'expiresAt'}
                or ticket['tenantId'] != value['tenantId'] or not isinstance(ticket['token'], str)
                or not 1 <= len(ticket['token']) <= 256 or type(ticket['expiresAt']) is not int
                or ticket['expiresAt'] <= 0):
            raise ValueError('Explicit scoped enrollment ticket required')
        uuid.UUID(ticket['id'])
    if phase in {'cleanup', 'verify'} and not re.fullmatch(r'[0-9a-f]{64}', value['commandHash']):
        raise ValueError('Expected immutable cleanup command digest required')
    return api


def validate_result(value, phase, native_pid):
    finished = phase in {'cleanup', 'verify'}
    expected = {'phase': phase, 'pid': native_pid, 'realTls': True,
                'untrustedCertificateRejected': True, 'realAndroidKey': True,
                'cloudResponsesAreReal': True, 'adultIdentityIsFixture': True,
                'cleanupCompleted': finished, 'journalRetained': finished,
                'originalKeyDeleted': finished, 'cachesDeleted': finished,
                'physicalWipeProven': False}
    if (phase not in PHASES - {'negative'} or value != expected
            or any(type(value.get(key)) is not type(item) for key, item in expected.items())):
        raise ValueError('Native HTTPS report differs from required scope or boundary')


def validate_handoff(value):
    if (not isinstance(value, dict) or value.keys() != {'deviceId', 'registrationId', 'pairingCode'}
            or not re.fullmatch(r'[A-Z0-9]{8}', value.get('pairingCode', ''))):
        raise ValueError('Invalid private pairing handoff')
    uuid.UUID(value['deviceId'])
    uuid.UUID(value['registrationId'])


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_installation(query, pause=time.sleep):
    # adb occasionally loses a read-only dumpsys exchange. Retry no mutation,
    # never retry ambiguous metadata, and never infer an installation identity.
    for attempt in range(3):
        try:
            value = query()
        except RuntimeError:
            if attempt == 2:
                raise
            pause(.2 * (attempt + 1))
            continue
        return parse_installation(value), attempt
    raise RuntimeError('Installation metadata unavailable')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--phase', choices=sorted(PHASES), required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--apk', type=Path, required=True)
    for flag in ['adb', 'aapt', 'flutter', 'serial', 'expected-avd']:
        parser.add_argument('--' + flag, required=True)
    parser.add_argument('--allow-owned-debug-avd', action='store_true')
    args = parser.parse_args()
    app, fixture_path, apk = args.app.resolve(), args.fixture.resolve(), args.apk.resolve()
    if ('.local' not in fixture_path.parts or not fixture_path.parent.name.startswith('android-cleanup-https-')
            or not apk.is_file() or apk.suffix != '.apk'):
        raise ValueError('Isolated JVM fixture and prebuilt test APK required')
    fixture = json.loads(fixture_path.read_text(encoding='utf-8'))
    api = validate_fixture(fixture)
    if fixture['phase'] != args.phase:
        raise ValueError('Requested phase differs from private fixture')
    validate_apk(apk, args.aapt)
    directory = fixture_path.parent / ('native-' + args.phase)
    directory.mkdir(exist_ok=False)
    process = None
    owned = False
    reverse_owned = False
    forwarded = None
    metadata_read_retries = 0
    mapping = 'tcp:' + str(api.port)

    def adb(*command, check=True, payload=None):
        result = subprocess.run([args.adb, '-s', args.serial, *command], input=payload,
                                capture_output=True, timeout=30)
        if check and result.returncode:
            raise RuntimeError('Owned Android command failed: ' + command[0] + ' (exit ' + str(result.returncode) + ')')
        return result.stdout

    def text(*command, check=True):
        return adb(*command, check=check).decode('utf-8', errors='replace').strip()

    def metadata():
        nonlocal metadata_read_retries
        result, retries = read_installation(lambda: text('shell', 'dumpsys', 'package', PACKAGE))
        metadata_read_retries += retries
        return result

    def stop_app():
        adb('shell', 'am', 'force-stop', PACKAGE)
        for _ in range(30):
            if not text('shell', 'pidof', PACKAGE, check=False):
                return
            time.sleep(.1)
        raise RuntimeError('Owned process did not stop')

    try:
        validate_target(args.serial, args.expected_avd, text('emu', 'avd', 'name'), args.allow_owned_debug_avd)
        if text('shell', 'getprop', 'sys.boot_completed') != '1' or text('shell', 'getprop', 'ro.build.version.sdk') != '34':
            raise RuntimeError('Dedicated API34 emulator must be booted')
        if text('shell', 'am', 'get-current-user') != '0':
            raise RuntimeError('Dedicated primary-user installation required')
        owned = True
        installed = text('shell', 'pm', 'list', 'packages', PACKAGE)
        if installed not in {'', 'package:' + PACKAGE}:
            raise RuntimeError('Ambiguous debug installation')
        before = metadata() if installed else None
        if before is None and args.phase not in {'negative', 'enroll'}:
            raise RuntimeError('Previous native installation required')
        if any(mapping in line.split() for line in text('reverse', '--list').splitlines()):
            raise RuntimeError('Refuse to replace an existing reverse mapping')
        stop_app()
        if 'Success' not in text('install', '-r', str(apk)):
            raise RuntimeError('Preserving APK install failed; no uninstall fallback')
        after = metadata()
        if before is not None and before != after:
            raise RuntimeError('Installation identity changed')
        installed_path = text('shell', 'pm', 'path', PACKAGE).removeprefix('package:')
        if not re.fullmatch(r'/data/app/[A-Za-z0-9_~+=./-]+\.apk', installed_path) or '/../' in installed_path:
            raise RuntimeError('Unexpected installed APK path')
        if text('shell', 'sha256sum', installed_path).split()[0] != sha(apk):
            raise RuntimeError('Installed APK digest mismatch')
        adb('reverse', mapping, mapping)
        reverse_owned = True
        adb('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'files')
        adb('shell', 'run-as', PACKAGE, 'sh', '-c', '"cat > ' + INPUT + '"', payload=fixture_path.read_bytes())
        adb('shell', 'am', 'start', '-n', PACKAGE + '/com.aimanager.child.MainActivity',
            '--ez', 'start-paused', 'true', '--ez', 'enable-dart-profiling', 'true')
        deadline = time.monotonic() + 40
        vm = None
        while time.monotonic() < deadline:
            native_pid = text('shell', 'pidof', PACKAGE, check=False)
            if native_pid.isdigit():
                logs = text('logcat', '-d', '--pid=' + native_pid, '-v', 'raw')
                match = re.search(r'(?:Dart VM service|Observatory)[^\r\n]*(http://127\.0\.0\.1:[0-9]+/[^\s]+)', logs)
                if match:
                    vm = urlsplit(match.group(1))
                    break
            time.sleep(.1)
        if vm is None:
            raise RuntimeError('Paused native VM discovery failed')
        port = text('forward', 'tcp:0', 'tcp:' + str(vm.port))
        if not port.isdigit():
            raise RuntimeError('Invalid owned forward port')
        forwarded = 'tcp:' + port
        env = os.environ.copy()
        env['FLUTTER_TEST_OUTPUTS_DIR'] = str(directory)
        options = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {'start_new_session': True}
        command = [args.flutter, 'drive', '--no-pub', '--keep-app-running',
                   '--driver=test_driver/cleanup_https_driver.dart',
                   '--target=integration_test/cleanup_https_test.dart', '-d', args.serial,
                   '--use-existing-app=http://127.0.0.1:' + port + vm.path]
        log = directory / 'driver.log'
        with log.open('wb') as output:
            process = subprocess.Popen(command, cwd=app, env=env, stdout=output, stderr=subprocess.STDOUT, **options)
            code = process.wait(timeout=180)
        if text('shell', 'pidof', PACKAGE) != native_pid:
            raise RuntimeError('Native PID changed during phase')
        native_log = text('logcat', '-d', '--pid=' + native_pid, '-v', 'raw')
        (directory / 'native.log').write_text(native_log, encoding='utf-8')
        if args.phase == 'negative':
            if code == 0 or 'NATIVE_CLEANUP_HTTPS_MISSING_SEED' not in native_log:
                raise RuntimeError('Missing-seed control failed for an unexpected reason')
            result = {'phase': 'negative', 'pid': int(native_pid), 'expectedMissingSeedFailure': True}
        else:
            if code != 0:
                raise RuntimeError('Native HTTPS phase failed; inspect local safe logs')
            result = json.loads((directory / 'cleanup_https_result.json').read_text(encoding='utf-8'))
            validate_result(result, args.phase, int(native_pid))
        if metadata() != after:
            raise RuntimeError('Installation changed during phase')
        if args.phase == 'enroll':
            pairing = adb('exec-out', 'run-as', PACKAGE, 'cat', HANDOFF)
            validate_handoff(json.loads(pairing))
            (fixture_path.parent / 'pairing.json').write_bytes(pairing)
            adb('shell', 'run-as', PACKAGE, 'rm', HANDOFF)
        if text('shell', 'run-as', PACKAGE, 'ls', INPUT, check=False):
            raise RuntimeError('Private input was not consumed')
        stop_app()
        result.update({'driverExitCode': code, 'installation': after, 'serial': args.serial,
                       'avd': args.expected_avd, 'apiLevel': 34, 'nativePidVerified': True,
                       'processStopped': True, 'installPreserved': before is None or before == after,
                       'metadataReadRetries': metadata_read_retries,
                       'driverAttachedExistingApp': True, 'apkSha256': sha(apk),
                       'driverLogSha256': sha(log), 'nativeLogSha256': sha(directory / 'native.log')})
        (directory / 'host-result.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        print('Android real HTTPS cleanup ' + args.phase + ': PASS; process stopped', flush=True)
    finally:
        try:
            if owned:
                stop_app()
        finally:
            try:
                if process is not None and process.poll() is None:
                    if os.name == 'nt':
                        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True, timeout=20)
                    else:
                        import signal
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=20)
            finally:
                try:
                    if owned:
                        adb('shell', 'run-as', PACKAGE, 'rm', '-f', INPUT, HANDOFF, check=False)
                finally:
                    try:
                        if forwarded is not None:
                            adb('forward', '--remove', forwarded, check=False)
                    finally:
                        if reverse_owned:
                            adb('reverse', '--remove', mapping, check=False)


if __name__ == '__main__':
    main()
