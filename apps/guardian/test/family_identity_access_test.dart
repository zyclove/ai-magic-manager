import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/access.dart';
import 'package:guardian/ui/console_navigation.dart';

void main() {
  test('only authenticated explicit platform capabilities open the entry', () {
    expect(
        canOpenIdentityProviders(
            authenticated: true,
            canRead: false,
            canManage: false,
            canTest: false),
        isFalse);
    expect(
        canOpenIdentityProviders(
            authenticated: false,
            canRead: true,
            canManage: true,
            canTest: true),
        isFalse);
    expect(
        canOpenIdentityProviders(
            authenticated: true,
            canRead: true,
            canManage: false,
            canTest: false),
        isTrue);
    expect(
        canOpenIdentityProviders(
            authenticated: true,
            canRead: false,
            canManage: true,
            canTest: false),
        isTrue);
    expect(
        canOpenIdentityProviders(
            authenticated: true,
            canRead: false,
            canManage: false,
            canTest: true),
        isTrue);
  });
  test('tenant roles cannot grant the platform identity configuration entry',
      () {
    for (final role in [
      'OWNER',
      'ORG_ADMIN',
      'GUARDIAN',
      'AUDITOR',
      'CHILD',
      'TEACHER',
      ''
    ]) {
      expect(canOpenSection(role, 'identity-providers'), isFalse, reason: role);
    }
  });

  test('identity configuration is an exact trusted authentication return path',
      () {
    expect(trustedReturnPath('/identity-providers'), '/identity-providers');
    for (final path in [
      '/identity-providers?next=/devices',
      '//identity-providers',
      'https://example.invalid/identity-providers',
      '/identity-providers/',
      '/identity-providers/details'
    ]) {
      expect(trustedReturnPath(path), '/');
    }
  });

  test('identity configuration belongs only to the platform navigation group',
      () {
    expect(
        destinations.where((item) => item.$1 == 'identity-providers').single.$2,
        '短信与微信');
    final groups = navigationGroups
        .where((group) => group.$3.contains('identity-providers'));
    expect(groups.single.$1, 'platform');
  });
}
