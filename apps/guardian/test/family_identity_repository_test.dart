import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/family_identity_repository.dart';
import 'family_identity_configuration_test.dart';

http.Response identityReply(Object value, {int status = 200}) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json'});

void main() {
  test('status reads the actual backend status route', () async {
    final sent = <http.Request>[];
    final repository = FamilyIdentityRepository(
        api: Api(
            () async => MockClient((request) async {
                  sent.add(request);
                  return identityReply(identityStatusFixture());
                }),
            baseUrl: 'https://fixture.invalid/api/v1'),
        current: () => true);
    await repository.status();
    expect(sent.single.url.path, '/api/v1/platform/identity-providers/status');
  });
  test(
      'saving secrets bypasses the generic pending-body cache and never follows redirects',
      () async {
    final sent = <http.Request>[];
    final repository = FamilyIdentityRepository(
        api: Api(
            () async => MockClient((request) async {
                  sent.add(request);
                  return identityReply(identityVersionFixture());
                }),
            baseUrl: 'https://fixture.invalid'),
        current: () => true);
    await repository.saveVersion(identityVersionId, 0,
        IdentityProviderVersion.parse(identityVersionFixture()).settings,
        replacements: {'wechatAppSecret': 'b' * 32});
    expect(sent.single.url.path, '/platform/identity-providers/versions');
    expect(sent.single.followRedirects, isFalse);
    expect(sent.single.headers.containsKey('Idempotency-Key'), isFalse);
    expect(jsonDecode(sent.single.body)['replacements'],
        {'wechatAppSecret': 'b' * 32});
  });
  test('mismatched version and acceptance identities are hidden', () async {
    final repository = FamilyIdentityRepository(
        api: Api(
            () async => MockClient((request) async => identityReply(
                request.url.path.contains('acceptance-runs')
                    ? identityAcceptanceFixture()
                    : identityVersionFixture())),
            baseUrl: 'https://fixture.invalid'),
        current: () => true);
    await expectLater(
        repository.version(identityOperationId), throwsA(isA<ApiFailure>()));
    await expectLater(repository.acceptanceRun(identityVersionId),
        throwsA(isA<ApiFailure>()));
  });
  test('revoked scope blocks dispatch and hides late responses', () async {
    var current = false, sent = 0;
    final repository = FamilyIdentityRepository(
        api: Api(
            () async => MockClient((request) async {
                  sent++;
                  current = false;
                  return identityReply(identityStatusFixture());
                }),
            baseUrl: 'https://fixture.invalid'),
        current: () => current);
    await expectLater(repository.status(), throwsA(isA<ApiFailure>()));
    expect(sent, 0);
    current = true;
    await expectLater(repository.status(), throwsA(isA<ApiFailure>()));
    expect(sent, 1);
  });
  test('upstream arbitrary error text is not exposed', () async {
    final repository = FamilyIdentityRepository(
        api: Api(
            () async => MockClient((request) async => identityReply(
                {'errorCode': 'SECRET_RETURNED_BY_BAD_UPSTREAM'},
                status: 500)),
            baseUrl: 'https://fixture.invalid'),
        current: () => true);
    try {
      await repository.status();
      fail('must reject');
    } catch (failure) {
      expect('$failure', isNot(contains('SECRET_RETURNED')));
    }
  });
}
