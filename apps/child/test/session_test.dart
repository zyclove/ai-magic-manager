import 'dart:convert';
import 'package:child/core/session.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class TestSecrets implements DeviceSecretStore {
  String? record;
  @override
  Future<String?> read() async => record;
  @override
  Future<void> write(String value) async => record = value;
}

void main() {
  const tenant = '11111111-1111-1111-1111-111111111111';
  const enrollment = '22222222-2222-2222-2222-222222222222';
  const device = '33333333-3333-3333-3333-333333333333';
  const registration = '44444444-4444-4444-4444-444444444444';
  const now = 1800000000000;
  final ticket = jsonEncode({
    'tenantId': tenant,
    'id': enrollment,
    'token': 'a' * 43,
    'expiresAt': now + 600000
  });

  test(
      'pairing requires the complete bounded ticket and never accepts an origin',
      () {
    expect(parseRegistrationTicket(ticket).enrollmentId, enrollment);
    for (final invalid in [
      '{}',
      '{bad',
      jsonEncode({
        'tenantId': tenant,
        'id': enrollment,
        'token': 'a' * 43,
        'expiresAt': now + 600000,
        'apiRoot': 'https://foreign.example/api/v1'
      }),
      'a' * 8193
    ]) {
      expect(() => parseRegistrationTicket(invalid),
          throwsA(isA<FormatException>()));
    }
  });

  test(
      'actual identity manager connects, waits, confirms and masks the pairing code',
      () async {
    final requests = <String>[];
    var confirmed = false;
    final store = TestSecrets();
    final client = MockClient((request) async {
      requests.add(request.url.path);
      if (request.url.path.endsWith('enrollment-claims')) {
        return http.Response(
            jsonEncode({
              'deviceId': device,
              'registrationId': registration,
              'credential': 'b' * 43,
              'expiresAt': now + 86400000,
              'pairingCode': '12345678',
              'confirmBefore': now + 600000,
              'state': 'AWAITING_CONFIRMATION'
            }),
            201,
            headers: {'content-type': 'application/json'});
      }
      if (!confirmed) {
        return http.Response('{}', 401,
            headers: {'content-type': 'application/json'});
      }
      final sequence = (jsonDecode(request.body) as Map)['sequence'];
      return http.Response(
          jsonEncode({
            'registrationId': registration,
            'sequence': sequence,
            'receivedAt': now
          }),
          200,
          headers: {'content-type': 'application/json'});
    });
    final manager = DeviceIdentityManager(
        api: DeviceIdentityApi(
            apiRoot: Uri.parse('https://service.example/api/v1'),
            client: client),
        secrets: store,
        nowMillis: () => now);
    final session = ChildSession(identity: manager);
    await session.initialize();
    expect(session.identityView, isNull);
    expect(
        await session.pair(ticket, displayName: '我的手机', osVersion: 'Android'),
        isTrue);
    expect(session.identityView!.phase, IdentityPhase.awaitingConfirmation);
    expect(session.pairingCode, '12345678');
    session.setForeground(false);
    expect(session.pairingCode, isNull);
    await session.setForeground(true);
    expect(session.pairingCode, '12345678');
    expect(await session.checkConnection(), isFalse);
    expect(session.errorCode, 'AWAITING_GUARDIAN');
    expect(session.identityView!.phase, IdentityPhase.awaitingConfirmation);
    confirmed = true;
    expect(await session.checkConnection(), isTrue);
    expect(session.identityView!.phase, IdentityPhase.active);
    expect(session.pairingCode, isNull);
    expect(session.systemEnforced, isFalse);
    expect(await session.synchronizeRules(), isFalse);
    expect(session.errorCode, 'CONFIGURATION_TRUST_UNAVAILABLE');
    expect(requests.length, 3);
    session.dispose();
    client.close();
  });
}
