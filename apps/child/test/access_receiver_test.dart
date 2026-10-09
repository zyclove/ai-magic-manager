import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:child/core/access.dart';
import 'package:child/core/access_receiver.dart';
import 'package:child/core/environment.dart';
import 'package:child/platform/access_database_io.dart';
import 'package:device_access/device_access.dart';
import 'package:device_policy/device_policy.dart' as policy;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../../../packages/device_access/test/fixtures.dart' as grants;
import '../../../packages/device_policy/test/fixtures.dart' as rules;
import 'support/identity_fixture.dart';

class BindingMemory implements ChildAccessBindingStore {
  final records = <String, String>{};
  bool failWrite = false;
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw const AccessFailure('ACCESS_STORAGE_FAILED');
    records[key] = value;
  }

  String? get phase => records.isEmpty
      ? null
      : (jsonDecode(records.values.single) as Map)['phase'];
}

void main() {
  late IdentityFixture identity;
  late Directory directory;
  late BindingMemory store;
  late http.Client client;
  late SignedAccessReceiver receiver;
  final key = grants.newKey('child-access-test');
  late Map<String, dynamic> payload;
  late List<policy.VerifiedConfiguration> baseline;
  bool offline = false, invalidDocument = false;
  int contextStatus = 200, listStatus = 200, calls = 0, baselineReads = 0;
  String boundSubject = grants.subject;
  Completer<void>? gate;
  final signatures = <String, String>{};
  Map<String, dynamic> context() => {
        'tenantId': IdentityFixture.tenant,
        'subjectId': boundSubject,
        'deviceId': IdentityFixture.device,
        'registrationId': IdentityFixture.registration
      };
  Future<policy.VerifiedConfiguration> base(
      [Map<String, dynamic> changes = const {}]) async {
    final body = rules.envelope({
      'tenantId': IdentityFixture.tenant,
      'deviceId': IdentityFixture.device,
      'registrationId': IdentityFixture.registration,
      'issuedAt': IdentityFixture.now - 1000,
      'deliveryExpiresAt': IdentityFixture.now + 300000,
      'document': {
        'name': '学习规则',
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
            'displayName': '合成阅读应用',
            'packageName': 'org.example.reading',
            'platform': 'ANDROID',
            'profile': 'PRIMARY'
          }
        ],
        'schedules': [],
        'protectedPackageExemptions': []
      },
      ...changes
    });
    return policy.ConfigurationVerifier(
            scope: const policy.DevicePolicyScope(
                issuer: 'ai-manager',
                tenantId: IdentityFixture.tenant,
                deviceId: IdentityFixture.device,
                registrationId: IdentityFixture.registration),
            trustedKeys: grants.publicRing(key),
            nowMillis: () => identity.clock)
        .verify(rules.sign(key, body), restoration: true);
  }

  Future<SignedAccessReceiver> create() async => SignedAccessReceiver(
      environment: ChildEnvironment(
          apiRoot: Uri.parse('https://service.example/api/v1'),
          configurationIssuer: 'ai-manager',
          configurationKeys: grants.publicRing(key)),
      identity: await identity.identity.view(),
      credential: identity.identity.activeCredential,
      readBaseline: () async {
        baselineReads++;
        return baseline;
      },
      nowMillis: () => identity.clock,
      bindingStore: store,
      databaseOpener: (scope) => openAccessDatabase(scope,
          directoryPath: directory.path,
          keyProvider: (_, {required existingDatabase}) async =>
              Uint8List.fromList(List.generate(32, (i) => i))),
      transportFactory: () => DeviceAccessTransport(
          apiRoot: Uri.parse('https://service.example/api/v1'),
          credential: identity.identity.activeCredential,
          client: client));
  setUp(() async {
    identity = IdentityFixture();
    await identity.activate();
    directory = await Directory.systemTemp.createTemp('child-access-receiver-');
    store = BindingMemory();
    offline = false;
    invalidDocument = false;
    contextStatus = 200;
    listStatus = 200;
    calls = 0;
    baselineReads = 0;
    boundSubject = grants.subject;
    gate = null;
    signatures.clear();
    payload = grants.envelope({
      'tenantId': IdentityFixture.tenant,
      'deviceId': IdentityFixture.device,
      'registrationId': IdentityFixture.registration,
      'grantIssuedAt': IdentityFixture.now - 1000,
      'documentIssuedAt': IdentityFixture.now - 500,
      'absoluteNotAfter': IdentityFixture.now + 60000
    });
    baseline = [await base()];
    client = MockClient((request) async {
      calls++;
      expect(request.headers['authorization'], 'Bearer ${'b' * 43}');
      expect(store.phase, 'CHECKING',
          reason: 'Durable intent must precede all access HTTP');
      if (offline) throw http.ClientException('Synthetic network loss');
      Map<String, dynamic> body;
      var status = 200;
      if (request.url.path.endsWith('/access-context')) {
        body = context();
        status = contextStatus;
      } else if (request.url.path.endsWith('/access-requests')) {
        status = listStatus;
        body = {
          'items': [
            {
              'requestId': payload['requestId'],
              'approvalVersion': payload['approvalVersion'],
              'approvalState': payload['approvalState'],
              'absoluteNotAfter': payload['absoluteNotAfter']
            }
          ],
          'nextCursor': null
        };
      } else if (request.method == 'GET') {
        if (gate != null) await gate!.future;
        final signed = signatures.putIfAbsent(
            '${jsonEncode(payload)}:$invalidDocument',
            () => grants.sign(
                invalidDocument ? grants.newKey('different') : key, payload));
        body = {
          'documentId': payload['documentId'],
          'requestId': payload['requestId'],
          'approvalVersion': payload['approvalVersion'],
          'action': payload['action'],
          'signedDocument': signed,
          'documentIssuedAt': payload['documentIssuedAt'],
          'deliveryAttempt': 1,
          'deliveryState': 'SIGNED',
          'retryStatus': 'NOT_NEEDED'
        };
      } else {
        final input = jsonDecode(request.body) as Map;
        body = {
          'documentId': input['documentId'],
          'approvalVersion': payload['approvalVersion'],
          'deliveryAttempt': input['deliveryAttempt'],
          'phase': input['phase'],
          'receivedAt': identity.clock,
          'current': true,
          'evidenceStatus': 'DEVICE_REPORT_UNVERIFIED',
          'executionState': 'NOT_ENFORCED'
        };
      }
      if (status != 200) {
        body = {
          'errorCode': status == 401 ? 'DEVICE_UNAUTHENTICATED' : 'SCOPE_DENIED'
        };
      }
      return http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});
    });
    receiver = await create();
  });
  tearDown(() async {
    if (gate != null && !gate!.isCompleted) gate!.complete();
    await receiver.close();
    client.close();
    identity.close();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    final actual = await directory.resolveSymbolicLinks();
    if (!actual.toLowerCase().startsWith(
        '$temp${Platform.pathSeparator}child-access-receiver-'.toLowerCase())) {
      throw StateError('Invalid fixture directory');
    }
    await Directory(actual).delete(recursive: true);
  });
  test(
      'signed receiver binds context, persists encrypted state and expires offline after restart',
      () async {
    expect((await receiver.restore()).contextReady, isFalse);
    var view = await receiver.synchronize();
    expect(view.entries.single.record.state, AccessEntryState.stored);
    expect(view.entries.single.applicationName, '合成阅读应用');
    expect(view.onlineConfirmed, isTrue);
    expect(view.pendingReceipts, 0);
    expect(view.systemEnforced, isFalse);
    expect(store.phase, 'VALID');
    expect(baselineReads, greaterThan(0));
    await receiver.close();
    receiver = await create();
    offline = true;
    final before = calls;
    view = await receiver.restore();
    expect(view.entries.single.record.state, AccessEntryState.stored);
    expect(view.onlineConfirmed, isFalse);
    expect(calls, before);
    await expectLater(
        receiver.synchronize(), throwsA(isA<AccessTransportFailure>()));
    expect(store.phase, 'VALID');
    expect((await receiver.restore()).entries.length, 1);
    identity.clock = IdentityFixture.now + 60000;
    expect((await receiver.restore()).entries.single.record.state,
        AccessEntryState.expired);
  });
  test(
      'explicit refusal stays blocked after restart and cannot restore old windows offline',
      () async {
    await receiver.synchronize();
    listStatus = 401;
    await expectLater(
        receiver.synchronize(), throwsA(isA<AccessTransportFailure>()));
    expect(store.phase, 'BLOCKED');
    await receiver.close();
    receiver = await create();
    offline = true;
    expect((await receiver.restore()).entries, isEmpty);
    await expectLater(
        receiver.synchronize(), throwsA(isA<AccessTransportFailure>()));
    expect((await receiver.restore()).contextReady, isFalse);
  });
  test('context cannot silently rebind subject or read another scope database',
      () async {
    await receiver.synchronize();
    boundSubject = grants.tenant;
    await expectLater(receiver.synchronize(), throwsA(isA<AccessFailure>()));
    expect(store.phase, 'BLOCKED');
    expect((await receiver.restore()).entries, isEmpty);
  });
  test(
      'bad current document keeps old request under review across restart, successful observation clears it',
      () async {
    await receiver.synchronize();
    payload = {...payload, 'approvalVersion': 2, 'documentId': grants.policy};
    invalidDocument = true;
    var view = await receiver.synchronize();
    expect(view.entries.single.requiresReview, isTrue);
    await receiver.close();
    receiver = await create();
    expect((await receiver.restore()).entries.single.requiresReview, isTrue);
    invalidDocument = false;
    view = await receiver.synchronize();
    expect(view.entries.single.requiresReview, isFalse);
    expect(view.entries.single.record.window.approvalVersion, 2);
  });
  test('missing exact baseline rejects only configuration and records a reason',
      () async {
    baseline = [
      await base({'versionId': grants.application})
    ];
    final view = await receiver.synchronize();
    expect(view.entries.single.record.state, AccessEntryState.rejected);
    expect(view.entries.single.record.reasonCode, 'BASELINE_MISSING');
    expect(view.systemEnforced, isFalse);
  });
  test('ambiguous malformed compiled source IDs cannot be ignored', () async {
    final document = Map<String, dynamic>.from(baseline.single.document!);
    final rule = Map<String, dynamic>.from((document['rules'] as List).single);
    document['rules'] = [
      rule,
      {
        ...rule,
        'sourceRuleIds': ['game', 'game']
      }
    ];
    baseline = [
      await base({'document': document})
    ];
    final view = await receiver.synchronize();
    expect(view.entries.single.record.state, AccessEntryState.rejected);
    expect(view.entries.single.record.reasonCode, 'BASELINE_MISSING');
  });
  test(
      'pause cancels in-flight work and leaves durable checking instead of reviving cache',
      () async {
    await receiver.synchronize();
    gate = Completer<void>();
    final running = receiver.synchronize();
    while (calls < 7) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    receiver.pause();
    await expectLater(running, throwsA(anything));
    expect(store.phase, 'CHECKING');
    gate!.complete();
    gate = null;
    receiver.resume();
    await receiver.synchronize();
    expect(store.phase, 'VALID');
  });
  test(
      'failed checking write prevents any HTTP and does not fabricate a context',
      () async {
    store.failWrite = true;
    await expectLater(receiver.synchronize(), throwsA(isA<AccessFailure>()));
    expect(calls, 0);
    expect((await receiver.restore()).entries, isEmpty);
  });
  test('baseline objects cannot bypass raw signature verification', () async {
    baseline = [
      policy.VerifiedConfiguration.internal(
          'invalid-raw-configuration', baseline.single.fields)
    ];
    await expectLater(
        receiver.synchronize(), throwsA(isA<policy.ConfigurationFailure>()));
    expect(store.phase, 'CHECKING');
    expect((await receiver.restore()).entries, isEmpty);
  });
  test('corrupt cached context and clock rollback never get silently repaired',
      () async {
    await receiver.synchronize();
    identity.clock = IdentityFixture.now - 2000;
    final original = Map<String, String>.from(store.records);
    await expectLater(receiver.restore(), throwsA(isA<AccessFailure>()));
    expect(store.records, original);
    identity.clock = IdentityFixture.now;
    store.records[store.records.keys.single] = 'broken';
    final before = calls;
    await expectLater(receiver.synchronize(), throwsA(isA<AccessFailure>()));
    expect(calls, before);
    expect(store.records.values.single, 'broken');
  });
}
