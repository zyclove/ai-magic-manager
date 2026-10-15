import 'dart:convert';
import 'package:device_identity/device_identity.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';
import 'package:test/test.dart';

const bindingNow = 1792080000000;
const challengeId = '77777777-7777-4777-8777-777777777777';
const bindingAudience = 'ai-manager:managed-agent-binding';
final nonce = base64Url.encode(List.filled(32, 0)).replaceAll('=', '');

class BindingSecrets implements DeviceSecretStore {
  String? record;
  @override
  Future<String?> read() async => record;
  @override
  Future<void> write(String value) async => record = value;
}

class HookBindingKeys extends JoseDeviceEnrollmentKeys {
  final Future<void> Function() afterSigning;
  const HookBindingKeys(this.afterSigning);
  @override
  Future<ManagedAgentBindingProof> managedBindingProof(
      String handle, ManagedAgentChallenge challenge, int nowMillis) async {
    final proof = await super.managedBindingProof(handle, challenge, nowMillis);
    await afterSigning();
    return proof;
  }
}

Map<String, dynamic> bindingChallenge() => {
      'challengeId': challengeId,
      'nonce': nonce,
      'audience': bindingAudience,
      'createdAt': bindingNow - 1000,
      'expiresAt': bindingNow + 599000,
    };

void main() {
  late BindingSecrets secrets;
  late DeviceIdentityManager manager;
  late DeviceIdentityApi api;
  late String handle;
  late int now, status;
  late Object? response;
  Future<void> Function()? responding;
  final requests = <http.Request>[];
  setUp(() async {
    now = bindingNow;
    status = 200;
    response = bindingChallenge();
    responding = null;
    requests.clear();
    handle = await const JoseDeviceEnrollmentKeys().generateHandle();
    secrets = BindingSecrets()
      ..record = jsonEncode({
        'schemaVersion': 1,
        'kind': 'DEVICE_IDENTITY',
        'apiRoot': 'https://device.example/api/v1',
        'tenantId': '11111111-1111-4111-8111-111111111111',
        'enrollmentId': '22222222-2222-4222-8222-222222222222',
        'deviceId': '33333333-3333-4333-8333-333333333333',
        'registrationId': '44444444-4444-4444-8444-444444444444',
        'keyHandle': handle,
        'displayName': '儿童设备',
        'osVersion': '14',
        'observedAt': now,
        'ticketExpiresAt': now + 600000,
        'heartbeatSequence': 1,
        'phase': 'active',
        'credential': 'A' * 43,
        'credentialExpiresAt': now + 3600000,
      });
    api = DeviceIdentityApi(
        apiRoot: Uri.parse('https://device.example/api/v1'),
        client: MockClient((request) async {
          requests.add(request);
          await responding?.call();
          return http.Response(
              status == 204 ? '' : jsonEncode(response), status,
              headers: {'content-type': 'application/json'});
        }));
    manager =
        DeviceIdentityManager(api: api, secrets: secrets, nowMillis: () => now);
  });
  tearDown(() => api.close());

  test(
      'active original key signs minimal proof from authenticated GET challenge',
      () async {
    final proof = (await manager.managedAgentBindingProof())!;
    expect(requests.single.method, 'GET');
    expect(
        requests.single.url.path, '/api/v1/device-api/managed-agent-challenge');
    expect(requests.single.body, isEmpty);
    expect(requests.single.headers['Authorization'], 'Bearer ${'A' * 43}');
    final compact = proof.compact;
    expect(compact.length, lessThanOrEqualTo(1000));
    final parts = compact.split('.');
    Map<String, dynamic> decode(String value) =>
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(value))));
    expect(decode(parts[0]), {'alg': 'ES256', 'typ': 'JWT'});
    final payload = decode(parts[1]);
    expect(payload.keys.toSet(), {'sub', 'nonce', 'aud', 'iat', 'exp', 'jti'});
    expect(payload['sub'], challengeId);
    expect(payload['nonce'], nonce);
    expect(payload['aud'], [bindingAudience]);
    expect(payload['iat'], now ~/ 1000);
    expect(payload['exp'], (bindingNow + 599000) ~/ 1000);
    final keys = JsonWebKeyStore()
      ..addKey(JsonWebKey.fromJson(jsonDecode(handle)));
    expect(
        await JsonWebSignature.fromCompactSerialization(compact).verify(keys),
        isTrue);
    expect(proof.toString(), isNot(contains(nonce)));
    expect(secrets.record, isNot(contains(challengeId)));
  });
  test('204 means no challenge and no proof', () async {
    status = 204;
    expect(await manager.managedAgentBindingProof(), isNull);
    expect(requests, hasLength(1));
  });
  Matcher failure(String code) =>
      isA<DeviceIdentityFailure>().having((e) => e.code, 'code', code);
  void mutate(String field, Object? value) {
    final record = jsonDecode(secrets.record!);
    record[field] = value;
    secrets.record = jsonEncode(record);
  }

  for (final mutation in <String, void Function(Map<String, dynamic>)>{
    'wrong audience': (v) => v['audience'] = 'ai-manager:cleanup',
    'stable identity field': (v) => v['deviceId'] = 'private',
    'missing nonce': (v) => v.remove('nonce'),
    'noncanonical nonce': (v) => v['nonce'] = '${'A' * 42}B',
    'wrong UUID version': (v) =>
        v['challengeId'] = '77777777-7777-1777-8777-777777777777',
    'fractional time': (v) => v['createdAt'] = bindingNow - 0.5,
    'unsafe time': (v) => v['expiresAt'] = 9007199254740992,
    'excess lifetime': (v) => v['expiresAt'] = bindingNow + 600000,
    'negative creation': (v) => v['createdAt'] = -1,
  }.entries) {
    test('rejects ${mutation.key}', () async {
      final value = bindingChallenge();
      mutation.value(value);
      response = value;
      await expectLater(manager.managedAgentBindingProof(),
          throwsA(failure('MANAGED_CHALLENGE_INVALID')));
    });
  }
  test('expired challenge cannot be signed', () async {
    response = bindingChallenge()
      ..['createdAt'] = bindingNow - 600000
      ..['expiresAt'] = bindingNow;
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('MANAGED_CHALLENGE_EXPIRED')));
  });
  test('server clock too far ahead stops signing', () async {
    response = bindingChallenge()..['createdAt'] = bindingNow + 30001;
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('CLOCK_UNTRUSTED')));
  });
  test('empty 200 is invalid, not a no-challenge response', () async {
    response = <String, dynamic>{};
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('RESPONSE_INVALID')));
  });
  test('blocked identity never polls or signs', () async {
    mutate('authenticationBlocked', true);
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('DEVICE_CREDENTIAL_UNAVAILABLE')));
    expect(requests, isEmpty);
  });
  test('expired credential never polls', () async {
    mutate('credentialExpiresAt', bindingNow);
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('DEVICE_CREDENTIAL_UNAVAILABLE')));
    expect(requests, isEmpty);
  });
  test('confirmed old credential during requested rotation can sign', () async {
    mutate('phase', 'rotationRequested');
    // A confirmed old credential during rotation remains usable.
    expect(await manager.managedAgentBindingProof(), isNotNull);
  });
  test('uncertain activation never polls', () async {
    mutate('phase', 'activationUncertain');
    mutate('pendingCredential', {
      'credentialId': '55555555-5555-4555-8555-555555555555',
      'credential': 'B' * 43,
      'expiresAt': now + 7200000,
      'activateBefore': now + 300000,
    });
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('IDENTITY_PHASE_CONFLICT')));
    expect(requests, isEmpty);
  });
  test('HTTP refusal blocks identity without leaking raw server text',
      () async {
    status = 401;
    response = {'errorCode': 'PRIVATE_BACKEND_ERROR'};
    await expectLater(
        manager.managedAgentBindingProof(), throwsA(failure('HTTP_FAILURE')));
    expect(await manager.activeCredential(), isNull);
  });
  test('identity mutation during challenge HTTP prevents releasing feedback',
      () async {
    responding = () async => mutate('credential', 'B' * 43);
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('IDENTITY_STATE_CONFLICT')));
    expect(jsonDecode(secrets.record!)['credential'], 'B' * 43);
  });
  test('deadline is rechecked after HTTP', () async {
    responding = () async {
      now = bindingNow + 599000;
    };
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('MANAGED_CHALLENGE_EXPIRED')));
  });
  test('legacy JOSE never changes the registered key', () async {
    final original = jsonDecode(secrets.record!)['keyHandle'];
    await manager.managedAgentBindingProof();
    expect(jsonDecode(secrets.record!)['keyHandle'], original);
  });
  test('signing completion after expiry cannot release proof', () async {
    manager = DeviceIdentityManager(
        api: api,
        secrets: secrets,
        nowMillis: () => now,
        keys: HookBindingKeys(() async {
          now += 600000;
        }));
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('MANAGED_CHALLENGE_EXPIRED')));
  });
  test('identity deletion during signing cannot release proof', () async {
    manager = DeviceIdentityManager(
        api: api,
        secrets: secrets,
        nowMillis: () => now,
        keys: HookBindingKeys(() async {
          secrets.record = null;
        }));
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('IDENTITY_NOT_FOUND')));
  });
  test('key provider causes are never exposed', () async {
    manager = DeviceIdentityManager(
        api: api,
        secrets: secrets,
        nowMillis: () => now,
        keys: HookBindingKeys(() async {
          throw StateError('RAW_PRIVATE_MATERIAL');
        }));
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('DEVICE_KEY_UNAVAILABLE')));
  });
  test('a rollback during signing is refused even above stored time floor',
      () async {
    now += 10000;
    manager = DeviceIdentityManager(
        api: api,
        secrets: secrets,
        nowMillis: () => now,
        keys: HookBindingKeys(() async {
          now -= 5000;
        }));
    await expectLater(manager.managedAgentBindingProof(),
        throwsA(failure('CLOCK_UNTRUSTED')));
  });
}
