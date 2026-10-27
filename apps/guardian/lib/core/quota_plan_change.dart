import 'api.dart';

const _invalidInput = ApiFailure(400, 'VALIDATION_FAILED');
const _invalidResponse = ApiFailure(502, 'INVALID_QUOTA_PLAN_RESPONSE');
const _maximumInteger = 9007199254740991;
const _weekdays = {
  'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY',
  'FRIDAY', 'SATURDAY', 'SUNDAY',
};
const _identity = ['id', 'subjectId', 'scope', 'applicationId', 'timeZone', 'createdAt'];
const _configuration = ['name', 'state', 'weeklyLimits', 'dateOverrides'];

bool _text(Object? value, {int? maximum}) => value is String &&
    value.trim().isNotEmpty && (maximum == null || value.length <= maximum);
bool _integer(Object? value, {int maximum = _maximumInteger}) =>
    value is int && value >= 0 && value <= maximum;
bool _fields(Json value, Set<String> required,
    {Set<String> optional = const {}}) => required.every(value.containsKey) &&
    value.keys.every((key) => required.contains(key) || optional.contains(key));

bool _date(Object? value) {
  if (value is! String ||
      !RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(value) ||
      value.length != 10) return false;
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  if (month < 1 || month > 12 || day < 1) return false;
  final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  final lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= lengths[month - 1];
}

bool _scope(Json value) => const {'TOTAL', 'APPLICATION'}.contains(value['scope']) &&
    (value['scope'] == 'APPLICATION'
        ? _text(value['applicationId']) : value['applicationId'] == null);

Json _weekly(Object? raw) {
  if (raw is! Json || raw.length != 7 ||
      !_weekdays.every(raw.containsKey) ||
      raw.values.any((value) => !_integer(value, maximum: 86400))) {
    throw _invalidResponse;
  }
  return Map<String, dynamic>.unmodifiable(raw);
}

Json _overrides(Object? raw) {
  if (raw is! Json || raw.length > 60 || raw.entries.any((entry) =>
      !_date(entry.key) || !_integer(entry.value, maximum: 86400))) {
    throw _invalidResponse;
  }
  return Map<String, dynamic>.unmodifiable(raw);
}

Json _readConfiguration(Json raw, {String? state}) {
  final selectedState = state ?? raw['state'];
  if (!_text(raw['name'], maximum: 100) ||
      !const {'ACTIVE', 'PAUSED'}.contains(selectedState)) throw _invalidResponse;
  return Map<String, dynamic>.unmodifiable({
    'name': raw['name'],
    'state': selectedState,
    'weeklyLimits': _weekly(raw['weeklyLimits']),
    'dateOverrides': _overrides(raw['dateOverrides']),
  });
}

/// Read only complete, detached plan facts; resource identifiers remain opaque.
Json readQuotaPlanSnapshot(Object? raw, {String? expectedId}) {
  if (raw is! Json || !_text(raw['id']) ||
      expectedId != null && raw['id'] != expectedId ||
      !_text(raw['subjectId']) || !_scope(raw) ||
      !_text(raw['timeZone'], maximum: 100) || !_date(raw['effectiveFrom']) ||
      !_integer(raw['version']) || !_integer(raw['createdAt'])) {
    throw _invalidResponse;
  }
  final configuration = _readConfiguration(raw);
  return Map<String, dynamic>.unmodifiable({
    'id': raw['id'],
    'subjectId': raw['subjectId'],
    'scope': raw['scope'],
    'applicationId': raw['applicationId'],
    'timeZone': raw['timeZone'],
    ...configuration,
    'effectiveFrom': raw['effectiveFrom'],
    'version': raw['version'],
    'createdAt': raw['createdAt'],
  });
}

Json readQuotaPlanCalendar(Object? raw) {
  if (raw is! Json || !_text(raw['timeZone'], maximum: 100) ||
      !_date(raw['currentDate'])) throw _invalidResponse;
  return Map<String, dynamic>.unmodifiable({
    'timeZone': raw['timeZone'],
    'currentDate': raw['currentDate'],
  });
}

class QuotaPlanChangeResult {
  final Json committed, current;
  const QuotaPlanChangeResult._(this.committed, this.current);
}

/// Original input and committed receipt stay separate from later saved edits.
class QuotaPlanChange {
  final Json body;
  final Json? _before;
  const QuotaPlanChange._(this.body, this._before);

  factory QuotaPlanChange.create(Json originalBody) {
    try {
      if (!_fields(originalBody, const {
        'name', 'subjectId', 'scope', 'timeZone', 'effectiveFrom',
        'weeklyLimits', 'dateOverrides',
      }, optional: const {'applicationId'}) ||
          !_text(originalBody['subjectId']) || !_scope(originalBody) ||
          !_text(originalBody['timeZone'], maximum: 100) ||
          !_date(originalBody['effectiveFrom'])) throw _invalidInput;
      final configuration = _readConfiguration(originalBody, state: 'ACTIVE');
      return QuotaPlanChange._(Map<String, dynamic>.unmodifiable({
        'name': configuration['name'],
        'subjectId': originalBody['subjectId'],
        'scope': originalBody['scope'],
        if (originalBody.containsKey('applicationId'))
          'applicationId': originalBody['applicationId'],
        'timeZone': originalBody['timeZone'],
        'effectiveFrom': originalBody['effectiveFrom'],
        'weeklyLimits': configuration['weeklyLimits'],
        'dateOverrides': configuration['dateOverrides'],
      }), null);
    } on ApiFailure {
      throw _invalidInput;
    }
  }

  factory QuotaPlanChange.update(Json before, Json originalBody) {
    try {
      final original = readQuotaPlanSnapshot(before);
      if (!_fields(originalBody,
          const {'name', 'state', 'weeklyLimits', 'dateOverrides'}) ||
          original['version'] == _maximumInteger) throw _invalidInput;
      return QuotaPlanChange._(_readConfiguration(originalBody), original);
    } on ApiFailure {
      throw _invalidInput;
    }
  }

  Json committed(Object? raw) {
    final before = _before;
    final result = readQuotaPlanSnapshot(raw,
        expectedId: before?['id'] as String?);
    if (result['version'] != (before == null ? 0 : before['version'] + 1) ||
        _configuration.any((key) => !_same(result[key],
            key == 'state' && before == null ? 'ACTIVE' : body[key]))) {
      throw _invalidResponse;
    }
    if (before == null) {
      if (const ['subjectId', 'scope', 'applicationId', 'timeZone', 'effectiveFrom']
          .any((key) => result[key] != body[key])) throw _invalidResponse;
    } else if (_identity.any((key) => result[key] != before[key])) {
      throw _invalidResponse;
    }
    return result;
  }

  QuotaPlanChangeResult queryResult(Object? raw, {required String requestId}) {
    if (!_text(requestId)) throw _invalidInput;
    if (raw is! Json ||
        !_fields(raw, const {'requestId', 'operation', 'committed', 'current'}) ||
        raw['requestId'] != requestId ||
        raw['operation'] != (_before == null ? 'PLAN_CREATE' : 'PLAN_UPDATE')) {
      throw _invalidResponse;
    }
    final original = committed(raw['committed']);
    final current = readQuotaPlanSnapshot(raw['current'],
        expectedId: original['id'] as String);
    if (_identity.any((key) => current[key] != original[key]) ||
        (current['version'] as int) < (original['version'] as int) ||
        (current['version'] == original['version'] && !_same(current, original))) {
      throw _invalidResponse;
    }
    return QuotaPlanChangeResult._(original, current);
  }
}

bool _same(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length && left.keys.every((key) =>
        right.containsKey(key) && _same(left[key], right[key]));
  }
  return left == right;
}
