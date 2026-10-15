import 'api.dart';
import 'device_management.dart';

final _id =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
bool isAgentBindingId(Object? value) => value is String && _id.hasMatch(value);
bool _integer(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991;
Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_MANAGED_BINDING_RESPONSE');
Json _object(Object? value, Set<String> fields) {
  if (value is! Json ||
      value.length != fields.length ||
      !value.keys.every(fields.contains)) _invalid();
  return value;
}

/// A historical identity proof result. It never asserts device policy enforcement.
class ManagedAgentBinding {
  final String id, enrollmentId, deviceId, registrationId, state;
  final int version, createdAt, expiresAt;
  final int? verifiedAt;
  const ManagedAgentBinding(
      {required this.id,
      required this.enrollmentId,
      required this.deviceId,
      required this.registrationId,
      required this.state,
      required this.version,
      required this.createdAt,
      required this.expiresAt,
      this.verifiedAt});
  factory ManagedAgentBinding.parse(Object? value, String enrollment) {
    final raw = _object(value, {
      'id',
      'enrollmentId',
      'deviceId',
      'registrationId',
      'state',
      'version',
      'createdAt',
      'expiresAt',
      'verifiedAt',
      'systemControlAvailable'
    });
    if (!['id', 'enrollmentId', 'deviceId', 'registrationId']
            .every((key) => isAgentBindingId(raw[key])) ||
        raw['enrollmentId'] != enrollment ||
        !const {'PENDING', 'VERIFIED', 'REVOKED', 'EXPIRED'}
            .contains(raw['state']) ||
        !['version', 'createdAt', 'expiresAt']
            .every((key) => _integer(raw[key])) ||
        raw['version'] < 1 ||
        raw['expiresAt'] <= raw['createdAt'] ||
        raw['expiresAt'] - raw['createdAt'] > 600000 ||
        raw['systemControlAvailable'] != false ||
        (raw['verifiedAt'] != null &&
            (!_integer(raw['verifiedAt']) ||
                raw['verifiedAt'] < raw['createdAt'])) ||
        (raw['state'] == 'VERIFIED' && raw['verifiedAt'] == null) ||
        (const {'PENDING', 'EXPIRED'}.contains(raw['state']) &&
            raw['verifiedAt'] != null)) _invalid();
    return ManagedAgentBinding(
        id: raw['id'],
        enrollmentId: raw['enrollmentId'],
        deviceId: raw['deviceId'],
        registrationId: raw['registrationId'],
        state: raw['state'],
        version: raw['version'],
        createdAt: raw['createdAt'],
        expiresAt: raw['expiresAt'],
        verifiedAt: raw['verifiedAt']);
  }
  String stateAt(DateTime now) =>
      state == 'PENDING' && expiresAt <= now.millisecondsSinceEpoch
          ? 'EXPIRED'
          : state;
}

/// One enrollment's setup status, current association and bounded device choices.
class ManagedAgentBindingContext {
  final String enrollmentId, subjectId, reasonCode;
  final bool ready;
  final ManagedAgentBinding? currentBinding;
  final List<DeviceManagementRecord> candidates;
  final String? nextCursor;
  const ManagedAgentBindingContext(
      {required this.enrollmentId,
      required this.subjectId,
      required this.reasonCode,
      required this.ready,
      required this.currentBinding,
      required this.candidates,
      required this.nextCursor});
  factory ManagedAgentBindingContext.parse(
      Object? value, String enrollment, String subject,
      {String? after}) {
    final raw = _object(value, {
      'enrollmentId',
      'subjectId',
      'ready',
      'reasonCode',
      'currentBinding',
      'candidates'
    });
    const reasons = {
      'READY',
      'ENROLLMENT_NOT_VERIFIED',
      'SUBJECT_INACTIVE',
      'RELEASE_TRUST_REQUIRED',
      'EMM_UNAVAILABLE',
      'PROVIDER_EVIDENCE_UNSUPPORTED',
      'ENTERPRISE_BINDING_NOT_ACTIVE',
      'MANAGED_ANDROID_CONTRACT_REQUIRED',
      'MANAGED_ENTERPRISE_CHANGED',
      'EMM_PROVIDER_MISMATCH',
      'ENTERPRISE_BINDING_NOT_FOUND'
    };
    if (raw['enrollmentId'] != enrollment ||
        raw['subjectId'] != subject ||
        !reasons.contains(raw['reasonCode']) ||
        raw['ready'] is! bool ||
        raw['ready'] != (raw['reasonCode'] == 'READY')) _invalid();
    final page = _object(raw['candidates'], {'items', 'nextCursor'});
    if (page['items'] is! List ||
        (page['items'] as List).length > 50 ||
        (page['nextCursor'] != null && !isAgentBindingId(page['nextCursor']))) {
      _invalid();
    }
    final devices = <DeviceManagementRecord>[];
    String previous = after ?? '';
    for (final item in page['items']) {
      if (item is! Json || !isAgentBindingId(item['id'])) _invalid();
      final device =
          DeviceManagementRecord.fromJson(item, deviceId: item['id']);
      if (device.subjectId != subject ||
          device.state != 'ACTIVE' ||
          device.id.compareTo(previous) <= 0) _invalid();
      previous = device.id;
      devices.add(device);
    }
    if (page['nextCursor'] != null &&
        (devices.isEmpty || page['nextCursor'] != devices.last.id)) _invalid();
    return ManagedAgentBindingContext(
        enrollmentId: enrollment,
        subjectId: subject,
        ready: raw['ready'],
        reasonCode: raw['reasonCode'],
        currentBinding: raw['currentBinding'] == null
            ? null
            : ManagedAgentBinding.parse(raw['currentBinding'], enrollment),
        candidates: List.unmodifiable(devices),
        nextCursor: page['nextCursor']);
  }
}

String managedBindingReason(String code) => switch (code) {
      'READY' => '选择这位学生已经激活的儿童端设备，发起身份关联。',
      'ENROLLMENT_NOT_VERIFIED' => '请先完成这条注册记录的提供方身份核对。',
      'SUBJECT_INACTIVE' => '学生档案已归档，暂不能建立新关联。',
      'RELEASE_TRUST_REQUIRED' => '儿童端发布版本尚未完成接入配置，请联系平台管理员。',
      'PROVIDER_EVIDENCE_UNSUPPORTED' => '当前设备服务尚未接入儿童端身份核验，请联系平台管理员。',
      'MANAGED_ANDROID_CONTRACT_REQUIRED' => '机构合同的受管设备权益不可用，请联系机构管理员核对。',
      'ENTERPRISE_BINDING_NOT_ACTIVE' ||
      'ENTERPRISE_BINDING_NOT_FOUND' =>
        '机构资格尚未就绪，请先完成机构审核。',
      'MANAGED_ENTERPRISE_CHANGED' ||
      'EMM_PROVIDER_MISMATCH' =>
        '机构的设备服务已变化，请重新核对接入条件。',
      _ => '设备服务暂不可用，请稍后刷新。'
    };

String managedBindingError(Object error) {
  if (error is! ApiFailure) return '暂时未能完成操作，请刷新后重试。';
  return switch (error.code) {
    'INVALID_MANAGED_BINDING_RESPONSE' => '返回资料与当前注册记录不一致，已停止操作。请刷新后重试。',
    'MANAGED_AGENT_BINDING_UNAVAILABLE' => '儿童端身份关联尚未开通，请联系平台管理员。',
    'MANAGED_BINDING_ALREADY_EXISTS' => '这台设备或本次注册已有关联，请刷新查看当前记录。',
    'MANAGED_BINDING_VERIFY_RATE_LIMITED' => '正在等待设备反馈，请至少间隔 5 秒后再核验。',
    'MANAGED_BINDING_RATE_LIMITED' ||
    'MANAGED_BINDING_PENDING_LIMIT' =>
      '当前请求较多，请稍后再试。',
    'MANAGED_BINDING_EXPIRED' => '本次关联请求已到期，请重新发起。',
    'MANAGED_BINDING_DEVICE_MISMATCH' ||
    'MANAGED_BINDING_REGISTRATION_CHANGED' ||
    'MANAGED_BINDING_CONTEXT_CHANGED' =>
      '设备注册或学生归属已变化，请刷新并重新选择。',
    'MANAGED_AGENT_PROOF_INVALID' => '设备反馈尚未通过身份校验，请检查儿童端版本并重新核验。',
    'MANAGED_BINDING_REQUEST_REUSED' => '原操作内容已变化，请先刷新当前关联记录。',
    'MANAGED_BINDING_NOT_PENDING' => '关联状态已变化，请刷新后查看。',
    'MANAGED_BINDING_SUBJECT_INACTIVE' => '学生档案已归档，暂不能继续关联。',
    'MANAGED_BINDING_NOT_FOUND' => '未找到此关联记录，请刷新后查看。',
    _ => error.message,
  };
}
