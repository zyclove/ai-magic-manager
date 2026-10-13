import 'dart:convert';
import 'dart:io';
import 'package:child/core/cleanup_runner.dart';
import 'package:child/core/environment.dart';
import 'package:child/core/session.dart' show parseRegistrationTicket;
import 'package:child/platform/access_database_io.dart';
import 'package:child/platform/cleanup_executor_io.dart';
import 'package:child/platform/configuration_database_io.dart';
import 'package:child/platform/device_keys.dart';
import 'package:child/platform/secret_store.dart';
import 'package:device_cleanup/device_cleanup.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import '../../../packages/device_cleanup/test/fixtures.dart' as signatures;
import '../test/support/identity_fixture.dart';

const _now = IdentityFixture.now;
const _deadline = _now + 60000;
final _accessScope = 'a' * 64;
const _marker = 'synthetic-cleanup-private-cache';

/// Dedicated empty debug AVD only. Android key generation/deletion, encrypted
/// preferences, app-private files and commit/fsync channels are real. Cloud
/// registration, signed cleanup issuance and acknowledgements are controlled
/// substitutes; no production account or network service is involved.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android agent cleanup persists across separate process launches',
      (tester) async {
    const phase = String.fromEnvironment('CLEANUP_STORE_PHASE');
    expect(['seed', 'clear', 'finish', 'verify'].contains(phase), isTrue);
    final directory = await getApplicationSupportDirectory();
    final oracleFile = File('${directory.path}/cleanup-native-oracle.json');
    final store = AndroidIdentityStore();
    final keys = AndroidDeviceKeys();
    final cloud = IdentityFixture();
    addTearDown(cloud.close);
    const clock =
        phase == 'finish' || phase == 'verify' ? _deadline + 60000 : _now;
    final identity = DeviceIdentityManager(
        api: DeviceIdentityApi(
            apiRoot: Uri.parse('https://service.example/api/v1'),
            client: cloud.client),
        secrets: store,
        keys: keys,
        nowMillis: () => clock);
    Map<String, dynamic> oracle;
    if (phase == 'seed') {
      expect(await oracleFile.exists(), isFalse);
      expect(await store.read() == null, isTrue,
          reason: 'Dedicated empty debug installation required');
      expect((await store.storage.readAll()).isEmpty, isTrue);
      await identity.begin(parseRegistrationTicket(cloud.ticket),
          displayName: 'Native cleanup fixture', osVersion: 'Android API34');
      cloud.confirmed = true;
      await identity.heartbeat(
          agentVersion: 'cleanup-native-test', capabilities: const []);
      final proof = await identity.cleanupProof(action: 'READ');
      final state = jsonDecode((await store.read())!) as Map;
      final handle = state['keyHandle'] as String;
      expect(handle.startsWith('aimanager.device.'), isTrue,
          reason: 'Must exercise AndroidKeyStore, not software JWK');
      final scope = CleanupScope(IdentityFixture.tenant, IdentityFixture.device,
          IdentityFixture.registration, proof.keyThumbprint);
      final signer = signatures.Fixture(scope)..now = clock;
      final compact =
          signer.sign({'issuedAt': _now - 1000, 'notAfter': _deadline});
      oracle = {
        'schemaVersion': 1,
        'phase': 'seed',
        'handle': handle,
        'thumbprint': proof.keyThumbprint,
        'compact': compact,
        'publicKeys': signer.ring,
      };
      final command = await _command(oracle, clock);
      final journal = _journal(command, clock);
      await journal.load(command);
      final received = await journal.prepare(CleanupReceiptStage.received);
      await journal.acknowledge(received, _ack(received));

      final policy = await openConfigurationDatabase();
      await stringMapStoreFactory
          .store('native-cleanup')
          .record('marker')
          .put(policy, {'value': _marker});
      await policy.close();
      await File('${directory.path}/configuration-v1.db')
          .copy('${directory.path}/~configuration-v1.db');
      final access = await openAccessDatabase(_accessScope);
      await stringMapStoreFactory
          .store('native-cleanup')
          .record('marker')
          .put(access, {'value': _marker});
      await access.close();
      await File('${directory.path}/access-v1-$_accessScope.db')
          .copy('${directory.path}/~access-v1-$_accessScope.db');
      await store.storage.write(key: 'observation_record', value: _marker);
      await store.storage
          .write(key: 'access_context_v1_$_accessScope', value: _marker);
      await store.storage
          .write(key: 'help_request_v1_$_accessScope', value: _marker);
      await store.flushForCleanup();
      await store.flushAgentFiles(directory.path);
      await File('${directory.path}/unrelated-native-marker.txt')
          .writeAsString('preserve', flush: true);
      await oracleFile.writeAsString(jsonEncode(oracle), flush: true);
      expect(await identity.activeCredential() != null, isTrue);
    } else {
      expect(await oracleFile.exists(), isTrue,
          reason: 'NATIVE_CLEANUP_MISSING_SEED');
      oracle =
          jsonDecode(await oracleFile.readAsString()) as Map<String, dynamic>;
      expect(oracle['schemaVersion'] == 1, isTrue);
      final expectedPrevious =
          {'clear': 'seed', 'finish': 'clear', 'verify': 'finish'}[phase];
      expect(oracle['phase'] == expectedPrevious, isTrue,
          reason: 'Native phases must use the preceding process state');
      if (phase == 'clear') {
        expect((await identity.view()).phase == IdentityPhase.active, isTrue);
        expect(
            (await identity.cleanupProof(action: 'READ')).keyThumbprint ==
                oracle['thumbprint'],
            isTrue);
        final command = await _command(oracle, clock);
        final journal = _journal(command, clock);
        expect((await journal.load(command)).receivedAcknowledged, isTrue);
        await AndroidAgentCleanupExecutor(
            identity: identity,
            secureStore: store,
            ownersClosed: () => true).clearOwnData(command);
        await journal.markLocalDataCleared();
        final cleared =
            await journal.prepare(CleanupReceiptStage.agentDataCleared);
        await journal.acknowledge(cleared, _ack(cleared));
        expect(await identity.activeCredential() == null, isTrue);
        expect((await identity.view()).phase == IdentityPhase.cleanupPending,
            isTrue);
        expect(
            (await identity.cleanupProof(action: 'READ')).keyThumbprint ==
                oracle['thumbprint'],
            isTrue);
        expect(
            await CleanupReceiptJournal.finalKeyRemovalReady(
                scope: command.scope,
                commandHash: command.commandHash,
                store: AndroidCleanupRecordStore(command.scope)),
            isTrue);
        await _cachesGone(directory, store, allowIdentity: true);
      } else {
        // The production runner must take durable final-ack recovery before
        // attempting HTTP. Its command is now expired, proving no re-fetch.
        if (phase == 'finish') {
          expect((await identity.view()).phase == IdentityPhase.cleanupPending,
              isTrue);
          final result = await ChildCleanupRunner(
              environment: ChildEnvironment(
                  apiRoot: Uri.parse('https://cleanup-native.invalid/api/v1')),
              identity: identity,
              secureStore: store,
              ownersClosed: () => true,
              nowMillis: () => clock).runOnce();
          expect(result == CleanupRunStage.keyRemoved, isTrue);
        }
        expect(await store.read() == null, isTrue);
        await expectLater(
            keys.cleanupProof(
                oracle['handle'] as String,
                IdentityFixture.tenant,
                IdentityFixture.device,
                IdentityFixture.registration,
                'READ',
                null,
                clock),
            throwsA(isA<DeviceIdentityFailure>()));
        await _cachesGone(directory, store, allowIdentity: false);
      }
      expect(cloud.calls, 0);
      oracle['phase'] = phase;
      await oracleFile.writeAsString(jsonEncode(oracle), flush: true);
    }
    final result = {
      'phase': phase,
      'pid': pid,
      'realAndroidStorage': true,
      'realAndroidKeyAlias': true,
      'cloudIsControlledSubstitute': true,
      'cacheDeletionChecked': phase != 'seed',
      'originalKeyRetained': phase == 'seed' || phase == 'clear',
      'originalKeyDeletionChecked': phase == 'finish' || phase == 'verify',
      'expiredAcknowledgedRecovery': phase == 'finish',
      'physicalWipeProven': false,
    };
    binding.reportData = result;
    debugPrint('CLEANUP_NATIVE_RESULT ${jsonEncode(result)}');
  });
}

Future<VerifiedCleanupCommand> _command(
        Map<String, dynamic> oracle, int clock) =>
    CleanupCommandVerifier(
            scope: CleanupScope(IdentityFixture.tenant, IdentityFixture.device,
                IdentityFixture.registration, oracle['thumbprint'] as String),
            trustedKeys: Map<String, dynamic>.from(oracle['publicKeys'] as Map),
            nowMillis: () => clock)
        .verify(oracle['compact'] as String,
            operationId: signatures.operation,
            commandId: signatures.commandId,
            notAfter: _deadline);

CleanupReceiptJournal _journal(VerifiedCleanupCommand command, int clock) =>
    CleanupReceiptJournal(
        scope: command.scope,
        store: AndroidCleanupRecordStore(command.scope),
        nowMillis: () => clock);

CleanupReceiptAck _ack(CleanupReceipt receipt) {
  final command = receipt.command;
  return CleanupReceiptAck.parse({
    'id': command.operationId,
    'deviceId': command.scope.deviceId,
    'registrationId': command.scope.registrationId,
    'commandId': command.commandId,
    'action': 'AGENT_UNENROLL',
    'state': receipt.stage == CleanupReceiptStage.received
        ? 'COMMAND_RECEIVED'
        : 'CLEANUP_REPORTED',
    'remoteAccess': 'REVOKED',
    'localEvidence': receipt.stage == CleanupReceiptStage.received
        ? 'NONE'
        : 'DEVICE_REPORT_UNVERIFIED',
    'reasonCode': null,
    'issuedAt': command.issuedAt,
    'notAfter': command.notAfter,
    'version': 1,
  }, receipt);
}

Future<void> _cachesGone(Directory directory, AndroidIdentityStore store,
    {required bool allowIdentity}) async {
  for (final name in [
    'configuration-v1.db',
    '~configuration-v1.db',
    'access-v1-$_accessScope.db',
    '~access-v1-$_accessScope.db'
  ]) {
    expect(await File('${directory.path}/$name').exists(), isFalse);
  }
  final records = await store.storage.readAll();
  expect(
      records.keys.every((key) =>
          key.startsWith('cleanup_journal_v1_') ||
          allowIdentity && key == 'identity_record'),
      isTrue);
  expect(
      await File('${directory.path}/unrelated-native-marker.txt')
              .readAsString() ==
          'preserve',
      isTrue);
  await store.flushForCleanup();
}
