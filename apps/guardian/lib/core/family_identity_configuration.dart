import 'api.dart';

const identityRequiredAcceptanceCases = {
  'REAL_SMS_DELIVERY',
  'REAL_WECHAT_NATIVE_AUTH',
  'CHANGE_PHONE_E2E',
  'RECOVER_PHONE_E2E',
  'BIND_WECHAT_E2E',
  'UNBIND_WECHAT_E2E',
  'IDENTITY_CONFLICTS',
  'OLD_SESSION_REVOKED',
  'INTERRUPTION_RECOVERY',
  'MYSQL_CONCURRENCY_ROLLBACK',
  'SIGNED_DEVICE_BUILD',
  'LOG_REDACTION',
};

bool isIdentityProviderId(String value) => RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
    .hasMatch(value);
bool isIdentityProviderDigest(String value) =>
    RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
bool isIdentityProviderEnvironment(String value) =>
    RegExp(r'^[A-Za-z][A-Za-z0-9_-]{2,63}$').hasMatch(value);

Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
Json _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(value.keys.toSet()).isNotEmpty) _invalid();
  return value;
}

String _text(Object? value, {int maximum = 500, bool empty = false}) {
  if (value is! String ||
      value.length > maximum ||
      (!empty && value.isEmpty) ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) _invalid();
  return value;
}

bool _flag(Object? value) {
  if (value is! bool) _invalid();
  return value;
}

int _integer(Object? value, {int minimum = 0}) {
  if (value is! int || value < minimum || value > 9007199254740991) _invalid();
  return value;
}

String _id(Object? value) {
  final id = _text(value, maximum: 36);
  if (!isIdentityProviderId(id)) _invalid();
  return id;
}

String _state(Object? value, Set<String> states) {
  final state = _text(value, maximum: 64);
  if (!states.contains(state)) _invalid();
  return state;
}

void _runtime(Json value) {
  if (!const {'APPLY_REQUIRED', 'APPLIED_CLOSED'}
          .contains(value['runtimeStatus']) ||
      value['salesAllowed'] != false) _invalid();
}

List<IdentityProviderCheck> _checks(Object? value, {bool acceptance = false}) {
  if (value is! List || value.length > 64) _invalid();
  final checks = value.map(IdentityProviderCheck.parse).toList(growable: false);
  final ids = checks.map((check) => check.id).toSet();
  if (ids.length != checks.length) _invalid();
  if (acceptance &&
      (ids.length != identityRequiredAcceptanceCases.length ||
          !ids.containsAll(identityRequiredAcceptanceCases) ||
          checks.any((check) => check.status == 'READY'))) _invalid();
  return List.unmodifiable(checks);
}

class IdentityProviderSettings {
  final String smsSignName,
      smsTemplateCode,
      wechatAppId,
      parentPackageName,
      parentCertificateSha256;
  const IdentityProviderSettings(
      {required this.smsSignName,
      required this.smsTemplateCode,
      required this.wechatAppId,
      required this.parentPackageName,
      required this.parentCertificateSha256});
  factory IdentityProviderSettings.parse(Object? value) {
    final object = _object(value, {
      'smsSignName',
      'smsTemplateCode',
      'wechatAppId',
      'parentPackageName',
      'parentCertificateSha256'
    });
    return IdentityProviderSettings(
        smsSignName: _text(object['smsSignName'], maximum: 32, empty: true),
        smsTemplateCode:
            _text(object['smsTemplateCode'], maximum: 64, empty: true),
        wechatAppId: _text(object['wechatAppId'], maximum: 64, empty: true),
        parentPackageName:
            _text(object['parentPackageName'], maximum: 200, empty: true),
        parentCertificateSha256:
            _text(object['parentCertificateSha256'], maximum: 64, empty: true));
  }
  Json toJson() => {
        'smsSignName': smsSignName,
        'smsTemplateCode': smsTemplateCode,
        'wechatAppId': wechatAppId,
        'parentPackageName': parentPackageName,
        'parentCertificateSha256': parentCertificateSha256
      };
}

class IdentityProviderCredentials {
  final bool otpHmacKey,
      smsAccessKeyId,
      smsAccessKeySecret,
      smsSecurityToken,
      wechatAppSecret;
  const IdentityProviderCredentials(this.otpHmacKey, this.smsAccessKeyId,
      this.smsAccessKeySecret, this.smsSecurityToken, this.wechatAppSecret);
  factory IdentityProviderCredentials.parse(Object? value) {
    final object = _object(value, {
      'otpHmacKey',
      'smsAccessKeyId',
      'smsAccessKeySecret',
      'smsSecurityToken',
      'wechatAppSecret'
    });
    return IdentityProviderCredentials(
        _flag(object['otpHmacKey']),
        _flag(object['smsAccessKeyId']),
        _flag(object['smsAccessKeySecret']),
        _flag(object['smsSecurityToken']),
        _flag(object['wechatAppSecret']));
  }
}

class IdentityProviderVersion {
  final String id, readinessStatus;
  final int version, baseVersion, createdAt;
  final IdentityProviderSettings settings;
  final IdentityProviderCredentials credentials;
  const IdentityProviderVersion(this.id, this.version, this.baseVersion,
      this.createdAt, this.settings, this.credentials, this.readinessStatus);
  factory IdentityProviderVersion.parse(Object? value) {
    final object = _object(value, {
      'id',
      'version',
      'baseVersion',
      'createdAt',
      'settings',
      'credentials',
      'readinessStatus'
    });
    final version = _integer(object['version'], minimum: 1),
        base = _integer(object['baseVersion']);
    if (version != base + 1) _invalid();
    return IdentityProviderVersion(
        _id(object['id']),
        version,
        base,
        _integer(object['createdAt']),
        IdentityProviderSettings.parse(object['settings']),
        IdentityProviderCredentials.parse(object['credentials']),
        _state(object['readinessStatus'], {'READY', 'BLOCKED'}));
  }
}

class IdentityProviderCapabilities {
  final bool canRead,
      canManage,
      canTest,
      secretStorageReady,
      releasePreparationReady;
  const IdentityProviderCapabilities(this.canRead, this.canManage, this.canTest,
      this.secretStorageReady, this.releasePreparationReady);
  factory IdentityProviderCapabilities.parse(Object? value) {
    final object = _object(value, {
      'canRead',
      'canManage',
      'canTest',
      'secretStorageReady',
      'releasePreparationReady'
    });
    return IdentityProviderCapabilities(
        _flag(object['canRead']),
        _flag(object['canManage']),
        _flag(object['canTest']),
        _flag(object['secretStorageReady']),
        _flag(object['releasePreparationReady']));
  }
}

class IdentityProviderCheck {
  final String id, label, stage, status, reasonCode, action;
  const IdentityProviderCheck(this.id, this.label, this.stage, this.status,
      this.reasonCode, this.action);
  factory IdentityProviderCheck.parse(Object? value) {
    final object = _object(
        value, {'id', 'label', 'stage', 'status', 'reasonCode', 'action'});
    final id = _text(object['id'], maximum: 80),
        stage = _text(object['stage'], maximum: 40),
        status = _state(object['status'], {'READY', 'PENDING', 'BLOCKED'});
    if (!RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(id) ||
        stage == '真实联调' && status == 'READY') _invalid();
    return IdentityProviderCheck(
        id,
        _text(object['label'], maximum: 160),
        stage,
        status,
        _text(object['reasonCode'], maximum: 80),
        _text(object['action'], maximum: 500));
  }
}

class IdentityProviderStatus {
  final String environmentId, runtimeStatus;
  final IdentityProviderCapabilities capabilities;
  final int latestVersion;
  final IdentityProviderVersion? version;
  final List<IdentityProviderCheck> readinessChecks;
  const IdentityProviderStatus(this.environmentId, this.capabilities,
      this.latestVersion, this.version, this.readinessChecks,
      [this.runtimeStatus = 'APPLY_REQUIRED']);
  factory IdentityProviderStatus.parse(Object? value) {
    final object = _object(value, {
      'environmentId',
      'capabilities',
      'latestVersion',
      'version',
      'readinessChecks',
      'runtimeStatus',
      'salesAllowed'
    });
    _runtime(object);
    final environment = _text(object['environmentId'], maximum: 64);
    if (!isIdentityProviderEnvironment(environment)) _invalid();
    final latest = _integer(object['latestVersion']);
    final version = object['version'] == null
        ? null
        : IdentityProviderVersion.parse(object['version']);
    if ((latest == 0) != (version == null) ||
        version != null && latest != version.version) _invalid();
    return IdentityProviderStatus(
        environment,
        IdentityProviderCapabilities.parse(object['capabilities']),
        latest,
        version,
        _checks(object['readinessChecks']),
        object['runtimeStatus'] as String);
  }
}

class IdentityProviderValidation {
  final String versionId, readinessStatus;
  final List<IdentityProviderCheck> checks;
  const IdentityProviderValidation(
      this.versionId, this.readinessStatus, this.checks);
  factory IdentityProviderValidation.parse(Object? value) {
    final object = _object(value, {
      'versionId',
      'readinessStatus',
      'checks',
      'runtimeStatus',
      'salesAllowed'
    });
    _runtime(object);
    return IdentityProviderValidation(
        _id(object['versionId']),
        _state(object['readinessStatus'], {'READY', 'BLOCKED'}),
        _checks(object['checks']));
  }
}

class IdentityProviderReleasePreparation {
  final String id, versionId, status, reasonCode;
  const IdentityProviderReleasePreparation(
      this.id, this.versionId, this.status, this.reasonCode);
  factory IdentityProviderReleasePreparation.parse(Object? value) {
    final object = _object(value, {
      'id',
      'versionId',
      'status',
      'reasonCode',
      'runtimeStatus',
      'salesAllowed'
    });
    _runtime(object);
    return IdentityProviderReleasePreparation(
        _id(object['id']),
        _id(object['versionId']),
        _state(object['status'], {'PREPARED', 'BLOCKED'}),
        _text(object['reasonCode'], maximum: 80));
  }
}

class IdentityProviderAcceptanceRun {
  final String id, versionId, environmentId, providerJarSha256, parentApkSha256;
  final int createdAt;
  final List<IdentityProviderCheck> checks;
  final String? releaseOperationId;
  final int? runtimeRevision, expiresAt;
  const IdentityProviderAcceptanceRun(
      this.id,
      this.versionId,
      this.environmentId,
      this.providerJarSha256,
      this.parentApkSha256,
      this.createdAt,
      this.checks,
      {this.releaseOperationId,
      this.runtimeRevision,
      this.expiresAt});
  factory IdentityProviderAcceptanceRun.parse(Object? value) {
    const legacyKeys = {
      'id',
      'versionId',
      'environmentId',
      'providerJarSha256',
      'parentApkSha256',
      'createdAt',
      'status',
      'checks',
      'runtimeStatus',
      'salesAllowed',
      'providerRequestsPerformed'
    };
    final bound = value is Json && value.containsKey('releaseOperationId');
    final object = _object(
        value,
        bound
            ? {
                ...legacyKeys,
                'releaseOperationId',
                'runtimeRevision',
                'expiresAt'
              }
            : legacyKeys);
    _runtime(object);
    if (object['status'] != 'BLOCKED' ||
        object['providerRequestsPerformed'] != false) _invalid();
    final environment = _text(object['environmentId'], maximum: 64),
        jar = _text(object['providerJarSha256'], maximum: 64),
        apk = _text(object['parentApkSha256'], maximum: 64);
    if (!isIdentityProviderEnvironment(environment) ||
        !isIdentityProviderDigest(jar) ||
        !isIdentityProviderDigest(apk)) _invalid();
    final releaseId = bound && object['releaseOperationId'] != null
        ? _id(object['releaseOperationId'])
        : null;
    final revision = bound && object['runtimeRevision'] != null
        ? _integer(object['runtimeRevision'])
        : null;
    final expiresAt = bound && object['expiresAt'] != null
        ? _integer(object['expiresAt'])
        : null;
    final createdAt = _integer(object['createdAt']);
    if ((releaseId == null) != (revision == null) ||
        (releaseId == null) != (expiresAt == null) ||
        expiresAt != null && expiresAt <= createdAt) _invalid();
    return IdentityProviderAcceptanceRun(
        _id(object['id']),
        _id(object['versionId']),
        environment,
        jar,
        apk,
        createdAt,
        _checks(object['checks'], acceptance: true),
        releaseOperationId: releaseId,
        runtimeRevision: revision,
        expiresAt: expiresAt);
  }
}

String identityProviderErrorMessage(Object failure) {
  if (failure is! ApiFailure) return '操作未完成，请核对当前状态后重试。';
  return switch (failure.code) {
    'REAUTH_REQUIRED' || 'UNAUTHENTICATED' => '请先完成近期多因素安全验证。密钥输入已清除，验证后请重新填写。',
    'SCOPE_DENIED' => '当前账号没有此平台操作权限。',
    'WORKSPACE_CHANGED' => '账号会话已变化，请重新打开本页。',
    'IDENTITY_PROVIDER_VERSION_CONFLICT' => '配置已被更新，请刷新后重新填写。',
    'IDENTITY_PROVIDER_ID_CONFLICT' => '此操作编号已用于其他内容，请核对原操作结果。',
    'IDENTITY_PROVIDER_NOT_FOUND' => '未找到原操作，请刷新当前配置后重新填写。',
    'IDENTITY_PROVIDER_VAULT_UNAVAILABLE' => '安全密钥存储尚未准备好，请联系部署管理员。',
    'IDENTITY_PROVIDER_INVALID_INPUT' => '请检查配置格式和必填项。',
    'IDENTITY_PROVIDER_OPERATION_PENDING' => '原操作结果尚未确认，请先核对，避免重复提交。',
    'IDENTITY_PROVIDER_RECOVERY_UNAVAILABLE' => '无法保存安全操作编号，本次未提交，请重新打开本页。',
    'IDENTITY_PROVIDER_RUNTIME_REVISION_CONFLICT' ||
    'IDENTITY_PROVIDER_RUNTIME_VERSION_CONFLICT' =>
      '发布状态已变化，请刷新后重新核对目标。',
    'IDENTITY_PROVIDER_RELEASE_ACTIVE' ||
    'IDENTITY_PROVIDER_RELEASE_IN_PROGRESS' =>
      '已有发布或回退正在处理中，请先核对原操作。',
    'IDENTITY_PROVIDER_RELEASE_NOT_READY' => '部署执行尚未准备好，请联系部署管理员。',
    'IDENTITY_PROVIDER_ROLLBACK_NOT_ALLOWED' ||
    'IDENTITY_PROVIDER_ROLLBACK_UNAVAILABLE' =>
      '此版本不在可回退清单中，请刷新后重新选择。',
    'IDENTITY_PROVIDER_RUNTIME_UNAVAILABLE' ||
    'IDENTITY_PROVIDER_RUNTIME_NOT_CONFIGURED' =>
      '暂时无法核对全部身份实例，请联系部署管理员。',
    'IDENTITY_PROVIDER_RELEASE_TARGET_MISMATCH' => '配置与发布准备不一致，请刷新后重新准备。',
    'IDENTITY_PROVIDER_ROLLBACK_IDENTITY_MISMATCH' => '历史配置与当前账号恢复信息不兼容，暂不能回退。',
    'IDENTITY_PROVIDER_RUNTIME_CHECK_NOT_AVAILABLE' => '当前任务尚不能核对生效，请刷新部署进度。',
    'IDENTITY_PROVIDER_RELEASE_ALREADY_CLAIMED' => '部署已经开始，不能取消；请核对原操作。',
    'INVALID_IDENTITY_PROVIDER_RESPONSE' => '返回资料未通过安全核对，已隐藏内容。请刷新状态或核对原操作。',
    _ => failure.status == 0 || failure.status >= 500
        ? '暂时无法确认结果，请核对原操作；不要重复提交密钥。'
        : '操作未完成，请核对当前状态后重试。',
  };
}
