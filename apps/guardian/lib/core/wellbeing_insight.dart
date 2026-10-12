import 'api.dart';
import 'bounded_json.dart';

final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _packageName =
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$');
const _maxSafeInteger = 9007199254740991;

Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_WELLBEING_INSIGHT_RESPONSE');

bool _time(Object? value) =>
    value is int && value >= 0 && value <= _maxSafeInteger;

class WellbeingSuggestion {
  final String packageName, displayName;
  final int days, minimumDailyMillis;

  WellbeingSuggestion._(Json value)
      : packageName = value['packageName'],
        displayName = value['displayName'],
        days = value['days'],
        minimumDailyMillis = value['minimumDailyMillis'];

  static WellbeingSuggestion parse(Object? value) {
    if (value is! Json ||
        value['kind'] != 'REVIEW_APP_TIME' ||
        value['packageName'] is! String ||
        !_packageName.hasMatch(value['packageName']) ||
        value['packageName'].length > 255 ||
        value['displayName'] is! String ||
        (value['displayName'] as String).isEmpty ||
        value['displayName'].length > 100 ||
        value['days'] is! int ||
        value['days'] < 3 ||
        value['days'] > 7 ||
        value['minimumDailyMillis'] != 7200000) _invalid();
    return WellbeingSuggestion._(value);
  }
}

/// Advice from device-reported aggregates; no diagnosis and no automatic policy edit.
class WellbeingInsight {
  final String tenantId, deviceId, registrationId, timeZone, status;
  final int generatedAt, from, to, queryCoverageMillis;
  final List<WellbeingSuggestion> suggestions;

  WellbeingInsight._(Json value, this.suggestions)
      : tenantId = value['tenantId'],
        deviceId = value['deviceId'],
        registrationId = value['registrationId'],
        timeZone = value['timeZone'],
        status = value['status'],
        generatedAt = value['generatedAt'],
        from = value['from'],
        to = value['to'],
        queryCoverageMillis = value['queryCoverageMillis'];

  static WellbeingInsight parse(
      Object? value, String tenantId, String deviceId, String registrationId) {
    if (value is! Json ||
        value['schemaVersion'] != 1 ||
        value['tenantId'] != tenantId ||
        value['deviceId'] != deviceId ||
        value['registrationId'] != registrationId ||
        value['timeZone'] is! String ||
        (value['timeZone'] as String).isEmpty ||
        value['timeZone'].length > 100 ||
        value['evidenceStatus'] != 'AGENT_REPORTED_UNVERIFIED' ||
        !const {
          'NOT_AUTHORIZED',
          'NO_DATA',
          'INSUFFICIENT_COVERAGE',
          'NO_PATTERN',
          'SUGGESTIONS'
        }.contains(value['status']) ||
        !_time(value['generatedAt']) ||
        !_time(value['from']) ||
        !_time(value['to']) ||
        value['from'] >= value['to'] ||
        value['to'] > value['generatedAt'] ||
        !_time(value['queryCoverageMillis']) ||
        value['queryCoverageMillis'] > value['to'] - value['from'] ||
        value['suggestions'] is! List ||
        (value['suggestions'] as List).length > 3) _invalid();
    final suggestions = (value['suggestions'] as List)
        .map(WellbeingSuggestion.parse)
        .toList(growable: false);
    if ((value['status'] == 'SUGGESTIONS') != suggestions.isNotEmpty ||
        suggestions.map((item) => item.packageName).toSet().length !=
            suggestions.length) _invalid();
    return WellbeingInsight._(value, List.unmodifiable(suggestions));
  }
}

class WellbeingInsightRepository {
  final Api api;
  final String root, tenantId;
  final bool Function() current;

  const WellbeingInsightRepository(
      {required this.api,
      required this.root,
      required this.tenantId,
      required this.current});

  Future<WellbeingInsight> load(String deviceId, String registrationId) async {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    if (!_uuid.hasMatch(deviceId) || !_uuid.hasMatch(registrationId)) {
      throw const ApiFailure(400, 'INVALID_DEVICE_ID');
    }
    final raw = await boundedJson(
        api, 'GET', '$root/devices/$deviceId/wellbeing-insight',
        maxBytes: 32 * 1024, ensureCurrent: () {
      if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    });
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    return WellbeingInsight.parse(raw, tenantId, deviceId, registrationId);
  }
}
