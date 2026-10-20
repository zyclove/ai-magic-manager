import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_execution_review_repository.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth;

import 'api_scope_test.dart'
    show RecordingTransport, expiredCredentials, refreshedToken;
import 'managed_execution_fixtures.dart';
import 'manual_recheck_contract_fixtures.dart';

void main() {
  late ReviewHttpFixture fixture;
  setUp(() => fixture = ReviewHttpFixture());
  tearDown(() => fixture.transport.close());

  Future<void> requireOneRequest(ReviewCall<dynamic> call) async {
    await call.completed;
    expect(fixture.transport.requests, hasLength(1),
        reason: 'This scenario requires entry to the real local HTTP boundary. '
            'An API placeholder is not request-contract RED evidence.');
  }

  test('eligibility GET is bound to original tenant and task', () async {
    fixture.transport.handler = (_) async => reviewResponse(eligibilityRaw());
    final call = ReviewCall(fixture.repository.eligibility(reviewTask()));
    await requireOneRequest(call);
    expect(call.error, isNull);
    final request = fixture.transport.requests.single;
    expect(request.method, 'GET');
    expect(
        request.url.toString(),
        '$reviewApiBase/tenants/$executionTenant/managed-android/executions/'
        '$executionId/review-eligibility');
    expect(request.headers.containsKey('If-Match'), isFalse);
    expect(request.headers.containsKey('If-None-Match'), isFalse);
    expect(request.headers.containsKey('Idempotency-Key'), isFalse);
    expect(fixture.transport.bodies.single, isEmpty);
    expect(call.value!.allowed, isTrue);
    expect(fixture.transport.closed, isFalse);
  });

  test('eligibility can change while task revision stays unchanged', () async {
    var reads = 0;
    fixture.transport.handler = (_) async {
      reads++;
      return reviewResponse(eligibilityRaw(
          allowed: reads == 1,
          reason: reads == 1 ? 'ELIGIBLE' : 'EXECUTION_RECHECK_UNAVAILABLE'));
    };
    final first = ReviewCall(fixture.repository.eligibility(reviewTask()));
    await first.completed;
    final second = ReviewCall(fixture.repository.eligibility(reviewTask()));
    await second.completed;
    expect(fixture.transport.requests, hasLength(2));
    expect(first.error, isNull);
    expect(second.error, isNull);
    expect(first.value!.allowed, isTrue);
    expect(second.value!.allowed, isFalse);
    expect(first.value!.revision, second.value!.revision);
  });

  test('recheck POST is bodyless and uses only original strong version',
      () async {
    fixture.transport.handler = (_) async => reviewResponse(reviewTaskRaw(
        revision: 9,
        state: 'WAITING_DEVICE',
        reason: 'MANUAL_DEVICE_RECHECK_REQUESTED'));
    final attempt = reviewAttempt();
    final call = ReviewCall(fixture.repository.submit(attempt));
    await requireOneRequest(call);
    expect(call.error, isNull);
    final request = fixture.transport.requests.single;
    expect(request.method, 'POST');
    expect(
        request.url.toString(),
        '$reviewApiBase/tenants/$executionTenant/managed-android/executions/'
        '$executionId/recheck-device');
    expect(request.headers['If-Match'], '"8"');
    expect(request.headers.containsKey('Idempotency-Key'), isFalse);
    expect(fixture.transport.bodies.single, isEmpty);
    expect(request.followRedirects, isFalse);
    expect(call.value!.revision, 9);
    expect(call.value!.state, 'WAITING_DEVICE');
    expect(call.value!.reason, 'MANUAL_DEVICE_RECHECK_REQUESTED');
    expect(call.value!.cancellationRequested, isFalse);
  });

  for (final variant in [
    'same-revision',
    'advanced-twice',
    'wrong-task',
    'wrong-registration',
    'applied-state',
    'wrong-reason',
    'cancelled',
    'internal-field'
  ]) {
    test('200 cannot be accepted as a receipt when $variant', () async {
      final raw = reviewTaskRaw(
          revision: 9,
          state: 'WAITING_DEVICE',
          reason: 'MANUAL_DEVICE_RECHECK_REQUESTED');
      if (variant == 'same-revision') raw['revision'] = 8;
      if (variant == 'advanced-twice') raw['revision'] = 10;
      if (variant == 'wrong-task') raw['id'] = executionOther;
      if (variant == 'wrong-registration') {
        raw['registrationId'] = executionOther;
      }
      if (variant == 'applied-state') raw['state'] = 'APPLIED';
      if (variant == 'wrong-reason') raw['reason'] = 'DEVICE_PENDING';
      if (variant == 'cancelled') raw['cancellationRequested'] = true;
      if (variant == 'internal-field') raw['providerVersion'] = 7;
      fixture.transport.handler = (_) async => reviewResponse(raw);
      final call = ReviewCall(fixture.repository.submit(reviewAttempt()));
      await requireOneRequest(call);
      expect(
          call.error, executionFailure('INVALID_MANAGED_EXECUTION_RESPONSE'));
      expect(call.error, isNot(isA<ExecutionOperationDenied>()));
    });
  }

  for (final mime in [
    'application/json',
    'application/problem+json; charset=utf-8'
  ]) {
    test('complete exact POST MFA denial is trusted for $mime', () async {
      fixture.transport.handler = (_) async => reviewResponse(
          {'errorCode': 'REAUTH_REQUIRED'},
          status: 401, mime: mime);
      final attempt = reviewAttempt();
      final call = ReviewCall(fixture.repository.submit(attempt));
      await requireOneRequest(call);
      expect(call.error, isA<ExecutionOperationDenied>());
      final denial = call.error as ExecutionOperationDenied;
      expect(denial.record.intent.owner.key, attempt.intent.owner.key);
      expect(denial.record.intent.task.id, attempt.intent.task.id);
      expect(denial.record.intent.task.revision, 8);
      expect(denial.record.intent.operationId, reviewOperationId);
      expect(denial.failure.status, 401);
      expect(denial.failure.code, 'REAUTH_REQUIRED');
    });
  }

  for (final variant in [
    'fabricated-error',
    'wrong-mime',
    'wrong-content-length',
    'stream-failure',
    'unknown-code'
  ]) {
    test('untrusted POST denial cannot settle original attempt: $variant',
        () async {
      fixture.transport.handler = (_) async {
        if (variant == 'fabricated-error') {
          throw const ApiFailure(401, 'REAUTH_REQUIRED');
        }
        if (variant == 'stream-failure') {
          return http.StreamedResponse(
              Stream<List<int>>.error(StateError('fixture broken body')), 401,
              headers: {'content-type': 'application/problem+json'});
        }
        final code = variant == 'unknown-code'
            ? 'UNRECOGNIZED_SECURITY_CODE'
            : 'REAUTH_REQUIRED';
        final body = <String, dynamic>{'errorCode': code};
        final bytes = utf8.encode(jsonEncode(body));
        return reviewResponse(body,
            status: 401,
            mime: variant == 'wrong-mime'
                ? 'text/plain'
                : 'application/problem+json',
            lengthOverride:
                variant == 'wrong-content-length' ? bytes.length + 1 : null);
      };
      final call = ReviewCall(fixture.repository.submit(reviewAttempt()));
      await requireOneRequest(call);
      expect(call.error, isA<ApiFailure>());
      expect(call.error, isNot(isA<ExecutionOperationDenied>()));
    });
  }

  for (final operation in ['detail', 'eligibility']) {
    test('$operation GET denial is never evidence about POST submission',
        () async {
      fixture.transport.handler = (_) async => reviewResponse(
          {'errorCode': 'REAUTH_REQUIRED'},
          status: 401, mime: 'application/problem+json');
      final call = ReviewCall<dynamic>(operation == 'detail'
          ? fixture.repository.detail(reviewTask())
          : fixture.repository.eligibility(reviewTask()));
      await requireOneRequest(call);
      expect(fixture.transport.requests.single.method, 'GET');
      expect(call.error, isA<ApiFailure>());
      expect(call.error, isNot(isA<ExecutionOperationDenied>()));
    });
  }

  test('known 412 rejection never sends another version automatically',
      () async {
    fixture.transport.handler = (_) async =>
        reviewResponse({'errorCode': 'RESOURCE_VERSION_CONFLICT'}, status: 412);
    final call = ReviewCall(fixture.repository.submit(reviewAttempt()));
    await requireOneRequest(call);
    expect(call.error, isA<ExecutionOperationDenied>());
    expect((call.error as ExecutionOperationDenied).failure.status, 412);
    expect(fixture.transport.requests.single.headers['If-Match'], '"8"');
  });

  for (final declared in [true, false]) {
    test('oversized receipt fails bounded reading: declared=$declared',
        () async {
      fixture.transport.handler =
          (_) async => reviewResponse('x' * 16385, declaredLength: declared);
      final call = ReviewCall(fixture.repository.submit(reviewAttempt()));
      await requireOneRequest(call);
      expect(
          call.error, executionFailure('INVALID_MANAGED_EXECUTION_RESPONSE'));
      expect(call.error, isNot(isA<ExecutionOperationDenied>()));
    });
  }

  test('network loss remains ambiguous without resubmission', () async {
    fixture.transport.handler =
        (_) async => throw http.ClientException('fixture disconnected');
    final call = ReviewCall(fixture.repository.submit(reviewAttempt()));
    await requireOneRequest(call);
    expect(call.error, executionFailure('NETWORK_ERROR'));
    expect(call.error, isNot(isA<ExecutionOperationDenied>()));
  });

  for (final operation in ['eligibility', 'submit']) {
    test('$operation rejects revoked scope before transport', () async {
      fixture.current = false;
      final call = ReviewCall<dynamic>(operation == 'eligibility'
          ? fixture.repository.eligibility(reviewTask())
          : fixture.repository.submit(reviewAttempt()));
      await call.completed;
      expect(call.error, executionFailure('WORKSPACE_CHANGED'));
      expect(fixture.transport.requests, isEmpty);
    });
  }

  for (final operation in ['eligibility', 'submit']) {
    test('$operation preserves physical dispatch guard through OAuth refresh',
        () async {
      var current = true;
      final raw = RecordingTransport();
      final client = oauth.Client(expiredCredentials(),
          identifier: 'guardian',
          basicAuth: false,
          httpClient: ScopeGuardedClient(raw));
      addTearDown(() {
        if (!raw.tokenReply.isCompleted) {
          raw.tokenReply.complete(refreshedToken());
        }
        client.close();
      });
      final owner = reviewOwner(apiBase: 'https://app.example/api/v1');
      final repository = ManagedExecutionReviewRepository(
          api: Api(() async => client, baseUrl: 'https://app.example/api/v1'),
          owner: owner,
          deviceId: executionDevice,
          registrationId: executionRegistration,
          writable: true,
          current: () => current);
      final call = ReviewCall<dynamic>(operation == 'eligibility'
          ? repository.eligibility(reviewTask())
          : repository.submit(reviewAttempt(owner: owner)));
      await requirePhase(raw.tokenStarted, call);
      current = false;
      raw.tokenReply.complete(refreshedToken());
      await call.completed;
      expect(call.error, executionFailure('WORKSPACE_CHANGED'));
      expect(raw.businessRequests, isEmpty);
      expect(raw.requests, hasLength(1));
      expect(raw.closed, isFalse);
    });
  }
}
