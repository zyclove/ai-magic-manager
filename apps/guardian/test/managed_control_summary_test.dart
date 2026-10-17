import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/managed_control_summary.dart';

Map<String, Object?> _operation(String kind, String effect,
        [String? permission]) =>
    {'kind': kind, 'effect': effect, 'permission': permission};

// Explicit product permission catalog, independently checked against the Java
// AndroidRuntimePermissions names() catalog in the delivery source inventory.
const _permissions = [
  'CAMERA',
  'RECORD_AUDIO',
  'READ_CONTACTS',
  'WRITE_CONTACTS',
  'GET_ACCOUNTS',
  'READ_CALENDAR',
  'WRITE_CALENDAR',
  'ACCESS_COARSE_LOCATION',
  'ACCESS_FINE_LOCATION',
  'ACCESS_BACKGROUND_LOCATION',
  'POST_NOTIFICATIONS',
  'READ_MEDIA_IMAGES',
  'READ_MEDIA_VIDEO',
  'READ_MEDIA_AUDIO',
  'READ_MEDIA_VISUAL_USER_SELECTED',
  'READ_EXTERNAL_STORAGE',
  'WRITE_EXTERNAL_STORAGE',
  'BLUETOOTH_SCAN',
  'BLUETOOTH_CONNECT',
  'BLUETOOTH_ADVERTISE',
  'NEARBY_WIFI_DEVICES',
  'BODY_SENSORS',
  'BODY_SENSORS_BACKGROUND',
  'READ_PHONE_STATE',
  'READ_PHONE_NUMBERS',
  'CALL_PHONE',
  'ANSWER_PHONE_CALLS',
  'ADD_VOICEMAIL',
  'USE_SIP',
  'PROCESS_OUTGOING_CALLS',
  'ACTIVITY_RECOGNITION',
  'READ_SMS',
  'SEND_SMS',
  'RECEIVE_SMS',
  'RECEIVE_MMS',
  'RECEIVE_WAP_PUSH',
  'READ_CALL_LOG',
  'WRITE_CALL_LOG',
  'UWB_RANGING',
];

void main() {
  for (final kind in ['APP_INSTALL', 'APP_LAUNCH']) {
    for (final effect in ['ALLOW', 'DENY']) {
      test('$kind $effect is an exact non-permission operation', () {
        final value = ManagedControlSummary.parse([_operation(kind, effect)]);
        expect(value, isNotNull);
        expect(value!.operations.single.kind, kind);
        expect(value.operations.single.effect, effect);
        expect(value.operations.single.permission, isNull);
        expect(value.operations.single.label,
            contains(effect == 'ALLOW' ? '允许' : '禁止'));
      });
    }
  }
  for (final permission in _permissions) {
    for (final effect in ['DENY', 'DEFAULT']) {
      test('$permission $effect has a readable precise label', () {
        final value = ManagedControlSummary.parse([
          _operation(
              'RUNTIME_PERMISSION', effect, 'android.permission.$permission')
        ]);
        expect(value, isNotNull);
        final operation = value!.operations.single;
        expect(operation.permission, 'android.permission.$permission');
        expect(operation.label, contains(permission));
        expect(operation.label, contains(effect == 'DENY' ? '禁止' : '恢复用户询问'));
        expect(operation.label, isNot(startsWith('运行时权限')));
      });
    }
  }
  test('operation order is deterministic and returned lists are immutable', () {
    final input = [
      _operation('RUNTIME_PERMISSION', 'DEFAULT', 'android.permission.CAMERA'),
      _operation('APP_LAUNCH', 'DENY'),
      _operation('APP_INSTALL', 'ALLOW'),
    ];
    final summary = ManagedControlSummary.parse(input)!;
    expect(summary.operations.map((e) => e.label),
        ['应用安装 · 允许', '应用启动 · 禁止', '相机 · CAMERA · 恢复用户询问']);
    input.clear();
    expect(summary.operations, hasLength(3));
    expect(() => summary.operations.clear(), throwsUnsupportedError);
  });

  final invalid = <String, Object?>{
    'absent': null,
    'empty': [],
    'string': 'PRIVATE',
    'map': _operation('APP_LAUNCH', 'DENY'),
    'null item': [null],
    'mixed item': [_operation('APP_LAUNCH', 'DENY'), null],
    'list item': [[]],
    'empty item': [{}],
    'missing permission field': [
      {'kind': 'APP_LAUNCH', 'effect': 'DENY'}
    ],
    'missing kind': [
      {'effect': 'DENY', 'permission': null}
    ],
    'missing effect': [
      {'kind': 'APP_LAUNCH', 'permission': null}
    ],
    'extra field': [
      {..._operation('APP_LAUNCH', 'DENY'), 'provider': 'PRIVATE'}
    ],
    'unknown kind': [_operation('FUTURE_KIND', 'DENY')],
    'unknown effect': [_operation('APP_LAUNCH', 'FUTURE_EFFECT')],
    'null kind': [
      {'kind': null, 'effect': 'DENY', 'permission': null}
    ],
    'numeric effect': [
      {'kind': 'APP_LAUNCH', 'effect': 1, 'permission': null}
    ],
    'automatic grant': [
      _operation('RUNTIME_PERMISSION', 'GRANT', 'android.permission.CAMERA')
    ],
    'runtime allow': [
      _operation('RUNTIME_PERMISSION', 'ALLOW', 'android.permission.CAMERA')
    ],
    'runtime absent permission': [_operation('RUNTIME_PERMISSION', 'DENY')],
    'wildcard': [
      _operation('RUNTIME_PERMISSION', 'DENY', 'android.permission.*')
    ],
    'future permission': [
      _operation('RUNTIME_PERMISSION', 'DENY', 'android.permission.FUTURE')
    ],
    'unqualified permission': [
      _operation('RUNTIME_PERMISSION', 'DENY', 'CAMERA')
    ],
    'permission whitespace': [
      _operation('RUNTIME_PERMISSION', 'DENY', 'android.permission.CAMERA ')
    ],
    'permission case': [
      _operation('RUNTIME_PERMISSION', 'DENY', 'android.permission.camera')
    ],
    'permission on launch': [
      _operation('APP_LAUNCH', 'DENY', 'android.permission.CAMERA')
    ],
    'permission on install': [
      _operation('APP_INSTALL', 'ALLOW', 'android.permission.CAMERA')
    ],
    'default launch': [_operation('APP_LAUNCH', 'DEFAULT')],
    'default install': [_operation('APP_INSTALL', 'DEFAULT')],
    'duplicate': [
      _operation('APP_LAUNCH', 'DENY'),
      _operation('APP_LAUNCH', 'DENY')
    ],
    'too many': List.generate(129, (_) => _operation('APP_INSTALL', 'ALLOW')),
  };
  for (final entry in invalid.entries) {
    test('${entry.key} rejects the whole operation summary', () {
      expect(ManagedControlSummary.parse(entry.value), isNull);
    });
  }
}
