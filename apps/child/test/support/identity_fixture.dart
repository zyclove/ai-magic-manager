import 'dart:convert';
import 'package:child/core/session.dart';
import 'package:device_identity/device_identity.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FixtureSecrets implements DeviceSecretStore {
  String? record;
  bool failRead = false;
  @override
  Future<String?> read() async {
    if (failRead) throw StateError('fixture storage unavailable');
    return record;
  }

  @override
  Future<void> write(String value) async {
    record = value;
  }
}

/// Controlled cloud and storage substitutes, never a production app mode.
class IdentityFixture {
  final DeviceSecretStore? nativeSecrets;
  IdentityFixture({this.nativeSecrets});
  static const tenant = '11111111-1111-1111-1111-111111111111';
  static const enrollment = '22222222-2222-2222-2222-222222222222';
  static const device = '33333333-3333-3333-3333-333333333333';
  static const registration = '44444444-4444-4444-4444-444444444444';
  static const now = 1800000000000;
  int clock = now;
  bool confirmed = false, rejectAuthentication = false, loseClaim = false;
  int calls = 0;
  final secrets = FixtureSecrets();
  late final http.Client client = MockClient((request) async {
    calls++;
    Map<String, dynamic> response;
    var status = 200;
    if (request.url.path.endsWith('enrollment-claims') ||
        request.url.path.endsWith('enrollment-claims/recover')) {
      if (loseClaim && !request.url.path.endsWith('/recover')) {
        return http.Response('{}', 503,
            headers: {'content-type': 'application/json'});
      }
      response = {
        'deviceId': device,
        'registrationId': registration,
        'credential': 'b' * 43,
        'expiresAt': now + 86400000,
        'pairingCode': '12345678',
        'confirmBefore': now + 600000,
        'state': 'AWAITING_CONFIRMATION'
      };
      status = request.url.path.endsWith('/recover') ? 200 : 201;
    } else if (request.url.path.endsWith('credentials/rotate')) {
      response = {
        'credentialId': '55555555-5555-5555-5555-555555555555',
        'credential': 'c' * 43,
        'expiresAt': now + 172800000,
        'activateBefore': now + 300000
      };
    } else if (request.url.path.endsWith('credentials/activate') ||
        request.url.path.endsWith('rotation/cancel')) {
      return http.Response('', 204);
    } else {
      if (!confirmed || rejectAuthentication) {
        return http.Response('{}', 401,
            headers: {'content-type': 'application/json'});
      }
      response = {
        'registrationId': registration,
        'sequence': (jsonDecode(request.body) as Map)['sequence'],
        'receivedAt': now
      };
    }
    return http.Response(jsonEncode(response), status,
        headers: {'content-type': 'application/json'});
  });
  late final identity = DeviceIdentityManager(
      api: DeviceIdentityApi(
          apiRoot: Uri.parse('https://service.example/api/v1'), client: client),
      secrets: nativeSecrets ?? secrets,
      nowMillis: () => clock);
  ChildSession session({ChildRuleReceiverFactory? rules}) =>
      ChildSession(identity: identity, ruleReceiverFactory: rules);
  String get ticket => jsonEncode({
        'tenantId': tenant,
        'id': enrollment,
        'token': 'a' * 43,
        'expiresAt': now + 600000
      });
  Future<void> pair() async => identity.begin(parseRegistrationTicket(ticket),
      displayName: '我的手机', osVersion: 'Android test fixture');
  Future<void> activate() async {
    await pair();
    confirmed = true;
    await identity.heartbeat(agentVersion: 'test', capabilities: const []);
  }

  void close() => client.close();
}
