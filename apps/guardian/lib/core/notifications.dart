import 'dart:async';
import 'api.dart';

const notificationRoles = [
  'OWNER',
  'GUARDIAN',
  'ORG_ADMIN',
  'TEACHER',
  'CHILD'
];
const notificationStates = {
  'PENDING',
  'APPROVED_PENDING_DELIVERY',
  'DENIED',
  'CANCELLED',
  'REVOKED',
  'EXPIRED',
  'INVALIDATED'
};
Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_NOTIFICATION_RESPONSE');
bool _id(dynamic v) =>
    v is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(v);
bool _time(dynamic v) => v is int && v > 0 && v <= 8640000000000000;
bool _keys(dynamic v, Set<String> keys) =>
    v is Json && v.length == keys.length && v.keys.every(keys.contains);

class InboxNotice {
  final String id, requestId, subjectId, deviceId, state;
  final int requestVersion, occurredAt;
  final int? readAt;
  const InboxNotice(this.id, this.requestId, this.subjectId, this.deviceId,
      this.state, this.requestVersion, this.occurredAt, this.readAt);
  bool get unread => readAt == null;
  String get title => switch (state) {
        'PENDING' => '新的访问申请',
        'APPROVED_PENDING_DELIVERY' => '访问申请已批准',
        'DENIED' => '访问申请未获批准',
        'CANCELLED' => '访问申请已取消',
        'REVOKED' => '访问授权已撤回',
        'EXPIRED' => '访问申请或授权已到期',
        'INVALIDATED' => '访问申请已失效',
        _ => '申请状态已更新',
      };
  String get description => switch (state) {
        'PENDING' => '打开申请查看原因、申请范围和当前处理进度。',
        'APPROVED_PENDING_DELIVERY' => '批准结果已记录。设备是否生效，请打开申请查看最新回执。',
        'DENIED' => '这次申请未获批准，可在申请详情中查看处理结果。',
        'CANCELLED' => '申请人已取消这次申请，无需继续审批。',
        'REVOKED' => '这次临时访问授权已撤回，请查看当前状态与设备回执。',
        'EXPIRED' => '申请处理时限或临时访问窗口已结束，请查看当前状态。',
        'INVALIDATED' => '关联设备或策略已发生变化，请打开申请查看失效原因。',
        _ => '请打开申请查看最新状态。',
      };
  static InboxNotice parse(dynamic v) {
    if (!_keys(v, {
          'id',
          'requestId',
          'subjectId',
          'deviceId',
          'state',
          'requestVersion',
          'occurredAt',
          'readAt'
        }) ||
        !['id', 'requestId', 'subjectId', 'deviceId'].every((k) => _id(v[k])) ||
        !notificationStates.contains(v['state']) ||
        v['requestVersion'] is! int ||
        v['requestVersion'] < 0 ||
        v['requestVersion'] > 9007199254740991 ||
        !_time(v['occurredAt']) ||
        (v['readAt'] != null && !_time(v['readAt']))) _invalid();
    return InboxNotice(v['id'], v['requestId'], v['subjectId'], v['deviceId'],
        v['state'], v['requestVersion'], v['occurredAt'], v['readAt']);
  }
}

class InboxPage {
  final List<InboxNotice> items;
  final String? nextCursor;
  const InboxPage(this.items, this.nextCursor);
  static InboxPage parse(dynamic v, {bool unreadOnly = false}) {
    if (!_keys(v, {'items', 'nextCursor'}) ||
        v['items'] is! List ||
        v['items'].length > 20 ||
        (v['nextCursor'] != null &&
            (v['nextCursor'] is! String ||
                v['nextCursor'].isEmpty ||
                v['nextCursor'].length > 200 ||
                !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(v['nextCursor'])))) {
      _invalid();
    }
    final rows = (v['items'] as List).map(InboxNotice.parse).toList();
    final ids = <String>{};
    InboxNotice? prior;
    for (final row in rows) {
      if (!ids.add(row.id) ||
          (unreadOnly && !row.unread) ||
          (prior != null &&
              (row.occurredAt > prior.occurredAt ||
                  (row.occurredAt == prior.occurredAt &&
                      row.id.compareTo(prior.id) >= 0)))) _invalid();
      prior = row;
    }
    if (rows.isEmpty && v['nextCursor'] != null) _invalid();
    return InboxPage(List.unmodifiable(rows), v['nextCursor']);
  }
}

class InboxCount {
  final int count;
  final bool capped;
  const InboxCount(this.count, this.capped);
  String get label => '$count${capped ? '+' : ''}';
  static InboxCount parse(dynamic v) {
    if (!_keys(v, {'count', 'capped'}) ||
        v['count'] is! int ||
        v['count'] < 0 ||
        v['count'] > 1000 ||
        v['capped'] is! bool ||
        (v['capped'] && v['count'] != 1000)) _invalid();
    return InboxCount(v['count'], v['capped']);
  }
}

class InboxSnapshot {
  final InboxPage page;
  final InboxCount unread;
  const InboxSnapshot(this.page, this.unread);
}

/// Captures a single authenticated workspace. Server membership stays authoritative.
class NotificationRepository {
  static final _changes = StreamController<String>.broadcast();
  static Stream<String> get changes => _changes.stream;
  final Api api;
  final String root;
  final bool Function() current;
  NotificationRepository(
      {required this.api, required this.root, required this.current});
  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<dynamic> _send(String method, String suffix, {Json? body}) async {
    ensureCurrent();
    try {
      final result =
          await api.send(method, '$root/notifications$suffix', body: body);
      ensureCurrent();
      return result;
    } catch (_) {
      ensureCurrent();
      rethrow;
    }
  }

  Future<InboxCount> count() async =>
      InboxCount.parse(await _send('GET', '/unread-count'));
  Future<InboxSnapshot> load({String? cursor, bool unreadOnly = false}) async {
    final results = await Future.wait<dynamic>([
      _send('GET',
          '?limit=20&unreadOnly=$unreadOnly${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}'),
      count(),
    ]);
    ensureCurrent();
    final page = InboxPage.parse(results[0], unreadOnly: unreadOnly);
    if (cursor != null && page.nextCursor == cursor) _invalid();
    return InboxSnapshot(page, results[1] as InboxCount);
  }

  Future<void> markRead(List<String> ids) async {
    if (ids.isEmpty ||
        ids.length > 50 ||
        ids.toSet().length != ids.length ||
        !ids.every(_id)) {
      throw const ApiFailure(400, 'INVALID_NOTIFICATION_SELECTION');
    }
    final dynamic result = ids.length == 1
        ? await _send('PUT', '/${ids.single}/read')
        : await _send('POST', '/read', body: {'ids': List<String>.of(ids)});
    final List<dynamic> rows;
    if (ids.length == 1) {
      rows = [result];
    } else {
      if (!_keys(result, {'items'}) || result['items'] is! List) _invalid();
      rows = result['items'];
    }
    final seen = <String>{};
    for (final row in rows) {
      if (!_keys(row, {'id', 'readAt'}) ||
          !ids.contains(row['id']) ||
          !_time(row['readAt']) ||
          !seen.add(row['id'])) _invalid();
    }
    if (seen.length != ids.length) _invalid();
    _changes.add(root);
  }
}
