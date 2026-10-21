import json
import pathlib
import unittest

ROOT=pathlib.Path(__file__).resolve().parents[2]

class FamilyCommerceRoleDeploymentTest(unittest.TestCase):
    def test_financial_permissions_are_independent_and_not_granted_to_consumers(self):
        realm=json.loads((ROOT/'deploy/keycloak/realm-template.json').read_text(encoding='utf-8-sig'))
        scopes={scope['name'] for scope in realm['clientScopes']}
        roles={role['name'] for role in realm['roles']['realm']}
        mapping={item['clientScope']:set(item['roles']) for item in realm['scopeMappings']}
        parent=next(client for client in realm['clients'] if client['clientId']=='ai-manager-parent')
        console=next(client for client in realm['clients'] if client['clientId']=='ai-manager-guardian')
        for scope,role in [('family-refunds:review','family-refund-reviewer'),('family-finance:manage','family-finance-operator')]:
            self.assertIn(scope,scopes)
            self.assertIn(role,roles)
            self.assertEqual(mapping[scope],{role})
            self.assertIn(scope,console['defaultClientScopes'])
            self.assertNotIn(scope,parent['defaultClientScopes'])
            for user in realm.get('users',[]):
                self.assertNotIn(role,user.get('realmRoles',[]))
        self.assertNotIn('family-refund-reviewer',realm.get('defaultRoles',[]))
        self.assertNotIn('family-finance-operator',realm.get('defaultRoles',[]))

if __name__=='__main__': unittest.main()
