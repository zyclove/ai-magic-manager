import 'api.dart';

const _invalidResult = ApiFailure(502, 'INVALID_DOMAIN_CHECK_RESPONSE');

class PolicyDomainEvaluation {
  final String canonicalDomain, predictedEffect;
  final List<String> matchingRuleIds;
  PolicyDomainEvaluation(
      {required this.canonicalDomain,
      required this.predictedEffect,
      required Iterable<String> matchingRuleIds})
      : matchingRuleIds = List.unmodifiable(matchingRuleIds);
}

bool _whole(String value, String pattern) {
  final match = RegExp(pattern).firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}

bool _canonicalDomain(Object? value) =>
    value is String &&
    value.length <= 253 &&
    value.contains('.') &&
    !_whole(value, r'[0-9.]+') &&
    value.split('.').every(
        (label) => _whole(label, r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'));

/// This is a read-only prediction against one frozen draft, with no DNS lookup
/// or device execution. IDN conversion stays with the server's rule normalizer.
Future<PolicyDomainEvaluation> evaluatePolicyDomain(Api api,
    {required String root, required Json draft, required String domain}) async {
  final input = domain.trim();
  if (input.isEmpty ||
      input.length > 253 ||
      RegExp(r'[:/\\?#*@\s]').hasMatch(input)) {
    throw const ApiFailure(400, 'INVALID_DOMAIN');
  }
  final id = draft['id'], revision = draft['revision'], rules = draft['rules'];
  if (id is! String ||
      id.isEmpty ||
      id.length > 100 ||
      revision is! int ||
      revision < 0 ||
      revision > 9007199254740991 ||
      rules is! List ||
      rules.length > 100) {
    throw _invalidResult;
  }
  // Copy only immutable values before awaiting; never borrow mutable maps from
  // a details route or use later edits to validate an older response.
  final domainRules = <String, ({String domain, String effect})>{};
  for (final rule in rules) {
    if (rule is! Json) {
      throw _invalidResult;
    }
    if (rule['kind'] != 'DOMAIN_ACCESS') {
      continue;
    }
    final key = rule['id'], name = rule['domain'], effect = rule['effect'];
    if (key is! String ||
        !_whole(key, r'[a-z][a-z0-9_-]{0,49}') ||
        domainRules.containsKey(key) ||
        !_canonicalDomain(name) ||
        !const {'ALLOW', 'DENY'}.contains(effect)) {
      throw _invalidResult;
    }
    domainRules[key] = (domain: name as String, effect: effect as String);
  }

  final value = await api.send(
      'POST', '$root/policies/${Uri.encodeComponent(id)}/domain-evaluations',
      body: {'domain': input}, version: revision);
  const keys = {
    'policyId',
    'draftRevision',
    'canonicalDomain',
    'matchingRuleIds',
    'predictedEffect',
    'effectiveEffect',
    'matchMode',
    'executionStatus'
  };
  if (value is! Json ||
      value.length != keys.length ||
      !value.keys.every(keys.contains) ||
      value['policyId'] != id ||
      value['draftRevision'] is! int ||
      value['draftRevision'] != revision ||
      !_canonicalDomain(value['canonicalDomain']) ||
      value['effectiveEffect'] != null ||
      value['matchMode'] != 'EXACT_DOMAIN' ||
      value['executionStatus'] != 'NOT_EVALUATED' ||
      value['matchingRuleIds'] is! List) {
    throw _invalidResult;
  }
  final canonical = value['canonicalDomain'] as String;
  if (input.codeUnits.every((unit) => unit < 128) &&
      input.toLowerCase() != canonical) {
    throw _invalidResult;
  }
  final expected = domainRules.keys
      .where((key) => domainRules[key]!.domain == canonical)
      .toList()
    ..sort();
  final actual = value['matchingRuleIds'] as List;
  if (actual.length != expected.length) {
    throw _invalidResult;
  }
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      throw _invalidResult;
    }
  }
  final predicted = expected.isEmpty
      ? 'NO_MATCH'
      : expected.any((key) => domainRules[key]!.effect == 'DENY')
          ? 'DENY'
          : 'ALLOW';
  if (value['predictedEffect'] != predicted) {
    throw _invalidResult;
  }
  return PolicyDomainEvaluation(
      canonicalDomain: canonical,
      predictedEffect: predicted,
      matchingRuleIds: expected);
}
