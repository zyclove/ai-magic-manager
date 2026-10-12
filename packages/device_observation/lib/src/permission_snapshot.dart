import 'models.dart';

/// One local Android package query. It is not an administrator authorization or policy receipt.
class PermissionSnapshot {
  final String packageName, profile;
  final List<String> signingDigests;
  final int versionCode, observedAt;
  final List<PermissionFact> permissions;

  const PermissionSnapshot._(this.packageName, this.profile,
      this.signingDigests, this.versionCode, this.observedAt, this.permissions);

  static PermissionSnapshot parse(Map<String, dynamic> raw) {
    final package = raw['packageName'];
    final names = raw['signingDigests'];
    final facts = raw['permissions'];
    if (!exactKeys(raw, {
          'packageName',
          'profile',
          'signingDigests',
          'versionCode',
          'observedAt',
          'permissions'
        }) ||
        package is! String ||
        package.length > 255 ||
        !RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
            .hasMatch(package) ||
        !const {'PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN'}
            .contains(raw['profile']) ||
        !safeNumber(raw['versionCode']) ||
        !safeNumber(raw['observedAt'], minimum: 1) ||
        names is! List ||
        names.length > 8 ||
        names.any((value) =>
            value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) ||
        names.toSet().length != names.length ||
        facts is! List ||
        facts.length > 64) {
      throw const ObservationFailure('OBSERVATION_SAMPLE_INVALID');
    }
    final normalized = <PermissionFact>[], seen = <String>{};
    for (final item in facts) {
      final fact = PermissionFact.parse(item);
      if (!seen.add(fact.permissionName)) {
        throw const ObservationFailure('OBSERVATION_SAMPLE_INVALID');
      }
      normalized.add(fact);
    }
    normalized.sort((a, b) => a.permissionName.compareTo(b.permissionName));
    return PermissionSnapshot._(
        package,
        raw['profile'] as String,
        List.unmodifiable(List<String>.from(names)..sort()),
        raw['versionCode'] as int,
        raw['observedAt'] as int,
        List.unmodifiable(normalized));
  }

  /// Shape of POST /device-api/permission-observations; caller supplies the live consent version.
  Map<String, dynamic> report(
          int sequence, int authorizationVersion, String reportId) =>
      {
        'reportId': reportId,
        'sequence': sequence,
        'authorizationVersion': authorizationVersion,
        'packageName': packageName,
        'profile': profile,
        'signingDigests': signingDigests,
        'versionCode': versionCode,
        'observedAt': observedAt,
        'source': 'ANDROID_PACKAGE_MANAGER',
        'permissions': permissions.map((fact) => fact.toJson()).toList()
      };
}

class PermissionFact {
  final String permissionName, classification, observedGrant;
  const PermissionFact._(
      this.permissionName, this.classification, this.observedGrant);

  static PermissionFact parse(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        !exactKeys(
            raw, {'permissionName', 'classification', 'observedGrant'}) ||
        raw['permissionName'] is! String ||
        !RegExp(r'^android\.permission\.[A-Z][A-Z0-9_]{1,100}$')
            .hasMatch(raw['permissionName']) ||
        !const {'DANGEROUS', 'OTHER', 'UNKNOWN'}
            .contains(raw['classification']) ||
        !const {'GRANTED', 'DENIED', 'UNKNOWN'}
            .contains(raw['observedGrant']) ||
        (raw['classification'] != 'DANGEROUS' &&
            raw['observedGrant'] != 'UNKNOWN')) {
      throw const ObservationFailure('OBSERVATION_SAMPLE_INVALID');
    }
    return PermissionFact._(raw['permissionName'] as String,
        raw['classification'] as String, raw['observedGrant'] as String);
  }

  Map<String, dynamic> toJson() => {
        'permissionName': permissionName,
        'classification': classification,
        'observedGrant': observedGrant
      };
}

abstract interface class PermissionObservationSource {
  Future<PermissionSnapshot> permissionSnapshot(String packageName);
}

/// Ephemeral picker entry; never persisted in the observation journal.
class PermissionCandidate {
  final String packageName, displayName, profile;
  const PermissionCandidate(this.packageName, this.displayName, this.profile);
}

class PermissionCandidates {
  final ObservationView view;
  final List<PermissionCandidate> items;
  const PermissionCandidates(this.view, this.items);
}

abstract interface class PermissionObservationApi {
  Future<Map<String, dynamic>> permissionSettings();
  Future<Map<String, dynamic>> permissionReport(Map<String, dynamic> body);
}
