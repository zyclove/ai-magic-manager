import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:child/core/access.dart';
import 'package:child/core/access_receiver.dart';
import 'package:child/core/environment.dart';
import 'package:child/platform/access_codec.dart';
import 'package:child/platform/access_database_io.dart';
import 'package:device_access/device_access.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_policy/device_policy.dart' as policy;
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

/// JVM-owned loopback fixture only. Each invocation is a new Flutter process.
/// Synthetic file keys substitute Android secure storage; this is not OTP or
/// native keystore evidence. No credential or signed payload is logged.
class _FileBinding implements ChildAccessBindingStore {
  final Database database;
  _FileBinding(this.database);
  final store = stringMapStoreFactory.store('context');
  @override
  Future<String?> read(String key) async =>
      (await store.record(key).get(database))?['value'] as String?;
  @override
  Future<void> write(String key, String value) async {
    await store.record(key).put(database, {'value': value});
  }
}

void main() {
  test('real Spring to child host with durable authenticated scope', () async {
    final path = Platform.environment['CHILD_ACCESS_HTTP_FIXTURE'];
    final mode = Platform.environment['CHILD_ACCESS_HTTP_MODE'];
    expect(path, isNotNull);
    expect({
      'host',
      'host-revoked',
      'host-expired',
      'host-unauthenticated',
      'host-blocked'
    }, contains(mode));
    final file = File(path!);
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final root = Uri.parse(data['apiRoot'] as String);
    expect(root.scheme, 'http');
    expect(root.host, '127.0.0.1');
    final now = data['nowMillis'] as int;
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final priorOverrides = HttpOverrides.current;
    HttpOverrides.global = null; // Actual loopback, not Flutter's HTTP mock.
    final baselineDb = await databaseFactoryIo.openDatabase(
        '${file.parent.path}/host-baseline.db',
        mode: DatabaseMode.create);
    final contextDb = await databaseFactoryIo.openDatabase(
        '${file.parent.path}/host-context.db',
        mode: DatabaseMode.create,
        codec: AccessDatabaseCodec(key, '0' * 64).sembastCodec);
    final baseline = policy.ConfigurationJournal(
        database: baselineDb,
        verifier: policy.ConfigurationVerifier(
            scope: policy.DevicePolicyScope(
                issuer: 'ai-manager',
                tenantId: data['tenantId'],
                deviceId: data['deviceId'],
                registrationId: data['registrationId']),
            trustedKeys: Map<String, dynamic>.from(data['publicKeys']),
            nowMillis: () => now));
    final baselineSync = policy.DeviceConfigurationSynchronizer(
        journal: baseline,
        transport: policy.DeviceConfigurationTransport(
            apiRoot: root,
            credential: () async => data['credential'],
            allowLoopbackHttp: true));
    final receiver = SignedAccessReceiver(
        environment: ChildEnvironment(
            apiRoot: root,
            configurationIssuer: 'ai-manager',
            configurationKeys: Map<String, dynamic>.from(data['publicKeys']),
            allowLoopbackHttp: true),
        identity: DeviceIdentityView(
            phase: IdentityPhase.active,
            tenantId: data['tenantId'],
            deviceId: data['deviceId'],
            registrationId: data['registrationId'],
            heartbeatSequence: 0,
            heartbeatPending: false,
            cloudAuthenticationBlocked: false),
        credential: () async => data['credential'],
        readBaseline: () async => (await baseline.restore()).values.toList(),
        nowMillis: () => now,
        bindingStore: _FileBinding(contextDb),
        databaseOpener: (scope) => openAccessDatabase(scope,
            directoryPath: file.parent.path,
            keyProvider: (_, {required existingDatabase}) async => key));
    try {
      if (mode == 'host') {
        final result = await baselineSync.synchronize();
        expect(result.hasMore, isFalse);
        expect((await baseline.restore()).length, 2);
      }
      final before = await receiver.restore();
      if (mode == 'host-blocked') {
        expect(before.contextReady, isFalse);
        expect(before.entries, isEmpty);
      } else if (mode == 'host-unauthenticated') {
        expect(before.entries.length, 2);
        await expectLater(
            receiver.synchronize(),
            throwsA(isA<AccessTransportFailure>()
                .having((e) => e.status, 'status', 401)));
        expect((await receiver.restore()).entries, isEmpty);
      } else {
        final snapshot = await receiver.synchronize();
        expect(snapshot.onlineConfirmed, isTrue);
        expect(snapshot.systemEnforced, isFalse);
        expect(snapshot.issues, isEmpty);
        expect(snapshot.pendingReceipts, 0);
        expect(snapshot.entries.length, 2);
        final grants = data['grants'] as List;
        for (var i = 0; i < grants.length; i++) {
          final entry = snapshot.entries.singleWhere(
              (e) => e.record.window.requestId == grants[i]['requestId']);
          expect(entry.record.window.absoluteNotAfter,
              grants[i]['absoluteNotAfter']);
          expect(entry.requiresReview, isFalse);
          expect(
              entry.record.state,
              mode == 'host-expired' || mode == 'host-revoked' && i == 0
                  ? AccessEntryState.removed
                  : AccessEntryState.stored);
        }
        if (mode != 'host') expect(before.entries.length, 2);
      }
      // New processes reopen the same encrypted context and signed journal.
      stdout.writeln('Child access HTTP $mode: PASS');
    } finally {
      await receiver.close();
      baselineSync.close();
      await baselineDb.close();
      await contextDb.close();
      HttpOverrides.global = priorOverrides;
    }
  });
}
