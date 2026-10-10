import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/commercial_entitlements.dart';
import 'package:guardian/core/commercial_repository.dart';

const tenant = '11111111-1111-1111-1111-111111111111';
const root = '/tenants/$tenant';

Json fixture({int version = 3, int base = 5, int addOn = 2}) => {
      'tenantId': tenant,
      'version': version,
      'evaluatedAt': 1791619200000,
      'activeSourceCount': 2,
      'baseDeviceCapacity': base,
      'addOnDeviceCapacity': addOn,
      'paidDeviceCapacity': base + addOn,
      'features': ['ADVANCED_SCHEDULES', 'MANAGED_ANDROID'],
      'technicalCapabilityIndependent': true
    };

TypeMatcher<ApiFailure> failure(String code) =>
    isA<ApiFailure>().having((error) => error.code, 'code', code);

void main() {
  test(
      'reads exact tenant route without treating paid rights as device authority',
      () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(
          request.url.path, '/api/v1/tenants/$tenant/commercial-entitlements');
      expect(request.followRedirects, isFalse);
      return http.Response(jsonEncode(fixture()), 200,
          headers: {'content-type': 'application/json'});
    });
    final repository = CommercialRepository(
        api: Api(() async => client, baseUrl: 'http://localhost/api/v1'),
        root: root,
        current: () => true);
    final rights = await repository.load();
    expect(rights.paidDeviceCapacity, 7);
    expect(rights.has('MANAGED_ANDROID'), isTrue);
    expect(rights.technicalCapabilityIndependent, isTrue);
    expect(commercialFeatureLabel('MANAGED_ANDROID'), contains('权益'));
  });

  test('refuses a stale workspace before sending a request', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response(jsonEncode(fixture()), 200,
          headers: {'content-type': 'application/json'});
    });
    final repository = CommercialRepository(
        api: Api(() async => client, baseUrl: 'http://localhost/api/v1'),
        root: root,
        current: () => false);
    await expectLater(repository.load(), throwsA(failure('WORKSPACE_CHANGED')));
    expect(calls, 0);
  });

  test('rejects tenant substitution, impossible totals and unknown features',
      () {
    expect(
        () => CommercialEntitlements.parse(
            {...fixture(), 'tenantId': 'other'}, tenant),
        throwsA(failure('INVALID_COMMERCIAL_RESPONSE')));
    expect(
        () => CommercialEntitlements.parse(
            {...fixture(), 'paidDeviceCapacity': 99}, tenant),
        throwsA(failure('INVALID_COMMERCIAL_RESPONSE')));
    expect(
        () => CommercialEntitlements.parse({
              ...fixture(),
              'features': ['NEW_FLAG']
            }, tenant),
        throwsA(failure('INVALID_COMMERCIAL_RESPONSE')));
    expect(
        () => CommercialEntitlements.parse(
            {...fixture(), 'technicalCapabilityIndependent': false}, tenant),
        throwsA(failure('INVALID_COMMERCIAL_RESPONSE')));
  });

  test('rejects HTML, malformed and oversized commercial responses', () async {
    Future<void> check(http.Response response) async {
      final client = MockClient((_) async => response);
      final repository = CommercialRepository(
          api: Api(() async => client, baseUrl: 'http://localhost/api/v1'),
          root: root,
          current: () => true);
      await expectLater(
          repository.load(), throwsA(failure('INVALID_COMMERCIAL_RESPONSE')));
    }

    await check(http.Response('<html>fake</html>', 200,
        headers: {'content-type': 'text/html'}));
    await check(
        http.Response('{', 200, headers: {'content-type': 'application/json'}));
    await check(http.Response(' ' * 17000, 200,
        headers: {'content-type': 'application/json'}));
  });

  test('preserves permission failures without exposing untrusted response body',
      () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({'errorCode': 'SCOPE_DENIED', 'secret': 'do-not-display'}),
        403,
        headers: {'content-type': 'application/json'}));
    final repository = CommercialRepository(
        api: Api(() async => client, baseUrl: 'http://localhost/api/v1'),
        root: root,
        current: () => true);
    await expectLater(repository.load(), throwsA(failure('SCOPE_DENIED')));
  });
}
