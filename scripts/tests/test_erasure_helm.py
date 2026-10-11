"""Render the chart's startup protection; no cluster or credentials are required."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELM = os.environ.get('HELM_COMMAND') or shutil.which('helm')
if not HELM:
    cached = ROOT / '.local/tools/helm-v3.22.0/windows-amd64/helm.exe'
    if cached.is_file():
        HELM = str(cached)


class ErasureHelmTest(unittest.TestCase):
    def values(self):
        return dict(publicOrigin='https://manager.example.com',
                    images=dict(backend='example/backend@sha256:'+'a'*64, edge='example/edge@sha256:'+'b'*64),
                    database=dict(jdbcUrl='jdbc:mysql://business/ai_manager', username='app', existingSecret='business'),
                    erasureLedger=dict(jdbcUrl='jdbc:mysql://ledger/erasure_ledger', username='ledger_app',
                        id='11111111-2222-4333-8444-555555555555', existingSecret='ledger', passwordKey='password'),
                    identity=dict(serviceName='identity'), signing=dict(existingSecret='signing'),
                    ingress=dict(host='manager.example.com', tlsSecretName='tls'))

    def render(self, values):
        self.assertIsNotNone(HELM, 'Helm is required for chart verification')
        with tempfile.TemporaryDirectory(prefix='erasure-helm-', dir=ROOT/'.local') as folder:
            path = Path(folder)/'values.json'
            path.write_text(json.dumps(values), encoding='utf-8')
            return subprocess.run([HELM, 'template', 'verification', str(ROOT/'deploy/helm/ai-manager'),
                                   '-f', str(path)], capture_output=True, text=True, encoding='utf-8', timeout=30)

    def test_api_and_worker_both_require_ledger_and_mount_its_secret(self):
        result = self.render(self.values())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count('{name: ERASURE_RECOVERY_REQUIRED, value: "true"}'), 2)
        self.assertEqual(result.stdout.count('path: manager.erasure-ledger.password'), 2)
        self.assertEqual(result.stdout.count('jdbc:mysql://ledger/erasure_ledger'), 2)
        self.assertEqual(result.stdout.count('configtree:/run/erasure-secrets/'), 2)

    def test_missing_independent_ledger_configuration_is_rejected(self):
        for key in ('jdbcUrl', 'username', 'existingSecret', 'id'):
            with self.subTest(key=key):
                values = self.values(); values['erasureLedger'][key] = ''
                self.assertNotEqual(self.render(values).returncode, 0)

    def test_unknown_ledger_settings_are_rejected(self):
        values = self.values(); values['erasureLedger']['autoInitialize'] = True
        self.assertNotEqual(self.render(values).returncode, 0)


if __name__ == '__main__':
    unittest.main()
