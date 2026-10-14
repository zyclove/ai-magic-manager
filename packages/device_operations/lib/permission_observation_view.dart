/// Strict, transport-independent permission view contracts shared by both clients.
/// Observations never establish platform enforcement or certification.
class PermissionViewException implements Exception {
  const PermissionViewException();
}

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

Never _invalid() => throw const PermissionViewException();
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
    if (raw is! Map<String, dynamic> ||
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
    if (raw is! Map<String, dynamic> ||
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
      if (app is! Map<String, dynamic> ||
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
    if (raw is! Map<String, dynamic> ||
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
      if (fact is! Map<String, dynamic> ||
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
