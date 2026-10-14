import 'parent_api.dart';
import 'schedules.dart';

/// Deployment examples are immutable drafting aids, never saved schedules.
class SchedulePreset {
  final String id, name, description;
  final List<Json> weekly;
  SchedulePreset._(this.id, this.name, this.description, List<Json> rows)
      : weekly = List.unmodifiable(
            rows.map((row) => Map<String, dynamic>.unmodifiable(row)));

  static List<SchedulePreset> readCatalog(dynamic raw) {
    const invalid = ParentApiException(502, 'INVALID_RESPONSE');
    if (raw is! Json ||
        raw['schemaVersion'] != 1 ||
        raw['items'] is! List ||
        (raw['items'] as List).length > 20) throw invalid;
    final ids = <String>{};
    final result = <SchedulePreset>[];
    bool text(dynamic value, int max) =>
        value is String &&
        value.trim().isNotEmpty &&
        value == value.trim() &&
        value.length <= max &&
        !RegExp(r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]')
            .hasMatch(value);
    for (final item in raw['items']) {
      if (item is! Json ||
          item['id'] is! String ||
          !RegExp(r'^[a-z][a-z0-9-]{0,39}$').hasMatch(item['id']) ||
          !ids.add(item['id']) ||
          !text(item['name'], 100) ||
          !text(item['description'], 300) ||
          item['weekly'] is! List ||
          (item['weekly'] as List).isEmpty) throw invalid;
      try {
        validateScheduleDefinition(
            {'timeZone': 'UTC', 'weekly': item['weekly'], 'exceptions': []});
      } on FormatException {
        throw invalid;
      }
      final keys = <String>{};
      final rows = <Json>[];
      for (final row in item['weekly']) {
        if (!keys.add('${row['day']}/${row['start']}/${row['end']}')) {
          throw invalid;
        }
        rows.add({'day': row['day'], 'start': row['start'], 'end': row['end']});
      }
      result.add(SchedulePreset._(
          item['id'], item['name'], item['description'], rows));
    }
    return List.unmodifiable(result);
  }
}
