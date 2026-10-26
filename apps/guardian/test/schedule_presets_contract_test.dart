import 'package:flutter_test/flutter_test.dart';
import 'package:schedule_contracts/schedule_contracts.dart';

Map<String, dynamic> _window({
  String day = 'MONDAY',
  String start = '22:00',
  String end = '01:00',
}) => {'day': day, 'start': start, 'end': end};

Map<String, dynamic> _preset({
  String id = 'evening',
  String name = '晚间示例',
  String description = '仅作本地填写参考',
  List<Object?>? weekly,
}) => {
  'id': id,
  'name': name,
  'description': description,
  'weekly': weekly ?? [_window()],
};

Map<String, dynamic> _catalog([List<Object?>? items]) => {
  'schemaVersion': 1,
  'items': items ?? [_preset()],
};

List<Object?> _windows(int count) => List.generate(count, (index) {
  const days = ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY',
    'FRIDAY', 'SATURDAY', 'SUNDAY'];
  final hour = (index ~/ 7).toString().padLeft(2, '0');
  return _window(day: days[index % 7], start: '$hour:00', end: '$hour:30');
});

void main() {
  test('preset values detach from raw input and remain deeply immutable', () {
    final row = _window();
    final weekly = <Object?>[row];
    final item = _preset(weekly: weekly);
    final items = <Object?>[item];
    final result = SchedulePreset.readCatalog(_catalog(items));
    item['name'] = '已改动';
    row['start'] = '13:00';
    weekly.clear();
    items.clear();

    expect(result.single.id, 'evening');
    expect(result.single.name, '晚间示例');
    expect(result.single.description, '仅作本地填写参考');
    expect(result.single.weekly, [
      {'day': 'MONDAY', 'start': '22:00', 'end': '01:00'}
    ], reason: 'An overnight example keeps its original wall times.');
    expect(() => result.clear(), throwsUnsupportedError);
    expect(() => result.single.weekly.clear(), throwsUnsupportedError);
    expect(() => result.single.weekly.single['start'] = '12:00',
        throwsUnsupportedError);
  });

  test('catalog and preset bounds accept endpoints without expanding examples', () {
    expect(SchedulePreset.readCatalog(_catalog([])), isEmpty);
    expect(SchedulePreset.readCatalog(_catalog(
      List.generate(20, (index) => _preset(id: 'example-$index')),
    )), hasLength(20));
    final maximum = SchedulePreset.readCatalog(_catalog([
      _preset(name: '名' * 100, description: '述' * 300, weekly: _windows(56))
    ])).single;
    expect(maximum.weekly, hasLength(56));
    for (final invalid in [
      _catalog(List.generate(21, (index) => _preset(id: 'example-$index'))),
      _catalog([_preset(weekly: [])]),
      _catalog([_preset(weekly: _windows(57))]),
      _catalog([_preset(name: '名' * 101)]),
      _catalog([_preset(description: '述' * 301)]),
    ]) {
      expect(() => SchedulePreset.readCatalog(invalid), throwsFormatException);
    }
  });

  test('every JSON layer rejects missing or unknown fields and loose versions', () {
    for (final invalid in <Object?>[
      {..._catalog(), 'schemaVersion': 1.0},
      {..._catalog(), 'schemaVersion': true},
      {..._catalog(), 'timeZone': 'UTC'},
      {'items': [_preset()]},
      _catalog([{..._preset(), 'exceptions': []}]),
      _catalog([{
        ..._preset(),
        'weekly': [{..._window(), 'seconds': 60}]
      }]),
      _catalog([{
        ..._preset(),
        'weekly': [{'day': 'MONDAY', 'start': '18:00'}]
      }]),
    ]) {
      expect(() => SchedulePreset.readCatalog(invalid), throwsFormatException);
    }
  });

  test('invalid raw values and unsafe labels fail without coercion or echo', () {
    for (final invalid in <Object?>[
      null,
      1,
      'private raw catalog',
      <Object?>[],
      <Object?, Object?>{1: 'private raw value', 'items': []},
      _catalog([{..._preset(), 'name': Object()}]),
      _catalog([_preset(name: ' leading')]),
      _catalog([_preset(description: 'trailing ')]),
      _catalog([_preset(name: 'private\u0000label')]),
      _catalog([_preset(name: 'private\u0085label')]),
      _catalog([_preset(description: 'private\u202elabel')]),
      _catalog([_preset(description: 'private\u061clabel')]),
      _catalog([_preset(name: 'private\u00adlabel')]),
      _catalog([_preset(description: 'private\u0600label')]),
      _catalog([_preset(description: 'private\u{1d173}label')]),
    ]) {
      expect(() => SchedulePreset.readCatalog(invalid),
          throwsA(isA<FormatException>()
              .having((error) => error.source, 'no raw source', isNull)
              .having((error) => error.message, 'no raw value echoed',
                  isNot(contains('private')))));
    }
  });

  test('ids and windows reject duplicates and noncanonical wall times', () {
    final one = _preset();
    for (final invalid in [
      _catalog([one, one]),
      _catalog([_preset(id: 'evening\n')]),
      _catalog([_preset(weekly: [_window(), _window()])]),
      _catalog([_preset(weekly: [_window(day: 'monday')])]),
      _catalog([_preset(weekly: [_window(start: '9:00')])]),
      _catalog([_preset(weekly: [_window(start: '24:00')])]),
      _catalog([_preset(weekly: [_window(end: '01:00\n')])]),
      _catalog([_preset(weekly: [_window(start: '01:00', end: '01:00')])]),
    ]) {
      expect(() => SchedulePreset.readCatalog(invalid), throwsFormatException);
    }
  });
}
