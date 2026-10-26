import 'package:flutter_test/flutter_test.dart';
import 'package:schedule_contracts/schedule_contracts.dart';

Map<String, Object?> window(String day,
        {String start = '22:00', String end = '01:00'}) =>
    {'day': day, 'start': start, 'end': end};

void main() {
  test('weekly additions preserve existing duplicates and return detached values',
      () {
    final first = window('MONDAY');
    final existing = [first, window('MONDAY')];
    final selected = ['WEDNESDAY', 'MONDAY', 'TUESDAY', 'TUESDAY'];
    final result = weeklyWindowAdditions(
        existing: existing,
        selectedDays: selected,
        start: '22:00',
        end: '01:00');

    expect(existing, [window('MONDAY'), window('MONDAY')]);
    expect(identical(existing.first, first), isTrue);
    expect(result, [window('TUESDAY'), window('WEDNESDAY')]);
    first['start'] = '17:00';
    existing.clear();
    selected.clear();
    expect(result, [window('TUESDAY'), window('WEDNESDAY')]);
    expect(() => result.clear(), throwsUnsupportedError);
    expect(() => result.first['end'] = '02:00', throwsUnsupportedError);
  });

  test('near capacity counts actual additions and leaves an oversized batch local',
      () {
    final existing = [
      for (final day in ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY'])
        window(day, start: '18:00', end: '20:00'),
      ...List.generate(51, (_) => window('MONDAY')),
    ];
    final fitting = weeklyWindowAdditions(
        existing: existing,
        selectedDays: ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY'],
        start: '18:00',
        end: '20:00');
    expect(fitting, [window('FRIDAY', start: '18:00', end: '20:00')]);
    expect(existing.length + fitting.length, maximumWeeklyWindows);

    final oversized = weeklyWindowAdditions(
        existing: existing,
        selectedDays: ['SATURDAY', 'SUNDAY'],
        start: '18:00',
        end: '20:00');
    expect(oversized, [
      window('SATURDAY', start: '18:00', end: '20:00'),
      window('SUNDAY', start: '18:00', end: '20:00'),
    ]);
    expect(existing.length + oversized.length,
        greaterThan(maximumWeeklyWindows));
    expect(existing, hasLength(55),
        reason: 'The caller can reject the complete batch before any mutation.');
  });
}
