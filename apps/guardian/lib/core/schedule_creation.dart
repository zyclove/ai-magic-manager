import 'dart:convert';
import 'api.dart';
import 'schedule_copy.dart';

final _scheduleId = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

Json _canonicalSchedule(String id, ScheduleCopy schedule) =>
    Map<String, dynamic>.unmodifiable({
      'id': id,
      'name': schedule.name,
      'definition': Map<String, dynamic>.unmodifiable({
        'timeZone': schedule.timeZone,
        'weekly': schedule.weekly,
        'exceptions': schedule.exceptions,
      }),
    });

/// Accepts only the complete original creation, preserving every ordered window.
Json requireScheduleCreationResult(Object? raw, Json originalBody) {
  if (raw is! Json || raw['id'] is! String ||
      _scheduleId.firstMatch(raw['id'] as String)?.end != (raw['id'] as String).length ||
      originalBody.length != 2 || !originalBody.containsKey('name') ||
      !originalBody.containsKey('definition')) {
    throw const ApiFailure(502, 'INVALID_RESPONSE');
  }
  final id = raw['id'] as String;
  final actual = _canonicalSchedule(id, ScheduleCopy.fromSchedule(raw));
  final expected = _canonicalSchedule(id,
      ScheduleCopy.fromSchedule({'id': id, ...originalBody}));
  if (jsonEncode(actual) != jsonEncode(expected)) {
    throw const ApiFailure(502, 'INVALID_RESPONSE');
  }
  return actual;
}
