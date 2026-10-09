import 'dart:convert';
import 'package:device_access/device_access.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

Map<String, dynamic> contextJson() => {
      'tenantId': tenant,
      'subjectId': subject,
      'deviceId': device,
      'registrationId': registration
    };

void main() {
  test('authenticated context binds all identity facts without choosing trust',
      () {
    final context = AccessDeviceContext.fromJson(contextJson());
    expect(context.subjectId, subject);
    context.requireIdentity(
        tenantId: tenant, deviceId: device, registrationId: registration);
    expect(
        () => context.requireIdentity(
            tenantId: subject, deviceId: device, registrationId: registration),
        throwsA(isA<AccessFailure>()));
    expect(
        () => context.requireIdentity(
            tenantId: tenant, deviceId: device, registrationId: subject),
        throwsA(isA<AccessFailure>()));
    expect(context.toString(), isNot(contains(subject)));
  });
  test(
      'context rejects extra trust/credential claims, absent and invalid bindings',
      () {
    for (final value in [
      {...contextJson(), 'issuer': 'untrusted'},
      {...contextJson(), 'credential': 'a' * 43},
      {...contextJson()}..remove('subjectId'),
      {...contextJson(), 'subjectId': '../other'},
      {...contextJson(), 'subjectId': null}
    ]) {
      expect(() => AccessDeviceContext.fromJson(value),
          throwsA(isA<AccessFailure>()));
    }
  });
  test('context uses only fixed authenticated read route and fresh credential',
      () async {
    var calls = 0, token = 'a' * 43;
    final client = MockClient((request) async {
      calls++;
      expect(request.method, 'GET');
      expect(request.url.toString(),
          'https://example.org/api/v1/device-api/access-context');
      expect(request.headers['authorization'], 'Bearer $token');
      expect(request.body, isEmpty);
      return http.Response(jsonEncode(contextJson()), 200,
          headers: {'content-type': 'application/json'});
    });
    final transport = DeviceAccessTransport(
        apiRoot: Uri.parse('https://example.org/api/v1'),
        credential: () async => token,
        client: client);
    addTearDown(transport.close);
    expect((await transport.context()).subjectId, subject);
    token = 'b' * 43;
    await transport.context();
    expect(calls, 2);
  });
}
