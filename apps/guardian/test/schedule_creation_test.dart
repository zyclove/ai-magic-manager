import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/schedule_creation.dart';

const _id = 'c1111111-1111-4111-8111-111111111111';
Json _body({bool emptyWeekly = false}) => {
  'name': '跨时区学习',
  'definition': {
    'timeZone': 'America/New_York',
    'weekly': emptyWeekly ? <Json>[] : [
      {'day': 'FRIDAY', 'start': '22:00', 'end': '01:00'},
      {'day': 'SATURDAY', 'start': '23:30', 'end': '02:15'},
    ],
    'exceptions': [
      {'date': '2026-12-25', 'windows': <Json>[]},
      {'date': '2027-01-01', 'windows': [
        {'start': '23:00', 'end': '01:00'}, {'start': '10:00', 'end': '12:00'},
      ]},
    ],
  },
};
Json _clone(Json value) => jsonDecode(jsonEncode(value)) as Json;
Json _definition(Json schedule) => schedule['definition'] as Json;
List _weekly(Json schedule) => _definition(schedule)['weekly'] as List;
List _exceptions(Json schedule) => _definition(schedule)['exceptions'] as List;
List _windows(Json schedule) => (_exceptions(schedule)[1] as Json)['windows'] as List;
Object? _reverseObjectKeys(Object? value) {
  if (value is Json) {
    return <String, dynamic>{
      for (final key in value.keys.toList().reversed) key: _reverseObjectKeys(value[key]),
    };
  }
  if (value is List) return value.map(_reverseObjectKeys).toList();
  return value;
}
Matcher get _invalid => throwsA(isA<ApiFailure>()
    .having((failure) => failure.status, 'status', 502)
    .having((failure) => failure.code, 'code', 'INVALID_RESPONSE'));

void main() {
  test('creation receipts preserve non-tenant zones, overnight and exception-only definitions independent of object key order', () {
    for (final emptyWeekly in [false, true]) {
      final body = _body(emptyWeekly: emptyWeekly);
      final response = _reverseObjectKeys({'id': _id, ...body});
      final result = requireScheduleCreationResult(response, body);
      expect(result, {'id': _id, ...body});
      expect(_definition(result)['timeZone'], 'America/New_York');
      expect((_exceptions(result).first as Json)['windows'], isEmpty);
      expect((_windows(result).first as Json)['end'], '01:00');
      if (emptyWeekly) {
        expect(_weekly(result), isEmpty);
      } else {
        expect((_weekly(result).first as Json)['end'], '01:00');
      }
    }
    final closed = _body(emptyWeekly: true);
    _definition(closed)['exceptions'] = <Json>[];
    expect(requireScheduleCreationResult({'id': _id, ...closed}, closed),
        {'id': _id, ...closed});
  });

  test('receipt mismatches and malformed original definitions cannot confirm another schedule', () {
    final body = _body();
    Json changed(void Function(Json) change) {
      final response = _clone({'id': _id, ...body});
      change(response);
      return response;
    }
    for (final invalid in <Object?>[
      null, [], body, changed((s) => s['id'] = _id.toUpperCase()),
      changed((s) => s['id'] = 'not-a-uuid'),
      changed((s) => s['name'] = '另一计划'),
      changed((s) => _definition(s)['timeZone'] = 'UTC'),
      changed((s) => _weekly(s).removeAt(0)),
      changed((s) => _definition(s)['weekly'] = _weekly(s).reversed.toList()),
      changed((s) => (_weekly(s).first as Json)['day'] = 'MONDAY'),
      changed((s) => (_weekly(s).first as Json)['start'] = '21:00'),
      changed((s) => _exceptions(s).removeAt(0)),
      changed((s) => _definition(s)['exceptions'] = _exceptions(s).reversed.toList()),
      changed((s) => (_exceptions(s).first as Json)['date'] = '2026-12-24'),
      changed((s) => _windows(s).removeAt(0)),
      changed((s) => (_exceptions(s)[1] as Json)['windows'] = _windows(s).reversed.toList()),
      changed((s) => (_windows(s).first as Json)['end'] = '02:00'),
      changed((s) => s['extra'] = true),
      changed((s) => _definition(s).remove('exceptions')),
      changed((s) => (_weekly(s).first as Json)['extra'] = true),
    ]) {
      expect(() => requireScheduleCreationResult(invalid, body), _invalid);
    }
    for (final invalidBody in <Json>[
      {...body, 'id': _id}, {'name': body['name']},
      {'name': ' ', 'definition': body['definition']},
      {'name': body['name'], 'definition': {..._definition(body), 'extra': true}},
    ]) {
      expect(() => requireScheduleCreationResult({'id': _id, ...body}, invalidBody), _invalid);
    }
    final invalidCalendar = _clone(body);
    (_exceptions(invalidCalendar).first as Json)['date'] = '2026-02-30';
    expect(() => requireScheduleCreationResult({'id': _id, ...invalidCalendar}, invalidCalendar),
        _invalid, reason: 'Matching invalid data still fails the shared calendar parser.');
  });

  test('verified schedules detach and freeze every nested object and list', () {
    final original = _body();
    final response = _clone({'id': _id, ...original});
    final expected = _clone(response);
    final result = requireScheduleCreationResult(response, original);
    expect(() => result['name'] = '改变', throwsUnsupportedError);
    expect(() => _definition(result)['timeZone'] = 'UTC', throwsUnsupportedError);
    expect(() => _weekly(result).clear(), throwsUnsupportedError);
    expect(() => (_weekly(result).first as Json)['start'] = '08:00', throwsUnsupportedError);
    expect(() => _exceptions(result).clear(), throwsUnsupportedError);
    expect(() => (_exceptions(result).first as Json)['date'] = '2027-01-02', throwsUnsupportedError);
    expect(() => _windows(result).clear(), throwsUnsupportedError);
    expect(() => (_windows(result).first as Json)['end'] = '18:00', throwsUnsupportedError);
    original['name'] = '改变原名称';
    _definition(original)['timeZone'] = 'UTC';
    _weekly(original).clear();
    _exceptions(original).clear();
    (_windows(response).first as Json)['start'] = '08:00';
    (_exceptions(response)[1] as Json)['date'] = '2027-02-01';
    _definition(response).clear();
    response.clear();
    expect(result, expected);
  });
}
