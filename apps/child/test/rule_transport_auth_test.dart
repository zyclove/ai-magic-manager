import 'dart:async';
import 'package:child/core/environment.dart';
import 'package:child/core/rule_receiver.dart';
import 'package:child/core/session.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_policy/device_policy.dart' as policy;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';
import '../../../packages/device_policy/test/fixtures.dart' as signatures;
import 'support/identity_fixture.dart';

/// Real signature verifier, journal, transport and identity manager. Only the
/// HTTP server response and platform database are controlled unit boundaries.
void main() {
  for (final status in [401, 403]) {
    test(
        'real signed receiver persists $status before exposing any cached rule',
        () async {
      final fixture = IdentityFixture();
      addTearDown(fixture.close);
      await fixture.activate();
      final key = signatures.newKey();
      final environment = ChildEnvironment(
          apiRoot: Uri.parse('https://service.example/api/v1'),
          configurationIssuer: 'ai-manager',
          configurationKeys: signatures.publicRing(key));
      final verifier = policy.ConfigurationVerifier(
          scope: const policy.DevicePolicyScope(
              issuer: 'ai-manager',
              tenantId: IdentityFixture.tenant,
              deviceId: IdentityFixture.device,
              registrationId: IdentityFixture.registration),
          trustedKeys: signatures.publicRing(key),
          nowMillis: () => fixture.clock);
      final filename = 'rule-auth-$status';
      final seed = await databaseFactoryMemory.openDatabase(filename);
      final journal =
          policy.ConfigurationJournal(database: seed, verifier: verifier);
      final receipt = await journal.accept(signatures.sign(
          key,
          signatures.envelope({
            'tenantId': IdentityFixture.tenant,
            'deviceId': IdentityFixture.device,
            'registrationId': IdentityFixture.registration,
            'issuedAt': fixture.clock - 1,
            'deliveryExpiresAt': fixture.clock + 60000
          })));
      await journal.acknowledge(receipt.receiptId);
      await seed.close();
      var attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        expect(request.headers['authorization'], 'Bearer ${'b' * 43}');
        return http.Response('{}', status,
            headers: {'content-type': 'application/json'});
      });
      addTearDown(client.close);
      final session = ChildSession(
          identity: fixture.identity,
          ruleReceiverFactory: (view) => SignedRuleReceiver.open(
              environment, fixture.identity, view, () => fixture.clock,
              databaseOpener: () =>
                  databaseFactoryMemory.openDatabase(filename),
              client: client));
      addTearDown(session.dispose);
      await session.initialize();
      expect(session.rules.configurations, hasLength(1));
      expect(await session.synchronizeRules(), isFalse);
      expect(attempts, 1);
      expect(session.rules.configurations, isEmpty);
      expect(session.credentialReady, isFalse);
      final recreated = DeviceIdentityManager(
          api: fixture.identity.api,
          secrets: fixture.secrets,
          nowMillis: () => fixture.clock);
      expect((await recreated.view()).cloudAuthenticationBlocked, isTrue);
      expect(await recreated.activeCredential(), isNull);
      final preserved = await databaseFactoryMemory.openDatabase(filename);
      expect(
          await policy.ConfigurationJournal(
                  database: preserved, verifier: verifier)
              .restore(),
          hasLength(1),
          reason:
              'Revocation hides private data; it never erases signed cache to claim recovery.');
      await preserved.close();
    });
  }
  test('real transport late 401 cannot block a successfully rotated credential',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final entered = Completer<void>(), release = Completer<void>();
    final client = MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer ${'b' * 43}');
      entered.complete();
      await release.future;
      return http.Response('{}', 401,
          headers: {'content-type': 'application/json'});
    });
    addTearDown(client.close);
    final environment = ChildEnvironment(
        apiRoot: Uri.parse('https://service.example/api/v1'),
        configurationIssuer: 'ai-manager',
        configurationKeys: signatures.publicRing(signatures.newKey()));
    final session = ChildSession(
        identity: fixture.identity,
        ruleReceiverFactory: (view) => SignedRuleReceiver.open(
            environment, fixture.identity, view, () => fixture.clock,
            client: client,
            databaseOpener: () =>
                databaseFactoryMemory.openDatabase('late-rule-auth')));
    addTearDown(session.dispose);
    await session.initialize();
    final synchronizing = session.synchronizeRules();
    await entered.future;
    await fixture.identity.rotate();
    await fixture.identity.activateRotation();
    release.complete();
    expect(await synchronizing, isFalse);
    expect(await fixture.identity.activeCredential(), 'c' * 43);
    expect((await fixture.identity.view()).cloudAuthenticationBlocked, isFalse);
    expect(session.credentialReady, isTrue);
  });
}
