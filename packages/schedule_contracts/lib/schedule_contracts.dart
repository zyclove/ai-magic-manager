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
          weekly.length > 56) {
        throw _invalid;
      }
      final seen = <String>{};
      final windows = <Map<String, String>>[];
      for (final value in weekly) {
        final row = _object(value, const {'day', 'start', 'end'});
        final day = row['day'];
        final start = row['start'];
        final end = row['end'];
        if (day is! String ||
            !_days.contains(day) ||
            start is! String ||
            !_exact(_time, start) ||
            end is! String ||
            !_exact(_time, end) ||
            start == end ||
            !seen.add('$day/$start/$end')) {
          throw _invalid;
        }
        windows.add(Map<String, String>.unmodifiable(
            {'day': day, 'start': start, 'end': end}));
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
