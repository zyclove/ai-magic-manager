import 'failure.dart';

const configurationDeliveryLabels = {
  'PENDING_SIGNATURE': '等待签发',
  'READY': '等待设备拉取',
  'SERVED': '已提供给设备 · 等待回执',
  'DEVICE_REPORTED_RECEIVED': '设备报告已接收',
  'DEVICE_REPORTED_STORED': '设备报告已保存',
  'DEVICE_REPORTED_REJECTED': '设备报告已拒绝',
  'EXPIRED_AWAITING_PULL': '交付已过期 · 等待设备重新拉取',
};
const configurationReasonLabels = {
  'CAPABILITY_NOT_VERIFIED': '设备能力尚未验证',
  'AWAITING_EXECUTION': '尚无执行结果',
  'APPLICATION_IDENTITY_NOT_VERIFIED': '应用身份尚未验证',
  'DEVICE_NOT_ACTIVE': '发布时设备尚未激活',
  'APPLICATION_PLATFORM_MISMATCH': '应用与设备平台不匹配',
  'APPLICATION_PROFILE_NOT_VERIFIED': '应用系统资料尚未验证',
  'MANAGED_REGISTRATION_REQUIRED': '需要符合条件的受管注册',
  'EVIDENCE_NOT_CERTIFIED': '设备报告尚未经独立验证',
};
const configurationRejectionLabels = {
  'UNSUPPORTED_SCHEMA': '设备不支持此文档格式',
  'SIGNATURE_INVALID': '设备报告签名校验失败',
  'IDENTITY_MISMATCH': '配置与设备身份不匹配',
  'UNSUPPORTED_RULES': '设备不支持配置中的规则',
  'STORAGE_FAILURE': '设备未能保存配置',
  'EXPIRED': '设备收到时交付已过期',
  'OLDER_VERSION': '设备报告配置版本较旧',
};
Never _invalid() =>
    throw const UsageReportFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
bool _keys(dynamic v, Set<String> keys) =>
    v is Map && v.length == keys.length && keys.every(v.containsKey);
bool _text(dynamic v, int max) =>
    v is String && v.trim().isNotEmpty && v.length <= max;
bool _number(dynamic v, [int min = 0, int max = 9007199254740991]) =>
    v is int && v >= min && v <= max;
bool _id(dynamic v) =>
    v is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(v);

class ReportConfigurationState {
  final int checkedAt;
  final List<ReportConfiguration> configurations;
  const ReportConfigurationState._(this.checkedAt, this.configurations);
  static ReportConfigurationState parse(dynamic v, int generated) {
    if (!_keys(v, {'checkedAt', 'evidenceStatus', 'configurations'}) ||
        !_number(v['checkedAt'], generated, generated + 60000) ||
        v['evidenceStatus'] != 'DELIVERY_ONLY_NOT_EXECUTION' ||
        v['configurations'] is! List ||
        v['configurations'].length > 100) _invalid();
    final items = <ReportConfiguration>[],
        ids = <String>{},
        policies = <String>{};
    for (final raw in v['configurations']) {
      final item = ReportConfiguration.parse(raw, v['checkedAt']);
      if (!ids.add(item.id) || !policies.add(item.policyId)) _invalid();
      items.add(item);
    }
    return ReportConfigurationState._(v['checkedAt'], List.unmodifiable(items));
  }
}

class ReportConfiguration {
  final String id, policyId, versionId, action, deliveryState;
  final int sourceSequence, issuedAt, deliveryExpiresAt;
  final int? firstServedAt, receivedReportedAt, storedReportedAt;
  final String? rejectionCode, name;
  final List<ReportConfigurationRule> rules;
  const ReportConfiguration._(
      this.id,
      this.policyId,
      this.versionId,
      this.sourceSequence,
      this.action,
      this.deliveryState,
      this.issuedAt,
      this.deliveryExpiresAt,
      this.firstServedAt,
      this.receivedReportedAt,
      this.storedReportedAt,
      this.rejectionCode,
      this.name,
      this.rules);
  static ReportConfiguration parse(dynamic v, int checked) {
    if (!_keys(v, {
          'id',
          'policyId',
          'versionId',
          'sourceSequence',
          'action',
          'deliveryState',
          'issuedAt',
          'deliveryExpiresAt',
          'firstServedAt',
          'receivedReportedAt',
          'storedReportedAt',
          'rejectionCode',
          'name',
          'rules'
        }) ||
        !_id(v['id']) ||
        !_id(v['policyId']) ||
        !_id(v['versionId']) ||
        !_number(v['sourceSequence'], 1) ||
        !{'UPSERT_CONFIGURATION', 'REMOVE_CONFIGURATION'}
            .contains(v['action']) ||
        !configurationDeliveryLabels.containsKey(v['deliveryState']) ||
        !_number(v['issuedAt'], 1, checked) ||
        !_number(v['deliveryExpiresAt'], v['issuedAt'] + 1) ||
        v['rules'] is! List ||
        v['rules'].length > 100) _invalid();
    final issued = v['issuedAt'] as int,
        first = v['firstServedAt'],
        received = v['receivedReportedAt'],
        stored = v['storedReportedAt'],
        rejected = v['rejectionCode'],
        state = v['deliveryState'];
    for (final time in [first, received, stored]) {
      if (time != null && !_number(time, issued, checked)) _invalid();
    }
    if (received != null && (first == null || received < first) ||
        stored != null && (received == null || stored < received)) _invalid();
    if (rejected != null &&
        !configurationRejectionLabels.containsKey(rejected)) {
      _invalid();
    }
    if (state == 'DEVICE_REPORTED_REJECTED') {
      if (first == null || rejected == null || stored != null) _invalid();
    } else if (rejected != null) {
      _invalid();
    }
    switch (state) {
      case 'PENDING_SIGNATURE':
      case 'READY':
        if (first != null || received != null || stored != null) _invalid();
      case 'SERVED':
        if (first == null || received != null || stored != null) _invalid();
      case 'DEVICE_REPORTED_RECEIVED':
        if (received == null || stored != null) _invalid();
      case 'DEVICE_REPORTED_STORED':
        if (stored == null) _invalid();
      case 'EXPIRED_AWAITING_PULL':
        if (v['deliveryExpiresAt'] > checked || stored != null) _invalid();
    }
    if (v['action'] == 'REMOVE_CONFIGURATION') {
      if (v['name'] != null || v['rules'].isNotEmpty) _invalid();
    } else if (!_text(v['name'], 100)) {
      _invalid();
    }
    final rules =
        (v['rules'] as List).map(ReportConfigurationRule.parse).toList();
    return ReportConfiguration._(
        v['id'],
        v['policyId'],
        v['versionId'],
        v['sourceSequence'],
        v['action'],
        state,
        issued,
        v['deliveryExpiresAt'],
        first,
        received,
        stored,
        rejected,
        v['name'],
        List.unmodifiable(rules));
  }
}

class ReportConfigurationRule {
  final Map<String, dynamic> _values;
  const ReportConfigurationRule._(this._values);
  String get kind => _values['kind'];
  String get predictedEffect => _values['predictedEffect'];
  String get status => _values['status'];
  String get reasonCode => _values['reasonCode'];
  String? get applicationName => _values['applicationName'];
  String? get platform => _values['platform'];
  String? get profile => _values['profile'];
  String? get packageName => _values['packageName'];
  String? get scheduleName => _values['scheduleName'];
  String? get permission => _values['permission'];
  String? get domain => _values['domain'];
  int? get seconds => _values['seconds'];
  bool get required => _values['required'];
  static ReportConfigurationRule parse(dynamic v) {
    if (!_keys(v, {
          'kind',
          'predictedEffect',
          'status',
          'reasonCode',
          'applicationName',
          'platform',
          'profile',
          'packageName',
          'scheduleName',
          'permission',
          'domain',
          'seconds',
          'required'
        }) ||
        !{
          'APP_LAUNCH',
          'APP_INSTALL',
          'APP_UNINSTALL',
          'RUNTIME_PERMISSION',
          'SPECIAL_ACCESS',
          'DAILY_QUOTA',
          'TIME_WINDOW',
          'DOMAIN_ACCESS',
          'USAGE_REMINDER'
        }.contains(v['kind']) ||
        !{'ALLOW', 'DENY', 'DEFAULT', 'GRANT', 'PROTECT', 'LIMIT', 'REMIND'}
            .contains(v['predictedEffect']) ||
        !{
          'UNKNOWN',
          'UNVERIFIED',
          'UNAVAILABLE',
          'UNSUPPORTED',
          'SUPPORTED_PENDING',
          'STALE'
        }.contains(v['status']) ||
        !_text(v['reasonCode'], 100) ||
        v['required'] is! bool ||
        v['seconds'] != null && !_number(v['seconds'], 1)) _invalid();
    for (final key in [
      'applicationName',
      'scheduleName',
      'permission',
      'domain'
    ]) {
      if (v[key] != null &&
          !_text(v[key], key == 'permission' || key == 'domain' ? 255 : 100)) {
        _invalid();
      }
    }
    if (v['applicationName'] == null) {
      if (v['platform'] != null ||
          v['profile'] != null ||
          v['packageName'] != null) _invalid();
    } else if (!{'ANDROID', 'ANDROID_TV'}.contains(v['platform']) ||
        !{'PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN'}.contains(v['profile']) ||
        !_text(v['packageName'], 255)) {
      _invalid();
    }
    return ReportConfigurationRule._(
        Map.unmodifiable(Map<String, dynamic>.from(v)));
  }
}
