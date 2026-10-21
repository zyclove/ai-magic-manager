import 'dart:async';
import 'dart:convert';
import 'package:child/core/environment.dart';
import 'package:child/core/family_access.dart';
import 'package:child/core/help_requests.dart';
import 'package:child/core/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/identity_fixture.dart';

class _Store implements ChildHelpStore {
  final values = <String, String>{};
  bool failWrite = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('private storage failure');
    values[key] = value;
  }
}

void main() {
  late IdentityFixture identity;
  late ChildSession session;
  late _Store store;
  late FamilyAccessCoordinator coordinator;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  var synchronized = 0;
  Map<String, dynamic> reply([Map<String, dynamic> changes = const {}]) {
    final pending = jsonDecode(store.values.values.single) as Map;
    final body = pending['body'] as Map;
    return {
      'id': body['requestId'],
      'subjectId': '99999999-9999-4999-8999-999999999999',
      'deviceId': IdentityFixture.device,
      'state': 'PENDING',
      'requestedSeconds': body['requestedSeconds'],
      'grantedSeconds': null,
      'reason': body['reason'] ?? '',
      'expiresAt': identity.clock + 3600000,
      'notAfter': null,
      'version': 0,
      ...changes
    };
  }

  FamilyAccessCoordinator create() => FamilyAccessCoordinator(
      session: session,
      environment: ChildEnvironment(
          apiRoot: Uri.parse('https://service.example/api/v1')),
      store: store,
      nowMillis: () => identity.clock,
      afterApproval: () async {
        synchronized++;
      },
      client: MockClient((request) async {
        requests.add(request);
        return handler(request);
      }));
  Matcher failure(String code) =>
      throwsA(isA<FamilyAccessFailure>().having((e) => e.code, 'code', code));
  setUp(() async {
    identity = IdentityFixture();
    await identity.activate();
    session = identity.session();
    await session.initialize();
    store = _Store();
    requests = [];
    synchronized = 0;
    handler = (_) async => http.Response(jsonEncode(reply()), 200,
        headers: {'content-type': 'application/json'});
    coordinator = create();
  });
  tearDown(() {
    coordinator.close();
    session.dispose();
    identity.close();
  });

  test('original UUID and body are durable before family request HTTP',
      () async {
    Map? prepared;
    handler = (request) async {
      prepared = jsonDecode(store.values.values.single) as Map;
      return http.Response(jsonEncode(reply()), 200,
          headers: {'content-type': 'application/json'});
    };
    final result = await coordinator.submit(300, reason: '完成这一局');
    final request = requests.single;
    expect(prepared!['phase'], 'PREPARED');
    expect(jsonDecode(request.body), prepared!['body']);
    expect(request.url.path, '/api/v1/device-api/family/access-requests');
    expect(request.headers['authorization'], 'Bearer ${'b' * 43}');
    expect(request.followRedirects, isFalse);
    expect(result.confirmed, isTrue);
    expect(result.state, 'PENDING');
    expect(synchronized, 0);
    expect((await coordinator.restore())!.requestId, result.requestId);
  });
  test('failed durable preparation prevents any POST', () async {
    store.failWrite = true;
    await expectLater(
        coordinator.submit(300), failure('FAMILY_ACCESS_STORAGE_UNAVAILABLE'));
    expect(requests, isEmpty);
  });
  test('lost response restores then GET recovers before retrying original POST',
      () async {
    handler = (_) async => throw http.ClientException('offline');
    await expectLater(coordinator.submit(300, reason: '原申请'),
        failure('FAMILY_ACCESS_NETWORK_UNKNOWN'));
    final original = jsonDecode(requests.single.body);
    coordinator.close();
    coordinator = create();
    requests.clear();
    final restored = await coordinator.restore();
    expect(restored!.phase, 'PREPARED');
    expect(requests, isEmpty);
    handler = (request) async {
      if (request.method == 'GET') return http.Response('{}', 404);
      return http.Response(jsonEncode(reply()), 200,
          headers: {'content-type': 'application/json'});
    };
    final recovered = await coordinator.retry();
    expect(requests.map((r) => r.method), ['GET', 'POST']);
    expect(jsonDecode(requests.last.body), original);
    expect(requests.first.url.path.endsWith('/${restored.requestId}'), isTrue);
    expect(recovered.requestId, restored.requestId);
  });
  test('uncertain lookup never creates a second POST or request UUID',
      () async {
    handler = (_) async => throw http.ClientException('offline');
    await expectLater(
        coordinator.submit(300), failure('FAMILY_ACCESS_NETWORK_UNKNOWN'));
    final before = store.values.values.single;
    requests.clear();
    handler = (_) async => http.Response('{}', 503);
    await expectLater(
        coordinator.retry(), failure('FAMILY_ACCESS_SERVER_UNAVAILABLE'));
    expect(requests.map((r) => r.method), ['GET']);
    expect(store.values.values.single, before);
  });
  test(
      'approved cloud receipt only requests signed configuration synchronization',
      () async {
    await coordinator.submit(300);
    handler = (_) async => http.Response(
        jsonEncode(reply({
          'state': 'APPROVED',
          'grantedSeconds': 120,
          'notAfter': identity.clock + 120000,
          'version': 1
        })),
        200,
        headers: {'content-type': 'application/json'});
    final approved = await coordinator.refresh();
    expect(approved!.state, 'APPROVED');
    expect(approved.notAfter, identity.clock + 120000);
    expect(synchronized, 1);
  });
  test('mismatched device cannot confirm or apply an approval', () async {
    handler = (_) async => http.Response(
        jsonEncode(reply({'deviceId': IdentityFixture.tenant})), 200,
        headers: {'content-type': 'application/json'});
    await expectLater(
        coordinator.submit(300), failure('FAMILY_ACCESS_RESPONSE_INVALID'));
    expect((await coordinator.restore())!.phase, 'PREPARED');
    expect(synchronized, 0);
  });
  test(
      'background epoch discards late approval while preserving original intent',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    handler = (_) async {
      entered.complete();
      await release.future;
      return http.Response(
          jsonEncode(reply({
            'state': 'APPROVED',
            'grantedSeconds': 120,
            'notAfter': identity.clock + 120000,
            'version': 1
          })),
          200,
          headers: {'content-type': 'application/json'});
    };
    final operation = coordinator.submit(300);
    await entered.future;
    coordinator.pause();
    release.complete();
    await expectLater(operation, failure('FAMILY_ACCESS_CONTEXT_CHANGED'));
    expect((await coordinator.restore())!.phase, 'PREPARED');
    expect(synchronized, 0);
  });
  test('corrupt encrypted journal cannot be replaced with a new request',
      () async {
    store.values[coordinator.scopeKey] = '{broken';
    await expectLater(
        coordinator.submit(300), failure('FAMILY_ACCESS_LOCAL_RECORD_INVALID'));
    expect(requests, isEmpty);
  });
  test('invalid duration or overlong reason cannot reach network', () async {
    for (final seconds in [0, 59, 3601]) {
      await expectLater(coordinator.submit(seconds),
          failure('INVALID_FAMILY_ACCESS_REQUEST'));
    }
    await expectLater(coordinator.submit(300, reason: 'x' * 301),
        failure('INVALID_FAMILY_ACCESS_REQUEST'));
    expect(requests, isEmpty);
  });
  test('feature scope denial does not revoke a valid device credential',
      () async {
    handler = (_) async => http.Response('{}', 403);
    await expectLater(
        coordinator.submit(300), failure('FAMILY_ACCESS_UNAVAILABLE'));
    expect(await identity.identity.activeCredential(), 'b' * 43);
  });
  test('authentication rejection blocks the rejected original credential',
      () async {
    handler = (_) async => http.Response('{}', 401);
    await expectLater(
        coordinator.submit(300), failure('DEVICE_CREDENTIAL_UNAVAILABLE'));
    expect(await identity.identity.activeCredential(), isNull);
  });
}
