import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oauth2/oauth2.dart' as oauth;

const clientRequestId = '01234567-89ab-4def-8123-456789abcdef';
const secondClientRequestId = '11234567-89ab-4def-8123-456789abcdef';
final tokenEndpoint = Uri.parse('https://identity.example/token');

Matcher scopeChanged() => isA<ApiFailure>()
    .having((failure) => failure.status, 'status', 409)
    .having((failure) => failure.code, 'code', 'WORKSPACE_CHANGED');

oauth.Credentials expiredCredentials() => oauth.Credentials('expired-access',
    refreshToken: 'refresh-token',
    tokenEndpoint: tokenEndpoint,
    expiration: DateTime.now().subtract(const Duration(minutes: 1)));

http.StreamedResponse refreshedToken() => http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode({
      'access_token': 'fresh-access',
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'fresh-refresh',
    }))),
    200,
    headers: {'content-type': 'application/json'});

/// Records entry to the physical transport before finalizing the request. A
/// finalize-only guard cannot make the OAuth dispatch-boundary test pass.
class RecordingTransport extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final tokenStarted = Completer<void>();
  final tokenReply = Completer<http.StreamedResponse>();
  bool closed = false;

  List<http.BaseRequest> get businessRequests =>
      requests.where((request) => request.url != tokenEndpoint).toList();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    request.finalize();
    if (request.url == tokenEndpoint) {
      if (!tokenStarted.isCompleted) tokenStarted.complete();
      return tokenReply.future;
    }
    return Future.value(http.StreamedResponse(
        Stream.value(utf8.encode('{"id":"business-result"}')), 200,
        request: request));
  }

  @override
  void close() => closed = true;
}

void main() {
  test('a stale request is rejected before looking up any client', () async {
    var clientLookups = 0, calls = 0;
    final api = Api(() async {
      clientLookups++;
      return MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });
    });
    await expectLater(api.send('POST', '/enrollments', isCurrent: () => false),
        throwsA(scopeChanged()));
    expect(clientLookups, 0);
    expect(calls, 0);
  });

  test('scope lost while obtaining a client prevents physical dispatch',
      () async {
    var current = true, calls = 0;
    final pendingClient = Completer<http.Client>();
    final started = Completer<void>();
    final api = Api(() {
      started.complete();
      return pendingClient.future;
    });
    final response = api.send('POST', '/enrollments', isCurrent: () => current);
    final rejected = expectLater(response, throwsA(scopeChanged()));
    await started.future;
    current = false;
    pendingClient.complete(MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }));
    await rejected;
    expect(calls, 0);
  });

  test('real OAuth refresh cannot dispatch an expired scoped business request',
      () async {
    var current = true;
    final raw = RecordingTransport();
    final client = oauth.Client(expiredCredentials(),
        identifier: 'guardian',
        basicAuth: false,
        httpClient: ScopeGuardedClient(raw));
    addTearDown(client.close);
    final api = Api(() async => client);
    final response = api.send('POST', '/enrollments',
        body: {'subjectId': 'original-subject'},
        clientRequestId: clientRequestId,
        isCurrent: () => current);
    final rejected = expectLater(response, throwsA(scopeChanged()));
    await raw.tokenStarted.future;
    current = false;
    raw.tokenReply.complete(refreshedToken());
    await rejected;
    expect(raw.requests.where((request) => request.url == tokenEndpoint),
        hasLength(1));
    expect(raw.businessRequests, isEmpty,
        reason: 'The transport must reject after OAuth awaited token refresh.');
  });

  test('real OAuth keeps the guarded request and sends current bearer and ID',
      () async {
    final raw = RecordingTransport();
    final client = oauth.Client(expiredCredentials(),
        identifier: 'guardian',
        basicAuth: false,
        httpClient: ScopeGuardedClient(raw));
    addTearDown(client.close);
    final api = Api(() async => client);
    final response = api.send('POST', '/enrollments',
        body: {'subjectId': 'original-subject'},
        clientRequestId: clientRequestId,
        isCurrent: () => true);
    await raw.tokenStarted.future;
    raw.tokenReply.complete(refreshedToken());
    expect((await response)['id'], 'business-result');
    final sent = raw.businessRequests.single;
    expect(sent, isA<ScopeGuardedRequest>());
    expect(sent.headers['authorization'], 'Bearer fresh-access');
    expect(sent.headers['client-request-id'], clientRequestId);
    expect(sent.headers.containsKey('idempotency-key'), isFalse);
  });

  test('a request without a scope guard retains existing OAuth behavior',
      () async {
    final raw = RecordingTransport();
    final client = oauth.Client(expiredCredentials(),
        identifier: 'guardian',
        basicAuth: false,
        httpClient: ScopeGuardedClient(raw));
    addTearDown(client.close);
    final api = Api(() async => client);
    final response = api.send('GET', '/me');
    await raw.tokenStarted.future;
    raw.tokenReply.complete(refreshedToken());
    expect((await response)['id'], 'business-result');
    expect(raw.businessRequests, hasLength(1));
    expect(raw.businessRequests.single, isNot(isA<ScopeGuardedRequest>()));
  });

  test('a late complete response cannot reveal data after the scope changes',
      () async {
    var current = true, calls = 0;
    final reply = Completer<http.Response>();
    final started = Completer<void>();
    final api = Api(() async => MockClient((_) async {
          calls++;
          started.complete();
          return reply.future;
        }));
    final response = api.send('GET', '/private', isCurrent: () => current);
    final rejected = expectLater(response, throwsA(scopeChanged()));
    await started.future;
    current = false;
    reply.complete(http.Response('{"private":"old-workspace"}', 200));
    await rejected;
    expect(calls, 1);
  });

  test('Client-Request-Id remains distinct from the generic idempotency header',
      () async {
    var calls = 0;
    final api = Api(() async => MockClient((request) async {
          calls++;
          expect(request.headers['client-request-id'], clientRequestId);
          expect(request.headers['idempotency-key'], 'generic-key');
          expect(request.headers['if-match'], '"7"');
          expect(jsonDecode(request.body), {'name': 'original'});
          return http.Response('{}', 200);
        }));
    await api.send('POST', '/enrollments',
        body: {'name': 'original'},
        version: 7,
        key: 'generic-key',
        clientRequestId: clientRequestId);
    expect(calls, 1);
  });

  for (final invalid in [
    '',
    '0123456789ab4def8123456789abcdef',
    '01234567-89AB-4def-8123-456789abcdef',
    '01234567-89ab-1def-8123-456789abcdef',
    '01234567-89ab-4def-0123-456789abcdef',
    ' 01234567-89ab-4def-8123-456789abcdef',
    '01234567-89ab-4def-8123-456789abcdef\n',
  ]) {
    test('invalid Client-Request-Id is rejected before client lookup: $invalid',
        () async {
      var lookups = 0;
      final api = Api(() async {
        lookups++;
        return MockClient((_) async => http.Response('{}', 200));
      });
      await expectLater(
          api.send('POST', '/enrollments', clientRequestId: invalid),
          throwsA(isA<ApiFailure>().having(
              (failure) => failure.code, 'code', 'INVALID_CLIENT_REQUEST_ID')));
      expect(lookups, 0);
    });
  }

  test('unknown generic writes cannot retry with a changed client creation ID',
      () async {
    var calls = 0;
    final api = Api(() async => MockClient((_) async {
          calls++;
          return calls == 1
              ? http.Response('{"errorCode":"REQUEST_FAILED"}', 503)
              : http.Response('{}', 200);
        }));
    await expectLater(
        api.send('POST', '/enrollments',
            key: 'original-key', clientRequestId: clientRequestId),
        throwsA(isA<ApiFailure>()));
    await expectLater(
        api.send('POST', '/enrollments',
            key: 'original-key', clientRequestId: secondClientRequestId),
        throwsA(isA<ApiFailure>().having(
            (failure) => failure.code, 'code', 'PENDING_OPERATION_UNCHANGED')));
    expect(calls, 1);
  });

  for (final all in [false, true]) {
    test('${all ? 'all' : 'page'} propagates scope before the first GET',
        () async {
      var calls = 0;
      final api = Api(() async => MockClient((_) async {
            calls++;
            return http.Response('{"items":[],"nextCursor":null}', 200);
          }));
      await expectLater(
          all
              ? api.all('/private', isCurrent: () => false)
              : api.page('/private', isCurrent: () => false),
          throwsA(scopeChanged()));
      expect(calls, 0);
    });
  }

  test(
      'scope loss during pagination stops and never returns partial private data',
      () async {
    var current = true, calls = 0;
    final api = Api(() async => MockClient((_) async {
          calls++;
          if (calls == 1) {
            current = false;
            return http.Response(
                '{"items":[{"id":"old-private"}],"nextCursor":"more"}', 200);
          }
          return http.Response('{"items":[],"nextCursor":null}', 200);
        }));
    await expectLater(
        api.all('/private', isCurrent: () => current), throwsA(scopeChanged()));
    expect(calls, 1);
  });
}
