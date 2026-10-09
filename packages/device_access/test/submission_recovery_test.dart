import 'dart:convert';
import 'package:device_access/device_access.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'fixtures.dart' as f;
import 'support/submission_fixture.dart' as sample;

void main() {
  DeviceAccessTransport transport(http.Client client) => DeviceAccessTransport(
      apiRoot: Uri.parse('https://device.invalid/api/v1'),
      credential: () async => 'A' * 43,
      client: client);
  test(
      'create recovery sends original private input and key and reads current revoked fact',
      () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(
          request.url.path, '/api/v1/device-api/access-submissions/recovery');
      expect(request.headers['Idempotency-Key'], 'original');
      expect(jsonDecode(request.body), sample.input().toJson());
      return http.Response(
          jsonEncode(sample.submission({
            'state': 'REVOKED',
            'version': 2,
            'grantedWindowSeconds': 300,
            'issuedAt': f.now + 1000,
            'absoluteNotAfter': f.now + 301000
          })),
          200,
          headers: {'content-type': 'application/json'});
    });
    final t = transport(client);
    addTearDown(t.close);
    addTearDown(client.close);
    final value = await t.recoverSubmission(sample.input(),
        context: sample.context(), idempotencyKey: 'original');
    expect(value.state, 'REVOKED');
    expect(value.absoluteNotAfter, f.now + 301000);
    expect(value.systemEnforced, isFalse);
  });
  test(
      'cancel recovery retains original request revision and validates a cancelled successor',
      () async {
    final client = MockClient((request) async {
      expect(request.url.path,
          '/api/v1/device-api/access-submissions/${f.request}/cancel-recovery');
      expect(request.headers['If-Match'], '"0"');
      expect(request.headers['Idempotency-Key'], 'cancel');
      return http.Response(
          jsonEncode(sample.submission({'state': 'CANCELLED', 'version': 1})),
          200,
          headers: {'content-type': 'application/json'});
    });
    final t = transport(client);
    addTearDown(t.close);
    addTearDown(client.close);
    final value = await t.recoverCancellation(f.request,
        context: sample.context(), version: 0, idempotencyKey: 'cancel');
    expect(value.state, 'CANCELLED');
  });
  test('unavailable recovery is a safe error and never generates a new request',
      () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(
          '{"errorCode":"ACCESS_RECOVERY_UNAVAILABLE","detail":"private reason"}',
          404,
          headers: {'content-type': 'application/problem+json'});
    });
    final t = transport(client);
    addTearDown(t.close);
    addTearDown(client.close);
    await expectLater(
        t.recoverSubmission(sample.input(),
            context: sample.context(), idempotencyKey: 'original'),
        throwsA(isA<AccessTransportFailure>()
            .having((e) => e.code, 'code', 'ACCESS_RECOVERY_UNAVAILABLE')
            .having(
                (e) => e.toString(), 'redacted', isNot(contains('private')))));
    expect(calls, 1);
  });
  test('recovery cannot accept a mismatched scope or an unchanged cancel state',
      () async {
    for (final value in [
      sample.submission({'deviceId': f.document}),
      sample.submission()
    ]) {
      final client = MockClient((request) async => http.Response(
          jsonEncode(value), 200,
          headers: {'content-type': 'application/json'}));
      final t = transport(client);
      try {
        await expectLater(
            t.recoverCancellation(f.request,
                context: sample.context(),
                version: 0,
                idempotencyKey: 'cancel'),
            throwsA(isA<AccessTransportFailure>()
                .having((e) => e.code, 'code', 'RESPONSE_INVALID')));
      } finally {
        t.close();
        client.close();
      }
    }
  });
  test('recovery rejects control characters in the original key before HTTP',
      () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response('{}', 500);
    });
    final t = transport(client);
    addTearDown(t.close);
    addTearDown(client.close);
    for (final key in ['original\n', 'original\r\n', 'original\u0000']) {
      expect(
          () => t.recoverSubmission(sample.input(),
              context: sample.context(), idempotencyKey: key),
          throwsArgumentError);
    }
    expect(calls, 0);
  });
}
