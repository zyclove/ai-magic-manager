import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/managed_execution_review.dart';
import 'package:guardian/core/managed_execution_review_repository.dart';

import 'manual_recheck_contract_fixtures.dart';

void main() {
  late ReviewHttpFixture fixture;
  setUp(() => fixture = ReviewHttpFixture());
  tearDown(() => fixture.transport.close());

  ExecutionOperationPending cancellation() => ExecutionOperationPending(
      intent: ExecutionOperationIntent(
          owner: reviewOwner(),
          task: reviewTask(),
          kind: ExecutionOperationKind.cancel,
          operationId: reviewOperationId,
          createdAt: 1000));

  for (final receipt in const {
    'CANCELLED': 'CANCELLED_BEFORE_ASSIGNMENT',
    'NEEDS_REVIEW': 'CANCELLATION_REQUIRES_REVIEW',
  }.entries) {
    test('cancel accepts exact single-version ${receipt.key} receipt',
        () async {
      fixture.transport.handler = (_) async => reviewResponse(reviewTaskRaw(
          revision: 9,
          state: receipt.key,
          reason: receipt.value,
          cancelled: true));
      final call = ReviewCall(fixture.repository.submit(cancellation()));
      await call.completed;
      expect(fixture.transport.requests, hasLength(1));
      expect(call.error, isNull);
      final request = fixture.transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, endsWith('/cancel'));
      expect(request.headers['If-Match'], '"8"');
      expect(request.headers.containsKey('Idempotency-Key'), isFalse);
      expect(fixture.transport.bodies.single, isEmpty);
      expect(call.value!.revision, 9);
      expect(call.value!.state, receipt.key);
      expect(call.value!.reason, receipt.value);
      expect(call.value!.cancellationRequested, isTrue);
    });
  }

  for (final variant in const [
    'same-version',
    'two-versions',
    'applied-reason',
    'opposite-cancellation-reason',
    'missing-cancellation',
    'applied-state',
  ]) {
    test('cancel cannot settle an impossible 200 receipt: $variant', () async {
      final raw = reviewTaskRaw(
          revision: 9,
          state: 'CANCELLED',
          reason: 'CANCELLED_BEFORE_ASSIGNMENT',
          cancelled: true);
      if (variant == 'same-version') raw['revision'] = 8;
      if (variant == 'two-versions') raw['revision'] = 10;
      if (variant == 'applied-reason') raw['reason'] = 'DEVICE_APPLIED';
      if (variant == 'opposite-cancellation-reason') {
        raw['reason'] = 'CANCELLATION_REQUIRES_REVIEW';
      }
      if (variant == 'missing-cancellation') {
        raw['cancellationRequested'] = false;
      }
      if (variant == 'applied-state') raw['state'] = 'APPLIED';
      fixture.transport.handler = (_) async => reviewResponse(raw);
      final call = ReviewCall(fixture.repository.submit(cancellation()));
      await call.completed;
      expect(fixture.transport.requests, hasLength(1));
      expect(
          call.error, executionFailure('INVALID_MANAGED_EXECUTION_RESPONSE'));
      expect(call.error, isNot(isA<ExecutionOperationDenied>()));
    });
  }
}
