import 'api.dart';

const _invalidPolicyResponse = ApiFailure(502, 'INVALID_RESPONSE');
const _maxSafePolicyInteger = 9007199254740991;

bool _nonemptyText(Object? value) => value is String && value.trim().isNotEmpty;
bool _nullableText(Object? value) => value == null || _nonemptyText(value);
bool _policyInteger(Object? value, {int minimum = 0}) =>
    value is int && value >= minimum && value <= _maxSafePolicyInteger;
bool _policyPattern(String value, String pattern) {
  final match = RegExp(pattern).firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}

Json _policyObject(Object? value) {
  if (value is! Json) throw _invalidPolicyResponse;
  return value;
}

/// Parse before rendering or capturing action inputs; callbacks never borrow a
/// mutable response map that another route may redact or clear.
Json readPolicyDraftSnapshot(Object? value, {String? expectedId}) {
  final draft = _policyObject(value);
  if (!_nonemptyText(draft['id']) ||
      (expectedId != null && draft['id'] != expectedId) ||
      !_nonemptyText(draft['name']) ||
      (draft['name'] as String).length > 100 ||
      !const {'POLICY', 'TEMPLATE'}.contains(draft['kind']) ||
      !_policyInteger(draft['revision']) ||
      !_nullableText(draft['sourceVersionId'])) throw _invalidPolicyResponse;
  return Map<String, dynamic>.unmodifiable({
    'id': draft['id'],
    'name': draft['name'],
    'kind': draft['kind'],
    'revision': draft['revision'],
    'rules': readPolicyDraftRules(draft['rules']),
    'sourceVersionId': draft['sourceVersionId'],
  });
}

List<Json> readPolicyDraftRules(Object? value) {
  if (value is! List || value.length > 100) throw _invalidPolicyResponse;
  final ids = <String>{};
  final rules = <Json>[];
  for (final item in value) {
    final rule = _policyObject(item);
    final id = rule['id'], kind = rule['kind'], effect = rule['effect'];
    if (id is! String ||
        !_policyPattern(id, r'[a-z][a-z0-9_-]{0,49}') ||
        !ids.add(id) ||
        rule['required'] is! bool ||
        !const {
          'APP_LAUNCH',
          'APP_INSTALL',
          'APP_UNINSTALL',
          'RUNTIME_PERMISSION',
          'SPECIAL_ACCESS',
          'DAILY_QUOTA',
          'TIME_WINDOW',
          'DOMAIN_ACCESS',
          'USAGE_REMINDER'
        }.contains(kind) ||
        !const {
          'ALLOW',
          'DENY',
          'DEFAULT',
          'GRANT',
          'PROTECT',
          'LIMIT',
          'REMIND'
        }.contains(effect)) throw _invalidPolicyResponse;
    const limits = {
      'applicationId': 36,
      'scheduleId': 36,
      'permission': 150,
      'domain': 253
    };
    for (final entry in limits.entries) {
      final field = rule[entry.key];
      if (!_nullableText(field) ||
          (field is String && field.length > entry.value)) {
        throw _invalidPolicyResponse;
      }
    }
    final seconds = rule['seconds'];
    if (seconds != null &&
        (!_policyInteger(seconds, minimum: 1) || (seconds as int) > 86400)) {
      throw _invalidPolicyResponse;
    }
    final application = rule['applicationId'];
    final schedule = rule['scheduleId'];
    final permission = rule['permission'];
    final domain = rule['domain'];
    final used = <String>{};
    Set<String> effects;
    switch (kind) {
      case 'APP_LAUNCH':
      case 'APP_INSTALL':
        if (application == null) throw _invalidPolicyResponse;
        used.add('applicationId');
        effects = {'ALLOW', 'DENY'};
      case 'APP_UNINSTALL':
        if (application == null) throw _invalidPolicyResponse;
        used.add('applicationId');
        effects = {'ALLOW', 'PROTECT'};
      case 'RUNTIME_PERMISSION':
      case 'SPECIAL_ACCESS':
        if (application == null || permission == null) {
          throw _invalidPolicyResponse;
        }
        used.addAll(['applicationId', 'permission']);
        effects = {'GRANT', 'DENY', 'DEFAULT'};
      case 'DAILY_QUOTA':
      case 'USAGE_REMINDER':
        if (seconds == null) throw _invalidPolicyResponse;
        used.addAll(['applicationId', 'seconds']);
        effects = {kind == 'DAILY_QUOTA' ? 'LIMIT' : 'REMIND'};
      case 'TIME_WINDOW':
        if (schedule == null) throw _invalidPolicyResponse;
        used.addAll(['applicationId', 'scheduleId']);
        effects = {'ALLOW'};
      case 'DOMAIN_ACCESS':
        if (domain == null) throw _invalidPolicyResponse;
        used.add('domain');
        effects = {'ALLOW', 'DENY'};
      default:
        throw _invalidPolicyResponse;
    }
    final fields = {
      'applicationId': application,
      'scheduleId': schedule,
      'permission': permission,
      'domain': domain,
      'seconds': seconds
    };
    if (!effects.contains(effect) ||
        fields.entries
            .any((entry) => entry.value != null && !used.contains(entry.key))) {
      throw _invalidPolicyResponse;
    }
    rules.add(Map<String, dynamic>.unmodifiable({
      'id': id,
      'kind': kind,
      'effect': effect,
      'required': rule['required'],
      ...fields
    }));
  }
  return List<Json>.unmodifiable(rules);
}

const _invalidPolicyInput = ApiFailure(400, 'VALIDATION_FAILED');

bool _hasFields(Json value, Set<String> fields) =>
    value.length == fields.length && fields.every(value.containsKey);

Json _draftInputValues(Json values) {
  if (!_nonemptyText(values['name']) ||
      (values['name'] as String).length > 100) throw _invalidPolicyInput;
  return Map<String, dynamic>.unmodifiable({
    'name': values['name'],
    'rules': readPolicyDraftRules(values['rules']),
  });
}

/// The immutable original write is the authority for its committed receipt.
/// A later current draft can describe newer edits, never replace that receipt.
class PolicyDraftChange {
  final Json body;
  final Json? _before;

  const PolicyDraftChange._(this.body, this._before);

  factory PolicyDraftChange.create(Json values) {
    try {
      if (!_hasFields(values, const {'name', 'kind', 'rules'}) ||
          !const {'POLICY', 'TEMPLATE'}.contains(values['kind'])) {
        throw _invalidPolicyInput;
      }
      return PolicyDraftChange._(Map<String, dynamic>.unmodifiable({
        'operation': 'CREATE',
        'kind': values['kind'],
        ..._draftInputValues(values),
      }), null);
    } on ApiFailure {
      throw _invalidPolicyInput;
    }
  }

  factory PolicyDraftChange.update(Json before, Json values) {
    try {
      final original = readPolicyDraftSnapshot(before);
      if (!_hasFields(values, const {'name', 'rules'}) ||
          original['revision'] == _maxSafePolicyInteger) {
        throw _invalidPolicyInput;
      }
      return PolicyDraftChange._(Map<String, dynamic>.unmodifiable({
        'operation': 'UPDATE',
        'policyId': original['id'],
        'revision': original['revision'],
        ..._draftInputValues(values),
      }), original);
    } on ApiFailure {
      throw _invalidPolicyInput;
    }
  }

  Json committed(Object? raw) {
    final before = _before;
    final result = readPolicyDraftSnapshot(raw,
        expectedId: before?['id'] as String?);
    if (result['name'] != body['name'] ||
        !_samePolicyValue(result['rules'], body['rules']) ||
        result['kind'] != (before?['kind'] ?? body['kind']) ||
        result['sourceVersionId'] != before?['sourceVersionId'] ||
        result['revision'] != (before == null ? 0 : before['revision'] + 1)) {
      throw _invalidPolicyResponse;
    }
    return result;
  }

  PolicyDraftChangeResult queryResult(Object? raw) {
    if (raw is! Json ||
        !_hasFields(raw, const {'operation', 'committed', 'current'}) ||
        raw['operation'] != body['operation']) throw _invalidPolicyResponse;
    final original = committed(raw['committed']);
    final current = readPolicyDraftSnapshot(raw['current'],
        expectedId: original['id'] as String);
    if (current['kind'] != original['kind'] ||
        (current['revision'] as int) < (original['revision'] as int) ||
        (current['revision'] == original['revision'] &&
            !_samePolicyValue(current, original))) throw _invalidPolicyResponse;
    return PolicyDraftChangeResult._(original, current);
  }
}

class PolicyDraftChangeResult {
  final Json committed, current;
  const PolicyDraftChangeResult._(this.committed, this.current);
}

bool _samePolicyValue(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length && left.keys.every((key) =>
        right.containsKey(key) && _samePolicyValue(left[key], right[key]));
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_samePolicyValue(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

