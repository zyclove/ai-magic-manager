import 'dart:convert';
import 'package:child/platform/secret_store.dart';
import 'package:child/platform/configuration_database.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sembast/sembast.dart';
import '../test/support/identity_fixture.dart';

/// Run only on a dedicated debug installation. The cloud is controlled, while
/// Android Keystore, encrypted preferences and the durability channel are real.
/// Separate write/read launches prove persistence across process termination.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android encrypted identity survives a separate process launch',
      (tester) async {
    const phase = String.fromEnvironment('STORE_CHECK_PHASE');
    expect(phase, anyOf('write', 'read'));
    final store = AndroidIdentityStore();
    final fixture = IdentityFixture(nativeSecrets: store);
    addTearDown(fixture.close);
    if (phase == 'write') {
      // Do not overwrite an identity from any other journey, even on debug.
      expect(await store.read() == null, isTrue,
          reason: 'Use a fresh dedicated debug installation for this test.');
      await fixture.activate();
      expect(fixture.calls, 2);
    } else {
      expect(await store.read() != null, isTrue);
      fixture.confirmed = true;
    }
    final view = await fixture.identity.view();
    expect(view.phase, IdentityPhase.active);
    expect(view.deviceId, IdentityFixture.device);
    expect(view.registrationId, IdentityFixture.registration);
    expect(await fixture.identity.activeCredential() != null, isTrue);
    // Prove that the persisted software key can still sign after restart.
    // Assert only booleans to prevent a failed expectation printing secrets.
    final record = jsonDecode((await store.read())!) as Map<String, dynamic>;
    expect(record['keyHandle'] is String, isTrue);
    final proof = await const JoseDeviceEnrollmentKeys().proof(
        record['keyHandle'] as String,
        IdentityFixture.enrollment,
        'a' * 43,
        'ai-manager:enrollment-recover',
        IdentityFixture.now);
    expect(proof.publicKeyJwk.isNotEmpty && proof.compact.isNotEmpty, isTrue);
    // Real path_provider + native Sembast file, separate from the secret store.
    // The marker is test-only and does not represent a signed policy receipt.
    final database = await openConfigurationDatabase();
    final marker = StoreRef<String, String>('integration_native_storage');
    try {
      if (phase == 'write') {
        await marker.record('marker').put(database, 'persisted-native-test');
      }
      expect(
          await marker.record('marker').get(database) ==
              'persisted-native-test',
          isTrue);
    } finally {
      await database.close();
    }
    // Heartbeat uses the restored bearer. This controlled cloud substitute
    // does not prove production API interoperability or policy execution.
    await fixture.identity.heartbeat(
        agentVersion: 'native-storage-check', capabilities: const []);
    expect((await fixture.identity.view()).phase, IdentityPhase.active);
  });
}
