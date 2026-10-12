import 'api.dart';

/// Minimal, validated projection; no private child message or adult identity is returned.
class HelpRequest {
  final String id, subjectId, deviceId, clientRequestId, reasonCode, state;
  final int createdAt, version;
  final int? acknowledgedAt;

  const HelpRequest._(
      this.id,
      this.subjectId,
      this.deviceId,
      this.clientRequestId,
      this.reasonCode,
      this.state,
      this.createdAt,
      this.acknowledgedAt,
      this.version);

  static HelpRequest parse(Object? input) {
    if (input is! Map<String, dynamic>) _invalid();
    final value = input;
    final id = _id(value['id']);
    final subject = _id(value['subjectId']);
    final device = _id(value['deviceId']);
    final client = _id(value['clientRequestId']);
    final reason = value['reasonCode'];
    final state = value['state'];
    final createdAt = value['createdAt'];
    final acknowledgedAt = value['acknowledgedAt'];
    final version = value['version'];
    if (!const {'NEED_HELP', 'UNCOMFORTABLE_CONTENT', 'DEVICE_PROBLEM'}
            .contains(reason) ||
        !const {'OPEN', 'ACKNOWLEDGED'}.contains(state) ||
        createdAt is! int ||
        createdAt < 0 ||
        (acknowledgedAt != null &&
            (acknowledgedAt is! int || acknowledgedAt < createdAt)) ||
        version is! int ||
        version < 0 ||
        (state == 'OPEN' && acknowledgedAt != null) ||
        (state == 'ACKNOWLEDGED' && acknowledgedAt == null)) _invalid();
    return HelpRequest._(id, subject, device, client, reason as String,
        state as String, createdAt, acknowledgedAt as int?, version);
  }
}

String _id(Object? value) {
  if (value is! String ||
      !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(value)) _invalid();
  return value;
}

Never _invalid() => throw const ApiFailure(502, 'INVALID_RESPONSE');

String helpReason(String code) => switch (code) {
      'NEED_HELP' => '需要监护人帮助',
      'UNCOMFORTABLE_CONTENT' => '遇到不适宜的内容',
      'DEVICE_PROBLEM' => '设备使用遇到问题',
      _ => '求助请求',
    };
