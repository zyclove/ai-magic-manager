"""Host release safety and interruption tests; HTTP and Docker boundaries are private fixtures."""
import base64
import hashlib
import hmac
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
TASK = ROOT / '.cache/family-provider-release-20261017-r2/runtime'
FIXTURES = ROOT / '.local/family-provider-release-20261017-r2/runtime-fixtures'
PWSH = shutil.which('pwsh')
COMMON = ROOT / 'scripts/family-identity-release-common.ps1'
RUNNER = ROOT / 'scripts/run_family_identity_release.ps1'
KEY = bytes(range(32))


def sign(*values):
    content = b''.join(str(len(str(v).encode('utf-8'))).encode() + b':' + str(v).encode('utf-8') for v in values)
    return base64.urlsafe_b64encode(hmac.new(KEY, content, hashlib.sha256).digest()).decode().rstrip('=')


class IdentityHostReleaseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = TASK / 'tmp/host-test-tools'
        cls.tools.mkdir(parents=True, exist_ok=True)
        cls.harness = cls.tools / 'host-harness.ps1'
        cls.harness.write_text("param($Common,$Target,$Action)\n$ErrorActionPreference='Stop'\n. $Common\nif($Action -eq 'target'){Get-IdentityReleaseTarget $Target|Out-Null}else{Get-IdentityReleaseActiveOverlay $Target}\n", encoding='utf-8')
        source = cls.tools / 'Docker.cs'
        source.write_text('using System;using System.IO;using System.Threading;class Docker {static int Main(string[] a){File.AppendAllText(Environment.GetEnvironmentVariable("FIXTURE_DOCKER_LOG"),string.Join("|",a)+"\\n");if(a.Length>1&&a[0]=="image"){Console.WriteLine(Environment.GetEnvironmentVariable("FIXTURE_IMAGE_ID"));return 0;}if(a.Length>0&&a[0]=="ps"){Console.WriteLine(Environment.GetEnvironmentVariable("FIXTURE_EXISTING_ID")??"");return 0;}if(a.Length>0&&a[0]=="inspect"){Console.WriteLine(Environment.GetEnvironmentVariable("FIXTURE_LABELS")??"{}");return 0;}if(a.Length>0&&a[0]=="compose"&&Array.IndexOf(a,"config")>=0){string wait=Environment.GetEnvironmentVariable("FIXTURE_CONFIG_WAIT_FILE");if(wait!=null){File.WriteAllText(wait+".entered","ready");int n=0;while(!File.Exists(wait)&&n++<200)Thread.Sleep(100);}Console.WriteLine(File.ReadAllText(Environment.GetEnvironmentVariable("FIXTURE_COMPOSE_JSON")));return 0;}return 0;}}', encoding='utf-8')
        compiler = Path('C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe')
        cls.docker = cls.tools / 'docker.exe'
        result = subprocess.run([str(compiler), '/nologo', '/target:exe', '/out:' + str(cls.docker), str(source)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def setUp(self):
        self.run_id = uuid.uuid4().hex
        self.directory = FIXTURES / self.run_id
        self.tmp = TASK / 'tmp' / self.run_id
        self.tmp.mkdir(parents=True)
        env = dict(os.environ, TEMP=str(self.tmp), TMP=str(self.tmp))
        result = subprocess.run([PWSH, '-NoProfile', '-File', str(ROOT / 'scripts/initialize-deployment.ps1'), '-Directory', str(self.directory), '-ProjectName', 'provider-test-' + self.run_id[:10], '-ConsumerIdentity'], cwd=ROOT, env=env, capture_output=True, text=True, encoding='utf-8', timeout=40)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.operation = str(uuid.uuid4())
        self.version = str(uuid.uuid4())
        self.preparation = str(uuid.uuid4())
        self.image = 'sha256:' + 'a' * 64
        fixture_jar = b'private-host-test-provider-fixture'
        self.jar = hashlib.sha256(fixture_jar).hexdigest()
        artifact = 'artifacts/release-' + uuid.uuid4().hex
        provider_file = self.directory / artifact / 'keycloak/keycloak/providers/consumer-identity-1.0.0.jar'
        provider_file.parent.mkdir(parents=True)
        provider_file.write_bytes(fixture_jar)
        (self.directory / 'release-manifest.json').write_text(json.dumps(dict(schemaVersion=1, consumerIdentity=True, artifactRoot=artifact, identityProviderSha256=self.jar)))
        self.target_file = self.directory / 'identity-release-target.json'
        self.admin = self.directory / 'provider-admin'
        self.runtime = self.directory / 'provider-runtime'
        self.admin.mkdir()
        self.runtime.mkdir()
        self.inventory = self.runtime / 'runtime-inventory.json'
        self.executor = self.runtime / 'executor-key'
        self.observation = self.runtime / 'observation-key'
        self.executor.write_text(base64.urlsafe_b64encode(KEY).decode().rstrip('='))
        self.observation.write_text(base64.urlsafe_b64encode(bytes(range(1, 33))).decode().rstrip('='))
        self.inventory.write_text(json.dumps({'schemaVersion': 1, 'environmentId': 'family-cn-isolated', 'instances': [{'instanceId': 'identity-1', 'url': 'http://identity:8080/identity/realms/ai-manager/consumer-account/runtime-observation', 'keyFile': '/run/identity-provider-runtime/observation-key'}]}))
        (self.admin / 'provider-keyring.json').write_text('{"keys":[]}')
        (self.admin / 'identity-admin.env').write_text("IDENTITY_PROVIDER_ADMIN_ROOT='" + self.admin.as_posix() + "'\nIDENTITY_PROVIDER_ACTIVE_KEY_ID='fixture-release-key'\nIDENTITY_PROVIDER_ENVIRONMENT_ID='family-cn-isolated'\n")
        (self.runtime / 'identity-runtime.env').write_text("IDENTITY_PROVIDER_RUNTIME_ROOT='" + self.runtime.as_posix() + "'\nIDENTITY_PROVIDER_ENVIRONMENT_ID='family-cn-isolated'\n")
        self.releases = self.admin / 'release-preparations'
        self.releases.mkdir()
        self.target = dict(schemaVersion=1, environmentId='family-cn-isolated', instanceId='identity-1', backendUrl='http://127.0.0.1:1', deploymentDirectory=str(self.directory), adminDirectory=str(self.admin), runtimeDirectory=str(self.runtime), releaseDirectory=str(self.releases), vaultKeyFile=str(self.admin / 'provider-keyring.json'), executorKeyFile=str(self.executor), observationKeyFile=str(self.observation), runtimeInventoryFile=str(self.inventory), identityImageId=self.image, providerJarSha256=self.jar)
        self.write_target()
        self.env = dict(env, PATH=str(self.tools) + os.pathsep + os.environ['PATH'], FIXTURE_DOCKER_LOG=str(self.tmp / 'docker.log'), FIXTURE_IMAGE_ID=self.image)
        self.original_env = (self.directory / '.env').read_bytes()
        self.original_secrets = {p.name: p.read_bytes() for p in (self.directory / 'secrets').iterdir()}
        self.server = None
        self.can_finalize = True
        self.reply_jar = self.jar
        self.confirmed_operation = None
        self.previous_reply = None

    def tearDown(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
        self.assertEqual((self.directory / '.env').read_bytes(), self.original_env)
        self.assertEqual({p.name: p.read_bytes() for p in (self.directory / 'secrets').iterdir()}, self.original_secrets)
        files = []
        for folder in (self.directory, self.tmp):
            for p in folder.rglob('*'):
                self.assertFalse(p.is_symlink() or (hasattr(p, 'is_junction') and p.is_junction()))
                if p.is_file():
                    files.append(dict(path=str(p.relative_to(folder)), bytes=p.stat().st_size, sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
        out = TASK / 'out/host-fixture-cleanup'
        out.mkdir(parents=True, exist_ok=True)
        (out / (self.run_id + '.json')).write_text(json.dumps(dict(test=self.id(), ownedFixtureInventory=files, providerRequestsPerformed=False, existingServicesTouched=False)), encoding='utf-8')
        self.assertEqual(self.directory.parent.resolve(), FIXTURES.resolve())
        self.assertEqual(self.tmp.parent.resolve(), (TASK / 'tmp').resolve())
        shutil.rmtree(self.directory)
        shutil.rmtree(self.tmp)

    def write_target(self):
        self.target_file.write_text(json.dumps(self.target), encoding='utf-8')

    def invoke(self, *args):
        return subprocess.run([PWSH, '-NoProfile', '-File', *map(str, args)], cwd=ROOT, env=self.env, capture_output=True, text=True, encoding='utf-8', timeout=45)

    def pointer(self, state='APPLIED_CLOSED'):
        version_dir = self.directory / 'identity-provider-releases' / self.operation
        version_dir.mkdir(parents=True, exist_ok=True)
        overlay = version_dir / 'identity-runtime.compose.json'
        overlay.write_text('{"services":{"identity":{"image":"' + self.image + '","pull_policy":"never"}}}')
        self.version_secrets(version_dir)
        contents = [(version_dir / 'secrets' / name).read_text() for name in self.secret_names()]
        pointer = dict(schemaVersion=1, environmentId=self.target['environmentId'], operationId=self.operation, versionId=self.version, claimId=str(uuid.uuid4()), state=state, overlaySha256=hashlib.sha256(overlay.read_bytes()).hexdigest(), versionProof=sign('family-identity-host-version-v1', self.operation, *contents))
        pointer['proof'] = sign('family-identity-host-active-v1', pointer['environmentId'], self.operation, self.version, pointer['claimId'], state, pointer['overlaySha256'], pointer['versionProof'])
        (self.directory / 'identity-release-active.json').write_text(json.dumps(pointer))
        return pointer, overlay

    @staticmethod
    def secret_names():
        return ['consumer_otp_hmac_key', 'consumer_sms_access_key_id', 'consumer_sms_access_key_secret', 'consumer_sms_security_token', 'consumer_wechat_app_secret']

    def version_secrets(self, version_dir):
        folder = version_dir / 'secrets'
        folder.mkdir(exist_ok=True)
        for name in self.secret_names():
            (folder / name).write_text('fixture-' + name)

    def test_pending_pointer_blocks_ordinary_start_before_docker(self):
        self.pointer('EXECUTION_UNKNOWN')
        result = self.invoke(ROOT / 'scripts/start-deployment.ps1', '-Directory', self.directory)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('awaiting runtime confirmation', result.stderr)
        self.assertFalse((self.tmp / 'docker.log').exists())

    def test_active_pointer_requires_authentication_and_unchanged_overlay(self):
        pointer, overlay = self.pointer()
        valid = self.invoke(self.harness, COMMON, self.directory, 'active')
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertIn(str(overlay), valid.stdout)
        overlay.write_text('{"services":{}}')
        changed = self.invoke(self.harness, COMMON, self.directory, 'active')
        self.assertNotEqual(changed.returncode, 0)
        self.assertIn('files changed', changed.stderr)

    def test_wrong_pointer_signature_is_rejected(self):
        pointer, _ = self.pointer()
        pointer['proof'] = 'x' * 43
        (self.directory / 'identity-release-active.json').write_text(json.dumps(pointer))
        result = self.invoke(self.harness, COMMON, self.directory, 'active')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('authentication failed', result.stderr)

    def test_changed_secret_files_block_normal_restart(self):
        _, overlay = self.pointer()
        (overlay.parent / 'secrets/consumer_sms_access_key_secret').write_text('changed-fixture-only')
        result = self.invoke(self.harness, COMMON, self.directory, 'active')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('secret files changed', result.stderr)

    def test_multi_instance_target_is_rejected_before_network_or_docker(self):
        inventory = json.loads(self.inventory.read_text())
        inventory['instances'].append(dict(inventory['instances'][0], instanceId='identity-2'))
        self.inventory.write_text(json.dumps(inventory))
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.tmp / 'docker.log').exists())
        self.assertFalse((self.directory / ('identity-release-' + self.operation + '.json')).exists())

    def start_server(self, lose_begin=False, finish_state='APPLIED_CLOSED', response_mode='normal', deny_begin=False, lose_abandon=False):
        owner = self
        self.requests = []
        self.remote_state = 'WAITING_EXECUTOR'

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                action = {'claims': 'CLAIM', 'query': 'QUERY', 'begin': 'BEGIN', 'outcomes': 'REPORT', 'abandon': 'ABANDON_BEFORE_BEGIN'}[self.path.split('/')[-1]]
                expected = sign('family-identity-executor-request-v1', action, body['environmentId'], body['operationId'], body['claimId'], body['nonce'], body['issuedAt'], body.get('outcome', ''))
                if not hmac.compare_digest(expected, body['proof']):
                    self.send_error(401)
                    return
                owner.requests.append(action)
                allowed = False
                if action == 'CLAIM':
                    owner.remote_state = 'CLAIMED'
                elif action == 'BEGIN':
                    owner.remote_state = 'CLAIMED' if deny_begin else 'EXECUTION_UNKNOWN'
                    if lose_begin:
                        self.connection.close()
                        return
                    allowed = not deny_begin
                elif action == 'REPORT':
                    owner.remote_state = finish_state
                    if finish_state == 'APPLIED_CLOSED':
                        owner.confirmed_operation = body['operationId']
                elif action == 'ABANDON_BEFORE_BEGIN':
                    owner.remote_state = 'CANCELLED'
                    if lose_abandon:
                        self.connection.close()
                        return
                historical = owner.previous_reply if action == 'QUERY' and owner.previous_reply and body['operationId'] == owner.previous_reply['operationId'] else None
                state = 'APPLIED_CLOSED' if historical else owner.remote_state
                response = dict(operationId=body['operationId'], claimId=body['claimId'], state=state, executionAllowed=allowed, canFinalizeHostPointer=state == 'APPLIED_CLOSED' and owner.can_finalize and body['operationId'] == owner.confirmed_operation, currentConfirmedOperationId=owner.confirmed_operation, canClearPendingHostPointer=state == 'CANCELLED' and owner.confirmed_operation is None, environmentId=body['environmentId'], versionId=historical['versionId'] if historical else owner.version, preparationId=owner.preparation, providerJarSha256=owner.reply_jar, parentApkSha256='c' * 64, kind='PUBLISH')
                encoded = json.dumps(response).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                if response_mode == 'oversized' and action == 'CLAIM':
                    self.send_header('Content-Length', '40000')
                elif response_mode == 'chunked' and action == 'CLAIM':
                    self.send_header('Transfer-Encoding', 'chunked')
                elif response_mode == 'slow' and action == 'CLAIM':
                    self.send_header('Content-Length', str(len(encoded)))
                else:
                    self.send_header('Content-Length', str(len(encoded)))
                self.end_headers()
                if response_mode == 'oversized' and action == 'CLAIM':
                    return
                if response_mode == 'chunked' and action == 'CLAIM':
                    try:
                        for _ in range(10):
                            self.wfile.write(b'1000\r\n' + b'x' * 4096 + b'\r\n')
                            self.wfile.flush()
                        self.wfile.write(b'0\r\n\r\n')
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                if response_mode == 'slow' and action == 'CLAIM':
                    time.sleep(17)
                    return
                self.wfile.write(encoded)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.target['backendUrl'] = 'http://127.0.0.1:' + str(self.server.server_port)
        self.write_target()
        version_dir = self.directory / 'identity-provider-releases' / self.operation
        version_dir.mkdir(parents=True)
        self.version_secrets(version_dir)
        (version_dir / 'prepared-release.json').write_text(json.dumps(dict(environmentId=self.target['environmentId'], versionId=self.version, applied=False, settings=dict(smsSignName='家庭验证码', smsTemplateCode='SMS_123', wechatAppId='wx0123456789abcdef'))))

    def test_lost_begin_reply_never_restarts_on_resume(self):
        self.start_server(lose_begin=True)
        first = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(first.returncode, 0)
        self.assertEqual(self.requests, ['CLAIM', 'BEGIN'])
        pointer = json.loads((self.directory / 'identity-release-active.json').read_text())
        self.assertEqual(pointer['state'], 'EXECUTION_UNKNOWN')
        blocked = self.invoke(ROOT / 'scripts/start-deployment.ps1', '-Directory', self.directory)
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn('awaiting runtime confirmation', blocked.stderr)
        second = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertEqual(second.returncode, 2, second.stderr)
        self.assertEqual(self.requests, ['CLAIM', 'BEGIN', 'QUERY'])
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)

    def test_finished_report_only_activates_after_server_observation_confirmation(self):
        self.start_server()
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests, ['CLAIM', 'BEGIN', 'REPORT'])
        pointer = json.loads((self.directory / 'identity-release-active.json').read_text())
        self.assertEqual(pointer['state'], 'APPLIED_CLOSED')
        commands = (self.tmp / 'docker.log').read_text()
        self.assertEqual(commands.count('|up|'), 1)
        self.assertIn('|--no-deps|--no-build|--pull|never|--force-recreate|', commands)
        self.assertTrue(commands.rstrip().endswith('|identity'))
        again = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual((self.tmp / 'docker.log').read_text(), commands)

    def test_unknown_runtime_keeps_pending_pointer_and_repeat_only_queries(self):
        self.start_server(finish_state='EXECUTION_UNKNOWN')
        first = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertEqual(first.returncode, 2, first.stderr)
        pointer = json.loads((self.directory / 'identity-release-active.json').read_text())
        self.assertEqual(pointer['state'], 'EXECUTION_UNKNOWN')
        commands = (self.tmp / 'docker.log').read_text()
        second = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertEqual(second.returncode, 2, second.stderr)
        self.assertEqual((self.tmp / 'docker.log').read_text(), commands)
        self.assertEqual(self.requests, ['CLAIM', 'BEGIN', 'REPORT', 'QUERY'])

    def test_preparation_failure_abandons_only_before_begin(self):
        self.start_server()
        (self.directory / 'identity-provider-releases' / self.operation / 'prepared-release.json').write_text('{}')
        failed = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(self.requests, ['CLAIM', 'ABANDON_BEFORE_BEGIN'])
        self.assertEqual(self.remote_state, 'CANCELLED')
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)
        resumed = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertEqual(resumed.returncode, 2, resumed.stderr)
        self.assertEqual(self.requests, ['CLAIM', 'ABANDON_BEFORE_BEGIN', 'QUERY'])

    def test_oversized_content_length_is_rejected_before_reading_body(self):
        self.start_server(response_mode='oversized')
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests, ['CLAIM'])
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)

    def test_chunked_body_is_bounded_without_content_length(self):
        self.start_server(response_mode='chunked')
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests, ['CLAIM'])
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)

    def test_body_read_obeys_total_deadline_after_headers(self):
        self.start_server(response_mode='slow')
        started = time.monotonic()
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        elapsed = time.monotonic() - started
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(elapsed, 25)
        self.assertEqual(self.requests, ['CLAIM'])
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)

    def test_copied_compose_project_is_rejected_before_claim(self):
        self.start_server()
        self.env['FIXTURE_EXISTING_ID'] = 'a' * 12
        self.env['FIXTURE_LABELS'] = json.dumps({'com.docker.compose.project': 'provider-test-' + self.run_id[:10], 'com.docker.compose.service': 'identity', 'com.docker.compose.project.working_dir': str(self.directory.parent / 'another-deployment')})
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests, [])
        self.assertFalse((self.directory / ('identity-release-' + self.operation + '.json')).exists())
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)

    def test_multiple_existing_identity_containers_are_rejected_before_claim(self):
        self.start_server()
        self.env['FIXTURE_EXISTING_ID'] = 'a' * 12 + '\n' + 'b' * 12
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests, [])
        self.assertFalse((self.directory / ('identity-release-' + self.operation + '.json')).exists())
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)

    def full_start_fixture(self):
        manifest_file = self.directory / 'release-manifest.json'
        manifest = json.loads(manifest_file.read_text())
        artifact = self.directory / manifest['artifactRoot']
        for relative in ['backend/manager-backend.jar', 'guardian/index.html', 'guardian/main.dart.js']:
            file = artifact / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('fixture-only-existing-release')
        deployment = json.loads((self.directory / 'deployment.json').read_text())
        manifest.update(publicUrl=deployment['publicUrl'], backendSha256=hashlib.sha256((artifact / 'backend/manager-backend.jar').read_bytes()).hexdigest(), guardianSha256=hashlib.sha256((artifact / 'guardian/main.dart.js').read_bytes()).hexdigest())
        manifest_file.write_text(json.dumps(manifest))
        ledger = next(line.split("'", 2)[1] for line in self.original_env.decode().splitlines() if line.startswith('ERASURE_LEDGER_ID='))
        (self.directory / 'erasure-ledger-initialized.json').write_text(json.dumps(dict(schemaVersion=1, ledgerId=ledger)))
        (self.directory / 'logs').mkdir()
        config = dict(services=dict(identity=dict(image=self.image, pull_policy='never'), backend=dict(build=dict(context=str(artifact / 'backend')), environment=dict(OIDC_ISSUER_URI=deployment['publicUrl'] + '/identity/realms/ai-manager', ERASURE_LEDGER_ID=ledger, ERASURE_RECOVERY_REQUIRED='true')), edge=dict(build=dict(context=str(artifact / 'guardian')))))
        config_file = self.tmp / 'compose.json'
        config_file.write_text(json.dumps(config))
        self.env['FIXTURE_COMPOSE_JSON'] = str(config_file)

    def test_ordinary_start_keeps_active_identity_image_and_backend_configuration(self):
        self.pointer()
        self.full_start_fixture()
        result = self.invoke(ROOT / 'scripts/start-deployment.ps1', '-Directory', self.directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = (self.tmp / 'docker.log').read_text()
        self.assertEqual(commands.count('|up|'), 1)
        self.assertIn('compose.identity-runtime-image.yaml', commands)
        self.assertIn('compose.identity-admin.yaml', commands)
        self.assertIn('compose.identity-runtime-control.yaml', commands)
        self.assertIn('identity-admin.env', commands)
        self.assertIn('identity-runtime.env', commands)
        self.assertIn('|--build|', commands)

    def test_old_confirmed_operation_does_not_overwrite_newer_pointer(self):
        self.start_server()
        first = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertEqual(first.returncode, 0, first.stderr)
        old_operation, old_version = self.operation, self.version
        self.operation, self.version = str(uuid.uuid4()), str(uuid.uuid4())
        self.pointer()
        self.confirmed_operation = self.operation
        newer = (self.directory / 'identity-release-active.json').read_bytes()
        self.operation, self.version = old_operation, old_version
        self.can_finalize = False
        commands = (self.tmp / 'docker.log').read_text()
        replay = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', old_operation)
        self.assertEqual(replay.returncode, 2, replay.stderr)
        self.assertEqual((self.directory / 'identity-release-active.json').read_bytes(), newer)
        self.assertEqual((self.tmp / 'docker.log').read_text(), commands)

    def test_wrong_approved_jar_is_safely_abandoned_before_begin(self):
        self.start_server()
        self.reply_jar = 'd' * 64
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests, ['CLAIM', 'ABANDON_BEFORE_BEGIN'])
        self.assertEqual(self.remote_state, 'CANCELLED')
        self.assertFalse((self.directory / 'identity-release-active.json').exists())
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)

    def test_start_holds_same_host_lock_through_preflight_and_up(self):
        self.start_server()
        self.pointer()
        self.full_start_fixture()
        wait = self.tmp / 'config-release'
        self.env['FIXTURE_CONFIG_WAIT_FILE'] = str(wait)
        process = subprocess.Popen([PWSH, '-NoProfile', '-File', str(ROOT / 'scripts/start-deployment.ps1'), '-Directory', str(self.directory)], cwd=ROOT, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8')
        try:
            deadline = time.monotonic() + 20
            while not Path(str(wait) + '.entered').exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(Path(str(wait) + '.entered').exists())
            contender = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
            self.assertNotEqual(contender.returncode, 0)
            self.assertEqual(self.requests, [])
            self.assertFalse((self.directory / ('identity-release-' + self.operation + '.json')).exists())
        finally:
            wait.write_text('continue')
            stdout, stderr = process.communicate(timeout=25)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 1)

    def journal(self, phase):
        value = dict(schemaVersion=1, operationId=self.operation, environmentId=self.target['environmentId'], claimId=str(uuid.uuid4()), phase=phase, previousPointer=None)
        (self.directory / ('identity-release-' + self.operation + '.json')).write_text(json.dumps(value))
        return value

    def test_unsent_abandon_resumes_safe_cancellation_of_never_begun_claim(self):
        self.start_server()
        self.remote_state = 'CLAIMED'
        self.journal('ABANDON_REQUESTED')
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.requests, ['QUERY', 'ABANDON_BEFORE_BEGIN'])
        self.assertEqual(self.remote_state, 'CANCELLED')
        self.assertFalse((self.tmp / 'docker.log').exists())

    def test_lost_abandon_reply_only_queries_and_confirms_cancellation(self):
        self.start_server(lose_abandon=True)
        (self.directory / 'identity-provider-releases' / self.operation / 'prepared-release.json').write_text('{}')
        first = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(first.returncode, 0)
        self.assertEqual(self.requests, ['CLAIM', 'ABANDON_BEFORE_BEGIN'])
        second = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertEqual(second.returncode, 2, second.stderr)
        self.assertEqual(self.requests, ['CLAIM', 'ABANDON_BEFORE_BEGIN', 'QUERY'])
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)

    def test_explicit_begin_denial_clears_first_pending_only_with_server_permission(self):
        self.start_server(deny_begin=True)
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests, ['CLAIM', 'BEGIN', 'ABANDON_BEFORE_BEGIN'])
        self.assertEqual(self.remote_state, 'CANCELLED')
        self.assertFalse((self.directory / 'identity-release-active.json').exists())
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)

    def test_cancelled_pending_restores_only_current_server_confirmed_previous_pointer(self):
        previous, _ = self.pointer()
        self.operation, self.version = str(uuid.uuid4()), str(uuid.uuid4())
        self.start_server(deny_begin=True)
        self.confirmed_operation = previous['operationId']
        self.previous_reply = previous
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests, ['CLAIM', 'BEGIN', 'ABANDON_BEFORE_BEGIN', 'QUERY'])
        self.assertEqual(json.loads((self.directory / 'identity-release-active.json').read_text()), previous)
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)

    def test_resumable_claim_rechecks_ownership_before_consuming_begin(self):
        self.start_server()
        self.remote_state = 'CLAIMED'
        self.journal('CLAIMED')
        self.env['FIXTURE_EXISTING_ID'] = 'a' * 12
        self.env['FIXTURE_LABELS'] = json.dumps({'com.docker.compose.project': 'provider-test-' + self.run_id[:10], 'com.docker.compose.service': 'identity', 'com.docker.compose.project.working_dir': str(self.directory.parent / 'another-deployment')})
        result = self.invoke(RUNNER, '-TargetFile', self.target_file, '-OperationId', self.operation)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests, ['QUERY', 'ABANDON_BEFORE_BEGIN'])
        self.assertEqual(self.remote_state, 'CANCELLED')
        self.assertEqual((self.tmp / 'docker.log').read_text().count('|up|'), 0)


if __name__ == '__main__':
    unittest.main()
