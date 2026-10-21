import 'dart:convert';
import 'package:child/core/assisted_reporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/identity_fixture.dart';

void main() {
  late IdentityFixture identity;
  setUp(() async {
    identity = IdentityFixture();
    await identity.activate();
  });
  tearDown(() => identity.close());
  Map<String, dynamic> snapshot() => {
        'tenantId': IdentityFixture.tenant,
        'deviceId': IdentityFixture.device,
        'registrationId': IdentityFixture.registration,
        'policyId': '55555555-5555-4555-8555-555555555555',
        'versionId': '66666666-6666-4666-8666-666666666666',
        'sourceSequence': 2,
        'reportSequence': 7,
        'observedAt': identity.clock,
        'health': 'ACTIVE',
        'limitStatus': 'ALLOW',
        'reason': 'within_rules',
        'remainingSeconds': 300,
        'optedIn': true,
        'usageGranted': true,
        'accessibilityConnected': true,
        'systemEnforced': false,
        'manufacturer': 'Example',
        'model': 'Test Phone',
        'apiLevel': 35,
        'interventionStatus': 'HOME_RETURNED',
      };
  test('reports only current enrolled native observation through device auth',
      () async {
    http.Request? received;
    final client = MockClient((request) async {
      received = request;
      return http.Response(
          jsonEncode({
            'accepted': true,
            'evidenceStatus': 'AGENT_REPORTED_UNVERIFIED',
            'receivedAt': identity.clock
          }),
          200);
    });
    final reporter = AssistedExecutionReporter(
        identity: identity.identity,
        apiRoot: Uri.parse('https://service.example/api/v1'),
        client: client,
        nowMillis: () => identity.clock);
    final input = snapshot()..['privatePackage'] = 'must.not.upload';
    expect(await reporter.upload(input), isTrue);
    expect(received!.url.path,
        '/api/v1/device-api/family/assisted-execution-reports');
    expect(received!.headers['authorization'], 'Bearer ${'b' * 43}');
    expect(jsonDecode(received!.body), snapshot());
  });
  test('wrong registration or stale evidence is never uploaded', () async {
    var requests = 0;
    final reporter = AssistedExecutionReporter(
        identity: identity.identity,
        apiRoot: Uri.parse('https://service.example/api/v1'),
        nowMillis: () => identity.clock,
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }));
    expect(
        await reporter
            .upload(snapshot()..['registrationId'] = IdentityFixture.device),
        isFalse);
    expect(
        await reporter
            .upload(snapshot()..['observedAt'] = identity.clock - 300001),
        isFalse);
    expect(requests, 0);
  });
  test('authenticated rejection invalidates the rejected device credential',
      () async {
    final reporter = AssistedExecutionReporter(
        identity: identity.identity,
        apiRoot: Uri.parse('https://service.example/api/v1'),
        nowMillis: () => identity.clock,
        client: MockClient((_) async => http.Response('{}', 401)));
    expect(await reporter.upload(snapshot()), isFalse);
    expect(await identity.identity.activeCredential(), isNull);
  });
  test('family feature 403 preserves the valid institutional credential',
      () async {
    var cleared = false;
    final reporter = AssistedExecutionReporter(
        identity: identity.identity,
        apiRoot: Uri.parse('https://service.example/api/v1'),
        nowMillis: () => identity.clock,
        onCredentialRejected: () async { cleared = true; },
        client: MockClient((_) async => http.Response('{}', 403)));
    expect(await reporter.upload(snapshot()), isFalse);
    expect(await identity.identity.activeCredential(), isNotNull);
    expect(cleared, isFalse);
  });
}
