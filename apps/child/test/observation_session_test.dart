import 'dart:convert';
import 'package:child/core/session.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_observation/device_observation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const tenant = '11111111-1111-1111-1111-111111111111';
const enrollment = '22222222-2222-2222-2222-222222222222';
const device = '33333333-3333-3333-3333-333333333333';
const registration = '44444444-4444-4444-4444-444444444444';
const now = 1800000000000;

class Secrets implements DeviceSecretStore {
  String? record;
  @override
  Future<String?> read() async => record;
  @override
  Future<void> write(String value) async => record = value;
}

class JournalStore implements ObservationStore {
  String? record;
  @override
  Future<String?> read() async => record;
  @override
  Future<void> write(String value) async => record = value;
}

class Source implements ObservationSource {
  int reads = 0, settingsOpened = 0;
  @override
  Future<ObservationPlatformState> inspect() async =>
      const ObservationPlatformState(
          usageGranted: true, unlocked: true, profile: 'PRIMARY');
  @override
  Future<List<Map<String, dynamic>>> inventory() async {
    reads++;
    return [];
  }

  @override
  Future<UsageSample> usage(
      {required int queryStart, required int queryEnd}) async {
    reads++;
    return UsageSample(
        queryStart: queryStart,
        queryEnd: queryEnd,
        observedAt: now,
        timeZone: 'UTC',
        profile: 'PRIMARY',
        applications: []);
  }

  @override
  Future<void> openUsageSettings() async => settingsOpened++;
}

class Api implements ObservationApi {
  int version = 1, uploads = 0;
  bool enabled = true, closed = false;
  @override
  Future<Map<String, dynamic>> settings() async => {
        'deviceId': device,
        'registrationId': registration,
        'version': version,
        'inventoryEnabled': enabled,
        'usageEnabled': enabled,
        'updatedAt': now
      };
  Map<String, dynamic> ack(Map<String, dynamic> body) {
    uploads++;
    return {
      'registrationId': registration,
      'sequence': body['sequence'],
      if (body.containsKey('reportId')) 'reportId': body['reportId'],
      'receivedAt': now
    };
  }

  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> body) async =>
      ack(body);
  @override
  Future<Map<String, dynamic>> usage(Map<String, dynamic> body) async =>
      ack(body);
  @override
  void close() => closed = true;
}

Future<void> waitIdle(ChildSession session) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await Future<void>.delayed(Duration.zero);
    if (!session.busy) return;
  }
  fail('Session did not become idle');
}

void main() {
  test('real session refreshes without collecting and only explicit sync reads',
      () async {
    final source = Source(), api = Api(), store = JournalStore();
    final client = MockClient((request) async {
      final claim = request.url.path.endsWith('enrollment-claims');
      return http.Response(
          jsonEncode(claim
              ? {
                  'deviceId': device,
                  'registrationId': registration,
                  'credential': 'b' * 43,
                  'expiresAt': now + 86400000,
                  'pairingCode': '12345678',
                  'confirmBefore': now + 600000,
                  'state': 'AWAITING_CONFIRMATION'
                }
              : {
                  'registrationId': registration,
                  'sequence': (jsonDecode(request.body) as Map)['sequence'],
                  'receivedAt': now
                }),
          claim ? 201 : 200,
          headers: {'content-type': 'application/json'});
    });
    final session = ChildSession(
        identity: DeviceIdentityManager(
            api: DeviceIdentityApi(
                apiRoot: Uri.parse('https://service.example/api/v1'),
                client: client),
            secrets: Secrets(),
            nowMillis: () => now),
        observationFactory: (identity) async {
          expect(identity.registrationId, registration);
          return ObservationAgent(
              scope: const ObservationScope(tenant, device, registration),
              store: store,
              api: api,
              source: source,
              nowMillis: () => now);
        });
    await session.initialize();
    await session.pair(
        jsonEncode({
          'tenantId': tenant,
          'id': enrollment,
          'token': 'a' * 43,
          'expiresAt': now + 600000
        }),
        displayName: '我的设备',
        osVersion: 'Android');
    expect(await session.checkConnection(), isTrue);
    await waitIdle(session);
    expect(session.observationView.onlineConfirmed, isTrue);
    expect(source.reads, 0, reason: '心跳后的自动刷新不能采集');
    expect(await session.synchronizeObservations(), isTrue);
    expect(source.reads, 2);
    expect(api.uploads, 2);
    expect(session.systemEnforced, isFalse);
    await session.setForeground(false);
    expect(await session.synchronizeObservations(), isFalse);
    expect(source.reads, 2);
    api
      ..version = 2
      ..enabled = false;
    await session.setForeground(true);
    await waitIdle(session);
    expect(session.observationView.authorization!.usageEnabled, isFalse);
    expect(session.observationView.lastUsageAt, isNull);
    expect(source.reads, 2, reason: '恢复前台只刷新授权');
    expect(await session.openObservationSettings(), isFalse);
    expect(session.observationErrorCode, 'OBSERVATION_NOT_AUTHORIZED');
    expect(session.errorCode, isNull, reason: '观察错误不能覆盖设备身份状态');
    expect(source.settingsOpened, 0);
    session.dispose();
    expect(api.closed, isTrue);
  });
}
