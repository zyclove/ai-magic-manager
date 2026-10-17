import 'api.dart';
import 'bounded_json.dart';
import 'managed_execution.dart';
import 'scoped_http_client.dart';

/// Device-scoped administrative access. There is deliberately no write retry.
/// The host must bind [current] to actor, tenant, role, generation, registration
/// and dialog lifetime; this repository never owns or closes the shared client.
class ManagedExecutionRepository {
  final Api api;
  final String tenantId, deviceId, registrationId;
  final bool writable;
  final bool Function() current;
  // Retain this guard through OAuth refresh and down to physical dispatch.
  late final Api _scopedApi = api.scoped(current);

  ManagedExecutionRepository(
      {required this.api,
      required this.tenantId,
      required this.deviceId,
      required this.registrationId,
      required this.writable,
      required this.current}) {
    if (![tenantId, deviceId, registrationId].every(isManagedExecutionId)) {
      throw const ApiFailure(400, 'INVALID_EXECUTION_ID');
    }
  }

  String get _root => '/tenants/$tenantId/managed-android/executions';

  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  bool canCancel(ManagedExecution task) =>
      current() &&
      writable &&
      task.deviceId == deviceId &&
      task.registrationId == registrationId &&
      !task.cancellationRequested &&
      !const {'APPLIED', 'CANCELLED'}.contains(task.state);

  void _selected(ManagedExecution task) {
    ensureCurrent();
    if (task.deviceId != deviceId) {
      throw const ApiFailure(400, 'INVALID_EXECUTION_ID');
    }
  }

  Future<Object?> _request(String method, String path,
      {required int maxBytes, int? version}) async {
    try {
      return await boundedJson(_scopedApi, method, path,
          ensureCurrent: ensureCurrent, version: version, maxBytes: maxBytes);
    } on ScopeChangedException {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    } on ApiFailure catch (error) {
      // Normalize the shared reader's transport-shape error into this domain.
      if (error.code == 'INVALID_REPORT_JOB_RESPONSE') {
        throw const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE');
      }
      rethrow;
    }
  }

  Future<ManagedExecutionPage> list(
      {String? cursor, String? state, String? publicationId}) async {
    ensureCurrent();
    if (cursor != null && !isManagedExecutionId(cursor)) {
      throw const ApiFailure(400, 'INVALID_CURSOR');
    }
    if (publicationId != null && !isManagedExecutionId(publicationId)) {
      throw const ApiFailure(400, 'INVALID_EXECUTION_ID');
    }
    if (state != null && !ManagedExecution.stateLabels.containsKey(state)) {
      throw const ApiFailure(400, 'INVALID_EXECUTION_STATE');
    }
    final query = Uri(queryParameters: {
      'deviceId': deviceId,
      'limit': '50',
      if (cursor != null) 'cursor': cursor,
      if (state != null) 'state': state,
      if (publicationId != null) 'publicationId': publicationId
    }).query;
    final raw = await _request('GET', '$_root?$query', maxBytes: 256 * 1024);
    return ManagedExecutionPage.parse(raw,
        deviceId: deviceId,
        cursor: cursor,
        state: state,
        publicationId: publicationId);
  }

  Future<ManagedExecution> detail(ManagedExecution selected) async {
    _selected(selected);
    final raw =
        await _request('GET', '$_root/${selected.id}', maxBytes: 16 * 1024);
    final result = ManagedExecution.parse(raw, deviceId: deviceId);
    result.requireContinuationOf(selected);
    return result;
  }

  Future<ManagedExecutionEventPage> events(ManagedExecution selected,
      {String? cursor}) async {
    _selected(selected);
    if (cursor != null && !isManagedExecutionCursor(cursor)) {
      throw const ApiFailure(400, 'INVALID_CURSOR');
    }
    final query = Uri(queryParameters: {
      'limit': '50',
      if (cursor != null) 'cursor': cursor
    }).query;
    final raw = await _request('GET', '$_root/${selected.id}/events?$query',
        maxBytes: 64 * 1024);
    return ManagedExecutionEventPage.parse(raw, cursor: cursor);
  }

  /// An uncertain outcome must be reconciled with reads by the host UI. A
  /// successful status alone is insufficient to confirm this cancellation.
  Future<ManagedExecution> cancel(ManagedExecution selected) async {
    _selected(selected);
    if (!writable) throw const ApiFailure(403, 'ACCESS_DENIED');
    if (!canCancel(selected)) {
      throw const ApiFailure(409, 'EXECUTION_NOT_CANCELLABLE');
    }
    final raw = await _request('POST', '$_root/${selected.id}/cancel',
        version: selected.revision, maxBytes: 16 * 1024);
    final result = ManagedExecution.parse(raw, deviceId: deviceId);
    result.requireContinuationOf(selected);
    if (result.revision <= selected.revision ||
        !result.cancellationRequested ||
        !const {'CANCELLED', 'NEEDS_REVIEW'}.contains(result.state)) {
      throw const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE');
    }
    return result;
  }
}
