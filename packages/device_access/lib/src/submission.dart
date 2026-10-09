import 'models.dart';

const _submissionStates = {
  'PENDING',
  'APPROVED_PENDING_DELIVERY',
  'DENIED',
  'CANCELLED',
  'EXPIRED',
  'REVOKED',
  'INVALIDATED'
};
final _ruleId = RegExp(r'^[a-z][a-z0-9_-]{0,49}$');

/// A request/decision fact, never a device execution permit. Personal reason is redacted in logs.
class AccessSubmission {
  final Map<String, dynamic> _value;
  AccessSubmission._(Map<String, dynamic> value)
      : _value = freezeAccessJson(value);
  factory AccessSubmission.fromJson(Map<String, dynamic> value) {
    const fields = {
      'id',
      'subjectId',
      'deviceId',
      'registrationId',
      'policyId',
      'baseVersionId',
      'applicationId',
      'ruleIds',
      'requestedWindowSeconds',
      'reason',
      'state',
      'requestExpiresAt',
      'grantedWindowSeconds',
      'issuedAt',
      'absoluteNotAfter',
      'reasonCode',
      'executionState',
      'version',
      'createdAt'
    };
    final rules = value['ruleIds'];
    final granted = value['grantedWindowSeconds'],
        issued = value['issuedAt'],
        deadline = value['absoluteNotAfter'];
    final reason = value['reason'], code = value['reasonCode'];
    if (value.length != fields.length ||
        !fields.every(value.containsKey) ||
        ![
          'id',
          'subjectId',
          'deviceId',
          'registrationId',
          'policyId',
          'baseVersionId',
          'applicationId'
        ].every((k) => accessId(value[k])) ||
        rules is! List ||
        rules.isEmpty ||
        rules.length > 20 ||
        rules.any((r) => r is! String || !_ruleId.hasMatch(r)) ||
        rules.toSet().length != rules.length ||
        !accessInteger(value['requestedWindowSeconds'], 1) ||
        value['requestedWindowSeconds'] > 3600 ||
        reason != null && (reason is! String || reason.length > 300) ||
        code != null &&
            (code is! String ||
                !RegExp(r'^[A-Z][A-Z0-9_]{0,59}$').hasMatch(code)) ||
        !_submissionStates.contains(value['state']) ||
        value['executionState'] != 'NOT_ENFORCED' ||
        !accessInteger(value['version'], 0) ||
        !accessInteger(value['createdAt'], 0) ||
        !accessInteger(value['requestExpiresAt'], 1) ||
        value['requestExpiresAt'] <= value['createdAt'] ||
        (granted == null
            ? issued != null || deadline != null
            : !accessInteger(granted, 1) ||
                granted > value['requestedWindowSeconds'] ||
                !accessInteger(issued, 0) ||
                !accessInteger(deadline, 1) ||
                deadline != issued + granted * 1000) ||
        {'APPROVED_PENDING_DELIVERY', 'REVOKED'}.contains(value['state']) &&
            granted == null ||
        {'PENDING', 'DENIED', 'CANCELLED', 'INVALIDATED'}
                .contains(value['state']) &&
            granted != null ||
        (value['state'] == 'PENDING'
            ? value['version'] != 0
            : value['version'] == 0)) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    return AccessSubmission._(value);
  }
  String get id => _value['id'];
  String get subjectId => _value['subjectId'];
  String get deviceId => _value['deviceId'];
  String get registrationId => _value['registrationId'];
  String get policyId => _value['policyId'];
  String get baseVersionId => _value['baseVersionId'];
  String get applicationId => _value['applicationId'];
  List<String> get ruleIds => (_value['ruleIds'] as List).cast<String>();
  String get state => _value['state'];
  String? get reason => _value['reason'];
  String? get reasonCode => _value['reasonCode'];
  int get requestedWindowSeconds => _value['requestedWindowSeconds'];
  int get requestExpiresAt => _value['requestExpiresAt'];
  int? get grantedWindowSeconds => _value['grantedWindowSeconds'];
  int? get absoluteNotAfter => _value['absoluteNotAfter'];
  int get version => _value['version'];
  bool get systemEnforced => false;
  void requireContext(AccessDeviceContext context) {
    if (subjectId != context.subjectId ||
        deviceId != context.deviceId ||
        registrationId != context.registrationId) {
      throw const AccessFailure('ACCESS_TARGET_CHANGED');
    }
  }

  @override
  String toString() => 'AccessSubmission(state=$state, version=$version)';
}

/// Persist this exact input and its original idempotency key before sending a mutation.
class AccessSubmissionInput {
  final String policyId, baseVersionId, applicationId;
  final List<String> ruleIds;
  final int requestedWindowSeconds;
  final String? reason;
  AccessSubmissionInput(
      {required this.policyId,
      required this.baseVersionId,
      required this.applicationId,
      required List<String> ruleIds,
      required this.requestedWindowSeconds,
      String? reason})
      : ruleIds = List.unmodifiable([...ruleIds]..sort()),
        reason = reason?.trim() {
    if (![policyId, baseVersionId, applicationId].every(accessId) ||
        ruleIds.isEmpty ||
        ruleIds.length > 20 ||
        ruleIds.toSet().length != ruleIds.length ||
        ruleIds.any((r) => !_ruleId.hasMatch(r)) ||
        !accessInteger(requestedWindowSeconds, 1) ||
        requestedWindowSeconds > 3600 ||
        reason != null && reason.length > 300) {
      throw ArgumentError('Invalid bounded access submission input');
    }
  }
  Map<String, dynamic> toJson() => {
        'policyId': policyId,
        'baseVersionId': baseVersionId,
        'applicationId': applicationId,
        'ruleIds': ruleIds,
        'requestedWindowSeconds': requestedWindowSeconds,
        'reason': reason
      };
  bool matches(AccessSubmission value) =>
      policyId == value.policyId &&
      baseVersionId == value.baseVersionId &&
      applicationId == value.applicationId &&
      requestedWindowSeconds == value.requestedWindowSeconds &&
      reason == value.reason &&
      ruleIds.length == value.ruleIds.length &&
      ruleIds.every(value.ruleIds.contains);
  @override
  String toString() => 'AccessSubmissionInput(private)';
}

class AccessSubmissionPage {
  final List<AccessSubmission> items;
  final String? nextCursor;
  AccessSubmissionPage._(this.items, this.nextCursor);
  factory AccessSubmissionPage.fromJson(Map<String, dynamic> value,
      {required String? after, required int limit}) {
    _pageInput(after, limit);
    final raw = value['items'], next = value['nextCursor'];
    if (raw is! List ||
        raw.length > limit ||
        !value.containsKey('nextCursor') ||
        next != null && !accessId(next)) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    final items = <AccessSubmission>[];
    String? previous = after;
    for (final item in raw) {
      if (item is! Map<String, dynamic>) {
        throw const AccessFailure('TRANSPORT_INVALID');
      }
      final parsed = AccessSubmission.fromJson(item);
      if (previous != null && parsed.id.compareTo(previous) <= 0) {
        throw const AccessFailure('TRANSPORT_INVALID');
      }
      previous = parsed.id;
      items.add(parsed);
    }
    if (next != null && (items.length != limit || next != previous)) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    return AccessSubmissionPage._(List.unmodifiable(items), next);
  }
}

class AccessSubmissionRule {
  final String id, kind;
  AccessSubmissionRule._(this.id, this.kind);
}

List<AccessSubmissionRule> _rules(dynamic raw) {
  if (raw is! List || raw.length > 100) {
    throw const AccessFailure('TRANSPORT_INVALID');
  }
  final result = <AccessSubmissionRule>[];
  final seen = <String>{};
  for (final item in raw) {
    if (item is! Map<String, dynamic> ||
        item.length != 2 ||
        item['id'] is! String ||
        !_ruleId.hasMatch(item['id']) ||
        !seen.add(item['id']) ||
        !{'APP_LAUNCH', 'TIME_WINDOW'}.contains(item['kind'])) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    result.add(AccessSubmissionRule._(item['id'], item['kind']));
  }
  return List.unmodifiable(result);
}

class AccessSubmissionApplication {
  final String id, displayName;
  final List<AccessSubmissionRule> rules;
  AccessSubmissionApplication._(this.id, this.displayName, this.rules);
}

class AccessSubmissionOption {
  final String id, name, baseVersionId;
  final List<AccessSubmissionRule> commonRules;
  final List<AccessSubmissionApplication> applications;
  AccessSubmissionOption._(this.id, this.name, this.baseVersionId,
      this.commonRules, this.applications);
  factory AccessSubmissionOption.fromJson(Map<String, dynamic> value) {
    final apps = value['applications'];
    if (value.length != 5 ||
        !accessId(value['id']) ||
        !accessId(value['baseVersionId']) ||
        !_name(value['name']) ||
        apps is! List ||
        apps.isEmpty ||
        apps.length > 100) throw const AccessFailure('TRANSPORT_INVALID');
    final common = _rules(value['commonRules']);
    final parsed = <AccessSubmissionApplication>[];
    final seen = <String>{};
    for (final app in apps) {
      if (app is! Map<String, dynamic> ||
          app.length != 3 ||
          !accessId(app['id']) ||
          !_name(app['displayName']) ||
          !seen.add(app['id'])) throw const AccessFailure('TRANSPORT_INVALID');
      final rules = _rules(app['rules']);
      if (rules.isEmpty && common.isEmpty ||
          rules.any((r) => common.any((c) => c.id == r.id))) {
        throw const AccessFailure('TRANSPORT_INVALID');
      }
      parsed.add(
          AccessSubmissionApplication._(app['id'], app['displayName'], rules));
    }
    return AccessSubmissionOption._(value['id'], value['name'],
        value['baseVersionId'], common, List.unmodifiable(parsed));
  }
}

bool _name(dynamic value) =>
    value is String && value.trim().isNotEmpty && value.length <= 100;
void _pageInput(String? after, int limit) {
  if (limit < 1 || limit > 100 || after != null && !accessId(after)) {
    throw ArgumentError('Invalid access submission page input');
  }
}

class AccessSubmissionOptionsPage {
  final List<AccessSubmissionOption> items;
  final String? nextCursor;
  AccessSubmissionOptionsPage._(this.items, this.nextCursor);
  factory AccessSubmissionOptionsPage.fromJson(Map<String, dynamic> value,
      {required String? after, required int limit}) {
    _pageInput(after, limit);
    final raw = value['items'], next = value['nextCursor'];
    if (raw is! List ||
        raw.length > limit ||
        !value.containsKey('nextCursor') ||
        next != null && !accessId(next)) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    final items = <AccessSubmissionOption>[];
    String? previous = after;
    for (final item in raw) {
      if (item is! Map<String, dynamic>) {
        throw const AccessFailure('TRANSPORT_INVALID');
      }
      final parsed = AccessSubmissionOption.fromJson(item);
      if (previous != null && parsed.id.compareTo(previous) <= 0) {
        throw const AccessFailure('TRANSPORT_INVALID');
      }
      previous = parsed.id;
      items.add(parsed);
    }
    // Cursor belongs to the scanned policy page, which may contain filtered-out policies.
    if (next != null &&
        (after != null && (next as String).compareTo(after) <= 0 ||
            previous != null && (next as String).compareTo(previous) < 0)) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    return AccessSubmissionOptionsPage._(List.unmodifiable(items), next);
  }
}
