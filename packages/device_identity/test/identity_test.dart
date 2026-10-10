import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:device_identity/device_identity.dart';
import 'package:jose/jose.dart';
import 'package:test/test.dart';

const tenant = '11111111-1111-4111-8111-111111111111';
const enrollment = '22222222-2222-4222-8222-222222222222';
const device = '33333333-3333-4333-8333-333333333333';
const registration = '44444444-4444-4444-8444-444444444444';
const credentialId = '55555555-5555-4555-8555-555555555555';
const time = 1791528000000;
final ticketToken = 'T' * 43, initialToken = 'A' * 43, nextToken = 'B' * 43;

// Explicit secure-storage substitute: never a production plaintext adapter.
class TestSecrets implements DeviceSecretStore {
  String? value;
  bool failWrites = false;
  int writes = 0;
  int? failAt;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String record) async {
    writes++;
    if (failWrites || writes == failAt) throw StateError('SENSITIVE SDK CAUSE');
    value = record;
  }
}

Matcher failure(String code) =>
    isA<DeviceIdentityFailure>().having((e) => e.code, 'code', code);

class BrokenKeys implements DeviceEnrollmentKeys {
  @override
  Future<String> generateHandle() async =>
      throw StateError('UNTRUSTED_KEY_PROVIDER_CAUSE');
  @override
  Future<EnrollmentProof> proof(String handle, String enrollmentId,
          String token, String purpose, int nowMillis) async =>
      throw StateError('UNTRUSTED_KEY_PROVIDER_CAUSE');
}

void main() {
  late HttpServer server;
  late DeviceIdentityApi api;
  late DeviceIdentityManager manager;
  late TestSecrets secrets;
  late EnrollmentTicket ticket;
  late Future<void> Function(HttpRequest) respond;
  late int now;
  final requests = <Map<String, dynamic>>[];
  final auth = <String?>[], paths = <String>[];
  Future<void> json(HttpRequest r, Object value, [int status = 200]) async {
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(value));
    await r.response.close();
  }

  Map<String, dynamic> claimed([String secret = '']) => {
        'deviceId': device,
        'registrationId': registration,
        'credential': secret.isEmpty ? initialToken : secret,
        'expiresAt': time + 3600000,
        'pairingCode': 'ABCD1234',
        'confirmBefore': time + 600000,
        'state': 'AWAITING_CONFIRMATION'
      };
  Future<void> normal(HttpRequest r) async {
    final body = Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(r).join()));
    requests.add(body);
    auth.add(r.headers.value('authorization'));
    paths.add(r.uri.path);
    if (r.uri.path.endsWith('/enrollment-claims')) {
      await json(r, claimed(), 201);
    } else if (r.uri.path.endsWith('/recover')) {
      await json(r, claimed(nextToken));
    } else if (r.uri.path.endsWith('/heartbeats')) {
      await json(r, {
        'registrationId': registration,
        'sequence': body['sequence'],
        'receivedAt': now
      });
    } else if (r.uri.path.endsWith('/rotate')) {
      await json(r, {
        'credentialId': credentialId,
        'credential': nextToken,
        'expiresAt': time + 7200000,
        'activateBefore': time + 300000
      });
    } else {
      r.response.statusCode = 204;
      await r.response.close();
    }
  }

  Future<void> begin() =>
      manager.begin(ticket, displayName: '儿童设备', osVersion: '14');
  Future<void> activate() async {
    await begin();
    await manager.heartbeat(agentVersion: '1.0', capabilities: []);
  }

  DeviceIdentityManager recreated() =>
      DeviceIdentityManager(api: api, secrets: secrets, nowMillis: () => now);
  test(
      'matching external credential rejection is durable and makes no HTTP request',
      () async {
    await activate();
    final scope = await manager.view(), calls = requests.length;
    expect(
        await manager.recordCredentialRejection(
            scope: scope, rejectedCredential: initialToken),
        isTrue);
    expect(requests.length, calls);
    expect(await manager.activeCredential(), isNull);
    expect((await recreated().view()).cloudAuthenticationBlocked, isTrue);
    expect(await recreated().activeCredential(), isNull);
    final writes = secrets.writes;
    expect(
        await manager.recordCredentialRejection(
            scope: scope, rejectedCredential: initialToken),
        isTrue);
    expect(secrets.writes, writes,
        reason: 'Repeated refusal is a read-only replay.');
  });
  test('late refusal for old rotated credential cannot block its replacement',
      () async {
    await activate();
    final oldScope = await manager.view();
    await manager.rotate();
    await manager.activateRotation();
    final record = secrets.value, writes = secrets.writes;
    expect(
        await manager.recordCredentialRejection(
            scope: oldScope, rejectedCredential: initialToken),
        isFalse);
    expect(await manager.activeCredential(), nextToken);
    expect(secrets.value, record);
    expect(secrets.writes, writes);
  });
  test('refusal for another registration is ignored without writes', () async {
    await activate();
    final scope = await manager.view();
    final other = DeviceIdentityView(
        phase: scope.phase,
        tenantId: scope.tenantId,
        deviceId: scope.deviceId,
        registrationId: enrollment,
        heartbeatSequence: scope.heartbeatSequence,
        heartbeatPending: scope.heartbeatPending,
        cloudAuthenticationBlocked: false);
    final writes = secrets.writes;
    expect(
        await manager.recordCredentialRejection(
            scope: other, rejectedCredential: initialToken),
        isFalse);
    expect(await manager.activeCredential(), initialToken);
    expect(secrets.writes, writes);
  });
  test(
      'awaiting-confirmation rejection cannot turn expected waiting into revocation',
      () async {
    await begin();
    final scope = await manager.view(), writes = secrets.writes;
    expect(
        await manager.recordCredentialRejection(
            scope: scope, rejectedCredential: initialToken),
        isFalse);
    expect((await manager.view()).cloudAuthenticationBlocked, isFalse);
    expect(secrets.writes, writes);
  });
  test(
      'external rejection storage failure is fixed-code and cannot reset identity',
      () async {
    await activate();
    final scope = await manager.view(), original = secrets.value;
    secrets.failWrites = true;
    await expectLater(
        manager.recordCredentialRejection(
            scope: scope, rejectedCredential: initialToken),
        throwsA(failure('SECURE_STORAGE_FAILED')));
    expect(secrets.value, original);
  });
  test('only a fresh authenticated heartbeat can recover a persisted rejection',
      () async {
    await activate();
    final scope = await manager.view();
    await manager.recordCredentialRejection(
        scope: scope, rejectedCredential: initialToken);
    expect(await recreated().activeCredential(), isNull);
    await manager.heartbeat(agentVersion: 'test', capabilities: []);
    expect(await recreated().activeCredential(), initialToken);
    expect((await manager.view()).cloudAuthenticationBlocked, isFalse);
  });
  setUp(() async {
    now = time;
    requests.clear();
    auth.clear();
    paths.clear();
    secrets = TestSecrets();
    server = await HttpServer.bind('127.0.0.1', 0);
    api = DeviceIdentityApi(
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        allowLoopbackHttp: true,
        timeout: const Duration(seconds: 10));
    ticket = EnrollmentTicket(
        tenantId: tenant,
        enrollmentId: enrollment,
        token: ticketToken,
        expiresAt: time + 900000);
    respond = normal;
    server.listen((r) async {
      try {
        await respond(r);
      } catch (_) {
        await r.response.close();
      }
    });
    manager = recreated();
  });
  tearDown(() async {
    api.close();
    await server.close(force: true);
  });

  test(
      'claim uses real ES256 proof, private key saved before send and public-only JWK',
      () async {
    respond = (r) async {
      expect(secrets.value, isNotNull);
      await normal(r);
    };
    await begin();
    final body = requests.single;
    final public = Map<String, dynamic>.from(jsonDecode(body['publicKeyJwk']));
    expect(public.containsKey('d'), isFalse);
    final proof = JsonWebSignature.fromCompactSerialization(body['proof']);
    final keys = JsonWebKeyStore()..addKey(JsonWebKey.fromJson(public));
    expect(await proof.verify(keys), isTrue);
    final claims = jsonDecode(proof.unverifiedPayload.stringContent);
    expect(claims['sub'], enrollment);
    expect(claims['aud'], ['ai-manager:enrollment-claim']);
    expect(claims['nonce'], ticketToken);
    expect(claims['exp'] - claims['iat'], 60);
    expect(auth.single, isNull);
    expect((await manager.view()).phase, IdentityPhase.awaitingConfirmation);
    expect(await manager.activeCredential(), isNull);
    expect(await manager.pairingCode(), 'ABCD1234');
  });
  test('secret write failure prevents network and sanitizes underlying cause',
      () async {
    secrets.failWrites = true;
    await expectLater(begin(), throwsA(failure('SECURE_STORAGE_FAILED')));
    expect(requests, isEmpty);
  });
  test('external key-provider errors are sanitized before leaving manager',
      () async {
    manager = DeviceIdentityManager(
        api: api, secrets: secrets, nowMillis: () => now, keys: BrokenKeys());
    await expectLater(begin(), throwsA(failure('DEVICE_KEY_UNAVAILABLE')));
    expect(requests, isEmpty);
  });
  test('existing identity cannot be overwritten by another begin', () async {
    await begin();
    final original = secrets.value;
    await expectLater(begin(), throwsA(failure('IDENTITY_ALREADY_EXISTS')));
    expect(secrets.value == original, isTrue);
    expect(requests, hasLength(1));
  });
  test(
      'lost claim response restores same key and uses fresh recovery purpose/jti',
      () async {
    respond = (r) async {
      if (r.uri.path.endsWith('/enrollment-claims')) {
        requests.add(Map<String, dynamic>.from(
            jsonDecode(await utf8.decoder.bind(r).join())));
        // Drop the acknowledgement after actually receiving the complete claim.
        final socket = await r.response.detachSocket(writeHeaders: false);
        socket.destroy();
      } else {
        await normal(r);
      }
    };
    await expectLater(
        begin(),
        throwsA(isA<DeviceIdentityFailure>()
            .having((e) => e.outcomeUnknown, 'outcomeUnknown', true)));
    manager = recreated();
    expect((await manager.view()).phase, IdentityPhase.claimUncertain);
    await manager.recoverClaim();
    expect(requests.first['publicKeyJwk'], requests.last['publicKeyJwk']);
    final a = jsonDecode(
        JsonWebSignature.fromCompactSerialization(requests.first['proof'])
            .unverifiedPayload
            .stringContent);
    final b = jsonDecode(
        JsonWebSignature.fromCompactSerialization(requests.last['proof'])
            .unverifiedPayload
            .stringContent);
    expect(b['aud'], ['ai-manager:enrollment-recover']);
    expect(b['jti'], isNot(a['jti']));
    expect((await manager.view()).phase, IdentityPhase.awaitingConfirmation);
  });
  test('unconfirmed 401 preserves pairing state without claiming activation',
      () async {
    await begin();
    respond = (r) => json(r, {'errorCode': 'DEVICE_UNAUTHENTICATED'}, 401);
    await expectLater(manager.heartbeat(agentVersion: '1.0', capabilities: []),
        throwsA(failure('DEVICE_UNAUTHENTICATED')));
    expect((await manager.view()).phase, IdentityPhase.awaitingConfirmation);
    expect(await manager.activeCredential(), isNull);
    expect(await manager.pairingCode(), 'ABCD1234');
  });
  test(
      'active authentication failure pauses cloud credentials without deleting identity',
      () async {
    await activate();
    respond = (r) => json(r, {'errorCode': 'DEVICE_UNAUTHENTICATED'}, 401);
    await expectLater(manager.heartbeat(agentVersion: '1', capabilities: []),
        throwsA(failure('DEVICE_UNAUTHENTICATED')));
    manager = recreated();
    expect((await manager.view()).cloudAuthenticationBlocked, isTrue);
    expect((await manager.view()).heartbeatPending, isTrue);
    expect(await manager.activeCredential(), isNull);
    respond = normal;
    await manager.heartbeat(agentVersion: '1', capabilities: []);
    expect((await manager.view()).cloudAuthenticationBlocked, isFalse);
    expect(await manager.activeCredential(), initialToken);
  });
  test(
      'successful bound heartbeat activates locally and erases enrollment secrets',
      () async {
    await activate();
    expect((await manager.view()).phase, IdentityPhase.active);
    expect(await manager.activeCredential(), initialToken);
    expect(await manager.pairingCode(), isNull);
    expect(secrets.value!.contains(ticketToken), isFalse);
    expect(secrets.value!.contains('ABCD1234'), isFalse);
    expect((await manager.view()).systemEnforced, isFalse);
  });
  test('unknown heartbeat response replays exactly persisted sequence and body',
      () async {
    await activate();
    bool lose = true;
    respond = (r) async {
      if (lose) {
        requests.add(Map<String, dynamic>.from(
            jsonDecode(await utf8.decoder.bind(r).join())));
        r.response.statusCode = 503;
        await r.response.close();
      } else {
        await normal(r);
      }
    };
    await expectLater(manager.heartbeat(agentVersion: '1.1', capabilities: []),
        throwsA(failure('HTTP_FAILURE')));
    final original = requests.last;
    manager = recreated();
    lose = false;
    final ack = await manager.heartbeat(agentVersion: '2.0', capabilities: []);
    expect(ack.replayed, isTrue);
    expect(requests.last, original);
    await manager.heartbeat(agentVersion: '2.0', capabilities: []);
    expect(requests.last['sequence'], 3);
    expect(requests.last['agentVersion'], '2.0');
  });
  test('foreign registration ACK cannot activate or clear pending heartbeat',
      () async {
    await begin();
    respond = (r) =>
        json(r, {'registrationId': device, 'sequence': 1, 'receivedAt': now});
    await expectLater(manager.heartbeat(agentVersion: '1.0', capabilities: []),
        throwsA(failure('RESPONSE_INVALID')));
    expect((await manager.view()).phase, IdentityPhase.awaitingConfirmation);
    expect((await manager.view()).heartbeatPending, isTrue);
  });
  test(
      'rotation persists pending before activation and exposes only old active',
      () async {
    await activate();
    await manager.rotate();
    expect((await manager.view()).phase, IdentityPhase.rotationPending);
    expect(await manager.activeCredential(), initialToken);
    manager = recreated();
    await manager.activateRotation();
    expect(auth.last, 'Bearer $nextToken');
    expect(await manager.activeCredential(), nextToken);
    expect(secrets.value!.contains(initialToken), isFalse);
  });
  test(
      'lost activation ACK survives recreation and retries new credential even after deadline',
      () async {
    await activate();
    await manager.rotate();
    bool lose = true;
    respond = (r) async {
      if (r.uri.path.endsWith('/activate') && lose) {
        await r.drain();
        r.response.statusCode = 503;
        await r.response.close();
      } else {
        await normal(r);
      }
    };
    await expectLater(
        manager.activateRotation(), throwsA(failure('HTTP_FAILURE')));
    expect((await manager.view()).phase, IdentityPhase.activationUncertain);
    expect(await manager.activeCredential(), isNull);
    now += 400000;
    manager = recreated();
    lose = false;
    await manager.activateRotation();
    expect(await manager.activeCredential(), nextToken);
  });
  test(
      'lost rotate response is cancelled with old credential instead of losing identity',
      () async {
    await activate();
    bool lose = true;
    respond = (r) async {
      if (r.uri.path.endsWith('/rotate') && lose) {
        await r.drain();
        r.response.statusCode = 503;
        await r.response.close();
      } else {
        await normal(r);
      }
    };
    await expectLater(manager.rotate(), throwsA(failure('HTTP_FAILURE')));
    manager = recreated();
    lose = false;
    await manager.cancelRotation();
    expect(auth.last, 'Bearer $initialToken');
    expect(await manager.activeCredential(), initialToken);
    expect((await manager.view()).phase, IdentityPhase.active);
  });
  test('origin-bound secret record rejects another API endpoint', () async {
    await begin();
    final other =
        DeviceIdentityApi(apiRoot: Uri.parse('https://other.invalid/api/v1'));
    try {
      final host = DeviceIdentityManager(
          api: other, secrets: secrets, nowMillis: () => now);
      await expectLater(
          host.view(), throwsA(failure('IDENTITY_STATE_INVALID')));
      await expectLater(
          host.begin(ticket, displayName: 'device', osVersion: '14'),
          throwsA(failure('IDENTITY_STATE_INVALID')));
    } finally {
      other.close();
    }
  });
  test('claim response storage failure keeps same key recoverable', () async {
    secrets.failAt = 3;
    await expectLater(begin(), throwsA(failure('SECURE_STORAGE_FAILED')));
    final oldKey = jsonDecode(secrets.value!)['keyHandle'];
    expect((await manager.view()).phase, IdentityPhase.claimUncertain);
    secrets.failAt = null;
    manager = recreated();
    await manager.recoverClaim();
    expect(jsonDecode(secrets.value!)['keyHandle'] == oldKey, isTrue);
    expect(await manager.pairingCode(), 'ABCD1234');
  });
  test(
      'pending rotation write failure can cancel using durable original credential',
      () async {
    await activate();
    secrets.failAt = secrets.writes + 2;
    await expectLater(
        manager.rotate(), throwsA(failure('SECURE_STORAGE_FAILED')));
    manager = recreated();
    expect((await manager.view()).phase, IdentityPhase.rotationRequested);
    expect(await manager.activeCredential(), initialToken);
    secrets.failAt = null;
    await manager.cancelRotation();
    expect((await manager.view()).phase, IdentityPhase.active);
  });
  test('write failure before activation sends no request and keeps old active',
      () async {
    await activate();
    await manager.rotate();
    final count = requests.length;
    secrets.failAt = secrets.writes + 1;
    await expectLater(
        manager.activateRotation(), throwsA(failure('SECURE_STORAGE_FAILED')));
    expect(requests, hasLength(count));
    expect(await manager.activeCredential(), initialToken);
  });
  test(
      'write failure after activation ACK retains pending for safe new-token retry',
      () async {
    await activate();
    await manager.rotate();
    secrets.failAt = secrets.writes + 2;
    await expectLater(
        manager.activateRotation(), throwsA(failure('SECURE_STORAGE_FAILED')));
    manager = recreated();
    expect((await manager.view()).phase, IdentityPhase.activationUncertain);
    expect(await manager.activeCredential(), isNull);
    secrets.failAt = null;
    await manager.activateRotation();
    expect(auth.last, 'Bearer $nextToken');
    expect(await manager.activeCredential(), nextToken);
  });
  test(
      'expired unsent activation is cancelled with old token and never activated',
      () async {
    await activate();
    await manager.rotate();
    final count = requests.length;
    now += 300000;
    await expectLater(manager.activateRotation(),
        throwsA(failure('ROTATION_WINDOW_EXPIRED')));
    expect(requests, hasLength(count));
    await manager.cancelRotation();
    expect(auth.last, 'Bearer $initialToken');
    expect(await manager.activeCredential(), initialToken);
  });
  test('fractional JSON sequence cannot acknowledge an integer heartbeat',
      () async {
    await begin();
    respond = (r) => json(r,
        {'registrationId': registration, 'sequence': 1.0, 'receivedAt': now});
    await expectLater(manager.heartbeat(agentVersion: '1', capabilities: []),
        throwsA(failure('RESPONSE_INVALID')));
    expect((await manager.view()).heartbeatPending, isTrue);
    expect((await manager.view()).phase, IdentityPhase.awaitingConfirmation);
  });
  test(
      'rotation does not retain untrusted extra response copy in secret record',
      () async {
    await activate();
    respond = (r) async {
      await r.drain();
      await json(r, {
        'credentialId': credentialId,
        'credential': nextToken,
        'expiresAt': time + 7200000,
        'activateBefore': time + 300000,
        'debug': 'UNEXPECTED_SERVER_COPY'
      });
    };
    await manager.rotate();
    expect(secrets.value!.contains('UNEXPECTED_SERVER_COPY'), isFalse);
  });
  test('invalid capability snapshots do not consume sequence or reach network',
      () async {
    await activate();
    final count = requests.length;
    final report = {
      'key': 'usage.report',
      'reportedSupported': true,
      'grantStatus': 'GRANTED'
    };
    await expectLater(
        manager.heartbeat(agentVersion: '1', capabilities: [report, report]),
        throwsArgumentError);
    expect(requests, hasLength(count));
    expect((await manager.view()).heartbeatSequence, 1);
  });
  test('expired credential is not supplied and clock rollback fails closed',
      () async {
    await activate();
    now += 3600001;
    expect(await manager.activeCredential(), isNull);
    now = time - 1;
    await expectLater(
        manager.activeCredential(), throwsA(failure('CLOCK_UNTRUSTED')));
  });
  test(
      'state corruption and endpoint changes cannot silently start a new identity',
      () async {
    await begin();
    secrets.value = '{"token":"secret"}';
    await expectLater(
        manager.view(), throwsA(failure('IDENTITY_STATE_INVALID')));
    await expectLater(begin(), throwsA(failure('IDENTITY_STATE_INVALID')));
  });
  test(
      'concurrent mutation is rejected rather than starting another enrollment',
      () async {
    final arrived = Completer<void>(), release = Completer<void>();
    respond = (r) async {
      arrived.complete();
      await release.future;
      await normal(r);
    };
    final first = begin();
    await arrived.future;
    await expectLater(begin(), throwsA(failure('IDENTITY_BUSY')));
    release.complete();
    await first;
    expect(requests, hasLength(1));
  });
}
