"""Use installed Compose to prove only identity loses its build configuration."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
TASK = ROOT / '.cache/family-provider-release-20261017-r2/compose'


class IdentityRuntimeComposeMergeTest(unittest.TestCase):
    def setUp(self):
        self.directory = TASK / 'tmp' / uuid.uuid4().hex
        self.directory.mkdir(parents=True)
        self.base = self.directory / 'base.json'
        self.base.write_text(json.dumps({'services': {
            name: {'build': {'context': str(ROOT / path)}, 'image': 'fixture-' + name + ':review'}
            for name, path in [('identity', 'deploy/keycloak'), ('backend', 'backend'), ('edge', 'deploy/edge')]
        }}), encoding='utf-8')
        self.target = self.directory / 'active.json'
        self.image = 'sha256:' + 'a' * 64
        self.target.write_text(json.dumps({'services': {'identity': {'image': self.image,
            'environment': {'CONSUMER_PHONE_ENABLED': 'false', 'CONSUMER_WECHAT_ENABLED': 'false',
                            'CONSUMER_ACCOUNT_SECURITY_ENABLED': 'false'}}}}), encoding='utf-8')

    def tearDown(self):
        self.assertEqual(self.directory.resolve().parent, (TASK / 'tmp').resolve())
        shutil.rmtree(self.directory)

    def configuration(self, active):
        args = ['docker', 'compose', '-f', str(self.base)]
        if active:
            args += ['-f', str(ROOT / 'deploy/compose/compose.identity-runtime-image.yaml'), '-f', str(self.target)]
        result = subprocess.run(args + ['config', '--format', 'json'], cwd=ROOT,
            env=dict(os.environ, TEMP=str(self.directory), TMP=str(self.directory)),
            capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        out = TASK / 'out'
        out.mkdir(exist_ok=True)
        receipt = {'mode': 'active' if active else 'ordinary', 'servicesStarted': False,
            'inputSha256': hashlib.sha256(self.base.read_bytes()).hexdigest(),
            'composeOutputSha256': hashlib.sha256(result.stdout.encode()).hexdigest(), 'configuration': data}
        (out / ('active-merge.json' if active else 'ordinary-merge.json')).write_text(json.dumps(receipt, indent=2), encoding='utf-8')
        return data['services']

    def test_active_identity_pins_image_and_does_not_build_old_provider(self):
        services = self.configuration(True)
        self.assertNotIn('build', services['identity'])
        self.assertEqual(services['identity']['image'], self.image)
        for name in ('backend', 'edge'):
            self.assertIn('build', services[name])
        for flag in ('CONSUMER_PHONE_ENABLED', 'CONSUMER_WECHAT_ENABLED', 'CONSUMER_ACCOUNT_SECURITY_ENABLED'):
            self.assertEqual(services['identity']['environment'][flag], 'false')

    def test_without_active_overlay_existing_build_behavior_is_preserved(self):
        services = self.configuration(False)
        for name in ('identity', 'backend', 'edge'):
            self.assertIn('build', services[name])


if __name__ == '__main__':
    unittest.main()
