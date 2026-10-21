"""Create local admin key infrastructure only; never start a service."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]


class IdentityProviderAdminSetupTest(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / '.cache/family-provider-admin-20261017/setup/tmp' / uuid.uuid4().hex
        self.directory.mkdir(parents=True)

    def tearDown(self):
        self.assertEqual(self.directory.resolve().parent,
            (ROOT / '.cache/family-provider-admin-20261017/setup/tmp').resolve())
        shutil.rmtree(self.directory)

    def run_setup(self, target=None, environment='family-cn-pilot'):
        destination = target or self.directory / 'admin'
        env = dict(os.environ, TEMP=str(self.directory), TMP=str(self.directory))
        return subprocess.run([shutil.which('pwsh'), '-NoProfile', '-File',
            str(ROOT / 'scripts/initialize_identity_provider_admin.ps1'),
            '-Directory', str(destination), '-EnvironmentId', environment],
            cwd=ROOT, env=env, capture_output=True, text=True, encoding='utf-8', timeout=30)

    def test_new_setup_creates_independent_key_and_only_nonsecret_environment(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        target = self.directory / 'admin'
        keys = json.loads((target / 'provider-keyring.json').read_text(encoding='utf-8-sig'))
        self.assertEqual(len(keys['keys']), 1)
        key = keys['keys'][0]
        self.assertEqual((key['kty'], key['use'], key['alg']), ('oct', 'enc', 'dir'))
        self.assertEqual(len(base64.urlsafe_b64decode(key['k'] + '=')), 32)
        self.assertNotIn(key['k'], (target / 'identity-admin.env').read_text())
        self.assertNotIn(key['k'], result.stdout + result.stderr)
        receipt = json.loads((target / 'admin-setup.json').read_text(encoding='utf-8-sig'))
        self.assertFalse(receipt['servicesStarted'])
        self.assertFalse(receipt['salesAllowed'])
        self.assertNotIn('keySha256', receipt)
        self.assertTrue((target / 'release-preparations').is_dir())

    def test_existing_directory_is_preserved(self):
        destination = self.directory / 'admin'
        destination.mkdir()
        marker = destination / 'unique-user-file.txt'
        marker.write_text('keep', encoding='utf-8')
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), 'keep')
        self.assertEqual(list(destination.iterdir()), [marker])

    def test_new_keys_are_independent_between_environments(self):
        first = self.run_setup(self.directory / 'first')
        second = self.run_setup(self.directory / 'second')
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        a = json.loads((self.directory / 'first/provider-keyring.json').read_text(encoding='utf-8-sig'))
        b = json.loads((self.directory / 'second/provider-keyring.json').read_text(encoding='utf-8-sig'))
        self.assertNotEqual(a, b)

    def test_invalid_environment_is_rejected_without_directory_creation(self):
        result = self.run_setup(environment='family\nINJECT=true')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / 'admin').exists())

    def test_output_outside_ignored_task_roots_is_rejected(self):
        destination = ROOT / ('outside-admin-' + uuid.uuid4().hex)
        result = self.run_setup(destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(destination.exists())

    def test_opt_in_compose_mounts_only_backend_key_and_encrypted_release_directory(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        base = self.directory / 'base.yaml'
        base.write_text('services:\n  backend:\n    image: busybox\n    environment:\n      MANAGER_FAMILY_SALES_ENABLED: "false"\n  identity:\n    image: busybox\n    environment:\n      CONSUMER_PHONE_ENABLED: "false"\n', encoding='utf-8')
        composed = subprocess.run(['docker', 'compose', '--env-file',
            str(self.directory / 'admin/identity-admin.env'), '-f', str(base), '-f',
            str(ROOT / 'deploy/compose/compose.identity-admin.yaml'), 'config', '--format', 'json'],
            cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.assertEqual(composed.returncode, 0, composed.stderr)
        config = json.loads(composed.stdout)
        backend = config['services']['backend']
        self.assertEqual(backend['environment']['IDENTITY_PROVIDER_ENVIRONMENT_ID'], 'family-cn-pilot')
        self.assertEqual(backend['environment']['MANAGER_FAMILY_SALES_ENABLED'], 'false')
        self.assertEqual(config['services']['identity']['environment']['CONSUMER_PHONE_ENABLED'], 'false')
        volumes = {item['target']: item for item in backend['volumes']}
        self.assertTrue(volumes['/run/identity-provider-admin/keyring.json']['read_only'])
        self.assertFalse(volumes['/var/lib/identity-provider-admin/releases'].get('read_only', False))
        self.assertNotIn('volumes', config['services']['identity'])
        key = json.loads((self.directory / 'admin/provider-keyring.json').read_text(encoding='utf-8-sig'))['keys'][0]['k']
        self.assertFalse(key in composed.stdout)

    def test_linked_ancestor_is_rejected_without_touching_target(self):
        target = self.directory / 'outside-target'
        target.mkdir()
        marker = target / 'keep.txt'
        marker.write_text('unique', encoding='utf-8')
        link = self.directory / 'linked'
        if os.name == 'nt':
            helper = self.directory / 'create-junction.ps1'
            helper.write_text('param([string]$LinkPath,[string]$TargetPath)\nNew-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null\n', encoding='utf-8')
            linked = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-File', str(helper),
                '-LinkPath', str(link), '-TargetPath', str(target)], capture_output=True, text=True, encoding='utf-8')
            self.assertEqual(linked.returncode, 0, linked.stderr)
        else:
            link.symlink_to(target, target_is_directory=True)
        try:
            result = self.run_setup(link / 'new-admin')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((target / 'new-admin').exists())
            self.assertEqual(marker.read_text(), 'unique')
        finally:
            if os.name == 'nt':
                link.rmdir()
            else:
                link.unlink()


if __name__ == '__main__':
    unittest.main()
