import 'package:device_policy/device_policy.dart' show validId, maxSafeInteger;

/// 诊断只包含固定代码，不能包含凭证、应用清单或服务器原始内容。
class ObservationFailure implements Exception {
  final String code;
  const ObservationFailure(this.code);
  @override
  String toString() => 'ObservationFailure($code)';
}

class ObservationScope {
  final String tenantId, deviceId, registrationId;
  const ObservationScope(this.tenantId, this.deviceId, this.registrationId);
  String get storageKey => '$tenantId.$deviceId.$registrationId';
}

class ObservationAuthorization {
  final String deviceId, registrationId;
  final int version;
  final bool inventoryEnabled, usageEnabled;
  final int? updatedAt;
  const ObservationAuthorization(
      {required this.deviceId,
      required this.registrationId,
      required this.version,
      required this.inventoryEnabled,
      required this.usageEnabled,
      this.updatedAt});
  static ObservationAuthorization parse(
      Map<String, dynamic> json, ObservationScope scope) {
    if (!exactKeys(json, {
          'deviceId',
          'registrationId',
          'version',
          'inventoryEnabled',
          'usageEnabled',
          'updatedAt'
        }) ||
        json['deviceId'] != scope.deviceId ||
        json['registrationId'] != scope.registrationId ||
        !safeNumber(json['version']) ||
        json['inventoryEnabled'] is! bool ||
        json['usageEnabled'] is! bool ||
        (json['version'] == 0
            ? json['updatedAt'] != null ||
                json['inventoryEnabled'] == true ||
                json['usageEnabled'] == true
            : !safeNumber(json['updatedAt'], minimum: 1))) {
      throw const ObservationFailure('OBSERVATION_AUTHORIZATION_INVALID');
    }
    return ObservationAuthorization(
        deviceId: json['deviceId'],
        registrationId: json['registrationId'],
        version: json['version'],
        inventoryEnabled: json['inventoryEnabled'],
        usageEnabled: json['usageEnabled'],
        updatedAt: json['updatedAt']);
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'registrationId': registrationId,
        'version': version,
        'inventoryEnabled': inventoryEnabled,
        'usageEnabled': usageEnabled,
        'updatedAt': updatedAt
      };
}

/// 检查特殊访问不读取使用记录；系统授权与云端管理员授权互相独立。
class ObservationPlatformState {
  final bool usageGranted, unlocked, television;
  final bool usageSupported;
  final String usageGrantStatus;
  final String profile;
  const ObservationPlatformState(
      {required this.usageGranted,
      required this.unlocked,
      this.television = false,
      this.profile = 'UNKNOWN',
      this.usageSupported = true,
      String? usageGrantStatus})
      : usageGrantStatus =
            usageGrantStatus ?? (usageGranted ? 'GRANTED' : 'NOT_REQUESTED');
}

class UsageSample {
  final int queryStart, queryEnd, observedAt;
  final String timeZone, profile;
  final List<Map<String, dynamic>> applications;
  const UsageSample(
      {required this.queryStart,
      required this.queryEnd,
      required this.observedAt,
      required this.timeZone,
      required this.profile,
      required this.applications});
}

abstract interface class ObservationSource {
  Future<ObservationPlatformState> inspect();
  Future<List<Map<String, dynamic>>> inventory();
  Future<UsageSample> usage({required int queryStart, required int queryEnd});
  Future<void> openUsageSettings();
}

/// 宿主必须提供原子、持久、加密的单记录存储；禁止明文/浏览器回退。
abstract interface class ObservationStore {
  Future<String?> read();
  Future<void> write(String value);
}

abstract interface class ObservationApi {
  Future<Map<String, dynamic>> settings();
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> body);
  Future<Map<String, dynamic>> usage(Map<String, dynamic> body);
  void close();
}

/// UI 最小状态，不包含原始清单、原始行为、管理员身份或设备凭证。
class ObservationView {
  final ObservationAuthorization? authorization;
  final ObservationPlatformState? platform;
  final int pendingReports, inventoryCount, usageCount;
  final int? lastInventoryAt, lastUsageAt;
  final bool onlineConfirmed;
  const ObservationView(
      {this.authorization,
      this.platform,
      this.pendingReports = 0,
      this.inventoryCount = 0,
      this.usageCount = 0,
      this.lastInventoryAt,
      this.lastUsageAt,
      this.onlineConfirmed = false});
}

bool exactKeys(Map<String, dynamic> value, Set<String> names) =>
    value.length == names.length && value.keys.every(names.contains);
bool safeNumber(dynamic value, {int minimum = 0}) =>
    value is int && value >= minimum && value <= maxSafeInteger;
bool validScope(ObservationScope value) =>
    validId(value.tenantId) &&
    validId(value.deviceId) &&
    validId(value.registrationId);
