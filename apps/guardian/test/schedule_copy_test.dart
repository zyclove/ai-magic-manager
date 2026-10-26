import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/schedule_copy.dart';

Json _schedule({
  String name = '学习时段',
  String timeZone = 'America/New_York',
  List<Json>? weekly,
  List<Json>? exceptions,
}) =>
    {
      'id': 'saved-schedule',
      'name': name,
      'definition': {
        'timeZone': timeZone,
        'weekly': weekly ??
            [
              {'day': 'FRIDAY', 'start': '22:00', 'end': '01:00'},
            ],
        'exceptions': exceptions ??
            [
              {
                'date': '2026-12-25',
                'windows': [
                  {'start': '10:00', 'end': '12:00'},
                ]
              },
            ],
      },
    };

Json _changed(void Function(Json) change) {
  final value = _schedule();
  change(value);
  return value;
}

void main() {
  final invalidResponse = throwsA(isA<ApiFailure>()
      .having((failure) => failure.status, 'status', 502)
      .having((failure) => failure.code, 'code', 'INVALID_RESPONSE'));

  test('copy is isolated from later changes to every input layer', () {
    final input = _schedule();
    final copy = ScheduleCopy.fromSchedule(input);
    final definition = input['definition'] as Json;
    ((definition['weekly'] as List).first as Json)['start'] = '08:00';
    final exception = (definition['exceptions'] as List).first as Json;
    ((exception['windows'] as List).first as Json)['end'] = '18:00';
    exception['date'] = '2027-01-01';
    (definition['weekly'] as List).clear();
    (definition['exceptions'] as List).clear();
    definition['timeZone'] = 'UTC';
    input['name'] = '改名';
    input['definition'] = <String, dynamic>{};

    expect(copy.name, '学习时段');
    expect(copy.timeZone, 'America/New_York');
    expect(copy.weekly, [
      {'day': 'FRIDAY', 'start': '22:00', 'end': '01:00'},
    ]);
    expect(copy.exceptions, [
      {
        'date': '2026-12-25',
        'windows': [
          {'start': '10:00', 'end': '12:00'},
        ]
      },
    ]);
  });

  test('the copied lists and nested records are all immutable', () {
    final copy = ScheduleCopy.fromSchedule(_schedule());
    expect(() => copy.weekly.clear(), throwsUnsupportedError);
    expect(() => copy.weekly.first['start'] = '08:00', throwsUnsupportedError);
    expect(() => copy.exceptions.clear(), throwsUnsupportedError);
    expect(() => copy.exceptions.first['date'] = '2027-01-01',
        throwsUnsupportedError);
    final windows = copy.exceptions.first['windows'] as List;
    expect(() => windows.clear(), throwsUnsupportedError);
    expect(
        () => (windows.first as Json)['end'] = '18:00', throwsUnsupportedError);
  });

  test('preserves timezone overnight duplicates order and a closed exception',
      () {
    final input = _schedule(weekly: [
      {'day': 'SUNDAY', 'start': '22:00', 'end': '01:00'},
      {'day': 'SUNDAY', 'start': '22:00', 'end': '01:00'},
      {'day': 'SATURDAY', 'start': '23:30', 'end': '02:15'},
    ], exceptions: [
      {'date': '2026-11-01', 'windows': <Json>[]},
      {
        'date': '2026-12-24',
        'windows': [
          {'start': '10:00', 'end': '12:00'},
          {'start': '10:00', 'end': '12:00'},
          {'start': '11:00', 'end': '13:00'},
        ]
      },
    ]);
    final copy = ScheduleCopy.fromSchedule(input);
    final definition = input['definition'] as Json;
    expect(copy.timeZone, 'America/New_York');
    expect(copy.weekly, definition['weekly']);
    expect(copy.exceptions, definition['exceptions']);
    expect(copy.suggestedName, '学习时段（副本）');
  });

  test('allows closed schedules and exception-only schedules without defaults',
      () {
    for (final exceptions in <List<Json>>[
      [],
      [
        {
          'date': '2024-02-29',
          'windows': [
            {'start': '23:00', 'end': '01:00'},
          ]
        }
      ],
    ]) {
      final copy = ScheduleCopy.fromSchedule(
          _schedule(timeZone: 'UTC', weekly: [], exceptions: exceptions));
      expect(copy.timeZone, 'UTC');
      expect(copy.weekly, isEmpty);
      expect(copy.exceptions, exceptions);
    }
  });

  test('suggested names fit 100 UTF-16 units and never split a surrogate pair',
      () {
    final full = ScheduleCopy.fromSchedule(
        _schedule(name: List.filled(100, '名').join()));
    expect(full.name.length, 100);
    expect(full.suggestedName, '${List.filled(96, '名').join()}（副本）');
    final prefix = List.filled(95, 'a').join();
    final unicode = ScheduleCopy.fromSchedule(_schedule(name: '$prefix😀bbb'));
    expect(unicode.name.length, 100);
    expect(unicode.suggestedName, '$prefix（副本）');
    expect(unicode.suggestedName.length, lessThanOrEqualTo(100));
  });

  test(
      'accepts backend limits and rejects incomplete extra or oversized shapes',
      () {
    final window = {'day': 'MONDAY', 'start': '09:00', 'end': '10:00'};
    final dateWindows =
        List<Json>.generate(8, (_) => {'start': '09:00', 'end': '10:00'});
    final dates = List<Json>.generate(
        366,
        (index) => {
              'date': DateTime.utc(2024, 1, 1)
                  .add(Duration(days: index))
                  .toIso8601String()
                  .substring(0, 10),
              'windows': dateWindows,
            });
    final boundary = ScheduleCopy.fromSchedule(
        _schedule(weekly: List<Json>.filled(56, window), exceptions: dates));
    expect(boundary.weekly, hasLength(56));
    expect(boundary.exceptions, hasLength(366));

    final invalid = <String, Json>{
      'missing definition': _changed((value) => value.remove('definition')),
      'missing id': _changed((value) => value.remove('id')),
      'extra entry field': _changed((value) => value['createdAt'] = 123),
      'blank name': _schedule(name: '   '),
      'long name': _schedule(name: List.filled(101, 'a').join()),
      'blank timezone': _schedule(timeZone: ''),
      'long timezone': _schedule(timeZone: List.filled(101, 'a').join()),
      'missing weekly':
          _changed((value) => (value['definition'] as Json).remove('weekly')),
      'extra definition field':
          _changed((value) => (value['definition'] as Json)['unknown'] = true),
      'non-list weekly': _changed(
          (value) => (value['definition'] as Json)['weekly'] = 'MONDAY'),
      'non-object weekly item':
          _changed((value) => (value['definition'] as Json)['weekly'] = [null]),
      'extra window field': _schedule(weekly: [
        {...window, 'unknown': true}
      ]),
      'too many weekly windows':
          _schedule(weekly: List<Json>.filled(57, window)),
      'too many dates': _schedule(exceptions: [
        ...dates,
        {'date': '2025-01-01', 'windows': <Json>[]},
      ]),
      'too many date windows': _schedule(exceptions: [
        {
          'date': '2026-01-01',
          'windows': List<Json>.filled(9, {'start': '09:00', 'end': '10:00'})
        },
      ]),
      'extra date field': _schedule(exceptions: [
        {'date': '2026-01-01', 'windows': <Json>[], 'unknown': true},
      ]),
      'extra date window field': _schedule(exceptions: [
        {
          'date': '2026-01-01',
          'windows': [
            {'start': '09:00', 'end': '10:00', 'unknown': true},
          ]
        },
      ]),
    };
    for (final entry in invalid.entries) {
      expect(() => ScheduleCopy.fromSchedule(entry.value), invalidResponse,
          reason: entry.key);
    }
  });

  test(
      'rejects invalid weekdays dates and time windows without normalizing them',
      () {
    final invalid = <String, Json>{
      'unknown weekday': _schedule(weekly: [
        {'day': 'FUNDAY', 'start': '09:00', 'end': '10:00'},
      ]),
      'numeric weekday': _schedule(weekly: [
        {'day': 1, 'start': '09:00', 'end': '10:00'},
      ]),
      for (final time in ['24:00', '09:60', '9:00', '09:00\n'])
        'invalid time $time': _schedule(weekly: [
          {'day': 'MONDAY', 'start': time, 'end': '10:00'},
        ]),
      'equal endpoints': _schedule(weekly: [
        {'day': 'MONDAY', 'start': '09:00', 'end': '09:00'},
      ]),
      for (final date in [
        '2026-02-29',
        '2026-04-31',
        '1899-12-31',
        '2201-01-01',
        '2026-1-01',
        '2026-01-01\n'
      ])
        'invalid date $date': _schedule(exceptions: [
          {'date': date, 'windows': <Json>[]},
        ]),
      'duplicate date': _schedule(exceptions: [
        {'date': '2026-01-01', 'windows': <Json>[]},
        {'date': '2026-01-01', 'windows': <Json>[]},
      ]),
      'equal date endpoints': _schedule(exceptions: [
        {
          'date': '2026-01-01',
          'windows': [
            {'start': '09:00', 'end': '09:00'},
          ]
        },
      ]),
    };
    for (final entry in invalid.entries) {
      expect(() => ScheduleCopy.fromSchedule(entry.value), invalidResponse,
          reason: entry.key);
    }
  });
}
