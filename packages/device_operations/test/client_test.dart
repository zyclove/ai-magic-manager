import 'dart:convert';
import 'package:device_operations/device_operations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'fixtures.dart';

ExitScope scope({String role = 'OWNER'}) => ExitScope(
    actorId: 'verified-subject',
    tenantId: tenantId,
    deviceId: deviceId,
    registrationId: registrationId,
    role: role);
DeviceOperationsClient client(MockClient transport,
        {Duration timeout = const Duration(seconds: 2)}) =>
    DeviceOperationsClient(
        apiRoot: Uri.parse('https://example.test/api/v1'),
        clientFactory: () async => transport,
        timeout: timeout);
http.Response response(Map<String, dynamic> body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('reads the actual Spring ProblemDetail errorCode field', () async {
    final api = client(MockClient((_) async => response({
      'type':'about:blank', 'status':401, 'errorCode':'REAUTH_REQUIRED',
      'messageKey':'error.reauth_required', 'correlationId':'request-456',
    }, status:401)));
    await expectLater(api.preview(scope(),7),throwsA(isA<ExitFailure>()
      .having((e)=>e.code,'code','REAUTH_REQUIRED')
      .having((e)=>e.correlationId,'correlation','request-456')));
  });
  test('production transport rejects plaintext, query, and userinfo', () {
    for (final root in [
      'http://example.test/api/v1',
      'https://example.test/api/v1?token=secret',
      'https://user@example.test/api/v1'
    ]) {
      expect(
          () => DeviceOperationsClient(
              apiRoot: Uri.parse(root),
              clientFactory: () async =>
                  MockClient((_) async => response(deviceJson()))),
          throwsArgumentError);
    }
  });
  test('confirm carries original resource version, key and exact payload',
      () async {
    final api = client(MockClient((r) async {
      expect(r.method, 'POST');
      expect(r.url.path,
          '/api/v1/tenants/$tenantId/devices/$deviceId/deprovision/operations');
      expect(r.headers['if-match'], '"7"');
      expect(r.headers['idempotency-key'], requestKey);
      expect(jsonDecode(r.body),
          {'previewId': previewId, 'previewHash': previewHash});
      return response(operationJson(), status: 201);
    }));
    expect(
        (await api.confirm(scope(),
                previewId: previewId,
                previewHash: previewHash,
                deviceVersion: 7,
                key: requestKey))
            .id,
        operationId);
  });
  test('preview and device snapshots reject cross-device responses', () async {
    final api = client(MockClient((_) async =>
        response({...previewJson(), 'deviceId': tenantId}, status: 201)));
    await expectLater(
        api.preview(scope(), 7),
        throwsA(isA<ExitFailure>()
            .having((e) => e.code, 'code', 'RESPONSE_INVALID')));
  });
  test(
      'unknown mutation success is uncertain and cannot be treated as rejection',
      () async {
    final api = client(
        MockClient((_) async => response({'id': operationId}, status: 201)));
    await expectLater(
        api.confirm(scope(),
            previewId: previewId,
            previewHash: previewHash,
            deviceVersion: 7,
            key: requestKey),
        throwsA(isA<ExitFailure>()
            .having((e) => e.outcomeUnknown, 'unknown', true)));
  });
  test('server body is never exposed through safe failure copy', () async {
    final api = client(MockClient((_) async => response({
          'code': 'REAUTH_REQUIRED',
          'message': 'password=secret SQL details',
          'correlationId': 'request-123'
        }, status: 401)));
    await expectLater(
        api.preview(scope(), 7),
        throwsA(isA<ExitFailure>()
            .having((e) => e.code, 'code', 'REAUTH_REQUIRED')
            .having((e) => e.message.contains('secret'), 'private text', false)
            .having((e) => e.correlationId, 'correlation', 'request-123')
            .having((e) => e.outcomeUnknown, 'known rejection', false)));
  });
  test('mutation timeout is uncertain and never automatically retried',
      () async {
    var count = 0;
    final api = client(MockClient((_) async {
      count++;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      return response(operationJson());
    }), timeout: const Duration(milliseconds: 10));
    await expectLater(
        api.confirm(scope(),
            previewId: previewId,
            previewHash: previewHash,
            deviceVersion: 7,
            key: requestKey),
        throwsA(isA<ExitFailure>()
            .having((e) => e.outcomeUnknown, 'unknown', true)));
    expect(count, 1);
  });
  test('unknown 409 is kept uncertain rather than clearing the journal',
      () async {
    final api = client(MockClient(
        (_) async => response({'code': 'NEW_UNKNOWN_CONFLICT'}, status: 409)));
    await expectLater(
        api.cancel(scope(),
            operationId: operationId, version: 1, key: requestKey),
        throwsA(isA<ExitFailure>()
            .having((e) => e.outcomeUnknown, 'unknown', true)));
  });
  test('wrong operation ID is rejected even when device matches', () async {
    final api = client(MockClient(
        (_) async => response({...operationJson(), 'id': commandId})));
    await expectLater(
        api.operation(scope(), operationId), throwsA(isA<ExitFailure>()));
  });
  test('list unwraps ItemPage and validates each registration', () async {
    final api = client(MockClient((_) async => response({
          'items': [operationJson()],
          'nextCursor': null
        })));
    expect((await api.operations(scope())).single.id, operationId);
  });
}
