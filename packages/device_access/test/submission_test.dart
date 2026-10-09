import 'dart:convert';
import 'package:device_access/device_access.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'fixtures.dart' as f;

Map<String, dynamic> submission([Map<String, dynamic> changes = const {}]) => {
      'id': f.request,
      'subjectId': f.subject,
      'deviceId': f.device,
      'registrationId': f.registration,
      'policyId': f.policy,
      'baseVersionId': f.version,
      'applicationId': f.application,
      'ruleIds': ['reading'],
      'requestedWindowSeconds': 600,
      'reason': '继续阅读',
      'state': 'PENDING',
      'requestExpiresAt': f.now + 1800000,
      'grantedWindowSeconds': null,
      'issuedAt': null,
      'absoluteNotAfter': null,
      'reasonCode': null,
      'executionState': 'NOT_ENFORCED',
      'version': 0,
      'createdAt': f.now,
      ...changes
    };
AccessDeviceContext context() => AccessDeviceContext.fromJson({
      'tenantId': f.tenant,
      'subjectId': f.subject,
      'deviceId': f.device,
      'registrationId': f.registration
    });
AccessSubmissionInput input() => AccessSubmissionInput(
    policyId: f.policy,
    baseVersionId: f.version,
    applicationId: f.application,
    ruleIds: ['reading'],
    requestedWindowSeconds: 600,
    reason: '继续阅读');
void main() {
  test(
      'submission is a scoped authority fact and never an operating-system unlock',
      () {
    final value = AccessSubmission.fromJson(submission());
    value.requireContext(context());
    expect(value.state, 'PENDING');
    expect(value.version, 0);
    expect(value.systemEnforced, isFalse);
    expect(value.toString(), isNot(contains('继续阅读')));
    for (final change in <Map<String, dynamic>>[
      {'state': 'APPLIED'},
      {'executionState': 'ENFORCED'},
      {'version': 0.5},
      {'requestedWindowSeconds': 3601},
      {
        'ruleIds': ['reading', 'reading']
      },
      {'absoluteNotAfter': f.now + 1000},
      {'approverActorId': 'private'},
      {'state': 'APPROVED_PENDING_DELIVERY'},
      {'requestExpiresAt': f.now}
    ]) {
      expect(() => AccessSubmission.fromJson(submission(change)),
          throwsA(isA<AccessFailure>()));
    }
    expect(
        () => AccessSubmission.fromJson(submission({'deviceId': f.document}))
            .requireContext(context()),
        throwsA(isA<AccessFailure>()));
  });
  test('approved response retains the original bounded deadline', () {
    final value = AccessSubmission.fromJson(submission({
      'state': 'APPROVED_PENDING_DELIVERY',
      'version': 1,
      'grantedWindowSeconds': 300,
      'issuedAt': f.now + 1000,
      'absoluteNotAfter': f.now + 301000
    }));
    expect(value.absoluteNotAfter, f.now + 301000);
    expect(
        () => AccessSubmission.fromJson(submission({
              'state': 'APPROVED_PENDING_DELIVERY',
              'version': 1,
              'grantedWindowSeconds': 300,
              'issuedAt': f.now + 1000,
              'absoluteNotAfter': f.now + 302000
            })),
        throwsA(isA<AccessFailure>()));
  });
  test('input is immutable bounded and contains no credential-bound target',
      () {
    final value = input();
    expect(value.toJson().keys, isNot(contains('deviceId')));
    expect(() => value.ruleIds.add('other'), throwsUnsupportedError);
    expect(
        () => AccessSubmissionInput(
            policyId: f.policy,
            baseVersionId: f.version,
            applicationId: f.application,
            ruleIds: ['reading', 'reading'],
            requestedWindowSeconds: 60),
        throwsArgumentError);
    expect(value.toString(), isNot(contains('继续阅读')));
  });
  test('options preserve a cursor even when the filtered page is empty', () {
    final page = AccessSubmissionOptionsPage.fromJson(
        {'items': [], 'nextCursor': f.policy},
        after: null, limit: 1);
    expect(page.items, isEmpty);
    expect(page.nextCursor, f.policy);
    expect(
        () => AccessSubmissionOptionsPage.fromJson(
            {'items': [], 'nextCursor': f.policy},
            after: f.policy, limit: 1),
        throwsA(isA<AccessFailure>()));
  });
  test('transport creates with stable input and idempotency and checks binding',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((r) async {
      requests.add(r);
      return http.Response(jsonEncode(submission()), 201,
          headers: {'content-type': 'application/json'});
    });
    final t = DeviceAccessTransport(
        apiRoot: Uri.parse('https://device.invalid/api/v1'),
        credential: () async => 'A' * 43,
        client: client);
    addTearDown(t.close);
    addTearDown(client.close);
    final value = await t.createSubmission(input(),
        context: context(), idempotencyKey: 'stable-create');
    expect(value.id, f.request);
    expect(requests.single.url.path, '/api/v1/device-api/access-submissions');
    expect(requests.single.headers['Idempotency-Key'], 'stable-create');
    expect(jsonDecode(requests.single.body), input().toJson());
    expect(requests.single.headers['Authorization'], 'Bearer ${'A' * 43}');
  });
  test('mutation uncertainty is retained and there is no transparent resend',
      () async {
    var calls = 0;
    final client = MockClient((r) async {
      calls++;
      throw http.ClientException('Lost acknowledgement');
    });
    final t = DeviceAccessTransport(
        apiRoot: Uri.parse('https://device.invalid/api/v1'),
        credential: () async => 'A' * 43,
        client: client);
    addTearDown(t.close);
    addTearDown(client.close);
    await expectLater(
        t.createSubmission(input(),
            context: context(), idempotencyKey: 'stable'),
        throwsA(isA<AccessTransportFailure>()
            .having((e) => e.outcomeUnknown, 'outcomeUnknown', isTrue)));
    expect(calls, 1);
  });
  test('cancel sends a strong version and never contains administrator fields',
      () async {
    late http.Request request;
    final client = MockClient((r) async {
      request = r;
      return http.Response(
          jsonEncode(submission({
            'state': 'CANCELLED',
            'version': 1,
            'reasonCode': 'DEVICE_CANCELLED'
          })),
          200,
          headers: {'content-type': 'application/json'});
    });
    final t = DeviceAccessTransport(
        apiRoot: Uri.parse('https://device.invalid/api/v1'),
        credential: () async => 'A' * 43,
        client: client);
    addTearDown(t.close);
    addTearDown(client.close);
    final value = await t.cancelSubmission(f.request,
        context: context(), version: 0, idempotencyKey: 'stable-cancel');
    expect(value.state, 'CANCELLED');
    expect(request.headers['If-Match'], '"0"');
    expect(request.body, isEmpty);
    expect(request.url.path,
        '/api/v1/device-api/access-submissions/${f.request}/cancel');
  });
  test('authority state cannot carry contradictory grant fields', () {
    final approved = {
      'grantedWindowSeconds': 300,
      'issuedAt': f.now,
      'absoluteNotAfter': f.now + 300000
    };
    for (final state in ['PENDING', 'DENIED', 'CANCELLED', 'INVALIDATED']) {
      expect(
          () => AccessSubmission.fromJson(
              submission({...approved, 'state': state, 'version': 1})),
          throwsA(isA<AccessFailure>()));
    }
    expect(
        () => AccessSubmission.fromJson(
            submission({'state': 'REVOKED', 'version': 1})),
        throwsA(isA<AccessFailure>()));
    expect(
        () => AccessSubmission.fromJson(
            submission({'state': 'DENIED', 'version': 0})),
        throwsA(isA<AccessFailure>()));
    expect(
        AccessSubmission.fromJson(
            submission({'state': 'EXPIRED', 'version': 1})).absoluteNotAfter,
        isNull);
  });
  test('eligible options parse bounded immutable common and application rules',
      () {
    final option = {
      'id': f.policy,
      'name': '阅读规则',
      'baseVersionId': f.version,
      'commonRules': [
        {'id': 'study', 'kind': 'TIME_WINDOW'}
      ],
      'applications': [
        {
          'id': f.application,
          'displayName': '阅读',
          'rules': [
            {'id': 'reading', 'kind': 'APP_LAUNCH'}
          ]
        }
      ]
    };
    final page = AccessSubmissionOptionsPage.fromJson({
      'items': [option],
      'nextCursor': f.version
    }, after: null, limit: 2);
    expect(page.items.single.applications.single.rules.single.id, 'reading');
    expect(page.nextCursor, f.version);
    expect(() => page.items.single.commonRules.clear(), throwsUnsupportedError);
    expect(
        () => AccessSubmissionOption.fromJson({
              ...option,
              'commonRules': [
                {'id': 'study', 'kind': 'DAILY_QUOTA'}
              ]
            }),
        throwsA(isA<AccessFailure>()));
    expect(
        () => AccessSubmissionOption.fromJson({
              ...option,
              'applications': [
                {
                  'id': f.application,
                  'displayName': '阅读',
                  'rules': [
                    {'id': 'study', 'kind': 'TIME_WINDOW'}
                  ]
                }
              ]
            }),
        throwsA(isA<AccessFailure>()));
  });
  test(
      'submission pages reject duplicates unordered or misleading next cursors',
      () {
    expect(
        () => AccessSubmissionPage.fromJson({
              'items': [submission(), submission()],
              'nextCursor': null
            }, after: null, limit: 2),
        throwsA(isA<AccessFailure>()));
    expect(
        () => AccessSubmissionPage.fromJson({
              'items': [submission()],
              'nextCursor': f.document
            }, after: null, limit: 1),
        throwsA(isA<AccessFailure>()));
    expect(
        () => AccessSubmissionPage.fromJson({
              'items': [submission()],
              'nextCursor': null
            }, after: f.request, limit: 1),
        throwsA(isA<AccessFailure>()));
  });
  test('context mismatch after create has an unknown mutation outcome',
      () async {
    final client = MockClient((r) async => http.Response(
        jsonEncode(submission({'deviceId': f.document})), 201,
        headers: {'content-type': 'application/json'}));
    final t = DeviceAccessTransport(
        apiRoot: Uri.parse('https://device.invalid/api/v1'),
        credential: () async => 'A' * 43,
        client: client);
    addTearDown(t.close);
    addTearDown(client.close);
    await expectLater(
        t.createSubmission(input(),
            context: context(), idempotencyKey: 'create'),
        throwsA(isA<AccessTransportFailure>()
            .having((e) => e.code, 'code', 'RESPONSE_INVALID')
            .having((e) => e.outcomeUnknown, 'outcomeUnknown', isTrue)));
  });
  test('known cooldown is safe and does not expose server text', () async {
    final client = MockClient((r) async => http.Response(
            jsonEncode({
              'errorCode': 'ACCESS_REQUEST_COOLDOWN',
              'detail': 'private child reason',
              'correlationId': f.document
            }),
            429,
            headers: {
              'content-type': 'application/problem+json',
              'retry-after': '60'
            }));
    final t = DeviceAccessTransport(
        apiRoot: Uri.parse('https://device.invalid/api/v1'),
        credential: () async => 'A' * 43,
        client: client);
    addTearDown(t.close);
    addTearDown(client.close);
    await expectLater(
        t.createSubmission(input(),
            context: context(), idempotencyKey: 'create'),
        throwsA(isA<AccessTransportFailure>()
            .having((e) => e.code, 'code', 'ACCESS_REQUEST_COOLDOWN')
            .having(
                (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 60))
            .having((e) => e.outcomeUnknown, 'outcomeUnknown', isFalse)
            .having(
                (e) => e.toString(), 'redacted', isNot(contains('private')))));
  });
}
