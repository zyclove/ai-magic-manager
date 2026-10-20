import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/managed_execution.dart';
import 'package:guardian/core/managed_execution_review.dart';

import 'managed_execution_fixtures.dart';
import 'manual_recheck_contract_fixtures.dart';

void main() {
  ManagedExecution exhaustedTask() => ManagedExecution.parse(
      reviewTaskRaw(revision: managedExecutionMaxRevision),
      deviceId: executionDevice);

  test('eligibility cannot authorize an exhausted original task version', () {
    final selected = exhaustedTask();
    expect(
        () => ExecutionReviewEligibility.parse(
            eligibilityRaw(selected: selected), selected: selected),
        throwsA(executionFailure('INVALID_MANAGED_EXECUTION_RESPONSE')));
  });

  test('eligibility retains the explicit exhausted-version explanation', () {
    final selected = exhaustedTask();
    final result = ExecutionReviewEligibility.parse(
        eligibilityRaw(
            selected: selected,
            allowed: false,
            reason: 'EXECUTION_VERSION_EXHAUSTED'),
        selected: selected);
    expect(result.allowed, isFalse);
    expect(result.reason, 'EXECUTION_VERSION_EXHAUSTED');
    expect(result.revision, selected.revision);
  });
}
