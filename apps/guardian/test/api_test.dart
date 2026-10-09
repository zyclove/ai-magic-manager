import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';

void main() {
  test('unknown writes retain original key and reject changed retry payload',
      () async {
    var calls = 0;
    final api = Api(() async => MockClient((request) async {
          calls++;
          expect(request.headers['idempotency-key'], 'copy-key');
          if (calls == 1) throw http.ClientException('response lost');
          return http.Response('{"id":"same-result"}', 200);
        }));
    await expectLater(
        api.send('POST', '/copies',
            body: {'name': 'original'}, key: 'copy-key'),
        throwsA(isA<ApiFailure>()));
    await expectLater(
        api.send('POST', '/copies', body: {'name': 'changed'}, key: 'copy-key'),
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'PENDING_OPERATION_UNCHANGED')));
    expect(calls, 1);
    final result = await api.send('POST', '/copies',
        body: {'name': 'original'}, key: 'copy-key');
    expect(result['id'], 'same-result');
    expect(calls, 2);
  });
  test('writes carry version and idempotency without retrying conflicts',
      () async {
    var calls = 0;
    final api = Api(() async => MockClient((request) async {
          calls++;
          expect(request.headers['if-match'], '"3"');
          expect(request.headers['idempotency-key'], 'request-key');
          expect(jsonDecode(request.body)['nickname'], '小明');
          return http.Response(
              '{"errorCode":"RESOURCE_VERSION_CONFLICT","correlationId":"trace-123"}',
              412);
        }));
    await expectLater(
        api.send('PATCH', '/tenants/t/subjects/s',
            body: {'nickname': '小明'}, version: 3, key: 'request-key'),
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'RESOURCE_VERSION_CONFLICT')
            .having((e) => e.correlationId, 'trace', 'trace-123')));
    expect(calls, 1);
  });
  test('pagination preserves cursor and errors never appear as empty success',
      () async {
    final api = Api(() async => MockClient((request) async {
          expect(request.url.queryParameters['cursor'], 'next-id');
          return http.Response(
              '{"items":[{"id":"second"}],"nextCursor":null}', 200);
        }));
    final page = await api.page('/tenants', cursor: 'next-id');
    expect(page.items.single['id'], 'second');
    expect(page.nextCursor, isNull);
    final failing = Api(
        () async => MockClient((_) async => http.Response('bad gateway', 502)));
    await expectLater(failing.page('/tenants'), throwsA(isA<ApiFailure>()));
  });
}
