import 'dart:convert';
import 'dart:io';
import 'package:child/core/access_receiver.dart';
import 'package:child/core/environment.dart';
import 'package:child/platform/secret_store.dart';
import 'package:device_access/device_access.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_policy/device_policy.dart' as policy;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha256.dart';
import '../../../packages/device_access/test/fixtures.dart' as grants;
import '../../../packages/device_policy/test/fixtures.dart' as rules;

const _issuer = 'ai-manager-access-native-fixture-v1';
const _origin = 'https://access-storage-fixture.invalid/api/v1';
const _now = 1800000000000, _deadline = _now + 60000;
const _scope = DeviceAccessScope(
    issuer: _issuer,
    tenantId: grants.tenant,
    subjectId: grants.subject,
    deviceId: grants.device,
    registrationId: grants.registration);
final _bindingKey = const policy.DevicePolicyScope(
        issuer: '$_issuer|$_origin',
        tenantId: grants.tenant,
        deviceId: grants.device,
        registrationId: grants.registration)
    .storageKey;
final _oracleKey = const policy.DevicePolicyScope(
        issuer: '$_issuer|oracle-v1',
        tenantId: grants.tenant,
        deviceId: grants.device,
        registrationId: grants.registration)
    .storageKey;

Future<String?> _digest(File file) async => await file.exists()
    ? base64Encode(SHA256Digest().process(await file.readAsBytes()))
    : null;

/// Runtime-generated signatures and public trust only. No signing private key
/// leaves memory; this explicit cloud substitute never opens a socket.
Map<String, dynamic> _newOracle() {
  final key = grants.newKey('native-access-fixture');
  final baseline = rules.envelope({
    'issuer': _issuer,
    'issuedAt': _now - 1000,
    'deliveryExpiresAt': _now + 300000,
    'document': {
      'name': 'Native synthetic baseline',
      'rules': [
        {
          'sourceRuleIds': ['game'],
          'kind': 'APP_LAUNCH',
          'predictedEffect': 'DENY',
          'effectiveEffect': null,
          'applicationId': grants.application
        }
      ],
      'applications': [
        {
          'id': grants.application,
          'displayName': 'Native synthetic reading',
          'packageName': 'org.example.accessnativefixture',
          'platform': 'ANDROID',
          'profile': 'PRIMARY'
        }
      ],
      'schedules': [],
      'protectedPackageExemptions': []
    }
  });
  final window = grants.envelope({
    'issuer': _issuer,
    'grantIssuedAt': _now - 1000,
    'documentIssuedAt': _now - 500,
    'absoluteNotAfter': _deadline
  });
  final removal = {
    ...window,
    'documentId': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'approvalVersion': 2,
    'approvalState': 'REVOKED',
    'action': 'REMOVE_ACCESS_WINDOW',
    'documentIssuedAt': _deadline + 2
  };
  return {
    'fixture': 'native-access-v1',
    'schemaVersion': 1,
    'publicKeys': grants.publicRing(key),
    'baseline': rules.sign(key, baseline),
    'window': grants.sign(key, window),
    'windowFields': window,
    'removal': grants.sign(key, removal),
    'removalFields': removal,
    'originalReceipt': null
  };
}

/// Dedicated debug emulator only. Host must prove process death between phases.
/// Native Keystore/plugin/path_provider/Sembast are real; cloud and identity
/// claims are controlled fixtures, not production approval or system control.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'native access context and encrypted journal survive process death',
      (tester) async {
    const phase = String.fromEnvironment('ACCESS_STORE_PHASE');
    expect(
        {
          'write_pending',
          'replay_pending',
          'offline_expire_pause',
          'verify_checking_reject',
          'verify_blocked',
          'apply_removal',
          'verify_removed',
          'cleanup'
        }.contains(phase),
        isTrue);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Text('Native access storage verification'))));
    final identity = AndroidIdentityStore();
    final observations = AndroidObservationStore();
    final bindings = AndroidAccessBindingStore();
    final identityBefore = await identity.read();
    final observationBefore = await observations.read();
    final directory = await getApplicationSupportDirectory();
    final configFile = File(path.join(directory.path, 'configuration-v1.db'));
    final configurationBefore = await _digest(configFile);
    final dbFile =
        File(path.join(directory.path, 'access-v1-${_scope.storageKey}.db'));
    final persisted = await bindings.read(_oracleKey);
    late final Map<String, dynamic> oracle;
    if (phase == 'write_pending') {
      expect(
          persisted == null &&
              await bindings.read(_bindingKey) == null &&
              !await dbFile.exists(),
          isTrue,
          reason: 'Refuse to overwrite a pre-existing access fixture.');
      oracle = _newOracle();
      await bindings.write(_oracleKey, jsonEncode(oracle));
    } else {
      expect(persisted != null, isTrue,
          reason: 'Requires oracle from the preceding native process.');
      oracle = Map<String, dynamic>.from(jsonDecode(persisted!) as Map);
      expect(
          oracle['fixture'] == 'native-access-v1' &&
              oracle['schemaVersion'] == 1,
          isTrue);
      expect(await dbFile.exists(), isTrue);
    }
    final keys = Map<String, dynamic>.from(oracle['publicKeys'] as Map);
    expect(
        (keys['keys'] as List).every((key) => !(key as Map).containsKey('d')),
        isTrue,
        reason: 'Persist only public signing material.');
    var clock = phase == 'write_pending'
        ? _now
        : phase == 'replay_pending' || phase == 'offline_expire_pause'
            ? _now + 1000
            : _deadline + 3;
    final verifier = policy.ConfigurationVerifier(
        scope: const policy.DevicePolicyScope(
            issuer: _issuer,
            tenantId: grants.tenant,
            deviceId: grants.device,
            registrationId: grants.registration),
        trustedKeys: keys,
        nowMillis: () => clock);
    var calls = 0, receiptPosts = 0;
    var originalCompared = false, interrupted = false;
    late SignedAccessReceiver receiver;
    final client = MockClient((request) async {
      calls++;
      expect(request.url.origin == Uri.parse(_origin).origin, isTrue);
      final binding = jsonDecode((await bindings.read(_bindingKey))!) as Map;
      expect(binding['phase'] == 'CHECKING', isTrue,
          reason: 'Native durable intent must precede each HTTP operation.');
      if (phase == 'offline_expire_pause') {
        receiver.pause();
        interrupted = true;
        throw http.ClientException('Explicit native cancellation fixture');
      }
      if (phase == 'verify_blocked' ||
          phase == 'verify_removed' ||
          phase == 'cleanup') {
        throw StateError('Read-only native restore must never use HTTP');
      }
      if (phase == 'verify_checking_reject') {
        return http.Response(
            jsonEncode({'errorCode': 'DEVICE_UNAUTHENTICATED'}), 401,
            headers: {'content-type': 'application/json'});
      }
      const removing = phase == 'apply_removal';
      final payload = Map<String, dynamic>.from(
          oracle[removing ? 'removalFields' : 'windowFields'] as Map);
      Map<String, dynamic> body;
      if (request.url.path.endsWith('/access-context')) {
        body = {
          'tenantId': grants.tenant,
          'subjectId': grants.subject,
          'deviceId': grants.device,
          'registrationId': grants.registration
        };
      } else if (request.url.path.endsWith('/access-requests')) {
        body = {
          'items': [
            {
              'requestId': grants.request,
              'approvalVersion': payload['approvalVersion'],
              'approvalState': payload['approvalState'],
              'absoluteNotAfter': _deadline
            }
          ],
          'nextCursor': null
        };
      } else if (request.method == 'GET') {
        body = {
          'documentId': payload['documentId'],
          'requestId': grants.request,
          'approvalVersion': payload['approvalVersion'],
          'action': payload['action'],
          'signedDocument': oracle[removing ? 'removal' : 'window'],
          'documentIssuedAt': payload['documentIssuedAt'],
          'deliveryAttempt': 1,
          'deliveryState': 'SIGNED',
          'retryStatus': 'NOT_NEEDED'
        };
      } else {
        receiptPosts++;
        if (phase == 'write_pending') {
          expect(oracle['originalReceipt'] == null, isTrue);
          oracle['originalReceipt'] = request.body;
          await bindings.write(_oracleKey, jsonEncode(oracle));
          throw http.ClientException('Synthetic lost receipt acknowledgement');
        }
        if (phase == 'replay_pending') {
          expect(oracle['originalReceipt'] == request.body, isTrue,
              reason:
                  'Native restart must replay the original receipt unchanged.');
          originalCompared = true;
        }
        final receipt = jsonDecode(request.body) as Map;
        body = {
          'documentId': receipt['documentId'],
          'approvalVersion': payload['approvalVersion'],
          'deliveryAttempt': receipt['deliveryAttempt'],
          'phase': receipt['phase'],
          'receivedAt': clock,
          'current': true,
          'evidenceStatus': 'DEVICE_REPORT_UNVERIFIED',
          'executionState': 'NOT_ENFORCED'
        };
      }
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    });
    receiver = SignedAccessReceiver(
        environment: ChildEnvironment(
            apiRoot: Uri.parse(_origin),
            configurationIssuer: _issuer,
            configurationKeys: keys),
        identity: const DeviceIdentityView(
            phase: IdentityPhase.active,
            tenantId: grants.tenant,
            deviceId: grants.device,
            registrationId: grants.registration,
            heartbeatSequence: 0,
            heartbeatPending: false,
            cloudAuthenticationBlocked: false),
        credential: () async => 'b' * 43,
        readBaseline: () async => [
              await verifier.verify(oracle['baseline'] as String,
                  restoration: true)
            ],
        nowMillis: () => clock,
        bindingStore: bindings,
        transportFactory: () => DeviceAccessTransport(
            apiRoot: Uri.parse(_origin),
            credential: () async => 'b' * 43,
            client: client));
    addTearDown(receiver.close);
    addTearDown(client.close);
    var view = await receiver.restore();
    if (phase == 'write_pending' || phase == 'replay_pending') {
      if (phase == 'replay_pending') {
        expect(view.entries.single.requiresReview, isTrue);
        expect(view.pendingReceipts, 1);
      }
      view = await receiver.synchronize();
      expect(view.entries.single.record.state, AccessEntryState.stored);
      expect(view.pendingReceipts, phase == 'write_pending' ? 1 : 0);
      expect(view.entries.single.requiresReview, phase == 'write_pending');
      expect(receiptPosts, 1);
      if (phase == 'replay_pending') expect(originalCompared, isTrue);
    } else if (phase == 'offline_expire_pause') {
      expect(view.entries.single.record.state, AccessEntryState.stored);
      expect(view.onlineConfirmed, isFalse);
      expect(calls, 0);
      clock = _deadline;
      view = await receiver.restore();
      expect(view.entries.single.record.state, AccessEntryState.expired);
      await expectLater(receiver.synchronize(), throwsA(anything));
      expect(interrupted, isTrue);
    } else if (phase == 'verify_checking_reject') {
      expect(view.entries.isEmpty && !view.contextReady, isTrue);
      final binding = jsonDecode((await bindings.read(_bindingKey))!) as Map;
      expect(binding['phase'], 'CHECKING');
      await expectLater(
          receiver.synchronize(),
          throwsA(isA<AccessTransportFailure>()
              .having((e) => e.status, 'status', 401)));
      view = await receiver.restore();
      expect(view.entries.isEmpty && !view.contextReady, isTrue);
      expect(calls, 1);
    } else if (phase == 'verify_blocked') {
      expect(view.entries.isEmpty && !view.contextReady, isTrue);
      expect((jsonDecode((await bindings.read(_bindingKey))!) as Map)['phase'],
          'BLOCKED');
      expect(calls, 0);
    } else if (phase == 'apply_removal') {
      expect(view.entries, isEmpty);
      view = await receiver.synchronize();
      expect(view.entries.single.record.state, AccessEntryState.removed);
      expect(view.pendingReceipts, 0);
    } else {
      expect(view.entries.single.record.state, AccessEntryState.removed);
      expect(view.entries.single.record.window.approvalVersion, 2);
      expect(view.pendingReceipts, 0);
      expect(calls, 0);
    }
    if (view.entries.isNotEmpty) {
      expect(view.entries.single.record.window.absoluteNotAfter, _deadline);
    }
    expect(view.systemEnforced, isFalse);
    await receiver.close();
    if (phase == 'cleanup') {
      // Exact synthetic scope only. Never clear app data or key preferences.
      expect(path.basename(dbFile.path), 'access-v1-${_scope.storageKey}.db');
      expect(await dbFile.parent.resolveSymbolicLinks(),
          await directory.resolveSymbolicLinks());
      await dbFile.delete();
      for (final name in [
        'access_key_v1_${_scope.storageKey}',
        'access_context_v1_$_bindingKey',
        'access_context_v1_$_oracleKey'
      ]) {
        await identity.storage.delete(key: name);
      }
      await identity
          .read(); // Same native durability barrier after exact deletes.
      expect(
          await bindings.read(_bindingKey) == null &&
              await bindings.read(_oracleKey) == null &&
              !await dbFile.exists(),
          isTrue);
      await expectLater(
          AndroidAccessKeyStore()
              .keyFor(_scope.storageKey, existingDatabase: true),
          throwsA(isA<AccessFailure>()));
    } else {
      final rawFile = await dbFile.readAsString();
      final key = await AndroidAccessKeyStore()
          .keyFor(_scope.storageKey, existingDatabase: true);
      final prefs = File(path.join(
          directory.parent.path, 'shared_prefs', 'aimanager_identity_v1.xml'));
      expect(await prefs.exists(), isTrue);
      final rawPrefs = await prefs.readAsString();
      for (final marker in [
        oracle['window'] as String,
        oracle['baseline'] as String,
        base64Encode(key),
        'UPSERT_ACCESS_WINDOW',
        'Native synthetic reading'
      ]) {
        expect(!rawFile.contains(marker) && !rawPrefs.contains(marker), isTrue,
            reason:
                'Fixture payload and data key must not appear in plaintext.');
      }
    }
    expect(await identity.read() == identityBefore, isTrue);
    expect(await observations.read() == observationBefore, isTrue);
    expect(await _digest(configFile) == configurationBefore, isTrue);
    debugPrint('ACCESS_STORAGE_RESULT ${jsonEncode({
          'phase': phase,
          'pid': pid,
          'pendingReceipts': view.pendingReceipts,
          'httpCalls': calls,
          'receiptPosts': receiptPosts,
          'originalReceiptCompared': originalCompared,
          'originalDeadlineUnchanged': true,
          'identityUnchanged': true,
          'observationUnchanged': true,
          'configurationUnchanged': true,
          'plaintextAbsent': phase != 'cleanup',
          'fixtureRemoved': phase == 'cleanup',
          'identityPresentBefore': identityBefore != null,
          'states': view.entries.map((e) => e.record.state.name).toList()
        })}');
  });
}
