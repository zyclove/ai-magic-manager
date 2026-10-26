import 'api.dart';

/// A detached, immutable seed for creating another saved schedule.
/// Identity and server metadata are deliberately not exposed as POST fields.
class ScheduleCopy {
  final String name, timeZone;
  final List<Json> weekly, exceptions;

  const ScheduleCopy._(this.name, this.timeZone, this.weekly, this.exceptions);

  factory ScheduleCopy.fromSchedule(Json value) {
    final schedule = _object(value, const {'id', 'name', 'definition'});
    _text(schedule['id']);
    final name = _text(schedule['name'], maxLength: 100);
    final definition = _object(
        schedule['definition'], const {'timeZone', 'weekly', 'exceptions'});
    // The saved zone belongs to the server's ZoneId/TZDB. Copy its identifier;
    // do not substitute the tenant zone or evaluate DST in this model.
    final zone = _text(definition['timeZone'], maxLength: 100);
    final weekly = List<Json>.unmodifiable(_list(definition['weekly'], 56)
        .map((item) => _window(item, weekly: true)));
    final dates = <String>{};
    final exceptions = <Json>[];
    for (final item in _list(definition['exceptions'], 366)) {
      final override = _object(item, const {'date', 'windows'});
      final date = _date(override['date']);
      if (!dates.add(date)) _invalid();
      exceptions.add(Map<String, dynamic>.unmodifiable({
        'date': date,
        'windows': List<Json>.unmodifiable(
            _list(override['windows'], 8).map((item) => _window(item))),
      }));
    }
    return ScheduleCopy._(
        name, zone, weekly, List<Json>.unmodifiable(exceptions));
  }

  String get suggestedName {
    const suffix = '（副本）';
    const limit = 100 - suffix.length;
    var end = name.length < limit ? name.length : limit;
    if (end > 0 && end < name.length) {
      final previous = name.codeUnitAt(end - 1);
      if (previous >= 0xd800 && previous <= 0xdbff) end--;
    }
    return '${name.substring(0, end)}$suffix';
  }
}

Never _invalid() => throw const ApiFailure(502, 'INVALID_RESPONSE');

Json _object(Object? value, Set<String> keys) {
  if (value is! Json) _invalid();
  if (value.length != keys.length ||
      keys.any((key) => !value.containsKey(key))) {
    _invalid();
  }
  return value;
}

String _text(Object? value, {int? maxLength}) {
  if (value is! String ||
      value.trim().isEmpty ||
      (maxLength != null && value.length > maxLength)) _invalid();
  return value;
}

List<dynamic> _list(Object? value, int maxLength) {
  if (value is! List || value.length > maxLength) _invalid();
  return value;
}

const _weekdays = {
  'MONDAY',
  'TUESDAY',
  'WEDNESDAY',
  'THURSDAY',
  'FRIDAY',
  'SATURDAY',
  'SUNDAY',
};
final _timePattern = RegExp(r'([01][0-9]|2[0-3]):[0-5][0-9]');
final _datePattern = RegExp(r'[0-9]{4}-[0-9]{2}-[0-9]{2}');

bool _matches(String value, RegExp pattern) {
  final match = pattern.firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}

Json _window(Object? value, {bool weekly = false}) {
  final window = _object(
      value, weekly ? const {'day', 'start', 'end'} : const {'start', 'end'});
  if (weekly && !_weekdays.contains(window['day'])) _invalid();
  final start = window['start'], end = window['end'];
  if (start is! String ||
      end is! String ||
      !_matches(start, _timePattern) ||
      !_matches(end, _timePattern) ||
      start == end) _invalid();
  return Map<String, dynamic>.unmodifiable({
    if (weekly) 'day': window['day'],
    'start': start,
    'end': end,
  });
}

String _date(Object? value) {
  if (value is! String || !_matches(value, _datePattern)) _invalid();
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  if (year < 1900 || year > 2200) _invalid();
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) _invalid();
  return value;
}
