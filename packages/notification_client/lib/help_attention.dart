/// Minimal adult-facing attention request, reusable across native and web hosts.
/// Acknowledgement is a seen receipt; it never establishes contact or resolution.
class HelpAttention {
  final String id, subjectId, deviceId, clientRequestId, reasonCode, state;
  final String? subjectNickname;
  final int createdAt, version;
  final int? acknowledgedAt;
  const HelpAttention._(this.id, this.subjectId, this.deviceId, this.clientRequestId,
      this.reasonCode, this.state, this.subjectNickname, this.createdAt, this.version, this.acknowledgedAt);

  static HelpAttention parse(Object? raw) {
    if (raw is! Map<String, dynamic>) throw const FormatException('Invalid help response');
    for (final key in ['id', 'subjectId', 'deviceId', 'clientRequestId']) {
      if (!validHelpId(raw[key])) throw const FormatException('Invalid help reference');
    }
    final name = raw['subjectNickname'], time = raw['createdAt'], acknowledged = raw['acknowledgedAt'], version = raw['version'];
    if (name != null && (name is! String || name.trim().isEmpty || name.length > 60 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]').hasMatch(name)) ||
        !const {'NEED_HELP', 'UNCOMFORTABLE_CONTENT', 'DEVICE_PROBLEM'}.contains(raw['reasonCode']) ||
        !const {'OPEN', 'ACKNOWLEDGED'}.contains(raw['state']) ||
        !_time(time) || version is! int || version < 0 || version > 9007199254740990 ||
        (acknowledged != null && (!_time(acknowledged) || acknowledged < time)) ||
        (raw['state'] == 'OPEN' && acknowledged != null) ||
        (raw['state'] == 'ACKNOWLEDGED' && acknowledged == null)) {
      throw const FormatException('Invalid help state');
    }
    return HelpAttention._(raw['id'], raw['subjectId'], raw['deviceId'], raw['clientRequestId'],
      raw['reasonCode'], raw['state'], name as String?, time as int, version, acknowledged as int?);
  }
  bool sameRequest(HelpAttention other) => id == other.id && subjectId == other.subjectId &&
    deviceId == other.deviceId && clientRequestId == other.clientRequestId && reasonCode == other.reasonCode && createdAt == other.createdAt;
  String get reason => switch(reasonCode) {
    'NEED_HELP' => '需要监护人帮助', 'UNCOMFORTABLE_CONTENT' => '遇到不适宜的内容',
    'DEVICE_PROBLEM' => '设备使用遇到问题', _ => '求助请求',
  };
}
bool validHelpId(Object? value) => value is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(value);
bool _time(Object? value) => value is int && value >= 0 && value <= 8640000000000000;
