import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/device_group_change.dart';

const _groupId = '00000000-0000-4000-8000-000000000001';
const _newId = '00000000-0000-4000-8000-000000000002';
const _deviceA = '00000000-0000-4000-8000-000000000003';
const _deviceB = '00000000-0000-4000-8000-000000000004';
const _registrationA = '00000000-0000-4000-8000-000000000005';
const _registrationB = '00000000-0000-4000-8000-000000000006';

Json _group() => {
      'id': _groupId, 'name': '教室设备', 'state': 'ACTIVE', 'version': 7,
      'deviceCount': 3, 'createdAt': 100, 'updatedAt': 200,
    };
List<Json> _targets() => [
      {'deviceId': _deviceB, 'registrationId': _registrationB},
      {'deviceId': _deviceA, 'registrationId': _registrationA},
    ];
Json _clone(Json value) => jsonDecode(jsonEncode(value)) as Json;
Matcher _failure(int status, String code) => throwsA(isA<ApiFailure>()
    .having((failure) => failure.status, 'status', status)
    .having((failure) => failure.code, 'code', code));
Matcher get _invalidInput => _failure(400, 'VALIDATION_FAILED');
Matcher get _invalidResponse => _failure(502, 'INVALID_DEVICE_GROUP_RESPONSE');

Map<String, DeviceGroupChange> _changes() => {
      'CREATE': DeviceGroupChange.create({'name': '新设备组'}),
      'RENAME': DeviceGroupChange.rename(_group(), {'name': '新设备组'}),
      'ARCHIVE': DeviceGroupChange.archive(_group()),
      'ADD': DeviceGroupChange.members(_group(), _targets(), removing: false),
      'REMOVE': DeviceGroupChange.members(_group(), _targets(), removing: true),
    };
Json _receipt(String operation) => switch (operation) {
      'CREATE' => {..._group(), 'id': _newId, 'name': '新设备组', 'version': 0,
          'deviceCount': 0, 'createdAt': 300, 'updatedAt': 300},
      'RENAME' => {..._group(), 'name': '新设备组', 'version': 8, 'updatedAt': 300},
      'ARCHIVE' => {..._group(), 'state': 'ARCHIVED', 'version': 8, 'updatedAt': 300},
      'ADD' => {..._group(), 'deviceCount': 4, 'version': 8, 'updatedAt': 300},
      _ => {..._group(), 'deviceCount': 1, 'version': 8, 'updatedAt': 300},
    };

void main() {
  test('captures complete bounded group facts and freezes exact sorted writer and query inputs', () {
    final original = _group();
    final targets = _targets();
    final values = <String, dynamic>{'name': '  新设备组  '};
    final create = DeviceGroupChange.create(values);
    final rename = DeviceGroupChange.rename(original, values);
    final archive = DeviceGroupChange.archive(original);
    final add = DeviceGroupChange.members(original, targets, removing: false);
    final remove = DeviceGroupChange.members(original, targets, removing: true);
    final snapshot = readDeviceGroupSnapshot(original, expectedId: _groupId);
    original.clear();
    values.clear();
    targets.first.clear();
    targets.clear();
    expect(snapshot, _group());
    expect(() => snapshot.clear(), throwsUnsupportedError);
    expect(create.groupId, isNull);
    expect(create.version, isNull);
    expect(create.body, {'name': '新设备组'});
    expect(create.queryBody, {'operation': 'CREATE', 'name': '新设备组'});
    expect(rename.body, {'name': '新设备组'});
    expect(rename.queryBody, {'operation': 'RENAME', 'groupId': _groupId,
      'version': 7, 'name': '新设备组'});
    expect(archive.body, isEmpty);
    expect(archive.queryBody, {'operation': 'ARCHIVE', 'groupId': _groupId, 'version': 7});
    final ordered = [
      {'deviceId': _deviceA, 'registrationId': _registrationA},
      {'deviceId': _deviceB, 'registrationId': _registrationB},
    ];
    for (final change in [add, remove]) {
      expect(change.groupId, _groupId);
      expect(change.version, 7);
      expect(change.body, {'devices': ordered});
      expect(change.queryBody, {'operation': change == add ? 'ADD' : 'REMOVE',
        'groupId': _groupId, 'version': 7, 'devices': ordered});
      final frozen = change.body['devices'] as List;
      expect(() => frozen.clear(), throwsUnsupportedError);
      expect(() => (frozen.first as Json).clear(), throwsUnsupportedError);
    }
    for (final change in [create, rename, archive, add, remove]) {
      expect(() => change.body.clear(), throwsUnsupportedError);
      expect(() => change.queryBody.clear(), throwsUnsupportedError);
    }
    for (final invalid in <Object?>[
      null, {}, {..._group()}..remove('createdAt'),
      {..._group(), 'id': 'not-a-uuid'}, {..._group(), 'id': '$_groupId\n'},
      {..._group(), 'name': ' '}, {..._group(), 'name': 'a\u200bb'},
      {..._group(), 'name': 'a\nb'}, {..._group(), 'state': 'UNKNOWN'},
      {..._group(), 'version': 1.5}, {..._group(), 'version': -1},
      {..._group(), 'version': 9007199254740992},
      {..._group(), 'deviceCount': 5001}, {..._group(), 'deviceCount': -1},
      {..._group(), 'deviceCount': 1.5}, {..._group(), 'createdAt': -1},
      {..._group(), 'updatedAt': 8640000000000001},
      {..._group(), 'updatedAt': 99},
    ]) {
      expect(() => readDeviceGroupSnapshot(invalid), _invalidResponse);
    }
    expect(() => readDeviceGroupSnapshot(_group(), expectedId: _newId), _invalidResponse);
    for (final invalid in <Json>[
      {}, {'name': ' '}, {'name': 'a\u200bb'}, {'name': 'a\nb'},
      {'name': List.filled(101, 'a').join()}, {'name': '新设备组', 'extra': true},
    ]) {
      expect(() => DeviceGroupChange.create(invalid), _invalidInput);
      expect(() => DeviceGroupChange.rename(_group(), invalid), _invalidInput);
    }
    for (final invalid in <List<Json>>[
      [], List.generate(51, (_) => _targets().first),
      [_targets().first, _targets().first],
      [{'deviceId': _deviceA, 'registrationId': 'invalid'}],
      [{'deviceId': _deviceA, 'registrationId': _registrationA, 'name': 'extra'}],
    ]) {
      expect(() => DeviceGroupChange.members(_group(), invalid, removing: false), _invalidInput);
    }
    for (final before in <Json>[
      {}, {..._group(), 'state': 'ARCHIVED'},
      {..._group(), 'version': 9007199254740991},
    ]) {
      expect(() => DeviceGroupChange.rename(before, {'name': '新设备组'}), _invalidInput);
      expect(() => DeviceGroupChange.archive(before), _invalidInput);
      expect(() => DeviceGroupChange.members(before, _targets(), removing: false), _invalidInput);
    }
    expect(() => DeviceGroupChange.members({..._group(), 'deviceCount': 1},
        _targets(), removing: true), _invalidInput);
  });

  test('matches each original write including unchanged rename and fully existing additions', () {
    for (final entry in _changes().entries) {
      final raw = _receipt(entry.key);
      final expected = _clone(raw);
      final result = entry.value.committed(raw);
      raw.clear();
      expect(result, expected);
      expect(() => result.clear(), throwsUnsupportedError);
      for (final invalid in <Object?>[
        null, {}, {...expected, 'name': '不属于原操作的名称'},
        {...expected, 'state': entry.key == 'ARCHIVE' ? 'ACTIVE' : 'ARCHIVED'},
        {...expected, 'version': (expected['version'] as int) + 1},
        {...expected, 'deviceCount': 5000},
        if (entry.key != 'CREATE') ...[
          {...expected, 'id': _newId}, {...expected, 'createdAt': 101},
          {...expected, 'updatedAt': 199},
        ],
      ]) {
        expect(() => entry.value.committed(invalid), _invalidResponse);
      }
    }
    final sameName = DeviceGroupChange.rename(_group(), {'name': '  教室设备  '});
    expect(sameName.committed(_group()), _group());
    expect(() => sameName.committed({..._group(), 'version': 8}), _invalidResponse);
    expect(() => sameName.committed({..._group(), 'updatedAt': 201}), _invalidResponse);
    final add = DeviceGroupChange.members(_group(), _targets(), removing: false);
    expect(add.committed(_group()), _group());
    expect(add.committed({..._receipt('ADD'), 'deviceCount': 5})['deviceCount'], 5);
    for (final invalid in <Json>[
      {..._group(), 'updatedAt': 201}, {..._group(), 'deviceCount': 4},
      {..._receipt('ADD'), 'deviceCount': 3},
      {..._receipt('ADD'), 'deviceCount': 6},
    ]) {
      expect(() => add.committed(invalid), _invalidResponse);
    }
    final full = {..._group(), 'deviceCount': 5000};
    expect(DeviceGroupChange.members(full, _targets(), removing: false).committed(full), full);
    final remove = DeviceGroupChange.members(_group(), _targets(), removing: true);
    expect(() => remove.committed(_group()), _invalidResponse);
    expect(() => remove.committed({..._receipt('REMOVE'), 'deviceCount': 2}), _invalidResponse);
    expect(() => _changes()['CREATE']!.committed(
        {..._receipt('CREATE'), 'updatedAt': 301}), _invalidResponse);
  });

  test('separates committed facts from later current changes and rejects mismatched historical envelopes', () {
    for (final entry in _changes().entries) {
      final committed = _receipt(entry.key);
      final current = entry.key == 'ARCHIVE' ? _clone(committed) : <String, dynamic>{
        ...committed, 'version': (committed['version'] as int) + 3,
        'name': '后来修改的设备组', 'deviceCount': 2,
        'state': 'ARCHIVED', 'updatedAt': 400,
      };
      Json query({Json? original, Json? latest}) => {
        'operation': entry.key, 'committed': original ?? committed,
        'current': latest ?? current,
      };
      final result = entry.value.queryResult(query());
      expect(result.committed, committed);
      expect(result.current, current);
      expect(() => result.committed.clear(), throwsUnsupportedError);
      expect(() => result.current.clear(), throwsUnsupportedError);
      expect(entry.value.queryResult(query(latest: _clone(committed))).current, committed);
      for (final invalid in <Object?>[
        null, {}, {...query(), 'extra': true}, {...query(), 'operation': 'OTHER'},
        {...query(), 'committed': null}, query(original: {...committed, 'name': '伪造原回执'}),
        query(latest: {...current, 'id': _deviceA}),
        query(latest: {...current, 'createdAt': 101}),
        query(latest: {...current, 'updatedAt': 299}),
        query(latest: {...committed, 'version': (committed['version'] as int) - 1}),
        query(latest: {...committed, 'name': '相同版本的其他名称'}),
        query(latest: {...committed, 'deviceCount': 2}),
        query(latest: {...committed, 'updatedAt': 301}),
        if (entry.key == 'ARCHIVE')
          query(latest: {...committed, 'version': 9, 'deviceCount': 2, 'updatedAt': 400}),
      ]) {
        expect(() => entry.value.queryResult(invalid), _invalidResponse);
      }
      final expectedOriginal = _clone(result.committed);
      final expectedCurrent = _clone(result.current);
      committed.clear();
      current.clear();
      expect(result.committed, expectedOriginal);
      expect(result.current, expectedCurrent);
    }
  });
}
