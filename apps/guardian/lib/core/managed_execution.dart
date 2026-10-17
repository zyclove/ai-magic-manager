import 'api.dart';

/// Visibility helpers mirror the API roles; the server remains authoritative.
bool canReadManagedExecutions(String role) =>
    const {'OWNER', 'ORG_ADMIN', 'AUDITOR'}.contains(role);
bool canManageManagedExecutions(String role) =>
    const {'OWNER', 'ORG_ADMIN'}.contains(role);

const managedExecutionMaxRevision = 9007199254740990;
final _executionIdPattern =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// Canonical IDs prevent path/query ambiguity before acquiring credentials.
bool isManagedExecutionId(Object? value) =>
    value is String &&
    value.length == 36 &&
    _executionIdPattern.hasMatch(value);

/// A revision cursor is canonical decimal text, not a floating point number.
bool isManagedExecutionCursor(String value) {
  if (value.isEmpty ||
      value.length > 16 ||
      !RegExp(r'^[1-9][0-9]*$').hasMatch(value)) return false;
  final parsed = int.tryParse(value);
  return parsed != null &&
      parsed <= managedExecutionMaxRevision &&
      parsed.toString() == value;
}

Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE');

Json _object(Object? raw, Set<String> keys) {
  if (raw is! Json ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

int _revision(Object? raw) {
  if (raw is! int || raw < 1 || raw > managedExecutionMaxRevision) _invalid();
  return raw;
}

int _time(Object? raw) {
  // Dart DateTime supports at most 100 million days from the epoch.
  if (raw is! int || raw < 0 || raw > 8640000000000000) _invalid();
  return raw;
}

String _id(Object? raw) {
  if (!isManagedExecutionId(raw)) _invalid();
  return raw as String;
}

String _state(Object? raw) {
  if (raw is! String || !ManagedExecution.stateLabels.containsKey(raw)) {
    _invalid();
  }
  return raw;
}

String _reason(Object? raw) {
  if (raw is! String || !ManagedExecution.reasonLabels.containsKey(raw)) {
    _invalid();
  }
  return raw;
}

List<dynamic> _rows(Json page) {
  final rows = page['items'];
  if (rows is! List || rows.length > 50) _invalid();
  return rows;
}

/// Public projection only. Internal leases and provider resource names are rejected.
class ManagedExecution {
  static const stateLabels = <String, String>{
    'READY_TO_WRITE': '等待处理',
    'POLICY_WRITE_UNKNOWN': '策略写入待核对',
    'READY_TO_ASSIGN': '等待分配策略',
    'ASSIGNMENT_UNKNOWN': '策略分配待核对',
    'WAITING_DEVICE': '等待设备反馈',
    'APPLIED': '设备已应用',
    'NEEDS_REVIEW': '需要复核',
    'CANCELLED': '已取消',
  };
  static const reasonLabels = <String, String>{
    'QUEUED': '已进入处理队列',
    'CLAIMED': '处理任务已领取',
    'WRITE_DISPATCHED': '已发起策略写入，等待核对结果',
    'ASSIGN_DISPATCHED': '已发起策略分配，等待核对结果',
    'POLICY_CONFIRMED': '已确认策略内容',
    'ASSIGNMENT_CONFIRMED': '已确认策略分配',
    'DEVICE_PENDING': '等待设备报告应用结果',
    'DEVICE_NON_COMPLIANT': '设备报告尚未满足策略要求',
    'DEVICE_APPLIED': '设备反馈与目标策略一致',
    'WRITE_OUTCOME_UNKNOWN': '暂不能确认策略写入结果',
    'ASSIGNMENT_OUTCOME_UNKNOWN': '暂不能确认策略分配结果',
    'READ_FAILED': '暂时无法读取核对结果',
    'RECONCILIATION_REQUIRES_REVIEW': '核对结果需要管理员复核',
    'DEADLINE_EXCEEDED': '已超过处理期限',
    'ATTEMPTS_EXHAUSTED': '已达到处理次数上限',
    'CANCELLED_BEFORE_ASSIGNMENT': '已在策略分配前取消后续执行',
    'CANCELLATION_REQUIRES_REVIEW': '已登记取消，设备结果仍需复核',
    'CONTEXT_CHANGED': '设备或管理上下文已变化',
  };

  final String id, publicationId, deviceId, registrationId, state, reason;
  final int revision, createdAt, updatedAt;
  final bool cancellationRequested;

  const ManagedExecution._(
      this.id,
      this.publicationId,
      this.deviceId,
      this.registrationId,
      this.state,
      this.reason,
      this.revision,
      this.createdAt,
      this.updatedAt,
      this.cancellationRequested);

  String get stateLabel => stateLabels[state]!;
  String get reasonLabel => reasonLabels[reason]!;

  static ManagedExecution parse(Object? raw, {required String deviceId}) {
    final data = _object(raw, const {
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
    final actualDevice = _id(data['deviceId']);
    final created = _time(data['createdAt']),
        updated = _time(data['updatedAt']);
    final cancelled = data['cancellationRequested'];
    if (actualDevice != deviceId || updated < created || cancelled is! bool) {
      _invalid();
    }
    return ManagedExecution._(
        _id(data['id']),
        _id(data['publicationId']),
        actualDevice,
        _id(data['registrationId']),
        _state(data['state']),
        _reason(data['reason']),
        _revision(data['revision']),
        created,
        updated,
        cancelled);
  }

  /// Refreshes must preserve identity and must not move the version backwards.
  void requireContinuationOf(ManagedExecution selected) {
    if (id != selected.id ||
        publicationId != selected.publicationId ||
        deviceId != selected.deviceId ||
        registrationId != selected.registrationId ||
        createdAt != selected.createdAt ||
        revision < selected.revision) _invalid();
    if (revision == selected.revision &&
        (state != selected.state ||
            reason != selected.reason ||
            updatedAt != selected.updatedAt ||
            cancellationRequested != selected.cancellationRequested)) {
      _invalid();
    }
  }
}

/// A single bounded keyset page. The UI additionally checks cross-page merges.
class ManagedExecutionPage {
  final List<ManagedExecution> items;
  final String? nextCursor;
  ManagedExecutionPage._(List<ManagedExecution> items, this.nextCursor)
      : items = List.unmodifiable(items);

  static ManagedExecutionPage parse(Object? raw,
      {required String deviceId,
      String? cursor,
      String? state,
      String? publicationId}) {
    final data = _object(raw, const {'items', 'nextCursor'});
    final items = <ManagedExecution>[], seen = <String>{};
    for (final row in _rows(data)) {
      final item = ManagedExecution.parse(row, deviceId: deviceId);
      if (!seen.add(item.id) ||
          item.id == cursor ||
          (state != null && item.state != state) ||
          (publicationId != null && item.publicationId != publicationId)) {
        _invalid();
      }
      if (items.isNotEmpty) {
        final previous = items.last;
        if (item.createdAt > previous.createdAt ||
            (item.createdAt == previous.createdAt &&
                item.id.compareTo(previous.id) >= 0)) _invalid();
      }
      items.add(item);
    }
    final next = data['nextCursor'];
    if (next != null &&
        (!isManagedExecutionId(next) ||
            items.isEmpty ||
            next != items.last.id)) {
      _invalid();
    }
    return ManagedExecutionPage._(items, next as String?);
  }
}

class ManagedExecutionEvent {
  final int revision, occurredAt;
  final String state, reason;
  const ManagedExecutionEvent._(
      this.revision, this.state, this.reason, this.occurredAt);
  String get stateLabel => ManagedExecution.stateLabels[state]!;
  String get reasonLabel => ManagedExecution.reasonLabels[reason]!;

  static ManagedExecutionEvent parse(Object? raw) {
    final data =
        _object(raw, const {'revision', 'state', 'reason', 'occurredAt'});
    return ManagedExecutionEvent._(
        _revision(data['revision']),
        _state(data['state']),
        _reason(data['reason']),
        _time(data['occurredAt']));
  }
}

class ManagedExecutionEventPage {
  final List<ManagedExecutionEvent> items;
  final String? nextCursor;
  ManagedExecutionEventPage._(
      List<ManagedExecutionEvent> items, this.nextCursor)
      : items = List.unmodifiable(items);

  static ManagedExecutionEventPage parse(Object? raw, {String? cursor}) {
    final data = _object(raw, const {'items', 'nextCursor'});
    if (cursor != null && !isManagedExecutionCursor(cursor)) _invalid();
    var previous = cursor == null ? 0 : int.parse(cursor);
    final items = <ManagedExecutionEvent>[];
    for (final row in _rows(data)) {
      final item = ManagedExecutionEvent.parse(row);
      if (item.revision <= previous) _invalid();
      previous = item.revision;
      items.add(item);
    }
    final next = data['nextCursor'];
    if (next != null &&
        (next is! String ||
            !isManagedExecutionCursor(next) ||
            items.isEmpty ||
            next != items.last.revision.toString())) _invalid();
    return ManagedExecutionEventPage._(items, next as String?);
  }
}
