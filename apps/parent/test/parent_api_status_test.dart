import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';

void main() {
  test(
      'strict no-content mutation does not accept asynchronous or unrelated success',
      () async {
    for (final status in [200, 202, 204]) {
      final api = ParentApi(() async => 'fixture',
          baseUrl: 'https://fixture.invalid',
          client: MockClient((r) async => http.Response('', status)));
      addTearDown(api.close);
      final action = api.send('DELETE', '/fixture', expectedStatus: 204);
      if (status == 204) {
        expect(await action, null);
      } else {
        await expectLater(
            action,
            throwsA(isA<ParentApiException>()
                .having((e) => e.code, 'code', 'INVALID_RESPONSE')));
      }
    }
  });
  test(
      'strict status preserves definite server rejection code and default remains compatible',
      () async {
    final denied = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient(
            (r) async => http.Response('{"errorCode":"SCOPE_DENIED"}', 403)));
    addTearDown(denied.close);
    await expectLater(
        denied.send('DELETE', '/fixture', expectedStatus: 204),
        throwsA(isA<ParentApiException>()
            .having((e) => e.code, 'code', 'SCOPE_DENIED')));
    final normal = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient(
            (r) async => http.Response('{"operation":"pending"}', 202)));
    addTearDown(normal.close);
    expect((await normal.send('POST', '/fixture'))['operation'], 'pending');
  });
}
