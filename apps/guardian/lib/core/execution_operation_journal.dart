import 'dart:convert';

import 'api.dart';
import 'managed_execution.dart';
import 'managed_execution_review.dart';
import 'managed_execution_review_repository.dart';

const executionOperationMaximumPending = 20;
const executionOperationMaximumRecordBytes = 16 * 1024;

final class ExecutionOperationReservation {
  final ExecutionOperationPending record;
  final bool maySubmit;
  const ExecutionOperationReservation(
      {required this.record, required this.maySubmit});
}

/// One durable owner/execution slot shared by cancel and recheck. No read or
/// restored record authorizes a POST. No TTL, evict, reset, or replay operation.
abstract interface class ExecutionOperationJournal {
  Future<ExecutionOperationPending?> read(
      ExecutionOperationOwner owner, String executionId);
  Future<ExecutionOperationReservation> reserve(
      ExecutionOperationIntent intent);

  /// Caller must first obtain fresh detail/eligibility and a new explicit user
  /// confirmation. Only the exact recorded rejection can be replaced atomically.
  Future<ExecutionOperationReservation> replaceRejected(
      ExecutionOperationPending expected, ExecutionOperationIntent replacement);

  /// The proof constructor belongs to the real HTTP repository. A bare error
  /// code, GET failure, synthetic ApiFailure, or external boolean is not proof.
  Future<ExecutionOperationPending> markRejected(
      ExecutionOperationDenied proof);

  /// Caller supplies this physical POST's strictly verified repository response.
  /// False means a newer/different record won; no other slot is deleted.
  Future<bool> removeAfterVerifiedReceipt(
      ExecutionOperationPending expected, ManagedExecution response);

  /// Caller supplies a trusted GET continuation. A higher revision fences the
  /// original If-Match; it proves progress, never attribution to our operation.
  Future<bool> removeAfterObservedProgress(
      ExecutionOperationPending expected, ManagedExecution progress);

  /// Live controller only, after synchronous permanent detach and its private
  /// irreversible latch proves submit was never called and can never be called.
  /// Not for reload/recovery, exceptions, elapsed time, or a caller-supplied bool.
  Future<bool> removeAfterControllerProvedNeverDispatched(
      ExecutionOperationPending expected);
}

/// Current 1.0 format only. The canonical equality check also rejects duplicate
/// JSON keys, whitespace variants, aliases, extra fields and numeric coercions.
final class ExecutionOperationRecordCodec {
  static Never _invalid() =>
      throw const ApiFailure(409, 'INVALID_EXECUTION_OPERATION_RECORD');

  static Json _fields(Object? raw, Set<String> keys) {
    if (raw is! Json ||
        raw.length != keys.length ||
        !keys.every(raw.containsKey)) _invalid();
    return raw;
  }

  static Map<String, Object> _task(ManagedExecution task) => {
        'id': task.id,
        'publicationId': task.publicationId,
        'deviceId': task.deviceId,
        'registrationId': task.registrationId,
        'state': task.state,
        'reason': task.reason,
        'revision': task.revision,
        'createdAt': task.createdAt,
        'updatedAt': task.updatedAt,
        'cancellationRequested': task.cancellationRequested,
      };

  static String encode(ExecutionOperationPending record) {
    final intent = record.intent, owner = intent.owner;
    if ((record.phase == ExecutionOperationPhase.unknown &&
            record.refusalCode != null) ||
        (record.phase == ExecutionOperationPhase.rejectedNotApplied &&
            !executionOperationRefusalCodes.contains(record.refusalCode))) {
      _invalid();
    }
    final text = jsonEncode({
      'schema': 1,
      'intent': {
        'owner': {
          'actorId': owner.actorId,
          'tenantId': owner.tenantId,
          'apiBaseUrl': owner.apiBaseUrl,
          'issuer': owner.issuer
        },
        'task': _task(intent.task),
        'kind': intent.kind.name,
        'operationId': intent.operationId,
        'createdAt': intent.createdAt,
      },
      'phase': record.phase.value,
      'refusalCode': record.refusalCode,
    });
    if (utf8.encode(text).length > executionOperationMaximumRecordBytes) {
      _invalid();
    }
    return text;
  }

  static ExecutionOperationPending decode(String text,
      {required ExecutionOperationOwner owner, required String executionId}) {
    if (text.isEmpty ||
        !isManagedExecutionId(executionId) ||
        text.length > executionOperationMaximumRecordBytes ||
        utf8.encode(text).length > executionOperationMaximumRecordBytes) {
      _invalid();
    }
    try {
      final root = _fields(
          jsonDecode(text), {'schema', 'intent', 'phase', 'refusalCode'});
      if (root['schema'] is! int || root['schema'] != 1) _invalid();
      final raw = _fields(root['intent'],
          {'owner', 'task', 'kind', 'operationId', 'createdAt'});
      final identity = _fields(
          raw['owner'], {'actorId', 'tenantId', 'apiBaseUrl', 'issuer'});
      if (identity.values.any((v) => v is! String) ||
          raw['operationId'] is! String ||
          raw['createdAt'] is! int) _invalid();
      final parsedOwner = ExecutionOperationOwner(
          actorId: identity['actorId'],
          tenantId: identity['tenantId'],
          apiBaseUrl: identity['apiBaseUrl'],
          issuer: identity['issuer']);
      if (parsedOwner != owner) _invalid();
      final taskRaw = _fields(raw['task'], {
        'id',
        'publicationId',
        'deviceId',
        'registrationId',
        'state',
        'reason',
        'revision',
        'createdAt',
        'updatedAt',
        'cancellationRequested'
      });
      if (taskRaw['deviceId'] is! String) _invalid();
      final task =
          ManagedExecution.parse(taskRaw, deviceId: taskRaw['deviceId']);
      if (task.id != executionId) _invalid();
      final kind = ExecutionOperationKind.values
          .firstWhere((v) => v.name == raw['kind'], orElse: _invalid);
      final phase = ExecutionOperationPhase.values
          .firstWhere((v) => v.value == root['phase'], orElse: _invalid);
      if (root['refusalCode'] != null && root['refusalCode'] is! String) {
        _invalid();
      }
      final record = ExecutionOperationPending(
          intent: ExecutionOperationIntent(
              owner: owner,
              task: task,
              kind: kind,
              operationId: raw['operationId'],
              createdAt: raw['createdAt']),
          phase: phase,
          refusalCode: root['refusalCode']);
      if (encode(record) != text) _invalid();
      return record;
    } catch (_) {
      // Persisted values are untrusted. Never surface contents or parser causes.
      _invalid();
    }
  }
}
