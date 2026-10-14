import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oauth2/oauth2.dart' as oauth;

import 'api_scope_test.dart'
    show RecordingTransport, expiredCredentials, refreshedToken;

Matcher _changed() => isA<ApiFailure>()
    .having((failure) => failure.status, 'status', 409)
    .having((failure) => failure.code, 'code', 'WORKSPACE_CHANGED');

Matcher _pending() => isA<ApiFailure>()
    .having((failure) => failure.code, 'code', 'PENDING_OPERATION_UNCHANGED');

class _LateClient extends http.BaseClient {
  final started = Completer<void>();
  final response = Completer<http.StreamedResponse>();
  var calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls++;
    request.finalize();
    started.complete();
    return response.future;
  }
}

void main() {
  test('bound send rejects stale scope before client lookup despite local true',
      () async {
    var lookups = 0;
    final root = Api(() async {
      lookups++;
      return MockClient((_) async => http.Response('{}', 200));
    });
    final bound = root.scoped(() => false);
    await expectLater(bound.send('GET', '/private', isCurrent: () => true),
        throwsA(_changed()));
    expect(lookups, 0);
  });

  for (final all in [false, true]) {
    test('bound ${all ? 'all' : 'page'} rejects stale scope before first GET',
        () async {
      var calls = 0;
      final root = Api(() async => MockClient((_) async {
            calls++;
            return http.Response('{"items":[],"nextCursor":null}', 200);
          }));
      final bound = root.scoped(() => false);
      await expectLater(
          all
              ? bound.all('/private', isCurrent: () => true)
              : bound.page('/private', isCurrent: () => true),
          throwsA(_changed()));
      expect(calls, 0);
    });
  }

  test('a per-call false guard cannot be replaced by a current bound scope',
      () async {
    var calls = 0;
    final bound = Api(() async => MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        })).scoped(() => true);
    await expectLater(bound.send('GET', '/private', isCurrent: () => false),
        throwsA(_changed()));
    expect(calls, 0);
  });

  for (final staleOuter in [false, true]) {
    test('nested bound APIs retain ${staleOuter ? 'outer' : 'inner'} guard',
        () async {
      var calls = 0;
      final root = Api(() async => MockClient((_) async {
            calls++;
            return http.Response('{}', 200);
          }));
      final bound = root.scoped(() => !staleOuter).scoped(() => staleOuter);
      await expectLater(bound.send('GET', '/private', isCurrent: () => true),
          throwsA(_changed()));
      expect(calls, 0);
    });
  }

  test('current bound API preserves base URL, body and request headers',
      () async {
    final root = Api(
        () async => MockClient((request) async {
              expect(request.url.toString(),
                  'https://business.example/api/private');
              expect(request.method, 'POST');
              expect(jsonDecode(request.body), {'name': 'original'});
              expect(request.headers['if-match'], '"3"');
              expect(request.headers['idempotency-key'], 'pending-write');
              expect(request.headers['client-request-id'],
                  '01234567-89ab-4def-8123-456789abcdef');
              return http.Response('{"id":"current"}', 200);
            }),
        baseUrl: 'https://business.example/api');
    final bound = root.scoped(() => true);
    expect(bound.baseUrl, root.baseUrl);
    expect(
        await bound.send('POST', '/private',
            body: {'name': 'original'},
            version: 3,
            key: 'pending-write',
            clientRequestId: '01234567-89ab-4def-8123-456789abcdef'),
        {'id': 'current'});
  });

  test('binding a root API does not restrict independent root operations',
      () async {
    var current = true, calls = 0;
    final root = Api(() async => MockClient((_) async {
          calls++;
          return http.Response('{"id":"root"}', 200);
        }));
    final bound = root.scoped(() => current);
    current = false;
    await expectLater(bound.send('GET', '/private'), throwsA(_changed()));
    expect(await root.send('GET', '/me'), {'id': 'root'});
    expect(calls, 1);
  });

  test('bound scope lost while awaiting client prevents physical dispatch',
      () async {
    var current = true, calls = 0;
    final started = Completer<void>();
    final client = Completer<http.Client>();
    final bound = Api(() {
      started.complete();
      return client.future;
    }).scoped(() => current);
    final result = bound.send('POST', '/private', body: {'original': true});
    final rejected = expectLater(result, throwsA(_changed()));
    await started.future;
    current = false;
    client.complete(MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }));
    await rejected;
    expect(calls, 0);
  });

  test('bound raw client lookup also checks after waiting for authentication',
      () async {
    var current = true;
    final started = Completer<void>();
    final client = Completer<http.Client>();
    final bound = Api(() {
      started.complete();
      return client.future;
    }).scoped(() => current);
    final result = bound.client();
    final rejected = expectLater(result, throwsA(_changed()));
    await started.future;
    current = false;
    client.complete(MockClient((_) async => http.Response('{}', 200)));
    await rejected;
  });

  test('a previously obtained bound client rejects a later stale raw GET',
      () async {
    var current = true, calls = 0;
    final root = Api(() async => MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }));
    final client = await root.scoped(() => current).client();
    current = false;
    await expectLater(client.get(Uri.parse('https://business.example/private')),
        throwsA(isA<ScopeChangedException>()));
    expect(calls, 0);
  });

  test('bound API cannot dispatch through an OAuth refresh after scope loss',
      () async {
    var current = true;
    final raw = RecordingTransport();
    final authenticated = oauth.Client(expiredCredentials(),
        identifier: 'guardian',
        basicAuth: false,
        httpClient: ScopeGuardedClient(raw));
    addTearDown(authenticated.close);
    final bound = Api(() async => authenticated).scoped(() => current);
    final result = bound.send('POST', '/private', body: {'original': true});
    final rejected = expectLater(result, throwsA(_changed()));
    await raw.tokenStarted.future;
    current = false;
    raw.tokenReply.complete(refreshedToken());
    await rejected;
    expect(raw.businessRequests, isEmpty);
  });

  test('late headers reject bound results and cancel unread response bytes',
      () async {
    var current = true, cancelled = false;
    final body =
        StreamController<List<int>>.broadcast(onCancel: () => cancelled = true);
    addTearDown(body.close);
    final raw = _LateClient();
    final bound = Api(() async => raw).scoped(() => current);
    final result = bound.send('GET', '/private');
    final rejected = expectLater(result, throwsA(_changed()));
    await raw.started.future;
    current = false;
    raw.response.complete(http.StreamedResponse(body.stream, 200));
    await rejected;
    expect(cancelled, isTrue,
        reason: 'Unread private response must be cancelled.');
  });

  for (final all in [false, true]) {
    test('bound ${all ? 'all' : 'page'} does not return stale page data',
        () async {
      var current = true, calls = 0;
      final bound = Api(() async => MockClient((_) async {
            calls++;
            current = false;
            return http.Response(
                '{"items":[{"id":"old-private"}],"nextCursor":"more"}', 200);
          })).scoped(() => current);
      await expectLater(all ? bound.all('/private') : bound.page('/private'),
          throwsA(_changed()));
      expect(calls, 1);
    });
  }

  for (final boundFirst in [false, true]) {
    test(
        'unknown writes share pending key from ${boundFirst ? 'bound' : 'root'}',
        () async {
      var calls = 0;
      final root = Api(() async => MockClient((_) async {
            calls++;
            return http.Response('{"errorCode":"REQUEST_FAILED"}', 503);
          }));
      final bound = root.scoped(() => true);
      final first = boundFirst ? bound : root;
      final other = boundFirst ? root : bound;
      await expectLater(
          first.send('POST', '/private',
              body: {'name': 'original'}, key: 'same'),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 503)));
      await expectLater(
          other.send('POST', '/private',
              body: {'name': 'changed'}, key: 'same'),
          throwsA(_pending()));
      expect(calls, 1);
    });
  }

  test('successful same-body bound retry clears shared root pending key',
      () async {
    var calls = 0;
    final root = Api(() async => MockClient((_) async {
          calls++;
          return calls == 1
              ? http.Response('{"errorCode":"REQUEST_FAILED"}', 503)
              : http.Response('{}', 200);
        }));
    final bound = root.scoped(() => true).scoped(() => true);
    await expectLater(
        root.send('POST', '/private', body: {'name': 'original'}, key: 'same'),
        throwsA(isA<ApiFailure>()));
    await bound.send('POST', '/private',
        body: {'name': 'original'}, key: 'same');
    await root.send('POST', '/private', body: {'name': 'changed'}, key: 'same');
    expect(calls, 3);
  });

  test('scope-lost write response cannot clear its shared pending signature',
      () async {
    var current = true;
    final raw = _LateClient();
    final root = Api(() async => raw);
    final bound = root.scoped(() => current);
    final result =
        bound.send('POST', '/private', body: {'name': 'original'}, key: 'same');
    final rejected = expectLater(result, throwsA(_changed()));
    await raw.started.future;
    current = false;
    raw.response
        .complete(http.StreamedResponse(Stream.value(utf8.encode('{}')), 200));
    await rejected;
    await expectLater(
        root.send('POST', '/private', body: {'name': 'changed'}, key: 'same'),
        throwsA(_pending()));
    expect(raw.calls, 1);
  });
}
