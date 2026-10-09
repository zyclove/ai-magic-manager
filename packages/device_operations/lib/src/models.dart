/// Validates an identifier before placing it in a resource path.
String canonicalId(String value) {
  if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      .hasMatch(value)) {
    throw const FormatException('Invalid resource identifier');
  }
  return value;
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > 512) {
    throw FormatException('Invalid $key');
  }
  return value;
}

int _integer(Map<String, dynamic> json, String key) {
  final value = json[key];
  // Values must round-trip through JavaScript without precision loss.
  if (value is! int || value < 0 || value > 9007199254740991) {
    throw FormatException('Invalid $key');
  }
  return value;
}

DateTime _date(Map<String, dynamic> json, String key) {
  final value = _integer(json, key);
  if (value > 8640000000000000) throw FormatException('Invalid $key');
  return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}

List<String> _codes(Map<String, dynamic> json, String key) {
  final values = json[key];
  if (values is! List ||
      values.isEmpty ||
      values.length > 32 ||
      values.any((v) => v is! String || v.isEmpty || v.length > 128)) {
    throw FormatException('Invalid $key');
  }
  final codes = values.cast<String>();
  if (codes.toSet().length != codes.length) {
    throw FormatException('Duplicate $key');
  }
  return List.unmodifiable(codes);
}

const consequenceLabels = <String, String>{
  'REVOKE_REMOTE_BUSINESS_CREDENTIALS': '撤销此注册的云端业务凭证',
  'INVALIDATE_ACCESS_REQUESTS': '使此设备现有的临时访问窗口失效',
  'REQUEST_OWN_AGENT_CACHE_AND_CREDENTIAL_CLEANUP': '请求设备清理本代理的缓存和业务凭证',
  'REMOVE_REGISTRATION_KEY_AFTER_ACK': '设备收到清理回执确认后移除原注册密钥',
};
const limitationLabels = <String, String>{
  'LOCAL_ERASURE_UNVERIFIED': '本地清理由设备自报，平台不能独立验证',
  'NO_SYSTEM_UNMANAGE': '不解除系统级受管注册',
  'NO_DEVICE_WIPE': '不擦除整机',
  'NO_OTHER_APP_DATA_REMOVAL': '不删除其他应用或个人数据',
  'NO_CLOUD_HISTORY_DELETION': '不删除云端历史、审计、订阅或席位',
  'CACHED_COMMAND_CANNOT_BE_RECALLED_OFFLINE': '离线设备已缓存的有效清理命令无法召回',
};

/// Snapshot from the management API, never from local device claims.
class DeviceSnapshot {
  final String id, registrationId, displayName, managementMode, state;
  final int version;
  DeviceSnapshot.fromJson(Map<String, dynamic> json)
      : id = canonicalId(_string(json, 'id')),
        registrationId = canonicalId(_string(json, 'registrationId')),
        displayName = _string(json, 'displayName'),
        managementMode = _string(json, 'managementMode'),
        state = _string(json, 'state'),
        version = _integer(json, 'version');

  bool get canExit =>
      managementMode == 'BYOD' && (state == 'ACTIVE' || state == 'REVOKED');
}

/// Scope includes the authenticated subject, not a user-editable role selector.
class ExitScope {
  final String actorId, tenantId, deviceId, registrationId, role;
  ExitScope(
      {required this.actorId,
      required String tenantId,
      required String deviceId,
      required String registrationId,
      required this.role})
      : tenantId = canonicalId(tenantId),
        deviceId = canonicalId(deviceId),
        registrationId = canonicalId(registrationId) {
    if (actorId.isEmpty || actorId.length > 512) {
      throw ArgumentError('Invalid actor');
    }
  }
  bool get canManage => const {'OWNER', 'GUARDIAN', 'ORG_ADMIN'}.contains(role);
  bool get canRead => canManage || role == 'AUDITOR';
  String get storageIdentity =>
      '$actorId\u0000$tenantId\u0000$deviceId\u0000$registrationId';
}

/// Server-generated consequences bound to a specific registration and version.
class ExitPreview {
  final String id, deviceId, registrationId, action, hash;
  final int deviceVersion;
  final List<String> consequences, limitations;
  final DateTime expiresAt;
  ExitPreview.fromJson(Map<String, dynamic> json)
      : id = canonicalId(_string(json, 'id')),
        deviceId = canonicalId(_string(json, 'deviceId')),
        registrationId = canonicalId(_string(json, 'registrationId')),
        action = _string(json, 'action'),
        hash = _string(json, 'hash'),
        deviceVersion = _integer(json, 'deviceVersion'),
        consequences = _codes(json, 'consequences'),
        limitations = _codes(json, 'limitations'),
        expiresAt = _date(json, 'expiresAt') {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid preview hash');
    }
  }
  bool get understood =>
      action == 'AGENT_UNENROLL' &&
      consequences.toSet().containsAll(consequenceLabels.keys) &&
      consequences.every(consequenceLabels.containsKey) &&
      limitations.toSet().containsAll(limitationLabels.keys) &&
      limitations.every(limitationLabels.containsKey);
  bool matches(ExitScope scope) =>
      deviceId == scope.deviceId && registrationId == scope.registrationId;
}

/// Cloud access and local evidence are separate parts of an exit operation.
class ExitOperation {
  final String id,
      deviceId,
      registrationId,
      commandId,
      action,
      state,
      remoteAccess,
      localEvidence;
  final String? reasonCode;
  final int version;
  final DateTime issuedAt, notAfter;
  ExitOperation.fromJson(Map<String, dynamic> json)
      : id = canonicalId(_string(json, 'id')),
        deviceId = canonicalId(_string(json, 'deviceId')),
        registrationId = canonicalId(_string(json, 'registrationId')),
        commandId = canonicalId(_string(json, 'commandId')),
        action = _string(json, 'action'),
        state = _string(json, 'state'),
        remoteAccess = _string(json, 'remoteAccess'),
        localEvidence = _string(json, 'localEvidence'),
        reasonCode =
            json['reasonCode'] == null ? null : _string(json, 'reasonCode'),
        issuedAt = _date(json, 'issuedAt'),
        notAfter = _date(json, 'notAfter'),
        version = _integer(json, 'version') {
    if (!notAfter.isAfter(issuedAt) ||
        (state == 'CLEANUP_REPORTED' &&
            localEvidence != 'DEVICE_REPORT_UNVERIFIED')) {
      throw const FormatException('Inconsistent operation evidence');
    }
  }
  bool get understood =>
      action == 'AGENT_UNENROLL' &&
      remoteAccess == 'REVOKED' &&
      const {'NONE', 'DEVICE_REPORT_UNVERIFIED'}.contains(localEvidence) &&
      stateLabels.containsKey(state);
  bool get canCancel =>
      understood &&
      const {
        'WAITING_FOR_AGENT',
        'COMMAND_SERVED',
        'COMMAND_RECEIVED',
        'CLEANUP_FAILED'
      }.contains(state);
  bool matches(ExitScope scope) =>
      deviceId == scope.deviceId && registrationId == scope.registrationId;
  String get stateLabel => stateLabels[state] ?? '未知状态，请更新客户端或联系管理员';
}

const stateLabels = <String, String>{
  'WAITING_FOR_AGENT': '等待设备领取命令',
  'COMMAND_SERVED': '命令已提供，等待设备回执',
  'COMMAND_RECEIVED': '设备已确认收到命令',
  'CLEANUP_FAILED': '设备自报清理失败',
  'CLEANUP_REPORTED': '设备自报已清理（未独立验证）',
  'CLEANUP_CANCELLED': '清理任务已取消',
  'CLEANUP_EXPIRED': '清理任务已到期，本地结果未确认',
};
