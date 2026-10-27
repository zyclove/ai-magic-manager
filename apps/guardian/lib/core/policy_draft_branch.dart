import 'api.dart';
import 'policy_draft_change.dart';

const _invalidInput = ApiFailure(400, 'VALIDATION_FAILED');
const _invalidResponse = ApiFailure(502, 'INVALID_RESPONSE');
const _maximumRevision = 9007199254740991;

bool _text(Object? value) => value is String && value.trim().isNotEmpty;
Json _name(Json values) {
  final value = values['name'];
  if (values.length != 1 || value is! String || value.trim().isEmpty ||
      value.trim().length > 100) throw _invalidInput;
  return Map<String, dynamic>.unmodifiable({'name': value.trim()});
}

class PolicyDraftBranchResult {
  final Json committed, current;
  const PolicyDraftBranchResult._(this.committed, this.current);
}

/// A branch keeps its exact original source separate from later draft edits.
class PolicyDraftBranch {
  final Json body;
  final Json _before;
  final List<Json> _rules;
  final String? _sourceVersionId;
  const PolicyDraftBranch._(this.body, this._before, this._rules, this._sourceVersionId);

  factory PolicyDraftBranch.copy(Json template, Json values) {
    try {
      final original = readPolicyDraftSnapshot(template);
      if (original['kind'] != 'TEMPLATE') throw _invalidInput;
      return PolicyDraftBranch._(_name(values), original,
          original['rules'] as List<Json>, null);
    } on ApiFailure {
      throw _invalidInput;
    }
  }

  factory PolicyDraftBranch.rollback(Json currentDraft, Json sourceVersion, Json values) {
    try {
      final original = readPolicyDraftSnapshot(currentDraft);
      final snapshot = sourceVersion['snapshot'];
      if (original['kind'] != 'POLICY' || original['revision'] == _maximumRevision ||
          !_text(sourceVersion['id']) || sourceVersion['policyId'] != original['id'] ||
          snapshot is! Json || snapshot['schemaVersion'] is! int ||
          snapshot['schemaVersion'] != 1) throw _invalidInput;
      return PolicyDraftBranch._(_name(values), original,
          readPolicyDraftRules(snapshot['sourceRules']), sourceVersion['id'] as String);
    } on ApiFailure {
      throw _invalidInput;
    }
  }

  Json committed(Object? raw) {
    final copying = _sourceVersionId == null;
    final result = readPolicyDraftSnapshot(raw,
        expectedId: copying ? null : _before['id'] as String);
    if ((copying && result['id'] == _before['id']) ||
        result['kind'] != 'POLICY' || result['name'] != body['name'] ||
        result['revision'] != (copying ? 0 : _before['revision'] + 1) ||
        result['sourceVersionId'] != _sourceVersionId ||
        !_same(result['rules'], _rules)) throw _invalidResponse;
    return result;
  }

  PolicyDraftBranchResult queryResult(Object? raw, {required String requestId}) {
    if (!_text(requestId)) throw _invalidInput;
    if (raw is! Json || raw.length != 4 ||
        !const ['requestId', 'operation', 'committed', 'current'].every(raw.containsKey) ||
        raw['requestId'] != requestId || raw['operation'] !=
            (_sourceVersionId == null ? 'TEMPLATE_COPY' : 'ROLLBACK_DRAFT')) {
      throw _invalidResponse;
    }
    final original = committed(raw['committed']);
    final current = readPolicyDraftSnapshot(raw['current'],
        expectedId: original['id'] as String);
    if (current['kind'] != original['kind'] ||
        (current['revision'] as int) < (original['revision'] as int) ||
        (current['revision'] == original['revision'] && !_same(current, original))) {
      throw _invalidResponse;
    }
    return PolicyDraftBranchResult._(original, current);
  }
}

bool _same(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length && left.keys.every((key) =>
        right.containsKey(key) && _same(left[key], right[key]));
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_same(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
