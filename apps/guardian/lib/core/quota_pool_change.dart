import 'api.dart';

const _invalidInput = ApiFailure(400, 'VALIDATION_FAILED');
const _invalidDuration = ApiFailure(400, 'INVALID_QUOTA_DURATION');
const _invalidResponse = ApiFailure(502, 'INVALID_QUOTA_POOL_RESPONSE');
const _balanceConflict = ApiFailure(400, 'QUOTA_BALANCE_CONFLICT');
const _maximumInteger = 9007199254740991;
const _maximumEpoch = 8640000000000000;
const _snapshotKeys = [
  'id', 'subjectId', 'name', 'scope', 'applicationId', 'periodId', 'timeZone',
  'periodStart', 'periodEnd', 'limitSeconds', 'usedSeconds', 'reservedSeconds',
  'availableSeconds', 'status', 'evidenceStatus', 'version', 'planId', 'planVersion',
];
const _identityKeys = [
  'id', 'subjectId', 'name', 'scope', 'applicationId', 'periodId', 'timeZone',
  'periodStart', 'periodEnd', 'status', 'evidenceStatus', 'planId', 'planVersion',
];

bool _text(Object? value, {int? maximum}) => value is String &&
    value.trim().isNotEmpty && (maximum == null || value.length <= maximum);
bool _integer(Object? value, {int minimum = 0, int maximum = _maximumInteger}) =>
    value is int && value >= minimum && value <= maximum;
bool _fields(Json raw, Set<String> required, {Set<String> optional = const {}}) =>
    required.every(raw.containsKey) && raw.keys.every((key) =>
        required.contains(key) || optional.contains(key));
bool _same(Json left, Json right, Iterable<String> keys) =>
    keys.every((key) => left[key] == right[key]);

int _duration(Json values, {required bool allowZero}) {
  final minutes = values['minutes'];
  final seconds = values['seconds'] ?? 0;
  if (!_integer(minutes, maximum: 1440) || !_integer(seconds, maximum: 59)) {
    throw _invalidInput;
  }
  final total = (minutes as int) * 60 + (seconds as int);
  if (total > 86400 || (!allowZero && total == 0)) throw _invalidDuration;
  return total;
}

bool _date(Object? value) {
  if (value is! String || value.length != 10 ||
      !RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(value)) return false;
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  if (month < 1 || month > 12 || day < 1) return false;
  final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  final lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= lengths[month - 1];
}

String? quotaPoolPeriodError(String? value) => _date(value)
    ? null : '请输入有效日期，格式为 yyyy-MM-dd。';

/// The bounded ledger does not claim that a device has stopped an application.
/// Day boundaries are server facts and may span a daylight-saving transition.
Json readQuotaPoolSnapshot(Object? raw, {String? expectedId}) {
  if (raw is! Json || !_snapshotKeys.every(raw.containsKey) || !_text(raw['id']) ||
      (expectedId != null && raw['id'] != expectedId) ||
      !_text(raw['subjectId']) || !_text(raw['name'], maximum: 100) ||
      !const {'TOTAL', 'APPLICATION'}.contains(raw['scope']) ||
      (raw['scope'] == 'APPLICATION'
          ? !_text(raw['applicationId']) : raw['applicationId'] != null) ||
      !_date(raw['periodId']) || !_text(raw['timeZone'], maximum: 100) ||
      !_integer(raw['periodStart'], maximum: _maximumEpoch) ||
      !_integer(raw['periodEnd'], maximum: _maximumEpoch) ||
      (raw['periodEnd'] as int) <= (raw['periodStart'] as int) ||
      !_integer(raw['version']) || raw['status'] != 'CONFIGURED' ||
      raw['evidenceStatus'] != 'LEDGER_ONLY') throw _invalidResponse;
  for (final key in ['limitSeconds', 'usedSeconds', 'reservedSeconds', 'availableSeconds']) {
    if (!_integer(raw[key], maximum: 86400)) throw _invalidResponse;
  }
  if (raw['usedSeconds'] + raw['reservedSeconds'] + raw['availableSeconds'] !=
      raw['limitSeconds']) throw _invalidResponse;
  if (raw['planId'] == null
      ? raw['planVersion'] != null
      : !_text(raw['planId']) || !_integer(raw['planVersion'])) {
    throw _invalidResponse;
  }
  return Map<String, dynamic>.unmodifiable({
    for (final key in _snapshotKeys) key: raw[key],
  });
}

Json readQuotaLedgerEntry(Object? raw) {
  if (raw is! Json || !_text(raw['id']) ||
      (raw['leaseId'] != null && !_text(raw['leaseId'])) ||
      !const {'CREATED', 'ADJUSTED', 'RESERVED', 'SETTLED', 'RELEASED'}
          .contains(raw['kind']) ||
      !_integer(raw['limitDelta'], minimum: -86400, maximum: 86400) ||
      !_integer(raw['usedDelta'], maximum: 86400) ||
      !_integer(raw['reservedDelta'], minimum: -86400, maximum: 86400) ||
      (raw['sequence'] != null && !_integer(raw['sequence'])) ||
      (raw['reason'] != null && !_text(raw['reason'])) ||
      !_integer(raw['occurredAt'], maximum: _maximumEpoch)) throw _invalidResponse;
  return Map<String, dynamic>.unmodifiable({
    for (final key in const ['id', 'leaseId', 'kind', 'limitDelta', 'usedDelta',
      'reservedDelta', 'sequence', 'reason', 'occurredAt']) key: raw[key],
  });
}

class QuotaPoolChangeResult {
  final Json committed, current;
  const QuotaPoolChangeResult._(this.committed, this.current);
}

/// One original daily-pool mutation and its exact historical ledger receipt.
class QuotaPoolChange {
  final Json body;
  final Json? _before;
  const QuotaPoolChange._(this.body, this._before);

  factory QuotaPoolChange.create(Json rawFormValues) {
    if (!_fields(rawFormValues,
        const {'name', 'subjectId', 'periodId', 'timeZone', 'minutes'},
        optional: const {'applicationId', 'seconds'}) ||
        !_text(rawFormValues['name'], maximum: 100) ||
        !_text(rawFormValues['subjectId']) || !_date(rawFormValues['periodId']) ||
        !_text(rawFormValues['timeZone'], maximum: 100)) throw _invalidInput;
    final total = _duration(rawFormValues, allowZero: true);
    final application = rawFormValues['applicationId'];
    if (application != null && application != '' && !_text(application)) {
      throw _invalidInput;
    }
    final scoped = application != null && application != '';
    return QuotaPoolChange._(Map<String, dynamic>.unmodifiable({
      'name': (rawFormValues['name'] as String).trim(),
      'subjectId': rawFormValues['subjectId'],
      'scope': scoped ? 'APPLICATION' : 'TOTAL',
      if (scoped) 'applicationId': application,
      'periodId': rawFormValues['periodId'],
      'timeZone': rawFormValues['timeZone'],
      'limitSeconds': total,
    }), null);
  }

  factory QuotaPoolChange.adjust(Json before, Json rawFormValues) {
    final Json original;
    try {
      original = readQuotaPoolSnapshot(before);
    } on ApiFailure {
      throw _invalidInput;
    }
    if (!_fields(rawFormValues, const {'direction', 'minutes'},
        optional: const {'seconds'}) ||
        !const {'ADD', 'SUBTRACT'}.contains(rawFormValues['direction']) ||
        original['version'] == _maximumInteger) throw _invalidInput;
    final total = _duration(rawFormValues, allowZero: false);
    final adding = rawFormValues['direction'] == 'ADD';
    final delta = total * (adding ? 1 : -1);
    final next = original['limitSeconds'] + delta;
    if (next > 86400 || next < original['usedSeconds'] + original['reservedSeconds']) {
      throw _balanceConflict;
    }
    return QuotaPoolChange._(Map<String, dynamic>.unmodifiable({
      'deltaSeconds': delta,
      'reason': adding ? 'EXTRA_TIME' : 'CORRECTION',
    }), original);
  }

  Json committed(Object? raw) {
    final before = _before;
    final result = readQuotaPoolSnapshot(raw,
        expectedId: before?['id'] as String?);
    if (result['version'] != (before == null ? 0 : before['version'] + 1)) {
      throw _invalidResponse;
    }
    if (before == null) {
      if (!_same(result, body, const [
        'name', 'subjectId', 'scope', 'applicationId', 'periodId', 'timeZone', 'limitSeconds',
      ]) || result['usedSeconds'] != 0 || result['reservedSeconds'] != 0 ||
          result['planId'] != null || result['planVersion'] != null) {
        throw _invalidResponse;
      }
    } else if (!_same(result, before, _identityKeys) ||
        result['usedSeconds'] != before['usedSeconds'] ||
        result['reservedSeconds'] != before['reservedSeconds'] ||
        result['limitSeconds'] != before['limitSeconds'] + body['deltaSeconds']) {
      throw _invalidResponse;
    }
    return result;
  }

  QuotaPoolChangeResult queryResult(Object? raw, {required String requestId}) {
    if (!_text(requestId)) throw _invalidInput;
    if (raw is! Json ||
        !_fields(raw, const {'requestId', 'operation', 'committed', 'current'}) ||
        raw['requestId'] != requestId ||
        raw['operation'] != (_before == null ? 'CREATE' : 'ADJUST')) {
      throw _invalidResponse;
    }
    final original = committed(raw['committed']);
    final current = readQuotaPoolSnapshot(raw['current'],
        expectedId: original['id'] as String);
    if (!_same(current, original, _identityKeys) ||
        (current['version'] as int) < (original['version'] as int) ||
        (current['version'] == original['version'] &&
            !_same(current, original, _snapshotKeys))) throw _invalidResponse;
    return QuotaPoolChangeResult._(original, current);
  }
}
