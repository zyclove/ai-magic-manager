import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_domain_check.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Json _rule(String id, String effect, [String domain = 'example.com']) =>
    {'id': id, 'kind': 'DOMAIN_ACCESS', 'effect': effect, 'domain': domain};
Json _draft() => {
      'id': 'policy-one',
      'revision': 7,
      'rules': [_rule('rule_b', 'ALLOW'), _rule('rule_a', 'DENY')]
    };
Json _result(
        {String domain = 'example.com',
        String effect = 'DENY',
        List<String> ids = const ['rule_a', 'rule_b']}) =>
    {
      'policyId': 'policy-one',
      'draftRevision': 7,
      'canonicalDomain': domain,
      'matchingRuleIds': ids,
      'predictedEffect': effect,
      'effectiveEffect': null,
      'matchMode': 'EXACT_DOMAIN',
      'executionStatus': 'NOT_EVALUATED'
    };
http.Response _reply(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});
Future<PolicyDomainEvaluation> _check(Api api,
        {Json? draft, String domain = 'example.com'}) =>
    evaluatePolicyDomain(api,
        root: '/tenants/tenant-one', draft: draft ?? _draft(), domain: domain);

void main() {
  test('invalid prefixes cannot pass whole domain or rule identifier checks',
      () async {
    for (final domain in ['-host.example', '!host.example']) {
      final draft = _draft()..['rules'] = [];
      final api = Api(() async => MockClient((_) async =>
          _reply(_result(domain: domain, effect: 'NO_MATCH', ids: []))));
      await expectLater(
          _check(api, draft: draft, domain: domain),
          throwsA(isA<ApiFailure>()
              .having((e) => e.code, 'code', 'INVALID_DOMAIN_CHECK_RESPONSE')));
    }
    var sends = 0;
    final draft = _draft()..['rules'] = [_rule('1rule', 'ALLOW')];
    final api = Api(() async => MockClient((_) async {
          sends++;
          return _reply(_result(effect: 'ALLOW', ids: ['1rule']));
        }));
    await expectLater(
        _check(api, draft: draft),
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'INVALID_DOMAIN_CHECK_RESPONSE')));
    expect(sends, 0);
  });
  test('check binds the exact draft version and keeps domains out of URLs',
      () async {
    late http.Request sent;
    final api = Api(() async => MockClient((request) async {
          sent = request;
          return _reply(_result());
        }));
    final result = await _check(api, domain: '  EXAMPLE.COM  ');
    expect(sent.method, 'POST');
    expect(sent.url.path, endsWith('/policies/policy-one/domain-evaluations'));
    expect(sent.url.query, isEmpty);
    expect(sent.headers['If-Match'], '"7"');
    expect(sent.headers.containsKey('Idempotency-Key'), isFalse);
    expect(jsonDecode(sent.body), {'domain': 'EXAMPLE.COM'});
    expect(result.canonicalDomain, 'example.com');
    expect(result.predictedEffect, 'DENY');
    expect(result.matchingRuleIds, ['rule_a', 'rule_b']);
    expect(() => result.matchingRuleIds.add('other'), throwsUnsupportedError);
  });

  test('subdomains with no exact rule stay NO_MATCH instead of allowed',
      () async {
    final api = Api(() async => MockClient((_) async => _reply(
        _result(domain: 'sub.example.com', effect: 'NO_MATCH', ids: []))));
    final result = await _check(api, domain: 'sub.example.com');
    expect(result.predictedEffect, 'NO_MATCH');
    expect(result.matchingRuleIds, isEmpty);
  });

  test('IDN normalization is provided by the same server policy normalizer',
      () async {
    final draft = _draft()
      ..['rules'] = [_rule('books', 'ALLOW', 'xn--bcher-kva.example')];
    final api = Api(() async => MockClient((request) async {
          expect(jsonDecode(request.body), {'domain': 'BÜCHER.example'});
          return _reply(_result(
              domain: 'xn--bcher-kva.example',
              effect: 'ALLOW',
              ids: ['books']));
        }));
    final result = await _check(api, draft: draft, domain: 'BÜCHER.example');
    expect(result.canonicalDomain, 'xn--bcher-kva.example');
    expect(result.predictedEffect, 'ALLOW');
  });

  test('later changes to a borrowed draft cannot change the captured check',
      () async {
    final pending = Completer<http.Response>();
    final draft = _draft();
    final api = Api(() async => MockClient((_) => pending.future));
    final future = _check(api, draft: draft);
    draft['id'] = 'replacement';
    draft['revision'] = 8;
    (draft['rules'] as List).clear();
    pending.complete(_reply(_result()));
    expect((await future).matchingRuleIds, ['rule_a', 'rule_b']);
  });

  test('mismatched or execution-like results never become a rule prediction',
      () async {
    final invalid = <Json>[
      {..._result(), 'policyId': 'another-policy'},
      {..._result(), 'draftRevision': 8},
      {
        ..._result(),
        'matchingRuleIds': ['rule_b', 'rule_a']
      },
      {
        ..._result(),
        'matchingRuleIds': ['rule_a', 'rule_a']
      },
      {
        ..._result(),
        'matchingRuleIds': ['unrelated']
      },
      {..._result(), 'predictedEffect': 'ALLOW'},
      {..._result(), 'effectiveEffect': 'DENY'},
      {..._result(), 'executionStatus': 'APPLIED'},
      {..._result(), 'matchMode': 'INCLUDE_SUBDOMAINS'},
      {..._result(), 'canonicalDomain': 'other.example'},
      {..._result(), 'canonicalDomain': 'example.com\n'},
      {..._result(), 'unexpected': 'private-field'},
    ];
    for (final response in invalid) {
      final api = Api(() async => MockClient((_) async => _reply(response)));
      await expectLater(
          _check(api),
          throwsA(isA<ApiFailure>()
              .having((e) => e.code, 'code', 'INVALID_DOMAIN_CHECK_RESPONSE')));
    }
    final falseAllow = Api(() async => MockClient((_) async =>
        _reply(_result(domain: 'sub.example.com', effect: 'ALLOW', ids: []))));
    await expectLater(_check(falseAllow, domain: 'sub.example.com'),
        throwsA(isA<ApiFailure>()));
  });

  test('invalid input is rejected locally without dispatching a request',
      () async {
    var sends = 0;
    final api = Api(() async => MockClient((_) async {
          sends++;
          return _reply(_result());
        }));
    for (final value in [
      '',
      'https://example.com',
      'example.com/path',
      '*.example.com',
      'example.com:443',
      'a' * 254
    ]) {
      await expectLater(
          _check(api, domain: value),
          throwsA(isA<ApiFailure>()
              .having((e) => e.code, 'code', 'INVALID_DOMAIN')));
    }
    expect(sends, 0);
  });

  test('stale versions and authorization failures preserve the API failure',
      () async {
    for (final value in [
      (412, 'RESOURCE_VERSION_CONFLICT'),
      (403, 'SCOPE_DENIED')
    ]) {
      final api = Api(() async =>
          MockClient((_) async => _reply({'errorCode': value.$2}, value.$1)));
      await expectLater(
          _check(api),
          throwsA(isA<ApiFailure>()
              .having((e) => e.status, 'status', value.$1)
              .having((e) => e.code, 'code', value.$2)));
    }
  });
}
