import 'api.dart';

/// UI boundaries only; persisted server membership remains authoritative.
bool canReadObservation(String role) =>
    const ['OWNER', 'GUARDIAN', 'ORG_ADMIN'].contains(role);
bool canEditObservation(String role, String state) =>
    state == 'ACTIVE' &&
    const ['OWNER', 'GUARDIAN', 'ORG_ADMIN'].contains(role);

Never _invalid() => throw const ApiFailure(502, 'INVALID_OBSERVATION_RESPONSE');
bool _number(dynamic value, {int minimum = 0}) =>
    value is int && value >= minimum && value <= 9007199254740991;
bool _time(dynamic value) =>
    _number(value, minimum: 1) && value <= 8640000000000000;
bool _id(dynamic value) =>
    value is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
            caseSensitive: false)
        .hasMatch(value);
bool _keys(dynamic value, Set<String> keys) =>
    value is Json &&
    value.length == keys.length &&
    value.keys.every(keys.contains);
bool _text(dynamic value, int limit) =>
    value is String &&
    value.trim().isNotEmpty &&
    value.length <= limit &&
    !RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]').hasMatch(value);
const _profiles = {'PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN'};
bool validObservationReason(String value) =>
    value.trim().isNotEmpty &&
    value.length <= 300 &&
    !RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u202a-\u202e\u2066-\u2069]')
        .hasMatch(value);

String observationProfile(String value) => switch (value) {
      'PRIMARY' => '主用户',
      'WORK' => '工作资料',
      'SECONDARY' => '次用户',
      _ => '资料类型未知'
    };
String observationDuration(int millis) {
  final seconds = millis ~/ 1000;
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60, rest = seconds % 60;
  return '$minutes 分钟${rest == 0 ? '' : ' $rest 秒'}';
}

String observationError(Object error) {
  if (error is! ApiFailure) return '操作未完成，请刷新状态后重试。';
  return switch (error.code) {
    'WORKSPACE_CHANGED' => '工作空间或登录权限已变化。请关闭窗口，在当前工作空间重新打开。',
    'OBSERVATION_VIEW_CHANGED' => '读取期间授权或设备注册已变化，已隐藏旧数据。请刷新并重新核对。',
    'INVALID_OBSERVATION_RESPONSE' => '观察响应未通过校验，未显示不一致的数据。请联系管理员检查服务。',
    'OBSERVATION_BACKEND_UNAVAILABLE' => '观察接口或设备当前不可用。请刷新设备状态；若部署较旧，请联系管理员升级。',
    'DEVICE_NOT_ACTIVE' => '只有已激活设备可以修改授权，请检查注册状态。',
    _ => error.message
  };
}

class ManagedObservationSettings {
  final String deviceId, registrationId;
  final int version;
  final bool inventoryEnabled, usageEnabled;
  final int? updatedAt;
  const ManagedObservationSettings(this.deviceId, this.registrationId,
      this.version, this.inventoryEnabled, this.usageEnabled, this.updatedAt);
  static ManagedObservationSettings parse(dynamic raw,
      {required String deviceId, required String registrationId}) {
    if (!_keys(raw, {
          'deviceId',
          'registrationId',
          'version',
          'inventoryEnabled',
          'usageEnabled',
          'updatedAt'
        }) ||
        raw['deviceId'] != deviceId ||
        raw['registrationId'] != registrationId ||
        !_id(deviceId) ||
        !_id(registrationId) ||
        !_number(raw['version']) ||
        raw['inventoryEnabled'] is! bool ||
        raw['usageEnabled'] is! bool ||
        (raw['version'] == 0
            ? raw['updatedAt'] != null ||
                raw['inventoryEnabled'] ||
                raw['usageEnabled']
            : !_time(raw['updatedAt']))) _invalid();
    return ManagedObservationSettings(deviceId, registrationId, raw['version'],
        raw['inventoryEnabled'], raw['usageEnabled'], raw['updatedAt']);
  }
}

class ObservedUsageApplication {
  final String packageName, displayName;
  final int firstTimeStamp, lastTimeStamp, foregroundMillis;
  const ObservedUsageApplication(this.packageName, this.displayName,
      this.firstTimeStamp, this.lastTimeStamp, this.foregroundMillis);
}

class ObservedUsageBatch {
  final String registrationId, reportId, profile, timeZone;
  final int sequence,
      authorizationVersion,
      queryStart,
      queryEnd,
      observedAt,
      receivedAt;
  final List<ObservedUsageApplication> applications;
  const ObservedUsageBatch(
      this.registrationId,
      this.reportId,
      this.sequence,
      this.authorizationVersion,
      this.profile,
      this.queryStart,
      this.queryEnd,
      this.observedAt,
      this.timeZone,
      this.applications,
      this.receivedAt);
  static ObservedUsageBatch parse(dynamic raw, String registrationId) {
    if (!_keys(raw, {
          'registrationId',
          'reportId',
          'sequence',
          'authorizationVersion',
          'profile',
          'queryStart',
          'queryEnd',
          'observedAt',
          'timeZone',
          'applications',
          'receivedAt',
          'precision',
          'evidenceStatus'
        }) ||
        raw['registrationId'] != registrationId ||
        !_id(raw['reportId']) ||
        !_id(registrationId) ||
        !_number(raw['sequence'], minimum: 1) ||
        !_number(raw['authorizationVersion'], minimum: 1) ||
        !_profiles.contains(raw['profile']) ||
        !_time(raw['queryStart']) ||
        !_time(raw['queryEnd']) ||
        !_time(raw['observedAt']) ||
        !_time(raw['receivedAt']) ||
        raw['queryStart'] >= raw['queryEnd'] ||
        raw['queryEnd'] > raw['observedAt'] ||
        raw['queryEnd'] - raw['queryStart'] > 172800000 ||
        !_text(raw['timeZone'], 100) ||
        raw['precision'] != 'OS_AGGREGATE' ||
        raw['evidenceStatus'] != 'AGENT_REPORTED_UNVERIFIED' ||
        raw['applications'] is! List ||
        raw['applications'].length > 500) _invalid();
    final applications = <ObservedUsageApplication>[], seen = <String>{};
    for (final app in raw['applications']) {
      if (!_keys(app, {
            'packageName',
            'displayName',
            'firstTimeStamp',
            'lastTimeStamp',
            'foregroundMillis'
          }) ||
          !_text(app['packageName'], 255) ||
          !RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
              .hasMatch(app['packageName']) ||
          !_text(app['displayName'], 100) ||
          !_time(app['firstTimeStamp']) ||
          !_time(app['lastTimeStamp']) ||
          !_number(app['foregroundMillis']) ||
          app['firstTimeStamp'] > app['lastTimeStamp'] ||
          app['firstTimeStamp'] < raw['observedAt'] - 604800000 ||
          app['lastTimeStamp'] > raw['observedAt'] + 300000 ||
          app['foregroundMillis'] >
              app['lastTimeStamp'] - app['firstTimeStamp'] ||
          !seen.add(
              '${app['packageName']}|${app['firstTimeStamp']}|${app['lastTimeStamp']}')) {
        _invalid();
      }
      applications.add(ObservedUsageApplication(
          app['packageName'],
          app['displayName'],
          app['firstTimeStamp'],
          app['lastTimeStamp'],
          app['foregroundMillis']));
    }
    return ObservedUsageBatch(
        registrationId,
        raw['reportId'],
        raw['sequence'],
        raw['authorizationVersion'],
        raw['profile'],
        raw['queryStart'],
        raw['queryEnd'],
        raw['observedAt'],
        raw['timeZone'],
        List.unmodifiable(applications),
        raw['receivedAt']);
  }
}

class ObservationSnapshot {
  final ManagedObservationSettings settings;
  final List<ObservedUsageBatch> batches;
  final String? nextCursor;
  const ObservationSnapshot(this.settings, this.batches, this.nextCursor);
}

class ObservationRepository {
  final Api api;
  final String root, deviceId, registrationId;
  final bool Function() current;
  String get path => '$root/devices/$deviceId';
  ObservationRepository(
      {required this.api,
      required this.root,
      required this.deviceId,
      required this.registrationId,
      required this.current}) {
    if (!root.startsWith('/tenants/') ||
        !_id(root.substring(9)) ||
        !_id(deviceId) ||
        !_id(registrationId)) throw ArgumentError('Invalid observation target');
  }
  void _current() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<dynamic> _send(String method, String target,
      {Json? body, int? version, String? key}) async {
    _current();
    try {
      final result = await api.send(method, target,
          body: body, version: version, key: key);
      _current();
      return result;
    } on ApiFailure catch (error) {
      _current();
      if (error.status == 404) {
        throw const ApiFailure(404, 'OBSERVATION_BACKEND_UNAVAILABLE');
      }
      rethrow;
    }
  }

  Future<ManagedObservationSettings> _settings() async =>
      ManagedObservationSettings.parse(
          await _send('GET', '$path/observation-settings'),
          deviceId: deviceId,
          registrationId: registrationId);
  Future<ObservationSnapshot> load({String? cursor}) async {
    if (cursor != null &&
        (!RegExp(r'^[1-9][0-9]{0,15}$').hasMatch(cursor) ||
            int.parse(cursor) > 9007199254740991)) {
      throw ArgumentError('Invalid cursor');
    }
    final before = await _settings();
    if (!before.usageEnabled) {
      return ObservationSnapshot(before, const [], null);
    }
    final raw = await _send('GET',
        '$path/usage-observations?limit=5${cursor == null ? '' : '&cursor=$cursor'}');
    if (!_keys(raw, {'items', 'nextCursor'}) ||
        raw['items'] is! List ||
        raw['items'].length > 5) _invalid();
    final items = <ObservedUsageBatch>[], ids = <String>{};
    var previous = cursor == null ? 9007199254740992 : int.parse(cursor);
    for (final item in raw['items']) {
      final value = ObservedUsageBatch.parse(item, registrationId);
      if (value.sequence >= previous ||
          value.authorizationVersion > before.version ||
          !ids.add(value.reportId)) _invalid();
      previous = value.sequence;
      items.add(value);
    }
    final next = raw['nextCursor'];
    if (next != null &&
        (next is! String ||
            items.isEmpty ||
            next != '${items.last.sequence}')) {
      _invalid();
    }
    final after = await _settings();
    if (before.version != after.version ||
        before.inventoryEnabled != after.inventoryEnabled ||
        before.usageEnabled != after.usageEnabled) {
      throw const ApiFailure(409, 'OBSERVATION_VIEW_CHANGED');
    }
    return ObservationSnapshot(after, List.unmodifiable(items), next);
  }

  Future<ManagedObservationSettings> update(
      ManagedObservationSettings before, Json body, String key) async {
    _current();
    if (before.deviceId != deviceId ||
        before.registrationId != registrationId ||
        !_keys(body, {'inventoryEnabled', 'usageEnabled', 'reason'}) ||
        body['inventoryEnabled'] is! bool ||
        body['usageEnabled'] is! bool ||
        body['reason'] is! String ||
        !validObservationReason(body['reason'])) {
      throw const ApiFailure(400, 'VALIDATION_FAILED');
    }
    final result = ManagedObservationSettings.parse(
        await _send('PUT', '$path/observation-settings',
            body: {...body, 'reason': (body['reason'] as String).trim()},
            version: before.version,
            key: key),
        deviceId: deviceId,
        registrationId: registrationId);
    if (result.version != before.version + 1 ||
        result.inventoryEnabled != body['inventoryEnabled'] ||
        result.usageEnabled != body['usageEnabled']) _invalid();
    // The mutation response may be a replay. Callers must freshly load current settings.
    return result;
  }
}
