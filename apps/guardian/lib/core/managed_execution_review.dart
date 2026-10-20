import 'api.dart';
import 'managed_execution.dart';
import 'policy_publication.dart';

Never _invalidIntent() =>
    throw const ApiFailure(400, 'INVALID_EXECUTION_OPERATION');
Never _invalidResponse() =>
    throw const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE');

/// A stable identity namespace. A login epoch or role is intentionally absent:
/// logging in again must still find an unresolved operation for this account.
final class ExecutionOperationOwner {
  final PublicationOwner _identity;

  ExecutionOperationOwner._(this._identity);

  factory ExecutionOperationOwner({
    required String actorId,
    required String tenantId,
    required String apiBaseUrl,
    required String issuer,
  }) {
    if (!isManagedExecutionId(tenantId)) _invalidIntent();
    try {
      return ExecutionOperationOwner._(PublicationOwner(
          actorId: actorId,
          tenantId: tenantId,
          apiBaseUrl: apiBaseUrl,
          issuer: issuer));
    } on ApiFailure {
      _invalidIntent();
    }
  }

  String get actorId => _identity.actorId;
  String get tenantId => _identity.tenantId;
  String get apiBaseUrl => _identity.apiBaseUrl;
  String get issuer => _identity.issuer;
  String get key => _identity.key;

  @override
  bool operator ==(Object other) =>
      other is ExecutionOperationOwner && _identity == other._identity;

  @override
  int get hashCode => _identity.hashCode;
}

/// Both mutations compete for the same durable owner/execution slot.
enum ExecutionOperationKind { cancel, recheckDevice }

/// Immutable original inputs. The local operation ID is used for journal CAS;
/// the recheck API has no idempotency-key contract and never receives this ID.
final class ExecutionOperationIntent {
  final ExecutionOperationOwner owner;
  final ManagedExecution task;
  final ExecutionOperationKind kind;
  final String operationId;
  final int createdAt;

  ExecutionOperationIntent({
    required this.owner,
    required this.task,
    required this.kind,
    required this.operationId,
    required this.createdAt,
  }) {
    if (!isPublicationRequestId(operationId) ||
        createdAt < 0 ||
        createdAt > publicationMaximumTimestamp ||
        task.revision >= managedExecutionMaxRevision) {
      _invalidIntent();
    }
  }
  @override
  bool operator ==(Object other) =>
      other is ExecutionOperationIntent && owner == other.owner &&
      kind == other.kind && operationId == other.operationId &&
      createdAt == other.createdAt && task.id == other.task.id &&
      task.publicationId == other.task.publicationId &&
      task.deviceId == other.task.deviceId &&
      task.registrationId == other.task.registrationId &&
      task.state == other.task.state && task.reason == other.task.reason &&
      task.revision == other.task.revision &&
      task.createdAt == other.task.createdAt &&
      task.updatedAt == other.task.updatedAt &&
      task.cancellationRequested == other.task.cancellationRequested;

  @override
  int get hashCode => Object.hash(owner, kind, operationId, createdAt,
      task.id, task.publicationId, task.deviceId, task.registrationId,
      task.state, task.reason, task.revision, task.createdAt, task.updatedAt,
      task.cancellationRequested);

}

/// Constructed before dispatch. An outcome stays unknown until a trusted
/// response or a newer authoritative task version settles the original slot.
enum ExecutionOperationPhase {
  unknown('UNKNOWN'),
  rejectedNotApplied('REJECTED_NOT_APPLIED');
  final String value;
  const ExecutionOperationPhase(this.value);
}

/// A codec whitelist, not proof of a physical HTTP refusal. Only the repository's
/// privately constructed ExecutionOperationDenied authorizes markRejected.
const executionOperationRefusalCodes = <String>{
  'REAUTH_REQUIRED', 'UNAUTHENTICATED', 'SCOPE_DENIED', 'ACCESS_DENIED',
  'EXECUTION_RECHECK_REQUIRES_REVIEW', 'EXECUTION_RECHECK_CANCELLED',
  'EXECUTION_RECHECK_REQUIRES_POLICY_RECEIPT', 'EXECUTION_RECHECK_WINDOW_CLOSED',
  'EXECUTION_RECHECK_LEASE_ACTIVE', 'EXECUTION_RECHECK_UNAVAILABLE',
  'EXECUTION_CONTEXT_CHANGED', 'EXECUTION_VERSION_EXHAUSTED',
  'EXECUTION_NOT_CANCELLABLE', 'RESOURCE_VERSION_CONFLICT',
};

final class ExecutionOperationPending {
  final ExecutionOperationIntent intent;
  final ExecutionOperationPhase phase;
  final String? refusalCode;

  ExecutionOperationPending({required this.intent,
      this.phase = ExecutionOperationPhase.unknown, this.refusalCode}) {
    if ((phase == ExecutionOperationPhase.unknown && refusalCode != null) ||
        (phase == ExecutionOperationPhase.rejectedNotApplied &&
            !executionOperationRefusalCodes.contains(refusalCode))) {
      _invalidIntent();
    }
  }

  @override
  bool operator ==(Object other) => other is ExecutionOperationPending &&
      intent == other.intent && phase == other.phase && refusalCode == other.refusalCode;
  @override
  int get hashCode => Object.hash(intent, phase, refusalCode);
}

/// A point-in-time hint, never a transferable authorization or an expiry lease.
/// The server rechecks the same predicate atomically on every mutation.
final class ExecutionReviewEligibility {
  static const reasonLabels = <String, String>{
    'ELIGIBLE': '可重新核实设备状态',
    'ADMINISTRATOR_REQUIRED': '当前为只读访问',
    'EXECUTION_RECHECK_REQUIRES_REVIEW': '当前任务无需重新核实',
    'EXECUTION_RECHECK_CANCELLED': '已登记取消，请人工核对设备现状',
    'EXECUTION_RECHECK_REQUIRES_POLICY_RECEIPT': '暂无可靠回执，请人工核对',
    'EXECUTION_RECHECK_WINDOW_CLOSED': '本任务核实时间已结束，请人工核对',
    'EXECUTION_RECHECK_LEASE_ACTIVE': '仍有操作正在处理，可稍后刷新',
    'EXECUTION_RECHECK_UNAVAILABLE': '设备核实服务暂不可用',
    'EXECUTION_CONTEXT_CHANGED': '设备或规则信息已变化，请核对当前关联',
    'EXECUTION_VERSION_EXHAUSTED': '此记录无法继续操作，请人工核对',
  };

  final String id, publicationId, deviceId, registrationId, reason;
  final int revision;
  final bool allowed;

  const ExecutionReviewEligibility._(this.id, this.publicationId, this.deviceId,
      this.registrationId, this.revision, this.allowed, this.reason);

  String get reasonLabel => reasonLabels[reason]!;

  static ExecutionReviewEligibility parse(Object? raw,
      {required ManagedExecution selected}) {
    const keys = {
      'id', 'publicationId', 'deviceId', 'registrationId',
      'revision', 'allowed', 'reason'
    };
    if (raw is! Json ||
        raw.length != keys.length ||
        !keys.every(raw.containsKey)) _invalidResponse();
    final revision = raw['revision'];
    final allowed = raw['allowed'];
    final reason = raw['reason'];
    if (raw['id'] != selected.id ||
        raw['publicationId'] != selected.publicationId ||
        raw['deviceId'] != selected.deviceId ||
        raw['registrationId'] != selected.registrationId ||
        revision is! int ||
        revision < 1 ||
        revision > managedExecutionMaxRevision ||
        revision != selected.revision ||
        allowed is! bool ||
        reason is! String ||
        !reasonLabels.containsKey(reason) ||
        allowed != (reason == 'ELIGIBLE')) _invalidResponse();
    if (allowed &&
        (selected.state != 'NEEDS_REVIEW' ||
            selected.cancellationRequested ||
            selected.revision >= managedExecutionMaxRevision)) {
      _invalidResponse();
    }
    return ExecutionReviewEligibility._(selected.id, selected.publicationId,
        selected.deviceId, selected.registrationId, revision, allowed, reason);
  }
}
