"""Provision independent runtime keys and a fixed inventory; never start services."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
TASK = ROOT / '.cache/family-provider-release-20261017-r2/setup'
ENDPOINT = '/identity/realms/ai-manager/consumer-account/runtime-observation'


class IdentityProviderRuntimeSetupTest(unittest.TestCase):
    def setUp(self):
        self.directory = TASK / 'tmp' / uuid.uuid4().hex
        self.directory.mkdir(parents=True)

    def tearDown(self):
        self.assertEqual(self.directory.resolve().parent, (TASK / 'tmp').resolve())
        shutil.rmtree(self.directory)

    def run_setup(self, target=None, url=None, environment='family-cn-pilot', instance='identity-1'):
        args = [shutil.which('pwsh'), '-NoProfile', '-File',
            str(ROOT / 'scripts/initialize_identity_provider_runtime.ps1'),
            '-Directory', str(target or self.directory / 'runtime'), '-EnvironmentId', environment, '-InstanceId', instance]
        if url is not None: args += ['-ObservationUrl', url]
        return subprocess.run(args, cwd=ROOT, env=dict(os.environ, TEMP=str(self.directory), TMP=str(self.directory)),
            capture_output=True, text=True, encoding='utf-8', timeout=30)

    def test_independent_keys_fixed_inventory_and_no_runtime_mutation(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        target = self.directory / 'runtime'
        keys = [(target / name).read_text(encoding='utf-8') for name in ('executor-key', 'observation-key')]
        self.assertNotEqual(keys[0], keys[1])
        for key in keys:
            self.assertEqual(len(key), 43)
            self.assertEqual(len(base64.urlsafe_b64decode(key + '=')), 32)
            for public_name in ('identity-runtime.env', 'runtime-setup.json', 'runtime-inventory.json', 'NEXT_STEPS.md'):
                self.assertNotIn(key, (target / public_name).read_text(encoding='utf-8'))
            self.assertNotIn(key, result.stdout + result.stderr)
        inventory = json.loads((target / 'runtime-inventory.json').read_text(encoding='utf-8'))
        self.assertEqual(inventory, {'schemaVersion': 1, 'environmentId': 'family-cn-pilot', 'instances': [
            {'instanceId': 'identity-1', 'url': 'http://identity:8080' + ENDPOINT,
             'keyFile': '/run/identity-provider-runtime/observation-key'}]})
        receipt = json.loads((target / 'runtime-setup.json').read_text(encoding='utf-8'))
        self.assertFalse(receipt['servicesStarted'])
        self.assertFalse(receipt['existingDeploymentChanged'])
        self.assertFalse(receipt['salesAllowed'])
        self.assertEqual(receipt['runtimeStatus'], 'APPLY_REQUIRED')

    def test_setup_does_not_overwrite_existing_configuration(self):
        target = self.directory / 'runtime'
        target.mkdir()
        marker = target / 'unique-user-file'
        marker.write_text('preserve')
        result = self.run_setup(target)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(target.iterdir()), [marker])
        self.assertEqual(marker.read_text(), 'preserve')

    def test_public_http_userinfo_query_and_wrong_resource_are_rejected(self):
        for prefix in ['http://example.com', 'https://user:password@example.com',
                       'https://example.com' + ENDPOINT + '?x=1',
                       'https://example.com' + ENDPOINT + '#fragment', 'https://example.com/other']:
            url = prefix + ENDPOINT if prefix in ('http://example.com', 'https://user:password@example.com') else prefix
            result = self.run_setup(url=url)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.directory / 'runtime').exists())

    def test_loopback_inventory_is_explicit_and_does_not_contact_endpoint(self):
        url = 'http://127.0.0.1:1' + ENDPOINT
        result = self.run_setup(url=url)
        self.assertEqual(result.returncode, 0, result.stderr)
        inventory = json.loads((self.directory / 'runtime/runtime-inventory.json').read_text())
        self.assertEqual(inventory['instances'][0]['url'], url)

    def test_invalid_environment_and_outside_roots_are_rejected(self):
        result = self.run_setup(environment='family\nINJECT=true')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / 'runtime').exists())
        outside = ROOT / ('outside-runtime-' + uuid.uuid4().hex)
        result = self.run_setup(target=outside)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(outside.exists())

    def test_instance_identifier_matches_backend_inventory_contract(self):
        for instance in ('a', '1identity', 'invalid space'):
            result = self.run_setup(instance=instance)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.directory / 'runtime').exists())

    def test_private_key_permissions(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        target = self.directory / 'runtime'
        if os.name != 'nt':
            for name in ('executor-key', 'observation-key'):
                self.assertEqual((target / name).stat().st_mode & 0o077, 0)
        else:
            helper = self.directory / 'acl.ps1'
            helper.write_text('''param($Directory)
$allowed=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')
foreach($name in @('executor-key','observation-key')) {
  $acl=Get-Acl -LiteralPath (Join-Path $Directory $name)
  $extra=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $allowed })
  if($extra.Count -gt 0){exit 1}
}
''', encoding='utf-8')
            checked = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-File', str(helper),
                '-Directory', str(target)], capture_output=True, text=True, encoding='utf-8')
            self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_opt_in_overlay_mounts_only_readonly_backend_keys_and_inventory(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        base = self.directory / 'base.yaml'
        base.write_text('services:\n  backend:\n    image: busybox\n    environment:\n      MANAGER_FAMILY_SALES_ENABLED: "false"\n  identity:\n    image: busybox\n    environment:\n      CONSUMER_PHONE_ENABLED: "false"\n')
        composed = subprocess.run(['docker', 'compose', '--env-file', str(self.directory / 'runtime/identity-runtime.env'),
            '-f', str(base), '-f', str(ROOT / 'deploy/compose/compose.identity-runtime-control.yaml'),
            'config', '--format', 'json'], cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.assertEqual(composed.returncode, 0, composed.stderr)
        config = json.loads(composed.stdout)
        backend = config['services']['backend']
        self.assertEqual(backend['environment']['MANAGER_FAMILY_SALES_ENABLED'], 'false')
        self.assertEqual(backend['environment']['IDENTITY_PROVIDER_EXECUTOR_KEY_FILE'], '/run/identity-provider-runtime/executor-key')
        self.assertEqual(backend['environment']['IDENTITY_PROVIDER_RUNTIME_INVENTORY_FILE'], '/run/identity-provider-runtime/inventory.json')
        self.assertEqual(len(backend['volumes']), 3)
        self.assertTrue(all(v['read_only'] and not v['bind']['create_host_path'] for v in backend['volumes']))
        self.assertNotIn('volumes', config['services']['identity'])
        self.assertEqual(config['services']['identity']['environment']['CONSUMER_PHONE_ENABLED'], 'false')
        for name in ('executor-key', 'observation-key'):
            self.assertNotIn((self.directory / 'runtime' / name).read_text(), composed.stdout)

    def test_linked_ancestor_is_rejected_and_unique_target_preserved(self):
        target = self.directory / 'target'
        target.mkdir()
        (target / 'keep').write_text('unique')
        link = self.directory / 'link'
        if os.name == 'nt':
            helper = self.directory / 'link.ps1'
            helper.write_text('param($LinkPath,$TargetPath) New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null')
            made = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-File', str(helper),
                '-LinkPath', str(link), '-TargetPath', str(target)], capture_output=True, text=True, encoding='utf-8')
            self.assertEqual(made.returncode, 0, made.stderr)
        else: link.symlink_to(target, target_is_directory=True)
        try:
            result = self.run_setup(target=link / 'new')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(target.iterdir()), [target / 'keep'])
        finally:
            if os.name == 'nt': link.rmdir()
            else: link.unlink()


if __name__ == '__main__':
    unittest.main()
