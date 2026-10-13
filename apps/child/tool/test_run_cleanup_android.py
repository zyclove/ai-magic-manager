import unittest
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import run_cleanup_android as runner
from run_cleanup_android import validate_target, parse_installation, validate_result


class CleanupRunnerChecks(unittest.TestCase):
    def test_foreign_apk_is_rejected_before_any_adb_or_artifact_write(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            apk = root / 'wrong.apk'
            apk.write_bytes(b'synthetic')
            artifacts = root / '.local' / 'output'
            argv = ['runner', '--phase', 'seed', '--app', str(root), '--apk', str(apk),
                    '--artifacts', str(artifacts), '--adb', 'adb', '--aapt', 'aapt',
                    '--flutter', 'flutter', '--serial', 'emulator-5582',
                    '--expected-avd', 'Owned', '--allow-owned-debug-avd']
            def execute(command, **kwargs):
                self.assertEqual(command, ['aapt', 'dump', 'badging', str(apk)])
                return SimpleNamespace(returncode=0, stdout=b"package: name='other.app' versionCode='1'\napplication-debuggable\n")
            with patch('sys.argv', argv), patch.object(runner.subprocess, 'run', side_effect=execute):
                with self.assertRaises(ValueError):
                    runner.main()
            self.assertFalse(artifacts.exists())

    def test_apk_manifest_requires_one_expected_debug_package(self):
        valid = b"package: name='com.aimanager.child.debug' versionCode='1'\napplication-debuggable\n"
        invalid = [b'', valid.replace(b'child.debug', b'child'),
                   valid.replace(b'application-debuggable\n', b''),
                   valid + b"package: name='other.app'\n",
                   valid + b'application-debuggable\n']
        with patch.object(runner.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=valid)):
            runner.validate_apk(Path('test.apk'), 'aapt')
        for value in invalid:
            with self.subTest(value=value), patch.object(runner.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=value)):
                with self.assertRaises(ValueError):
                    runner.validate_apk(Path('test.apk'), 'aapt')
        with patch.object(runner.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout=valid)):
            with self.assertRaises(ValueError):
                runner.validate_apk(Path('test.apk'), 'aapt')

    def test_requires_explicit_owned_emulator(self):
        for serial, name, actual, allowed in [
            ('physical-device', 'Owned', 'Owned\nOK', True),
            ('emulator-5582', 'Owned', 'Other\nOK', True),
            ('emulator-5582', 'Owned', 'Owned\nOK', False),
            ('emulator-5582', '', 'Owned\nOK', True),
        ]:
            with self.assertRaises(ValueError):
                validate_target(serial, name, actual, allowed)
        validate_target('emulator-5582', 'Owned', 'Owned\nOK', True)
        validate_target('emulator-5582', 'Owned', 'Owned\r\r\nOK\r\r\n', True)

    def test_requires_unique_installation_metadata(self):
        self.assertEqual(parse_installation('userId=12345\nfirstInstallTime=2026-10-13 12:00:00'),
                         {'uid': '12345', 'firstInstallTime': '2026-10-13 12:00:00'})
        for value in ['', 'userId=12345', 'userId=123\nuserId=234\nfirstInstallTime=one']:
            with self.assertRaises(ValueError):
                parse_installation(value)

    def test_api34_app_id_is_recognized_but_ambiguous_ids_are_rejected(self):
        self.assertEqual(parse_installation('    appId=10190\r\r\n      firstInstallTime=2026-10-13 05:00:41'),
                         {'uid': '10190', 'firstInstallTime': '2026-10-13 05:00:41'})
        with self.assertRaises(ValueError):
            parse_installation('appId=10190\nuserId=10191\nfirstInstallTime=one')

    def test_result_must_match_phase_pid_and_truth_boundaries(self):
        valid = {'phase': 'finish', 'pid': 42, 'realAndroidStorage': True,
                 'realAndroidKeyAlias': True, 'cloudIsControlledSubstitute': True,
                 'cacheDeletionChecked': True, 'originalKeyRetained': False,
                 'originalKeyDeletionChecked': True, 'expiredAcknowledgedRecovery': True,
                 'physicalWipeProven': False}
        validate_result(valid, 'finish', 42)
        for key, value in [('pid', 43), ('phase', 'clear'), ('realAndroidStorage', False),
                           ('physicalWipeProven', True), ('expiredAcknowledgedRecovery', False),
                           ('originalKeyRetained', True), ('originalKeyDeletionChecked', False)]:
            with self.assertRaises(ValueError):
                validate_result({**valid, key: value}, 'finish', 42)


if __name__ == '__main__':
    unittest.main()
