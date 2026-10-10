"""Exercise host preflight refusals as a real CLI, before any adb operation."""
from pathlib import Path
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('android_host', Path(__file__).with_name('run_submission_android.py'))
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class PreservingInstallTest(unittest.TestCase):
    def test_install_failure_aborts_without_uninstall_or_retry(self):
        calls = []
        def adb(*args):
            calls.append(args)
            raise RuntimeError('controlled adb unavailable')
        with self.assertRaisesRegex(RuntimeError, 'Preserving install failed'):
            host.install_preserving_data(adb, lambda: {'uid': '1', 'firstInstallTime': 'original'}, Path('owned.apk'))
        self.assertEqual(calls, [('install', '-r', 'owned.apk')])

    def test_changed_installation_is_refused(self):
        calls = []
        snapshots = iter([{'uid': '1', 'firstInstallTime': 'original'}, {'uid': '2', 'firstInstallTime': 'reinstalled'}])
        def adb(*args):
            calls.append(args)
            return b'Success'
        with self.assertRaisesRegex(RuntimeError, 'installation identity changed'):
            host.install_preserving_data(adb, lambda: next(snapshots), Path('owned.apk'))
        self.assertEqual(calls, [('install', '-r', 'owned.apk')])

    def test_success_requires_same_installation(self):
        calls = []
        before = {'uid': '1', 'firstInstallTime': 'original'}
        def adb(*args):
            calls.append(args)
            return b'Success'
        self.assertEqual(host.install_preserving_data(adb, lambda: dict(before), Path('owned.apk')), before)
        self.assertEqual(calls, [('install', '-r', 'owned.apk')])


class HostPreflightTest(unittest.TestCase):
    def setUp(self):
        self.runner = Path(__file__).with_name('run_submission_android.py')
        self.private_root = self.runner.resolve().parents[3] / '.local'
        self.private_root.mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(prefix='android-child-http-guard-', dir=self.private_root)
        self.addCleanup(self.directory.cleanup)
        self.fixture = Path(self.directory.name) / 'fixture.json'
        self.data = {'schemaVersion': 1, 'runId': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                     'apiRoot': 'http://127.0.0.1:12345/api/v1'}

    def refused(self, expected, *, authorize=True, serial='emulator-5562', fixture=None):
        self.fixture.write_text(json.dumps(self.data), encoding='utf-8')
        args = [sys.executable, str(self.runner), '--fixture', str(fixture or self.fixture),
                '--phase', 'enroll', '--app', str(self.fixture.parent),
                '--adb', 'must-not-execute-adb', '--flutter', 'must-not-execute-flutter',
                '--serial', serial, '--expected-avd', 'owned-test-avd']
        if authorize:
            args.append('--allow-owned-debug-avd')
        result = subprocess.run(args, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected, result.stderr)
        self.assertNotIn('FileNotFoundError', result.stderr,
                         'Preflight must refuse before attempting external commands')
        self.assertEqual(json.loads(self.fixture.read_text()), self.data)
        self.assertEqual(list(self.fixture.parent.iterdir()), [self.fixture])

    def test_requires_explicit_owned_debug_opt_in(self):
        self.refused('Explicit owned debug AVD authorization is required', authorize=False)

    def test_refuses_physical_device_serial(self):
        self.refused('Explicit owned debug AVD authorization is required', serial='physical-device')

    def test_refuses_non_private_fixture_path(self):
        self.refused('JVM-created private run directory', fixture=Path('outside-fixture.json'))

    def test_refuses_remote_and_non_loopback_android_origins(self):
        for origin in ['https://service.example/api/v1', 'http://10.0.2.2:12345/api/v1',
                       'http://127.0.0.1:12345/api/v1?redirect=x',
                       'http://user@127.0.0.1:12345/api/v1', 'http://127.0.0.1:12345/other']:
            with self.subTest(origin=origin):
                self.data['apiRoot'] = origin
                self.refused('JVM-owned loopback Spring endpoint')

    def test_refuses_unsupported_fixture_schema(self):
        self.data['schemaVersion'] = 2
        self.refused('Unsupported fixture schema')


if __name__ == '__main__':
    unittest.main()
