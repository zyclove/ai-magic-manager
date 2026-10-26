/// Maximum stored weekly windows, including any existing duplicate rows.
const maximumWeeklyWindows = 56;

/// Computes a detached batch without changing or deduplicating existing rows.
/// Callers reject the complete batch if the resulting plan exceeds the limit.
List<Map<String, String>> weeklyWindowAdditions({
  required Iterable<Map<String, Object?>> existing,
  required Iterable<String> selectedDays,
  required String start,
  required String end,
}) {
  try {
    final selected = selectedDays.toSet();
    if (selected.isEmpty ||
        selected.any((day) => !_days.contains(day)) ||
        !_wallTimes(start, end)) {
      throw _invalid;
    }
    final present = <String>{};
    for (final value in existing) {
      final row = _weeklyWindow(value);
      present.add('${row['day']}/${row['start']}/${row['end']}');
    }
    return List<Map<String, String>>.unmodifiable([
      for (final day in _days)
        if (selected.contains(day) && !present.contains('$day/$start/$end'))
          Map<String, String>.unmodifiable(
              {'day': day, 'start': start, 'end': end}),
    ]);
  } on FormatException {
    throw const FormatException('Invalid weekly time window input.');
  }
}

/// A deployment-provided drafting example, never a saved or active schedule.
class SchedulePreset {
  final String id;
  final String name;
  final String description;
  final List<Map<String, String>> weekly;

  SchedulePreset._(this.id, this.name, this.description,
      List<Map<String, String>> windows)
      : weekly = List<Map<String, String>>.unmodifiable(windows);

  /// Reads the entire catalog atomically and detaches all returned values.
  /// Invalid input throws a constant error without retaining private raw data.
  static List<SchedulePreset> readCatalog(Object? raw) {
    final catalog = _object(raw, const {'schemaVersion', 'items'});
    if (catalog['schemaVersion'] is! int || catalog['schemaVersion'] != 1) {
      throw _invalid;
    }
    final items = catalog['items'];
    if (items is! List || items.length > 20) throw _invalid;
    final ids = <String>{};
    final result = <SchedulePreset>[];
    for (final value in items) {
      final item = _object(value, const {'id', 'name', 'description', 'weekly'});
      final id = item['id'];
      final name = item['name'];
      final description = item['description'];
      final weekly = item['weekly'];
      if (id is! String ||
          !_exact(_id, id) ||
          !ids.add(id) ||
          !_text(name, 100) ||
          !_text(description, 300) ||
          weekly is! List ||
          weekly.isEmpty ||
          weekly.length > maximumWeeklyWindows) {
        throw _invalid;
      }
      final seen = <String>{};
      final windows = <Map<String, String>>[];
      for (final value in weekly) {
        final row = _weeklyWindow(value);
        if (!seen.add('${row['day']}/${row['start']}/${row['end']}')) {
          throw _invalid;
        }
        windows.add(row);
      }
      result.add(SchedulePreset._(id, name as String, description as String,
          windows));
    }
    return List<SchedulePreset>.unmodifiable(result);
  }
}

const _invalid = FormatException('Invalid schedule preset catalog.');
final _id = RegExp(r'[a-z][a-z0-9-]{0,39}');
final _time = RegExp(r'(?:[01][0-9]|2[0-3]):[0-5][0-9]');
// Match the backend's control/format categories, including supplementary runes.
final _unsafeText = RegExp(r'[\p{Cc}\p{Cf}]', unicode: true);
const _days = {
  'MONDAY',
  'TUESDAY',
  'WEDNESDAY',
  'THURSDAY',
  'FRIDAY',
  'SATURDAY',
  'SUNDAY'
};

Map<String, Object?> _object(Object? raw, Set<String> fields) {
  if (raw is! Map ||
      raw.length != fields.length ||
      raw.keys.any((key) => key is! String || !fields.contains(key))) {
    throw _invalid;
  }
  return Map<String, Object?>.from(raw);
}

Map<String, String> _weeklyWindow(Object? raw) {
  final row = _object(raw, const {'day', 'start', 'end'});
  final day = row['day'], start = row['start'], end = row['end'];
  if (day is! String ||
      !_days.contains(day) ||
      !_wallTimes(start, end)) {
    throw _invalid;
  }
  return Map<String, String>.unmodifiable(
      {'day': day, 'start': start as String, 'end': end as String});
}

bool _wallTimes(Object? start, Object? end) =>
    start is String &&
    end is String &&
    _exact(_time, start) &&
    _exact(_time, end) &&
    start != end;

bool _exact(RegExp pattern, String value) {
  final match = pattern.firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}

bool _text(Object? value, int max) =>
    value is String &&
    value.isNotEmpty &&
    value == value.trim() &&
    value.length <= max &&
    !_unsafeText.hasMatch(value);
