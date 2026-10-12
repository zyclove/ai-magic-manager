import 'api.dart';
import 'observation.dart' show validObservationReason;

const _statuses = {'NOT_AUTHORIZED', 'UNKNOWN', 'STALE', 'RECENT'};
const _inventoryStatuses = {
  'NOT_AUTHORIZED',
  'UNKNOWN',
  'STALE',
  'RECENT',
  'REVOKED'
};
const _profiles = {'PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN'};
const _classes = {'DANGEROUS', 'OTHER', 'UNKNOWN'};
const _grants = {'GRANTED', 'DENIED', 'UNKNOWN'};
final _package = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$');
final _permission = RegExp(r'^android\.permission\.[A-Z][A-Z0-9_]{1,100}$');
final _id = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false);

Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_PERMISSION_OBSERVATION_RESPONSE');
bool _number(dynamic value, {int min = 0}) =>
    value is int && value >= min && value <= 9007199254740991;
bool _text(dynamic value, int limit) =>
    value is String &&
    value.trim().isNotEmpty &&
    value.length <= limit &&
    !RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]').hasMatch(value);

class PermissionObservationSettings {
  final String deviceId, registrationId;
  final int version;
  final bool enabled;
  final int? updatedAt;
  const PermissionObservationSettings(this.deviceId, this.registrationId,
      this.version, this.enabled, this.updatedAt);

  static PermissionObservationSettings parse(
      dynamic raw, String deviceId, String registrationId) {
    if (raw is! Json ||
        raw.length != 5 ||
        raw['deviceId'] != deviceId ||
        raw['registrationId'] != registrationId ||
        !_number(raw['version']) ||
        raw['enabled'] is! bool ||
        (raw['version'] == 0
            ? raw['enabled'] == true || raw['updatedAt'] != null
            : !_number(raw['updatedAt'], min: 1))) _invalid();
    return PermissionObservationSettings(
        deviceId,
        registrationId,
        raw['version'] as int,
        raw['enabled'] as bool,
        raw['updatedAt'] as int?);
  }
}

class PermissionCandidate {
  final String packageName, displayName, profile;
  const PermissionCandidate(this.packageName, this.displayName, this.profile);
}

class PermissionInventory {
  final String status, evidence;
  final int? receivedAt;
  final List<PermissionCandidate> applications;
  const PermissionInventory(
      this.status, this.evidence, this.receivedAt, this.applications);

  static PermissionInventory parse(
      dynamic raw, String deviceId, String registrationId) {
    if (raw is! Json ||
        raw['deviceId'] != deviceId ||
        raw['registrationId'] != registrationId ||
        raw['applications'] is! List ||
        (raw['applications'] as List).length > 500 ||
        !_inventoryStatuses.contains(raw['observationStatus']) ||
        raw['evidenceStatus'] != 'AGENT_REPORTED_UNVERIFIED' ||
        (raw['receivedAt'] != null && !_number(raw['receivedAt'], min: 1))) {
      _invalid();
    }
    final applications = <PermissionCandidate>[], seen = <String>{};
    for (final app in raw['applications'] as List) {
      if (app is! Json ||
          !_text(app['packageName'], 255) ||
          !_package.hasMatch(app['packageName']) ||
          !_text(app['displayName'], 100) ||
          !_profiles.contains(app['profile']) ||
          !seen.add('${app['packageName']}|${app['profile']}')) _invalid();
      applications.add(PermissionCandidate(app['packageName'] as String,
          app['displayName'] as String, app['profile'] as String));
    }
    return PermissionInventory(
        raw['observationStatus'] as String,
        raw['evidenceStatus'] as String,
        raw['receivedAt'] as int?,
        List.unmodifiable(applications));
  }
}

class PermissionFactView {
  final String permissionName, classification, observedGrant;
  const PermissionFactView(
      this.permissionName, this.classification, this.observedGrant);
}

class PermissionObservationResult {
  final String packageName, status, evidence;
  final String? profile;
  final int? versionCode, observedAt, receivedAt;
  final List<PermissionFactView> permissions;
  const PermissionObservationResult(
      this.packageName,
      this.status,
      this.evidence,
      this.profile,
      this.versionCode,
      this.observedAt,
      this.receivedAt,
      this.permissions);

  static PermissionObservationResult parse(
      dynamic raw, String deviceId, String registrationId, String packageName) {
    if (raw is! Json ||
        raw.length != 10 ||
        raw['deviceId'] != deviceId ||
        raw['registrationId'] != registrationId ||
        raw['packageName'] != packageName ||
        !_statuses.contains(raw['observationStatus']) ||
        raw['evidenceStatus'] != 'AGENT_REPORTED_UNVERIFIED' ||
        raw['permissions'] is! List ||
        (raw['permissions'] as List).length > 64 ||
        (raw['profile'] != null && !_profiles.contains(raw['profile'])) ||
        (raw['versionCode'] != null && !_number(raw['versionCode'])) ||
        (raw['observedAt'] != null && !_number(raw['observedAt'], min: 1)) ||
        (raw['receivedAt'] != null && !_number(raw['receivedAt'], min: 1))) {
      _invalid();
    }
    final permissions = <PermissionFactView>[], seen = <String>{};
    for (final fact in raw['permissions'] as List) {
      if (fact is! Json ||
          fact.length != 3 ||
          fact['permissionName'] is! String ||
          !_permission.hasMatch(fact['permissionName'] as String) ||
          !_classes.contains(fact['classification']) ||
          !_grants.contains(fact['observedGrant']) ||
          fact['classification'] != 'DANGEROUS' &&
              fact['observedGrant'] != 'UNKNOWN' ||
          !seen.add(fact['permissionName'] as String)) _invalid();
      permissions.add(PermissionFactView(fact['permissionName'] as String,
          fact['classification'] as String, fact['observedGrant'] as String));
    }
    final recent = raw['observationStatus'] == 'RECENT' ||
        raw['observationStatus'] == 'STALE';
    if (recent &&
            (raw['profile'] == null ||
                raw['versionCode'] == null ||
                raw['observedAt'] == null ||
                raw['receivedAt'] == null) ||
        !recent &&
            (raw['profile'] != null ||
                raw['versionCode'] != null ||
                raw['observedAt'] != null ||
                raw['receivedAt'] != null ||
                permissions.isNotEmpty)) _invalid();
    return PermissionObservationResult(
        packageName,
        raw['observationStatus'] as String,
        raw['evidenceStatus'] as String,
        raw['profile'] as String?,
        raw['versionCode'] as int?,
        raw['observedAt'] as int?,
        raw['receivedAt'] as int?,
        List.unmodifiable(permissions));
  }
}

class PermissionObservationRepository {
  final Api api;
  final String root, deviceId, registrationId;
  final bool Function() current;
  PermissionObservationRepository(
      {required this.api,
      required this.root,
      required this.deviceId,
      required this.registrationId,
      required this.current}) {
    if (!root.startsWith('/tenants/') ||
        !_id.hasMatch(root.substring(9)) ||
        !_id.hasMatch(deviceId) ||
        !_id.hasMatch(registrationId)) {
      throw ArgumentError('Invalid permission observation scope');
    }
  }
  String get _path => '$root/devices/$deviceId';
  void _current() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<dynamic> _send(String method, String path,
      {Json? body, int? version, String? key}) async {
    _current();
    try {
      final result =
          await api.send(method, path, body: body, version: version, key: key);
      _current();
      return result;
    } on ApiFailure catch (failure) {
      _current();
      if (failure.status == 404) {
        throw const ApiFailure(404, 'PERMISSION_BACKEND_UNAVAILABLE');
      }
      rethrow;
    }
  }

  Future<PermissionObservationSettings> settings() async =>
      PermissionObservationSettings.parse(
          await _send('GET', '$_path/permission-observation-settings'),
          deviceId,
          registrationId);

  Future<PermissionObservationSettings> update(
      PermissionObservationSettings before,
      bool enabled,
      String reason,
      String key) async {
    if (before.deviceId != deviceId ||
        before.registrationId != registrationId ||
        !validObservationReason(reason)) {
      throw const ApiFailure(400, 'VALIDATION_FAILED');
    }
    final value = PermissionObservationSettings.parse(
        await _send('PUT', '$_path/permission-observation-settings',
            body: {'enabled': enabled, 'reason': reason.trim()},
            version: before.version,
            key: key),
        deviceId,
        registrationId);
    if (value.version != before.version + 1 || value.enabled != enabled) {
      _invalid();
    }
    return value;
  }

  Future<PermissionInventory> inventory() async => PermissionInventory.parse(
      await _send('GET', '$_path/application-inventory'),
      deviceId,
      registrationId);

  Future<PermissionObservationResult> read(String packageName) async {
    if (packageName.length > 255 || !_package.hasMatch(packageName)) {
      throw const ApiFailure(400, 'INVALID_PACKAGE_NAME');
    }
    final before = await settings();
    final raw = await _send('GET',
        '$_path/permission-observations?packageName=${Uri.encodeQueryComponent(packageName)}');
    final result = PermissionObservationResult.parse(
        raw, deviceId, registrationId, packageName);
    final after = await settings();
    if (before.version != after.version || before.enabled != after.enabled) {
      throw const ApiFailure(409, 'PERMISSION_VIEW_CHANGED');
    }
    return result;
  }
}
