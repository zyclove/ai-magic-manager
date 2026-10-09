import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/observation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const tenant = '11111111-1111-1111-1111-111111111111';
const device = '22222222-2222-2222-2222-222222222222';
const registration = '33333333-3333-3333-3333-333333333333';
const now = 1791504000000;
Json settings({int version = 1, bool enabled = true}) => {
      'deviceId': device,
      'registrationId': registration,
      'version': version,
      'inventoryEnabled': enabled,
      'usageEnabled': enabled,
      'updatedAt': version == 0 ? null : now
    };
Json batch(int sequence) => {
      'registrationId': registration,
      'reportId': '44444444-4444-4444-4444-444444444444',
      'sequence': sequence,
      'authorizationVersion': 1,
      'profile': 'PRIMARY',
      'queryStart': now - 3600000,
      'queryEnd': now,
      'observedAt': now,
      'timeZone': 'Asia/Shanghai',
      'applications': [
        {
          'packageName': 'org.example.reader',
          'displayName': '阅读',
          'firstTimeStamp': now - 7200000,
          'lastTimeStamp': now,
          'foregroundMillis': 120000
        }
      ],
      'receivedAt': now,
      'precision': 'OS_AGGREGATE',
      'evidenceStatus': 'AGENT_REPORTED_UNVERIFIED'
    };

void main() {
  test(
      'authorization reasons allow readable multiline text but reject controls',
      () {
    expect(validObservationReason('说明用途\n已向儿童告知'), isTrue);
    expect(validObservationReason('  '), isFalse);
    expect(validObservationReason('说明\u0000'), isFalse);
    expect(validObservationReason('a' * 301), isFalse);
  });
  test('adult read and active write roles are explicit', () {
    for (final role in ['OWNER', 'GUARDIAN', 'ORG_ADMIN']) {
      expect(canReadObservation(role), isTrue);
    }
    expect(canReadObservation('TEACHER'), isFalse);
    expect(canReadObservation('AUDITOR'), isFalse);
    expect(canReadObservation('CHILD'), isFalse);
    expect(canReadObservation(''), isFalse);
    for (final role in ['OWNER', 'GUARDIAN', 'ORG_ADMIN']) {
      expect(canEditObservation(role, 'ACTIVE'), isTrue);
      expect(canEditObservation(role, 'REVOKED'), isFalse);
    }
    expect(canEditObservation('TEACHER', 'ACTIVE'), isFalse);
    expect(canEditObservation('AUDITOR', 'ACTIVE'), isFalse);
  });
  test('settings bind device registration and preserve default off', () {
    final value = ManagedObservationSettings.parse(
        settings(version: 0, enabled: false),
        deviceId: device,
        registrationId: registration);
    expect(value.version, 0);
    expect(value.usageEnabled, isFalse);
    for (final invalid in [
      {...settings(), 'registrationId': tenant},
      {...settings(), 'version': 1.0},
      {...settings(), 'version': 0},
      {...settings(), 'updatedAt': 9007199254740991},
    ]) {
      expect(
          () => ManagedObservationSettings.parse(invalid,
              deviceId: device, registrationId: registration),
          throwsA(isA<ApiFailure>()));
    }
  });
  test('batch keeps actual expanded intervals without summing durations', () {
    final value = ObservedUsageBatch.parse(batch(9), registration);
    expect(value.sequence, 9);
    expect(value.applications, hasLength(1));
    for (final invalid in [
      {...batch(9), 'registrationId': tenant},
      {...batch(9), 'precision': 'EXACT'},
      {...batch(9), 'applications': List.filled(501, {})},
      {
        ...batch(9),
        'applications': [
          ...batch(9)['applications'],
          ...batch(9)['applications']
        ]
      },
      {...batch(9), 'sequence': 9.0}
    ]) {
      expect(() => ObservedUsageBatch.parse(invalid, registration),
          throwsA(isA<ApiFailure>()));
    }
  });
  test('repository uses bounded paging and strong version/idempotency headers',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
          jsonEncode(request.method == 'PUT'
              ? settings(version: 2, enabled: false)
              : request.url.path.endsWith('usage-observations')
                  ? {
                      'items': [batch(9)],
                      'nextCursor': '9'
                    }
                  : settings()),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final repo = ObservationRepository(
        api: Api(() async => client, baseUrl: 'https://service.example/api/v1'),
        root: '/tenants/$tenant',
        deviceId: device,
        registrationId: registration,
        current: () => true);
    final snapshot = await repo.load();
    expect(snapshot.batches, hasLength(1));
    expect(requests[1].url.queryParameters, {'limit': '5'});
    await repo.update(
        snapshot.settings,
        {'inventoryEnabled': false, 'usageEnabled': false, 'reason': '  撤回  '},
        'k' * 48);
    expect(requests.last.headers['If-Match'], '"1"');
    expect(requests.last.headers['Idempotency-Key'], 'k' * 48);
    expect(jsonDecode(requests.last.body)['reason'], '撤回');
  });
  test('workspace changes and concurrent settings versions hide stale reports',
      () async {
    var current = true, version = 1, settingsReads = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('usage-observations')) {
        version = 2;
        return http.Response(
            jsonEncode({
              'items': [batch(8)],
              'nextCursor': null
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      settingsReads++;
      return http.Response(jsonEncode(settings(version: version)), 200);
    });
    final repo = ObservationRepository(
        api: Api(() async => client, baseUrl: 'https://service.example/api/v1'),
        root: '/tenants/$tenant',
        deviceId: device,
        registrationId: registration,
        current: () => current);
    await expectLater(repo.load(), throwsA(isA<ApiFailure>()));
    expect(settingsReads, 2, reason: '列表返回后重新核对当前授权');
    current = false;
    await expectLater(repo.load(), throwsA(isA<ApiFailure>()));
    expect(settingsReads, 2, reason: '工作区改变后不能再发请求');
  });
  test(
      'unknown write retries original version and rejects malformed acknowledgement',
      () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) return http.Response('{}', 503);
      return http.Response(jsonEncode(settings(version: 7)), 200);
    });
    final repo = ObservationRepository(
        api: Api(() async => client, baseUrl: 'https://service.example/api/v1'),
        root: '/tenants/$tenant',
        deviceId: device,
        registrationId: registration,
        current: () => true);
    final before = ManagedObservationSettings.parse(settings(),
        deviceId: device, registrationId: registration);
    final body = {
      'inventoryEnabled': true,
      'usageEnabled': true,
      'reason': '确认用途'
    };
    await expectLater(
        repo.update(before, body, 'x' * 48), throwsA(isA<ApiFailure>()));
    await expectLater(
        repo.update(before, body, 'x' * 48), throwsA(isA<ApiFailure>()));
  });
}
