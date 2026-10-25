import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';

void main() {
  test('maintenance explains uncertainty and preserves the original operation',
      () async {
    var calls = 0;
    final api = Api(() async => MockClient((request) async {
          calls++;
          return calls == 1
              ? http.Response(
                  '{"errorCode":"ERASURE_MAINTENANCE_REQUIRED"}', 503)
              : http.Response('{"id":"original-result"}', 200);
        }));
    await expectLater(
        api.send('POST', '/copies',
            body: {'name': 'original'}, key: 'maintenance-key'),
        throwsA(isA<ApiFailure>().having(
            (error) => error.message,
            'maintenance explanation',
            '系统正在暂停或恢复数据处理，暂时无法确认本次结果。请保留原操作内容，稍后重试。')));
    await expectLater(
        api.send('POST', '/copies',
            body: {'name': 'changed'}, key: 'maintenance-key'),
        throwsA(isA<ApiFailure>().having((error) => error.code,
            'unchanged retry', 'PENDING_OPERATION_UNCHANGED')));
    final result = await api.send('POST', '/copies',
        body: {'name': 'original'}, key: 'maintenance-key');
    expect(result['id'], 'original-result');
    expect(calls, 2);
  });
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
  final malformedSuccessBodies = <String, List<int>>{
    'invalid JSON': utf8.encode('{"id":'),
    'invalid UTF-8': <int>[0xc3, 0x28],
  };
  for (final entry in malformedSuccessBodies.entries) {
    test('malformed successful ${entry.key} preserves the original write',
        () async {
      var calls = 0;
      final api = Api(() async => MockClient((request) async {
            calls++;
            expect(request.headers['idempotency-key'], 'malformed-key');
            return calls == 1
                ? http.Response.bytes(entry.value, 200,
                    headers: {'content-type': 'application/json; charset=utf-8'})
                : http.Response('{"id":"recovered-result"}', 200);
          }));

      await expectLater(
          api.send('POST', '/copies',
              body: {'name': 'original'}, key: 'malformed-key'),
          throwsA(isA<ApiFailure>()
              .having((error) => error.status, 'status', 502)
              .having((error) => error.code, 'code', 'INVALID_RESPONSE')));
      await expectLater(
          api.send('POST', '/copies',
              body: {'name': 'changed'}, key: 'malformed-key'),
          throwsA(isA<ApiFailure>().having((error) => error.code, 'code',
              'PENDING_OPERATION_UNCHANGED')));
      expect(calls, 1);
      final recovered = await api.send('POST', '/copies',
          body: {'name': 'original'}, key: 'malformed-key');
      expect(recovered['id'], 'recovered-result');
      expect(calls, 2);
    });
  }
  test('empty success and explicit JSON null complete the pending write',
      () async {
    for (final response in <http.Response>[
      http.Response('', 200),
      http.Response('', 204),
      http.Response('null', 200),
    ]) {
      var calls = 0;
      final api = Api(() async => MockClient((_) async {
            calls++;
            return response;
          }));
      expect(
          await api.send('POST', '/copies',
              body: {'name': 'original'}, key: 'empty-key'),
          isNull);
      expect(
          await api.send('POST', '/copies',
              body: {'name': 'changed'}, key: 'empty-key'),
          isNull);
      expect(calls, 2);
    }
  });
  for (final entry in malformedSuccessBodies.entries) {
    test('non-JSON HTTP 403 (${entry.key}) preserves the denial status',
        () async {
      var calls = 0;
      final api = Api(() async => MockClient((_) async {
            calls++;
            return calls == 1
                ? http.Response.bytes(entry.value, 403,
                    headers: {'content-type': 'application/json; charset=utf-8'})
                : http.Response('{"id":"next-result"}', 200);
          }));
      await expectLater(
          api.send('POST', '/copies',
              body: {'name': 'original'}, key: 'denied-key'),
          throwsA(isA<ApiFailure>()
              .having((error) => error.status, 'status', 403)
              .having((error) => error.code, 'code', 'REQUEST_FAILED')));
      final result = await api.send('POST', '/copies',
          body: {'name': 'changed'}, key: 'denied-key');
      expect(result['id'], 'next-result');
      expect(calls, 2);
    });
  }
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

  final nonStringErrorValues = <String, Object>{
    'number': 17,
    'boolean': true,
    'list': <Object>['unexpected'],
    'map': <String, Object>{'unexpected': true},
  };
  for (final status in <int>[401, 403]) {
    for (final field in <String>['errorCode', 'correlationId']) {
      for (final entry in nonStringErrorValues.entries) {
        test(
            'HTTP $status with non-string $field (${entry.key}) preserves denial status',
            () async {
          var calls = 0;
          final api = Api(() async => MockClient((request) async {
                calls++;
                return http.Response(
                    jsonEncode(<String, Object>{
                      'errorCode': 'ACCESS_DENIED',
                      'correlationId': 'trace-auth-123',
                      field: entry.value,
                    }),
                    status);
              }));

          await expectLater(
              api.send('GET', '/tenants/t/devices'),
              throwsA(isA<ApiFailure>()
                  .having((error) => error.status, 'status', status)
                  .having((error) => error.code, 'code',
                      field == 'errorCode' ? 'REQUEST_FAILED' : 'ACCESS_DENIED')
                  .having((error) => error.correlationId, 'correlationId',
                      field == 'correlationId' ? null : 'trace-auth-123')));
          expect(calls, 1);
        });
      }
    }
  }

  test('HTTP 401 REAUTH_REQUIRED preserves explicit reauthentication code',
      () async {
    var calls = 0;
    final api = Api(() async => MockClient((request) async {
          calls++;
          return http.Response(
              '{"errorCode":"REAUTH_REQUIRED","correlationId":"trace-reauth-123"}',
              401);
        }));

    await expectLater(
        api.send('GET', '/tenants/t/devices'),
        throwsA(isA<ApiFailure>()
            .having((error) => error.status, 'status', 401)
            .having((error) => error.code, 'code', 'REAUTH_REQUIRED')
            .having((error) => error.correlationId, 'correlationId',
                'trace-reauth-123')));
    expect(calls, 1);
  });
}
