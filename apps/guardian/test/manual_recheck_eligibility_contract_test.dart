import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/managed_execution_review.dart';

import 'managed_execution_fixtures.dart';
import 'manual_recheck_contract_fixtures.dart';

void main() {
  test('eligibility accepts exactly seven aligned fields', () {
    final task = reviewTask();
    ExecutionReviewEligibility? value;
    expect(
        () => value = ExecutionReviewEligibility.parse(
            eligibilityRaw(selected: task), selected: task),
        returnsNormally);
    expect(value!.id, task.id);
    expect(value!.publicationId, task.publicationId);
    expect(value!.deviceId, task.deviceId);
    expect(value!.registrationId, task.registrationId);
    expect(value!.revision, task.revision);
    expect(value!.allowed, isTrue);
    expect(value!.reason, 'ELIGIBLE');
  });

  for (final reason in reviewDenials) {
    test('eligibility accepts exact stable refusal $reason', () {
      ExecutionReviewEligibility? value;
      expect(
          () => value = ExecutionReviewEligibility.parse(
              eligibilityRaw(allowed: false, reason: reason),
              selected: reviewTask()),
          returnsNormally);
      expect(value!.allowed, isFalse);
      expect(value!.reason, reason);
    });
  }

  for (final field in [
    'id',
    'publicationId',
    'deviceId',
    'registrationId',
    'revision',
    'allowed',
    'reason'
  ]) {
    test('eligibility rejects missing $field', () {
      final raw = eligibilityRaw()..remove(field);
      expect(
          () => ExecutionReviewEligibility.parse(raw, selected: reviewTask()),
          throwsA(executionFailure('INVALID_MANAGED_EXECUTION_RESPONSE')));
    });
  }

  for (final field in ['id', 'publicationId', 'deviceId', 'registrationId']) {
    test('eligibility rejects different $field identity', () {
      final raw = eligibilityRaw()..[field] = executionOther;
      expect(
          () => ExecutionReviewEligibility.parse(raw, selected: reviewTask()),
          throwsA(executionFailure('INVALID_MANAGED_EXECUTION_RESPONSE')));
    });
  }

  for (final revision in [7, 9, 0, 1.5, 9007199254740991]) {
    test('eligibility rejects wrong or unsafe revision $revision', () {
      final raw = eligibilityRaw()..['revision'] = revision;
      expect(
          () => ExecutionReviewEligibility.parse(raw, selected: reviewTask()),
          throwsA(executionFailure('INVALID_MANAGED_EXECUTION_RESPONSE')));
    });
  }

  for (final variant in [
    'extra-internal-field',
    'allowed-is-string',
    'unknown-reason',
    'true-with-denial',
    'false-with-eligible'
  ]) {
    test('eligibility rejects malformed $variant', () {
      final raw = eligibilityRaw();
      if (variant == 'extra-internal-field') raw['providerVersion'] = 7;
      if (variant == 'allowed-is-string') raw['allowed'] = 'true';
      if (variant == 'unknown-reason') raw['reason'] = 'PROVIDER_FREE_TEXT';
      if (variant == 'true-with-denial') {
        raw['reason'] = 'EXECUTION_RECHECK_UNAVAILABLE';
      }
      if (variant == 'false-with-eligible') raw['allowed'] = false;
      expect(
          () => ExecutionReviewEligibility.parse(raw, selected: reviewTask()),
          throwsA(executionFailure('INVALID_MANAGED_EXECUTION_RESPONSE')));
    });
  }
}
