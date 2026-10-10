import 'api.dart';

const supportTypes = [
  'DEVICE_STATUS',
  'CAPABILITIES',
  'CONFIGURATION_METADATA'
];
const supportTypeLabels = {
  'DEVICE_STATUS': '设备状态与版本',
  'CAPABILITIES': '设备能力与授权状态',
  'CONFIGURATION_METADATA': '配置下发记录与指纹',
};
final supportIdentifier =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final supportCode = RegExp(r'^[A-Za-z0-9_-]{43}$');
Never invalidSupport() =>
    throw const ApiFailure(502, 'INVALID_SUPPORT_RESPONSE');
Json supportObject(Object? value) => value is Json ? value : invalidSupport();
String supportId(Object? value) =>
    value is String && supportIdentifier.hasMatch(value)
        ? value
        : invalidSupport();
int supportInteger(Object? value, {int minimum = 0}) =>
    value is int && value >= minimum && value <= 9007199254740991
        ? value
        : invalidSupport();
String supportText(Object? value, int maximum) => value is String &&
        value.isNotEmpty &&
        value.length <= maximum &&
        !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)
    ? value
    : invalidSupport();
String? _optionalText(Object? value, int maximum) =>
    value == null ? null : supportText(value, maximum);
String _state(Object? value, Set<String> allowed) =>
    value is String && allowed.contains(value) ? value : invalidSupport();
List<String> parseSupportTypes(Object? value) {
  if (value is! List ||
      value.isEmpty ||
      value.length > 3 ||
      value.toSet().length != value.length ||
      !value.every(supportTypes.contains)) invalidSupport();
  return List.unmodifiable(supportTypes.where(value.contains));
}

class SupportPairing {
  final String id, recipientActorId, state;
  final String? displayName, verifiedEmail;
  final int version, createdAt, expiresAt;
  SupportPairing._(
      this.id,
      this.recipientActorId,
      this.displayName,
      this.verifiedEmail,
      this.state,
      this.version,
      this.createdAt,
      this.expiresAt);
  static SupportPairing parse(Object? input, {String? actor, String? id}) {
    final o = supportObject(input);
    final value = SupportPairing._(
        supportId(o['id']),
        supportText(o['recipientActorId'], 255),
        _optionalText(o['displayName'], 100),
        _optionalText(o['verifiedEmail'], 254),
        _state(o['state'], {'PENDING', 'CANCELLED', 'CONSUMED', 'EXPIRED'}),
        supportInteger(o['version']),
        supportInteger(o['createdAt']),
        supportInteger(o['expiresAt']));
    if ((actor != null && value.recipientActorId != actor) ||
        (id != null && value.id != id) ||
        value.expiresAt <= value.createdAt ||
        value.expiresAt - value.createdAt > 600000) invalidSupport();
    return value;
  }

  bool pendingAt(int now) => state == 'PENDING' && expiresAt > now;
  String get recipientLabel => displayName ?? verifiedEmail ?? '未提供显示名称';
}

class CreatedSupportPairing {
  final SupportPairing request;
  final String? code;
  CreatedSupportPairing._(this.request, this.code);
  CreatedSupportPairing refreshed(SupportPairing next) {
    if (next.id != request.id ||
        next.recipientActorId != request.recipientActorId ||
        next.version < request.version ||
        next.createdAt != request.createdAt ||
        next.expiresAt != request.expiresAt) invalidSupport();
    return CreatedSupportPairing._(next, next.state == 'PENDING' ? code : null);
  }

  static CreatedSupportPairing parse(Object? input, String actor) {
    final o = supportObject(input),
        request = SupportPairing.parse(o['request'], actor: actor),
        code = o['code'];
    if (code != null &&
        (code is! String ||
            !supportCode.hasMatch(code) ||
            request.state != 'PENDING')) invalidSupport();
    return CreatedSupportPairing._(request, code as String?);
  }
}

class SupportGrant {
  final String id,
      tenantId,
      deviceId,
      registrationId,
      creatorActorId,
      recipientActorId,
      state;
  final String? recipientDisplayName, recipientVerifiedEmail;
  final List<String> diagnosticTypes;
  final int version, createdAt, expiresAt;
  SupportGrant._(
      this.id,
      this.tenantId,
      this.deviceId,
      this.registrationId,
      this.creatorActorId,
      this.recipientActorId,
      this.recipientDisplayName,
      this.recipientVerifiedEmail,
      this.diagnosticTypes,
      this.state,
      this.version,
      this.createdAt,
      this.expiresAt);
  static SupportGrant parse(Object? input,
      {String? tenant, String? recipient, String? id}) {
    final o = supportObject(input);
    final value = SupportGrant._(
        supportId(o['id']),
        supportId(o['tenantId']),
        supportId(o['deviceId']),
        supportId(o['registrationId']),
        supportText(o['creatorActorId'], 255),
        supportText(o['recipientActorId'], 255),
        _optionalText(o['recipientDisplayName'], 100),
        _optionalText(o['recipientVerifiedEmail'], 254),
        parseSupportTypes(o['diagnosticTypes']),
        _state(o['state'], {'ACTIVE', 'REVOKED', 'EXPIRED'}),
        supportInteger(o['version']),
        supportInteger(o['createdAt']),
        supportInteger(o['expiresAt']));
    if ((tenant != null && value.tenantId != tenant) ||
        (recipient != null && value.recipientActorId != recipient) ||
        (id != null && value.id != id) ||
        value.expiresAt <= value.createdAt ||
        value.expiresAt - value.createdAt > 86400000) invalidSupport();
    return value;
  }

  bool withinTerm(int now) => state == 'ACTIVE' && expiresAt > now;
  String get recipientLabel =>
      recipientDisplayName ?? recipientVerifiedEmail ?? '未提供显示名称';
}

class SupportPage<T> {
  final List<T> items;
  final String? nextCursor;
  SupportPage(List<T> items, this.nextCursor)
      : items = List.unmodifiable(items);
  static SupportPage<T> parse<T>(
      Object? input, T Function(Object?) parse, String Function(T) id,
      {String? after}) {
    final o = supportObject(input), values = o['items'];
    if (values is! List || values.length > 25) invalidSupport();
    final items = values.map(parse).toList();
    String previous = after ?? '';
    for (final item in items) {
      final current = id(item);
      if (current.compareTo(previous) <= 0) invalidSupport();
      previous = current;
    }
    final cursor = o['nextCursor'];
    if (cursor != null && (supportId(cursor) != previous || items.length != 25))
      invalidSupport();
    return SupportPage(items, cursor as String?);
  }
}

/// Frozen input and idempotency key survive ambiguous retries in this page only.
class SupportGrantDraft {
  final String tenantId,
      deviceId,
      registrationId,
      recipientActorId,
      pairingCode,
      key;
  final int deviceVersion, durationMinutes;
  final List<String> diagnosticTypes;
  SupportGrantDraft(
      {required this.tenantId,
      required this.deviceId,
      required this.registrationId,
      required this.recipientActorId,
      required this.pairingCode,
      required this.deviceVersion,
      required this.durationMinutes,
      required List<String> diagnosticTypes,
      String? key})
      : diagnosticTypes = List.unmodifiable(parseSupportTypes(diagnosticTypes)),
        key = key ?? requestId() {
    for (final id in [tenantId, deviceId, registrationId]) {
      supportId(id);
    }
    supportText(recipientActorId, 255);
    supportInteger(deviceVersion);
    if (!supportCode.hasMatch(pairingCode) ||
        durationMinutes < 5 ||
        durationMinutes > 1440)
      throw const ApiFailure(400, 'INVALID_SUPPORT_SELECTION');
  }
  Json get body => {
        'pairingCode': pairingCode,
        'recipientActorId': recipientActorId,
        'registrationId': registrationId,
        'diagnosticTypes': diagnosticTypes,
        'durationMinutes': durationMinutes
      };
}

bool ambiguousSupportFailure(ApiFailure failure) =>
    failure.status == 0 || failure.status >= 500;
String supportErrorMessage(ApiFailure failure) => switch (failure.code) {
      'SUPPORT_PAIRING_UNAVAILABLE' => '配对码已过期、已取消或已使用。请让接收人重新生成。',
      'SUPPORT_PAIRING_ALREADY_USED' => '配对已用于授权，请刷新授权列表；如需结束访问，请撤销对应授权。',
      'SUPPORT_PAIRING_CAPACITY_REACHED' => '已有三个待使用的配对请求，请先取消不再需要的请求。',
      'SUPPORT_PAIRING_RATE_LIMITED' => '操作过于频繁，请等候一分钟后重试。',
      'SUPPORT_GRANT_CAPACITY_REACHED' => '有效授权数量已达上限，请先撤销不再需要的授权。',
      'SUPPORT_RECIPIENT_CHANGED' => '接收人身份不一致，请重新核对配对码。',
      'SUPPORT_DEVICE_SCOPE_CHANGED' => '设备已重新注册或绑定发生变化，请关闭窗口并刷新设备。',
      'INVALID_SUPPORT_SELECTION' => '请核对配对码、诊断范围及授权时长。',
      'INVALID_SUPPORT_RESPONSE' => '响应与当前账号或授权范围不一致，已隐藏结果。请刷新后重试。',
      _ => failure.message,
    };
