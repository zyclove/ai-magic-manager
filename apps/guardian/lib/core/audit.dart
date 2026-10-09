import 'api.dart';

const auditRoles = ['OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR'];
final auditUuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
bool auditResourceId(String value) =>
    auditUuid.hasMatch(value) || RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
Never _invalid() => throw const ApiFailure(502, 'INVALID_AUDIT_RESPONSE');

class AuditQuery {
  final int from, to;
  final String? action, resourceId, correlationId;
  const AuditQuery(
      {required this.from,
      required this.to,
      this.action,
      this.resourceId,
      this.correlationId});
  Map<String, String> get parameters => {
        'from': '$from',
        'to': '$to',
        'limit': '20',
        if (action != null) 'action': action!,
        if (resourceId != null) 'resourceId': resourceId!,
        if (correlationId != null) 'correlationId': correlationId!,
      };
}

class AuditEvent {
  final String id, actorId, action, resourceId, correlationId;
  final int occurredAt;
  const AuditEvent(this.id, this.actorId, this.action, this.resourceId,
      this.correlationId, this.occurredAt);
  static AuditEvent parse(dynamic v) {
    const keys = {
      'id',
      'actorId',
      'action',
      'resourceId',
      'correlationId',
      'occurredAt'
    };
    if (v is! Json ||
        v.length != 6 ||
        !v.keys.every(keys.contains) ||
        v['id'] is! String ||
        !auditUuid.hasMatch(v['id']) ||
        v['occurredAt'] is! int ||
        v['occurredAt'] < 0 ||
        v['occurredAt'] > 8640000000000000) _invalid();
    for (final entry in {
      'actorId': 255,
      'action': 100,
      'resourceId': 100,
      'correlationId': 36
    }.entries) {
      if (v[entry.key] is! String ||
          (v[entry.key] as String).isEmpty ||
          (v[entry.key] as String).length > entry.value) _invalid();
    }
    return AuditEvent(v['id'], v['actorId'], v['action'], v['resourceId'],
        v['correlationId'], v['occurredAt']);
  }
}

class AuditPage {
  final List<AuditEvent> items;
  final String? nextCursor;
  const AuditPage(this.items, this.nextCursor);
}

class AuditRepository {
  final Api api;
  final String root;
  final bool Function() current;
  AuditRepository(
      {required this.api, required this.root, required this.current});
  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<dynamic> _get(String suffix) async {
    ensureCurrent();
    try {
      final result = await api.send('GET', '$root/audit-events$suffix');
      ensureCurrent();
      return result;
    } catch (_) {
      ensureCurrent();
      rethrow;
    }
  }

  Future<AuditPage> load(AuditQuery q, {String? cursor}) async {
    final params = {...q.parameters, if (cursor != null) 'cursor': cursor};
    final v = await _get('/search?${Uri(queryParameters: params).query}');
    if (v is! Json ||
        v.length != 2 ||
        !v.containsKey('nextCursor') ||
        v['items'] is! List ||
        (v['items'] as List).length > 20) _invalid();
    final next = v['nextCursor'];
    if (next != null &&
        (next is! String ||
            next.isEmpty ||
            next.length > 256 ||
            next == cursor)) _invalid();
    final items =
        (v['items'] as List).map(AuditEvent.parse).toList(growable: false);
    if (next != null && items.length != 20) _invalid();
    final ids = <String>{};
    AuditEvent? previous;
    for (final item in items) {
      if (!ids.add(item.id) ||
          item.occurredAt < q.from ||
          item.occurredAt >= q.to ||
          (q.action != null && q.action != item.action) ||
          (q.resourceId != null && q.resourceId != item.resourceId) ||
          (q.correlationId != null && q.correlationId != item.correlationId)) {
        _invalid();
      }
      if (previous != null &&
          (previous.occurredAt < item.occurredAt ||
              (previous.occurredAt == item.occurredAt &&
                  previous.id.compareTo(item.id) <= 0))) _invalid();
      previous = item;
    }
    return AuditPage(items, next as String?);
  }

  Future<AuditEvent> detail(String id) async {
    if (!auditUuid.hasMatch(id)) {
      throw const ApiFailure(400, 'INVALID_AUDIT_ID');
    }
    final item = AuditEvent.parse(await _get('/$id'));
    if (item.id != id) _invalid();
    return item;
  }
}
