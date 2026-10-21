"""Offline realm permissions, with no identity Admin API or provider requests."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
SCOPES = {'identity-config:read', 'identity-config:manage', 'identity-config:test',
          'identity-config:publish', 'identity-config:rollback'}
ROLES = {'identity-provider-viewer', 'identity-provider-operator', 'identity-provider-tester',
         'identity-provider-publisher', 'identity-provider-rollback-operator'}


class IdentityProviderAdminPermissionsTest(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / '.cache/family-provider-release-20261017-r2/permissions/tmp' / uuid.uuid4().hex
        self.directory.mkdir(parents=True)
        self.realm = json.loads((ROOT / 'deploy/keycloak/realm-template.json').read_text(encoding='utf-8-sig'))

    def tearDown(self):
        boundary = (ROOT / '.cache/family-provider-release-20261017-r2/permissions/tmp').resolve()
        self.assertEqual(self.directory.resolve().parent, boundary)
        shutil.rmtree(self.directory)

    def assert_permissions(self, realm):
        clients = {item['clientId']: item for item in realm['clients']}
        self.assertIs(clients['ai-manager-guardian']['fullScopeAllowed'], False)
        self.assertIs(clients['ai-manager-parent']['fullScopeAllowed'], False)
        self.assertTrue(SCOPES <= set(clients['ai-manager-guardian']['defaultClientScopes']))
        self.assertFalse(SCOPES & set(clients['ai-manager-parent']['defaultClientScopes']))
        self.assertFalse(SCOPES & set(clients['ai-manager-parent'].get('optionalClientScopes', [])))
        self.assertTrue(ROLES <= {item['name'] for item in realm['roles']['realm']})
        mapping = {item['clientScope']: set(item['roles']) for item in realm['scopeMappings']}
        self.assertEqual(mapping['identity-config:read'], ROLES)
        self.assertEqual(mapping['identity-config:manage'], {'identity-provider-operator'})
        self.assertEqual(mapping['identity-config:test'], {'identity-provider-tester',
            'identity-provider-publisher', 'identity-provider-rollback-operator'})
        self.assertEqual(mapping['identity-config:publish'], {'identity-provider-publisher'})
        self.assertEqual(mapping['identity-config:rollback'], {'identity-provider-rollback-operator'})
        scopes = {item['name']: item for item in realm['clientScopes']}
        for name in SCOPES:
            self.assertEqual(scopes[name]['protocol'], 'openid-connect')
            self.assertEqual(scopes[name]['attributes']['include.in.token.scope'], 'true')

    def convert(self, realm=None, output=None):
        source = self.directory / 'input.json'
        source.write_text(json.dumps(realm or self.realm), encoding='utf-8')
        target = output or self.directory / 'output.json'
        result = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-File',
            str(ROOT / 'deploy/keycloak/merge-identity-provider-admin-realm.ps1'),
            '-InputPath', str(source), '-OutputPath', str(target)],
            cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=30)
        return result, source, target

    def test_fresh_realm_grants_scopes_only_through_platform_roles(self):
        self.assert_permissions(self.realm)

    def test_existing_export_conversion_preserves_every_existing_user_and_client(self):
        self.realm['users'] = [{'id': 'existing-user', 'username': 'fixture-admin', 'realmRoles': ['tenant-creator']}]
        old = json.loads(json.dumps(self.realm))
        result, source, target = self.convert()
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads(target.read_text(encoding='utf-8-sig'))
        self.assert_permissions(actual)
        self.assertEqual(actual['users'], old['users'])
        self.assertEqual(actual['browserFlow'], old['browserFlow'])
        self.assertEqual(actual['authenticationFlows'], old['authenticationFlows'])
        self.assertEqual(json.loads(source.read_text()), old)

    def test_conversion_refuses_to_overwrite_an_existing_output(self):
        output = self.directory / 'output.json'
        output.write_text('preserve this', encoding='utf-8')
        result, _, _ = self.convert(output=output)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_text(), 'preserve this')

    def test_conversion_is_idempotent_without_granting_roles_to_users(self):
        first, _, target = self.convert()
        self.assertEqual(first.returncode, 0, first.stderr)
        converted = json.loads(target.read_text(encoding='utf-8-sig'))
        result, _, second_target = self.convert(converted, self.directory / 'second.json')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(second_target.read_text(encoding='utf-8-sig')), converted)

    def test_conversion_refuses_consumer_client_with_platform_scope(self):
        parent = next(item for item in self.realm['clients'] if item['clientId'] == 'ai-manager-parent')
        parent['defaultClientScopes'].append('identity-config:manage')
        result, _, target = self.convert()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())

    def test_legacy_configuration_roles_upgrade_without_assigning_users(self):
        legacy = json.loads(json.dumps(self.realm))
        old_roles = {'identity-provider-viewer', 'identity-provider-operator', 'identity-provider-tester'}
        old_scopes = {'identity-config:read', 'identity-config:manage', 'identity-config:test'}
        legacy['roles']['realm'] = [r for r in legacy['roles']['realm'] if r['name'] not in ROLES - old_roles]
        legacy['clientScopes'] = [s for s in legacy['clientScopes'] if s['name'] not in SCOPES - old_scopes]
        legacy['scopeMappings'] = [m for m in legacy['scopeMappings'] if m['clientScope'] not in SCOPES - old_scopes]
        for mapping in legacy['scopeMappings']:
            if mapping['clientScope'] == 'identity-config:read': mapping['roles'] = sorted(old_roles)
            if mapping['clientScope'] == 'identity-config:test': mapping['roles'] = ['identity-provider-tester']
        guardian = next(c for c in legacy['clients'] if c['clientId'] == 'ai-manager-guardian')
        guardian['defaultClientScopes'] = [s for s in guardian['defaultClientScopes'] if s not in SCOPES - old_scopes]
        legacy['users'] = [{'username': 'existing-admin', 'realmRoles': ['identity-provider-operator']}]
        result, source, target = self.convert(legacy)
        self.assertEqual(result.returncode, 0, result.stderr)
        upgraded = json.loads(target.read_text(encoding='utf-8-sig'))
        self.assert_permissions(upgraded)
        self.assertEqual(upgraded['users'], legacy['users'])
        self.assertEqual(json.loads(source.read_text()), legacy)

    def test_unreviewed_role_mapping_is_not_silently_upgraded(self):
        mapping = next(m for m in self.realm['scopeMappings'] if m['clientScope'] == 'identity-config:read')
        mapping['roles'].append('tenant-creator')
        result, _, target = self.convert()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())

    def test_conversion_rejects_linked_parent_without_writing_to_target(self):
        outside = self.directory / 'link-target'
        outside.mkdir()
        marker = outside / 'unique.txt'
        marker.write_text('preserve', encoding='utf-8')
        linked = self.directory / 'linked'
        if os.name == 'nt':
            helper = self.directory / 'junction.ps1'
            helper.write_text('param($a,$b) New-Item -ItemType Junction -Path $a -Target $b | Out-Null', encoding='utf-8')
            result = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-File', str(helper),
                '-a', str(linked), '-b', str(outside)], capture_output=True, text=True, encoding='utf-8')
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            linked.symlink_to(outside, target_is_directory=True)
        try:
            result, _, _ = self.convert(output=linked / 'output.json')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((outside / 'output.json').exists())
            self.assertEqual(marker.read_text(), 'preserve')
        finally:
            if os.name == 'nt': linked.rmdir()
            else: linked.unlink()

    def test_export_file_is_private_even_under_a_permissive_parent(self):
        result, _, output = self.convert()
        self.assertEqual(result.returncode, 0, result.stderr)
        if os.name == 'nt':
            helper = self.directory / 'check-acl.ps1'
            helper.write_text('''param($FilePath)
$owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$allowed=@($owner,'S-1-5-18','S-1-5-32-544')
$acl=Get-Acl -LiteralPath $FilePath
$extra=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $allowed })
if(-not $acl.AreAccessRulesProtected -or $extra.Count -ne 0){exit 1}
''', encoding='utf-8')
            checked = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-File', str(helper),
                '-FilePath', str(output)], capture_output=True, text=True, encoding='utf-8')
            self.assertEqual(checked.returncode, 0, 'Realm export inherited permissions outside the allowed administrators')
        else:
            self.assertEqual(output.stat().st_mode & 0o077, 0)


if __name__ == '__main__':
    unittest.main()
