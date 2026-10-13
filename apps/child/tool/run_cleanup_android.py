"""Run native cleanup on an explicitly owned, dedicated debug Android AVD.

Install with adb -r (no uninstall/reset fallback), attach the official Flutter
driver to that running process, and correlate install metadata, PID and APK.
Only synthetic fixture state is accepted by the integration entry point.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import urlsplit

PACKAGE = 'com.aimanager.child.debug'
PHASES = {'negative', 'seed', 'clear', 'finish', 'verify'}


def validate_target(serial, expected, actual, allowed):
    if (not allowed or not re.fullmatch(r'emulator-[0-9]+', serial)
            or not re.fullmatch(r'[A-Za-z0-9_-]+', expected)
            or [line.strip() for line in actual.splitlines() if line.strip()] != [expected, 'OK']):
        raise ValueError('Explicit owned debug emulator identity required')


def parse_installation(value):
    uid = re.findall(r'^\s*(?:userId|appId)=([0-9]+)\s*$', value, re.M)
    first = re.findall(r'^\s*firstInstallTime=([^\r\n]+)', value, re.M)
    if len(uid) != 1 or len(first) != 1 or not first[0].strip():
        raise ValueError('Unique installation metadata unavailable')
    return {'uid': uid[0], 'firstInstallTime': first[0].strip()}


def validate_result(result, phase, native_pid):
    expected = {
        'phase': phase, 'pid': native_pid,
        'realAndroidStorage': True, 'realAndroidKeyAlias': True,
        'cloudIsControlledSubstitute': True,
        'cacheDeletionChecked': phase != 'seed',
        'originalKeyRetained': phase in {'seed', 'clear'},
        'originalKeyDeletionChecked': phase in {'finish', 'verify'},
        'expiredAcknowledgedRecovery': phase == 'finish',
        'physicalWipeProven': False,
    }
    if phase not in PHASES - {'negative'} or result != expected:
        raise ValueError('Native report does not match required phase and evidence')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_apk(apk, aapt):
    result = subprocess.run([aapt, 'dump', 'badging', str(apk)],
                            capture_output=True, timeout=30)
    if result.returncode != 0:
        raise ValueError('APK manifest inspection failed; installation forbidden')
    lines = result.stdout.decode('utf-8', errors='strict').splitlines()
    packages = [line for line in lines if line.startswith('package:')]
    if (len(packages) != 1
            or re.match(r"^package: name='([^']+)'(?:\s|$)", packages[0]) is None
            or re.match(r"^package: name='([^']+)'(?:\s|$)", packages[0]).group(1) != PACKAGE
            or lines.count('application-debuggable') != 1):
        raise ValueError('Only the expected child debug APK can be installed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=sorted(PHASES), required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--aapt', required=True)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--flutter', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--expected-avd', required=True)
    parser.add_argument('--allow-owned-debug-avd', action='store_true')
    args = parser.parse_args()
    app, apk, artifacts = args.app.resolve(), args.apk.resolve(), args.artifacts.resolve()
    if '.local' not in artifacts.parts or not apk.is_file() or apk.suffix != '.apk':
        raise ValueError('Existing test APK and isolated local artifacts required')
    validate_apk(apk, args.aapt)
    artifacts.mkdir(parents=True, exist_ok=False)
    process = None
    forwarded = None
    owned = False

    def adb(*command, check=True):
        result = subprocess.run([args.adb, '-s', args.serial, *command],
                                capture_output=True, timeout=30)
        if check and result.returncode:
            raise RuntimeError('Owned Android command failed: ' + command[0])
        return result.stdout.decode('utf-8', errors='replace').strip()

    def metadata():
        return parse_installation(adb('shell', 'dumpsys', 'package', PACKAGE))

    def stop_app():
        adb('shell', 'am', 'force-stop', PACKAGE)
        for _ in range(30):
            if not adb('shell', 'pidof', PACKAGE, check=False):
                return
            time.sleep(.1)
        raise RuntimeError('Known native process did not stop')

    try:
        validate_target(args.serial, args.expected_avd,
                        adb('emu', 'avd', 'name'), args.allow_owned_debug_avd)
        if adb('shell', 'getprop', 'sys.boot_completed') != '1':
            raise RuntimeError('Owned emulator not ready')
        api_level = adb('shell', 'getprop', 'ro.build.version.sdk')
        if api_level != '34':
            raise RuntimeError('This acceptance requires the dedicated API34 image')
        if adb('shell', 'am', 'get-current-user') != '0':
            raise RuntimeError('Dedicated primary-user installation required')
        owned = True
        installed = adb('shell', 'pm', 'list', 'packages', PACKAGE)
        if installed not in {'', 'package:' + PACKAGE}:
            raise RuntimeError('Ambiguous debug installation')
        before = metadata() if installed else None
        if before is None and args.phase not in {'negative', 'seed'}:
            raise RuntimeError('Previous native installation required')
        stop_app()
        # Never invoke Flutter's install/uninstall fallback.
        if 'Success' not in adb('install', '-r', str(apk)):
            raise RuntimeError('Preserving APK installation failed')
        after = metadata()
        if before is not None and before != after:
            raise RuntimeError('Installation identity changed')
        installed_path = adb('shell', 'pm', 'path', PACKAGE).removeprefix('package:')
        if not re.fullmatch(r'/data/app/[A-Za-z0-9_~+=./-]+\.apk', installed_path) or '/../' in installed_path:
            raise RuntimeError('Unexpected installed APK path')
        if adb('shell', 'sha256sum', installed_path).split()[0] != sha(apk):
            raise RuntimeError('Installed APK digest mismatch')
        adb('shell', 'am', 'start', '-n', PACKAGE + '/com.aimanager.child.MainActivity',
            '--ez', 'start-paused', 'true', '--ez', 'enable-dart-profiling', 'true')
        deadline = time.monotonic() + 40
        vm = None
        while time.monotonic() < deadline:
            native_pid = adb('shell', 'pidof', PACKAGE, check=False)
            if native_pid.isdigit():
                native_log = adb('logcat', '-d', '--pid=' + native_pid, '-v', 'raw')
                match = re.search(r'(?:Dart VM service|Observatory)[^\r\n]*(http://127\.0\.0\.1:[0-9]+/[^\s]+)', native_log)
                if match:
                    vm = urlsplit(match.group(1))
                    break
            time.sleep(.1)
        if vm is None:
            raise RuntimeError('Native VM service discovery failed')
        port = adb('forward', 'tcp:0', 'tcp:' + str(vm.port))
        if not port.isdigit():
            raise RuntimeError('Invalid owned forward port')
        forwarded = 'tcp:' + port
        env = os.environ.copy()
        env['FLUTTER_TEST_OUTPUTS_DIR'] = str(artifacts)
        options = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {'start_new_session': True}
        command = [args.flutter, 'drive', '--no-pub', '--keep-app-running',
                   '--driver=test_driver/cleanup_storage_driver.dart',
                   '--target=integration_test/cleanup_storage_test.dart',
                   '-d', args.serial, '--use-existing-app=http://127.0.0.1:' + port + vm.path]
        log = artifacts / 'driver.log'
        with log.open('wb') as output:
            process = subprocess.Popen(command, cwd=app, env=env, stdout=output,
                                       stderr=subprocess.STDOUT, **options)
            code = process.wait(timeout=180)
        actual_pid = adb('shell', 'pidof', PACKAGE)
        if actual_pid != native_pid or not actual_pid.isdigit():
            raise RuntimeError('Native PID changed during phase')
        native_log = adb('logcat', '-d', '--pid=' + native_pid, '-v', 'raw')
        (artifacts / 'native.log').write_text(native_log, encoding='utf-8')
        if args.phase == 'negative':
            if code == 0 or 'NATIVE_CLEANUP_MISSING_SEED' not in log.read_text(encoding='utf-8', errors='replace') + native_log:
                raise RuntimeError('Negative control failed for an unexpected reason')
            result = {'phase': 'negative', 'pid': int(native_pid), 'expectedMissingSeedFailure': True}
        else:
            if code != 0:
                raise RuntimeError('Native phase failed; inspect local safe logs')
            result = json.loads((artifacts / 'cleanup_storage_result.json').read_text(encoding='utf-8'))
            validate_result(result, args.phase, int(native_pid))
        if metadata() != after:
            raise RuntimeError('Installation changed during execution')
        stop_app()
        result.update({'driverExitCode': code, 'installation': after,
                       'serial': args.serial, 'avd': args.expected_avd, 'apiLevel': int(api_level),
                       'installPreserved': before is None or before == after,
                       'nativePidVerified': True, 'processStopped': True,
                       'driverAttachedExistingApp': True, 'apkSha256': sha(apk),
                       'driverLogSha256': sha(log), 'nativeLogSha256': sha(artifacts / 'native.log')})
        (artifacts / 'host-result.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        print('Android cleanup ' + args.phase + ': PASS; process stopped', flush=True)
    finally:
        try:
            if owned:
                stop_app()
        finally:
            if process is not None and process.poll() is None:
                if os.name == 'nt':
                    subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True, timeout=20)
                else:
                    process.terminate()
                process.wait(timeout=20)
            if forwarded is not None:
                adb('forward', '--remove', forwarded, check=False)


if __name__ == '__main__':
    main()
