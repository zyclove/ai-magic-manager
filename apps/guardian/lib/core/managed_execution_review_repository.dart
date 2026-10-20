import 'api.dart';
import 'bounded_json.dart';
import 'managed_execution.dart';
import 'managed_execution_review.dart';
import 'scoped_http_client.dart';

/// Only this library can attach a completed physical POST refusal to its
/// original reservation. A status code or a fabricated ApiFailure is not proof.
final class ExecutionOperationDenied implements Exception {
  final ExecutionOperationPending record;
  final ApiFailure failure;
  const ExecutionOperationDenied._(this.record, this.failure);
}

/// Bounded device-scoped reads and one original conditional mutation. This
/// repository never retries, changes the revision, polls, or closes the client.
final class ManagedExecutionReviewRepository {
  final Api api;
  final ExecutionOperationOwner owner;
  final String deviceId, registrationId;
  final bool writable;
  final bool Function() current;
  late final Api _scoped = api.scoped(current);

  ManagedExecutionReviewRepository({
    required this.api,
    required this.owner,
    required this.deviceId,
    required this.registrationId,
    required this.writable,
    required this.current,
  }) {
    if (api.baseUrl != owner.apiBaseUrl ||
        !isManagedExecutionId(deviceId) ||
        !isManagedExecutionId(registrationId)) {
      throw const ApiFailure(400, 'INVALID_EXECUTION_ID');
    }
  }

  String get _root =>
      '/tenants/${owner.tenantId}/managed-android/executions';

  void _ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  void _selected(ManagedExecution selected) {
    _ensureCurrent();
    if (selected.deviceId != deviceId ||
        selected.registrationId != registrationId) {
      throw const ApiFailure(400, 'INVALID_EXECUTION_ID');
    }
  }

  Future<Object?> _read(String path) async {
    try {
      return await boundedJson(_scoped, 'GET', path,
          ensureCurrent: _ensureCurrent, maxBytes: 16 * 1024);
    } on ScopeChangedException {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    } on ApiFailure catch (failure) {
      if (failure.code == 'INVALID_REPORT_JOB_RESPONSE') {
        throw const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE');
      }
      rethrow;
    }
  }

  Future<ManagedExecution> detail(ManagedExecution selected) async {
    _selected(selected);
    final raw = await _read('$_root/${selected.id}');
    _ensureCurrent();
    final result = ManagedExecution.parse(raw, deviceId: deviceId);
    result.requireContinuationOf(selected);
    return result;
  }

  Future<ExecutionReviewEligibility> eligibility(ManagedExecution selected) async {
    _selected(selected);
    final raw = await _read('$_root/${selected.id}/review-eligibility');
    _ensureCurrent();
    return ExecutionReviewEligibility.parse(raw, selected: selected);
  }

  bool _knownRefusal(ApiFailure failure) => switch (failure.status) {
    401 => const {'REAUTH_REQUIRED', 'UNAUTHENTICATED'}.contains(failure.code),
    403 => const {'SCOPE_DENIED', 'ACCESS_DENIED'}.contains(failure.code),
    409 => const {
        'EXECUTION_RECHECK_REQUIRES_REVIEW',
        'EXECUTION_RECHECK_CANCELLED',
        'EXECUTION_RECHECK_REQUIRES_POLICY_RECEIPT',
        'EXECUTION_RECHECK_WINDOW_CLOSED',
        'EXECUTION_RECHECK_LEASE_ACTIVE',
        'EXECUTION_RECHECK_UNAVAILABLE',
        'EXECUTION_CONTEXT_CHANGED',
        'EXECUTION_VERSION_EXHAUSTED',
        'EXECUTION_NOT_CANCELLABLE',
      }.contains(failure.code),
    412 => failure.code == 'RESOURCE_VERSION_CONFLICT',
    _ => false,
  };

  Future<ManagedExecution> submit(ExecutionOperationPending attempt) async {
    final intent = attempt.intent, selected = intent.task;
    _selected(selected);
    if (intent.owner != owner) {
      throw const ApiFailure(400, 'INVALID_EXECUTION_OPERATION');
    }
    if (!writable) throw const ApiFailure(403, 'ACCESS_DENIED');
    final recheck = intent.kind == ExecutionOperationKind.recheckDevice;
    if (selected.cancellationRequested ||
        (recheck && selected.state != 'NEEDS_REVIEW') ||
        (!recheck && const {'APPLIED', 'CANCELLED'}.contains(selected.state))) {
      throw const ApiFailure(409, 'EXECUTION_NOT_ACTIONABLE');
    }
    BoundedHttpErrorEvidence? responseEvidence;
    try {
      final raw = await boundedJson(_scoped, 'POST',
          '$_root/${selected.id}/${recheck ? 'recheck-device' : 'cancel'}',
          ensureCurrent: _ensureCurrent,
          version: selected.revision,
          maxBytes: 16 * 1024,
          onHttpError: (evidence) => responseEvidence = evidence);
      _ensureCurrent();
      final result = ManagedExecution.parse(raw, deviceId: deviceId);
      result.requireContinuationOf(selected);
      final valid = recheck
          ? result.revision == selected.revision + 1 &&
              result.state == 'WAITING_DEVICE' &&
              result.reason == 'MANUAL_DEVICE_RECHECK_REQUESTED' &&
              !result.cancellationRequested
          : result.revision == selected.revision + 1 &&
              result.cancellationRequested &&
              ((result.state == 'CANCELLED' &&
                      result.reason == 'CANCELLED_BEFORE_ASSIGNMENT') ||
                  (result.state == 'NEEDS_REVIEW' &&
                      result.reason == 'CANCELLATION_REQUIRES_REVIEW'));
      if (!valid) {
        throw const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE');
      }
      return result;
    } on ScopeChangedException {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    } on ApiFailure catch (failure) {
      if (responseEvidence != null &&
          identical(responseEvidence!.failure, failure) &&
          _knownRefusal(failure)) {
        _ensureCurrent();
        throw ExecutionOperationDenied._(attempt, failure);
      }
      if (failure.code == 'INVALID_REPORT_JOB_RESPONSE') {
        throw const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE');
      }
      rethrow;
    }
  }
}
