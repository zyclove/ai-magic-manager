import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_publication.dart';
import 'package:guardian/core/policy_publication_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

PublicationOwner _owner() => PublicationOwner(
    actorId: 'actor-a',
    tenantId: 'tenant-a',
    apiBaseUrl: 'https://fixture.invalid/api/v1',
    issuer: 'https://issuer.invalid/realm');
PublicationPending _pending({int expires = 2000}) => PublicationPending(
    intent: PublicationIntent(
        owner: _owner(),
        policyId: 'policy-a',
        revision: 7,
        previewId: '11111111-1111-4111-8111-111111111111',
        previewHash: 'a' * 64,
        previewExpiresAt: expires,
        createdAt: 0,
        idempotencyKey: '22222222-2222-4222-8222-222222222222'));
Json _receipt(
        {String mode = 'CONFIGURE_ONLY',
        String state = 'CONFIGURED_NOT_ENFORCED'}) =>
    {
      'id': 'publication-a',
      'versionId': 'version-a',
      'sequence': 1,
      'mode': mode,
      'state': state,
      'createdAt': 1000,
    };
http.Response _reply(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json'});
PolicyPublicationRepository _repo(http.Client client,
        {bool Function()? current,
        DateTime Function()? clock,
        void Function(ApiFailure)? onDenied}) =>
    PolicyPublicationRepository(
        api: Api(() async => client, baseUrl: _owner().apiBaseUrl),
        owner: _owner(),
        policyId: 'policy-a',
        current: current ?? () => true,
        clock: clock ?? () => DateTime.fromMillisecondsSinceEpoch(1000),
        onDenied: onDenied);

void main() {
  test(
      'POST uses the exact immutable intent and only accepts a complete 201 receipt',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return _reply(_receipt(), 201);
    });
    final record = _pending();
    final result = await _repo(client).publish(record);
    expect(result.state, 'CONFIGURED_NOT_ENFORCED');
    expect(requests, hasLength(1));
    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.url.path,
        '/api/v1/tenants/tenant-a/policies/policy-a/publications');
    expect(request.headers['if-match'], '"7"');
    expect(request.headers['idempotency-key'], record.intent.idempotencyKey);
    expect(jsonDecode(request.body), record.intent.body);
  });

  for (final response in [
    <String, dynamic>{},
    {..._receipt(), 'extra': true},
    _receipt(mode: 'ENFORCE', state: 'PENDING_EXECUTION')
  ]) {
    test(
        'invalid 201 receipt ${jsonEncode(response)} cannot confirm publication',
        () async {
      final client = MockClient((_) async => _reply(response, 201));
      await expectLater(
          _repo(client).publish(_pending()),
          throwsA(isA<ApiFailure>().having((error) => error.code, 'code',
              'INVALID_POLICY_PUBLICATION_RESPONSE')));
    });
  }

  test('a 200 POST is not the declared 201 creation contract', () async {
    final client = MockClient((_) async => _reply(_receipt()));
    await expectLater(
        _repo(client).publish(_pending()), throwsA(isA<ApiFailure>()));
  });

  test(
      'expired original preview still permits exact mode-bound GET without POST',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return _reply(_receipt());
    });
    final record = _pending(expires: 100);
    expect(await _repo(client).lookup(record), isA<PublicationReceipt>());
    expect(requests, hasLength(1));
    expect(requests.single.method, 'GET');
    expect(requests.single.body, isEmpty);
    expect(requests.single.url.path,
        '/api/v1/tenants/tenant-a/policies/policy-a/publication-results/${record.intent.idempotencyKey}');
    expect(requests.single.url.queryParameters, {
      'revision': '7',
      'previewId': record.intent.previewId,
      'previewHash': record.intent.previewHash,
      'mode': 'CONFIGURE_ONLY',
    });
  });

  test('only the exact unavailable lookup is an inconclusive null', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return _reply(
          {'errorCode': 'POLICY_PUBLICATION_RESULT_UNAVAILABLE'}, 404);
    });
    expect(await _repo(client).lookup(_pending()), isNull);
    expect(requests.single.method, 'GET');
    final other =
        MockClient((_) async => _reply({'errorCode': 'NOT_FOUND'}, 404));
    await expectLater(
        _repo(other).lookup(_pending()), throwsA(isA<ApiFailure>()));
  });

  test('a trusted POST rejection is tied to the exact attempted durable record',
      () async {
    final client =
        MockClient((_) async => _reply({'errorCode': 'REAUTH_REQUIRED'}, 401));
    final record = _pending();
    await expectLater(
        _repo(client).publish(record),
        throwsA(isA<PublicationReauthenticationRequired>()
            .having((failure) => failure.record, 'attempt', record)));
    await expectLater(
        _repo(client).lookup(record),
        throwsA(isA<ApiFailure>()
            .having((failure) => failure.code, 'code', 'REAUTH_REQUIRED')));
  });

  test(
      'client acquisition 401 is not a trusted rejection from the publication POST',
      () async {
    final repository = PolicyPublicationRepository(
        api: Api(() async {
          throw const ApiFailure(401, 'REAUTH_REQUIRED');
        }, baseUrl: _owner().apiBaseUrl),
        owner: _owner(),
        policyId: 'policy-a',
        current: () => true,
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000));
    await expectLater(
        repository.publish(_pending()), throwsA(isA<ApiFailure>()));
  });

  test('non JSON 401 cannot permit another mutation', () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({'errorCode': 'REAUTH_REQUIRED'}), 401,
        headers: {'content-type': 'text/plain'}));
    await expectLater(
        _repo(client).publish(_pending()), throwsA(isA<ApiFailure>()));
  });

  test('a hard HTTP denial permanently closes child and ancestor repositories',
      () async {
    var requests = 0, denied = 0;
    final client = MockClient((_) async {
      requests++;
      return _reply({'errorCode': 'ACCESS_DENIED'}, 403);
    });
    final parent = _repo(client, onDenied: (_) => denied++);
    final child = parent.scoped(() => true);
    await expectLater(child.lookup(_pending()), throwsA(isA<ApiFailure>()));
    expect(parent.isCurrent, isFalse);
    expect(child.isCurrent, isFalse);
    expect(denied, 1);
    await expectLater(parent.lookup(_pending()), throwsA(isA<ApiFailure>()));
    expect(requests, 1);
  });

  test(
      'scope revoked while acquiring the borrowed client blocks physical dispatch',
      () async {
    var current = true, requests = 0;
    final waiting = Completer<http.Client>();
    final client = MockClient((_) async {
      requests++;
      return _reply(_receipt(), 201);
    });
    final repository = PolicyPublicationRepository(
        api: Api(() => waiting.future, baseUrl: _owner().apiBaseUrl),
        owner: _owner(),
        policyId: 'policy-a',
        current: () => current,
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000));
    final operation = repository.publish(_pending());
    current = false;
    expect(repository.isCurrent, isFalse);
    current = true;
    waiting.complete(client);
    await expectLater(operation, throwsA(isA<ApiFailure>()));
    expect(requests, 0);
    expect(repository.isCurrent, isFalse);
  });

  test(
      'preview expiry during client acquisition blocks POST while lookup authority survives',
      () async {
    var now = 1000, requests = 0;
    final waiting = Completer<http.Client>();
    final client = MockClient((_) async {
      requests++;
      return _reply(_receipt());
    });
    var first = true;
    final repository = PolicyPublicationRepository(
        api: Api(() {
          if (first) {
            first = false;
            return waiting.future;
          }
          return Future.value(client);
        }, baseUrl: _owner().apiBaseUrl),
        owner: _owner(),
        policyId: 'policy-a',
        current: () => true,
        clock: () => DateTime.fromMillisecondsSinceEpoch(now));
    final record = _pending();
    final operation = repository.publish(record);
    now = 2000;
    waiting.complete(client);
    await expectLater(
        operation,
        throwsA(isA<ApiFailure>()
            .having((error) => error.code, 'code', 'PREVIEW_EXPIRED')));
    expect(requests, 0);
    expect(repository.isCurrent, isTrue);
    expect(await repository.lookup(record), isA<PublicationReceipt>());
    expect(requests, 1);
  });
}
