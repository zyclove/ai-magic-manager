import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth;

import 'api_scope_test.dart'
    show RecordingTransport, expiredCredentials, refreshedToken;

void main() {
  test('stale request finalization fails before exposing a body stream', () {
    final request = ScopeGuardedRequest(
        'POST', Uri.parse('https://app.example'),
        isCurrent: () => false)
      ..body = 'private';
    expect(request.finalize, throwsA(isA<ScopeChangedException>()));
    expect(request.finalized, isFalse);
  });

  test('transport checks a guarded request before invoking its raw delegate',
      () async {
    final raw = RecordingTransport();
    final client = ScopeGuardedClient(raw);
    addTearDown(client.close);
    final request = ScopeGuardedRequest(
        'DELETE', Uri.parse('https://app.example/enrollments/original'),
        isCurrent: () => false);
    await expectLater(
        client.send(request), throwsA(isA<ScopeChangedException>()));
    expect(raw.requests, isEmpty);
    expect(request.finalized, isFalse);
  });

  test('current request object is passed through without cloning', () async {
    final raw = RecordingTransport();
    final client = ScopeGuardedClient(raw);
    addTearDown(client.close);
    final request = ScopeGuardedRequest(
        'POST', Uri.parse('https://app.example'),
        isCurrent: () => true)
      ..body = jsonEncode({'name': 'original'});
    expect((await client.send(request)).statusCode, 200);
    expect(identical(raw.requests.single, request), isTrue);
    expect(request.finalized, isTrue);
  });

  test('plain OAuth token and existing unguarded requests remain unaffected',
      () async {
    final raw = RecordingTransport();
    final client = ScopeGuardedClient(raw);
    final request = http.Request('GET', Uri.parse('https://app.example/me'));
    expect((await client.send(request)).statusCode, 200);
    expect(identical(raw.requests.single, request), isTrue);
    client.close();
    expect(raw.closed, isTrue);
  });

  test('authentication owner accepts only its active unique identity', () {
    final owners = AuthenticationOwner();
    expect(owners.isCurrent(Object()), isFalse);
    final first = owners.begin();
    expect(owners.isCurrent(first), isTrue);
    final second = owners.begin();
    expect(identical(first, second), isFalse);
    expect(owners.isCurrent(first), isFalse);
    expect(owners.isCurrent(second), isTrue);
    owners.invalidate();
    expect(owners.isCurrent(second), isFalse);
    final third = owners.begin();
    expect(owners.isCurrent(first), isFalse);
    expect(owners.isCurrent(second), isFalse);
    expect(owners.isCurrent(third), isTrue);
  });

  test('old OAuth refresh after invalidation cannot save its credentials',
      () async {
    final owners = AuthenticationOwner();
    final first = owners.begin();
    final saved = <String>[];
    final raw = RecordingTransport();
    final client = oauth.Client(expiredCredentials(),
        identifier: 'guardian',
        basicAuth: false,
        httpClient: ScopeGuardedClient(raw),
        onCredentialsRefreshed: (credentials) => owners.saveIfCurrent(
            first, () => saved.add(credentials.accessToken)));
    addTearDown(client.close);
    final refresh = client.refreshCredentials();
    await raw.tokenStarted.future;
    owners.invalidate();
    raw.tokenReply.complete(refreshedToken());
    await refresh;
    expect(client.credentials.accessToken, 'fresh-access');
    expect(saved, isEmpty);
  });

  test('same-account workspace changes do not invalidate authentication owner',
      () async {
    final owners = AuthenticationOwner();
    final identity = owners.begin();
    var workspaceEpoch = 1;
    final capturedWorkspace = workspaceEpoch;
    final saved = <String>[];
    final raw = RecordingTransport();
    final client = oauth.Client(expiredCredentials(),
        identifier: 'guardian',
        basicAuth: false,
        httpClient: ScopeGuardedClient(raw),
        onCredentialsRefreshed: (credentials) => owners.saveIfCurrent(
            identity, () => saved.add(credentials.accessToken)));
    addTearDown(client.close);
    final refresh = client.refreshCredentials();
    await raw.tokenStarted.future;
    workspaceEpoch++;
    workspaceEpoch++;
    expect(workspaceEpoch == capturedWorkspace, isFalse);
    raw.tokenReply.complete(refreshedToken());
    await refresh;
    expect(saved, ['fresh-access']);
    expect(owners.isCurrent(identity), isTrue);
  });

  test('a replacement owner blocks old saves and permits current saves', () {
    final owners = AuthenticationOwner();
    final first = owners.begin();
    final second = owners.begin();
    final saved = <String>[];
    owners.saveIfCurrent(first, () => saved.add('old'));
    owners.saveIfCurrent(second, () => saved.add('current'));
    expect(saved, ['current']);
  });
}
