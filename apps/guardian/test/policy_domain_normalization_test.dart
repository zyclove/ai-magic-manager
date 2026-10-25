import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_domain_check.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _reply(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json'});
Future<String> _normalize(Api api, String value) =>
    normalizePolicyDomain(api, root: '/tenants/current-tenant', domain: value);

void main() {
  test('normalization needs no saved draft or write recovery identifiers',
      () async {
    late http.Request sent;
    final api = Api(() async => MockClient((request) async {
          sent = request;
          return _reply({'canonicalDomain': 'example.com'});
        }));
    expect(await _normalize(api, '  EXAMPLE.COM  '), 'example.com');
    expect(sent.method, 'POST');
    expect(sent.url.path, endsWith('/policy-domain-normalizations'));
    expect(sent.url.query, isEmpty);
    expect(jsonDecode(sent.body), {'domain': 'EXAMPLE.COM'});
    expect(sent.headers.containsKey('Idempotency-Key'), isFalse);
    expect(sent.headers.containsKey('If-Match'), isFalse);
  });

  test('Unicode input uses the shared server normalizer', () async {
    final api = Api(() async => MockClient((request) async {
          expect(jsonDecode(request.body), {'domain': 'BÜCHER.example'});
          return _reply({'canonicalDomain': 'xn--bcher-kva.example'});
        }));
    expect(await _normalize(api, 'BÜCHER.example'), 'xn--bcher-kva.example');
  });

  test('bad canonical names and mismatched ASCII responses are rejected',
      () async {
    for (final value in <Object>[
      {'canonicalDomain': '-host.example'},
      {'canonicalDomain': 'other.example'},
      {'canonicalDomain': 'EXAMPLE.COM'},
      {'canonicalDomain': 'example.com', 'extra': 'not allowed'},
      {'canonicalDomain': null},
      [],
    ]) {
      final api = Api(() async => MockClient((_) async => _reply(value)));
      await expectLater(
          _normalize(api, 'example.com'),
          throwsA(isA<ApiFailure>().having(
              (e) => e.code, 'code', 'INVALID_DOMAIN_NORMALIZATION_RESPONSE')));
    }
  });

  test('invalid input never starts a request', () async {
    var sends = 0;
    final api = Api(() async => MockClient((_) async {
          sends++;
          return _reply({'canonicalDomain': 'example.com'});
        }));
    for (final value in [
      '',
      'https://example.com',
      '*.example.com',
      'a' * 254
    ]) {
      await expectLater(
          _normalize(api, value),
          throwsA(isA<ApiFailure>()
              .having((e) => e.code, 'code', 'INVALID_DOMAIN')));
    }
    expect(sends, 0);
  });

  test('scope loss while authentication waits prevents normalization dispatch',
      () async {
    var current = true, sends = 0;
    final authenticated = Completer<http.Client>();
    final api = Api(() => authenticated.future).scoped(() => current);
    final future = _normalize(api, 'example.com');
    current = false;
    authenticated.complete(MockClient((_) async {
      sends++;
      return _reply({'canonicalDomain': 'example.com'});
    }));
    await expectLater(
        future,
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'WORKSPACE_CHANGED')));
    expect(sends, 0);
  });

  test('a failed read can be corrected without locking a write payload',
      () async {
    var calls = 0;
    final api = Api(() async => MockClient((request) async {
          calls++;
          if (calls == 1) throw http.ClientException('unavailable');
          expect(jsonDecode(request.body), {'domain': 'corrected.example'});
          return _reply({'canonicalDomain': 'corrected.example'});
        }));
    await expectLater(
        _normalize(api, 'original.example'),
        throwsA(
            isA<ApiFailure>().having((e) => e.code, 'code', 'NETWORK_ERROR')));
    expect(await _normalize(api, 'corrected.example'), 'corrected.example');
    expect(calls, 2);
  });
}
