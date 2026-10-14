part of 'quotas.dart';

const quotaWeekDays = [
  'MONDAY',
  'TUESDAY',
  'WEDNESDAY',
  'THURSDAY',
  'FRIDAY',
  'SATURDAY',
  'SUNDAY'
];
const quotaWeekLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

bool _planConfiguration(Json raw) {
  final week = raw['weeklyLimits'], dates = raw['dateOverrides'];
  return _text(raw['name'], 100) &&
      const {'ACTIVE', 'PAUSED'}.contains(raw['state']) &&
      week is Map &&
      week.length == 7 &&
      quotaWeekDays.every((day) => _integer(week[day], 0, 86400)) &&
      dates is Map &&
      dates.length <= 60 &&
      dates.entries
          .every((e) => quotaDate(e.key) && _integer(e.value, 0, 86400));
}

/// Saved configuration can be scheduled for tomorrow; ACTIVE does not prove device execution.
Json readQuotaPlan(dynamic raw) {
  if (raw is! Json ||
      !_planConfiguration(raw) ||
      !_uuid(raw['id']) ||
      !_uuid(raw['subjectId']) ||
      !_text(raw['timeZone'], 100) ||
      !quotaDate(raw['effectiveFrom']) ||
      !const {'TOTAL', 'APPLICATION'}.contains(raw['scope']) ||
      (raw['scope'] == 'TOTAL'
          ? raw['applicationId'] != null
          : !_uuid(raw['applicationId'])) ||
      !_integer(raw['version'], 0, 9007199254740991) ||
      !_integer(raw['createdAt'], 0, 253402300799999)) throw _invalid;
  return Map<String, dynamic>.unmodifiable(raw);
}

void validateQuotaPlanInput(String operation, Json body, Json? before) {
  if (!_planConfiguration(
      {...body, if (operation == 'PLAN_CREATE') 'state': 'ACTIVE'})) {
    throw const FormatException('请填写名称、一周七天的额度和有效的特殊日期；每天最多 1440 分钟。');
  }
  if (operation == 'PLAN_CREATE') {
    if (before != null ||
        !_uuid(body['subjectId']) ||
        !_text(body['timeZone'], 100) ||
        !quotaDate(body['effectiveFrom']) ||
        !const {'TOTAL', 'APPLICATION'}.contains(body['scope']) ||
        (body['scope'] == 'TOTAL'
            ? body['applicationId'] != null
            : !_uuid(body['applicationId']))) {
      throw const FormatException('请先选择儿童、应用范围和开始日期。');
    }
  } else if (operation == 'PLAN_UPDATE') {
    readQuotaPlan(before);
  } else {
    throw _invalid;
  }
}

bool _samePlanMap(dynamic a, dynamic b) =>
    a is Map &&
    b is Map &&
    a.length == b.length &&
    a.keys.every((key) => a[key] == b[key]);

Json _checkCommittedPlan(dynamic raw, Json pending) {
  final result = readQuotaPlan(raw),
      body = pending['body'] as Json,
      before = pending['before'] as Json?;
  for (final key in [
    'subjectId',
    'scope',
    'applicationId',
    'timeZone',
    if (before == null) 'effectiveFrom' else 'id'
  ]) {
    if (result[key] != (before ?? body)[key]) throw _invalid;
  }
  if (result['version'] != (before == null ? 0 : before['version'] + 1) ||
      result['name'] != (body['name'] as String).trim() ||
      result['state'] != (before == null ? 'ACTIVE' : body['state']) ||
      !_samePlanMap(result['weeklyLimits'], body['weeklyLimits']) ||
      !_samePlanMap(result['dateOverrides'], body['dateOverrides'])) {
    throw _invalid;
  }
  return result;
}

/// Preserves seconds from existing plans until an operator explicitly replaces that value.
String quotaMinutesInput(int seconds) => seconds % 60 == 0
    ? '${seconds ~/ 60}'
    : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
int? parseQuotaMinutes(String input) {
  final match = RegExp(r'^(\d{1,4})(?::([0-5]\d))?$').firstMatch(input.trim());
  if (match == null) return null;
  final value = int.parse(match[1]!) * 60 + int.parse(match[2] ?? '0');
  return value <= 86400 ? value : null;
}

/// Bounded version pagination; version numbers are resource identities, not UUIDs.
class QuotaRevisionController extends ChangeNotifier {
  final ParentApi api;
  final String path;
  final bool Function() isCurrent;
  final List<Json> items = [];
  String? cursor;
  bool busy = false, loaded = false, _disposed = false;
  Object? error;
  QuotaRevisionController(this.api, this.path, this.isCurrent);
  Future<void> load({bool reload = false}) async {
    if (_disposed ||
        !isCurrent() ||
        busy ||
        (loaded && cursor == null && !reload)) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final page = await api.page(path,
          limit: 20,
          cursor: reload ? null : cursor,
          isCurrent: () => !_disposed && isCurrent());
      if (_disposed || !isCurrent()) return;
      int? previous = reload || items.isEmpty ? null : items.last['version'];
      for (final row in page.items) {
        if (!_integer(row['version'], 0, 9007199254740991) ||
            !quotaDate(row['effectiveFrom']) ||
            !_integer(row['createdAt'], 0, 253402300799999) ||
            row['configuration'] is! Json ||
            !_planConfiguration(row['configuration']) ||
            (previous != null && row['version'] >= previous)) throw _invalid;
        previous = row['version'];
      }
      if (page.nextCursor != null &&
          (page.items.isEmpty || page.nextCursor != '$previous')) {
        throw _invalid;
      }
      if (reload) items.clear();
      items.addAll(page.items);
      cursor = page.nextCursor;
      loaded = true;
    } catch (failure) {
      if (!_disposed && isCurrent()) error = failure;
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
