@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/device_groups_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/device_group_batch_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _tenant = '11111111-1111-4111-8111-111111111111';
const _groupId = '22222222-2222-4222-8222-222222222222';
const _root = '/api/v1/tenants/$_tenant';
const _groups = '$_root/device-groups';
const _groupPath = '$_groups/$_groupId';
const _devices = <Json>[
  {
    'id': '33333333-3333-4333-8333-333333333333',
    'registrationId': '66666666-6666-4666-8666-666666666666',
    'displayName': '阅读平板', 'platform': 'ANDROID', 'state': 'ACTIVE',
  },
  {
    'id': '44444444-4444-4444-8444-444444444444',
    'registrationId': '77777777-7777-4777-8777-777777777777',
    'displayName': '课堂平板', 'platform': 'ANDROID', 'state': 'ACTIVE',
  },
  {
    'id': '55555555-5555-4555-8555-555555555555',
    'registrationId': '88888888-8888-4888-8888-888888888888',
    'displayName': '实验平板', 'platform': 'ANDROID', 'state': 'ACTIVE',
  },
];

class _GroupSession extends Session {
  final Api testApi;
  int stepUps = 0;
  _GroupSession(this.testApi) {
    profile = {'subject': 'device-group-flow-owner'};
    tenant = {'id': _tenant, 'kind': 'ORGANIZATION'};
    role = 'OWNER';
  }

  @override
  Api get api => testApi;
  @override
  bool get authenticated => true;
  @override
  void login({bool stepUp = false}) {
    if (stepUp) stepUps++;
  }
}

http.Response _reply(Object value, [int status = 200]) => http.Response(
    jsonEncode(value), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

// Public-page transport fixtures assert client orchestration, not server or
// device acceptance. Mutations remain pending until their request is inspected.
class _Fixture {
  final String? recoveryOperation;
  final requests = <http.Request>[];
  final members = <Json>[];
  int version = 3;
  String name = '七年级设备组', state = 'ACTIVE';
  Json? committed;
  Completer<http.Response>? pending;
  late final transport = MockClient(handle);
  late final api = Api(() async => transport,
      baseUrl: 'https://fixture.invalid/api/v1');
  late final session = _GroupSession(api);

  _Fixture({this.recoveryOperation}) {
    if (recoveryOperation == 'REMOVE') members.add(_member(_devices.first));
  }

  Json get group => {
    'id': _groupId, 'name': name, 'state': state,
    'version': version, 'deviceCount': members.length,
    'createdAt': 1000, 'updatedAt': 1000 + version,
  };

  Json _member(Json device) => {
    'deviceId': device['id'], 'registrationId': device['registrationId'],
    'displayName': device['displayName'], 'platform': device['platform'],
    'state': device['state'], 'membershipStatus': 'CURRENT', 'addedAt': 1000,
  };

  List<http.Request> reads(String path) => requests.where((request) =>
      request.method == 'GET' && request.url.path == path).toList();
  List<http.Request> get queries => requests.where((request) =>
      request.url.path.startsWith('$_groups/operation-results/')).toList();
  List<http.Request> get writes => requests.where((request) =>
      request.method != 'GET' &&
      !request.url.path.startsWith('$_groups/operation-results/')).toList();

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET') {
      if (path == _groups) {
        return _reply({'items': recoveryOperation == 'CREATE' && committed == null
            ? <Json>[] : [group], 'nextCursor': null});
      }
      if (path == _groupPath) return _reply(group);
      if (path == '$_groupPath/devices') {
        return _reply({'items': members, 'nextCursor': null});
      }
      if (path == '$_groupPath/summary') {
        return _reply({
          'groupId': _groupId, 'version': version,
          'total': members.length, 'current': members.length,
          'staleRegistration': 0, 'deviceInactive': 0, 'profileArchived': 0,
        });
      }
      if (path == '$_root/devices') {
        return _reply({'items': _devices, 'nextCursor': null});
      }
    }
    if (recoveryOperation != null && request.method == 'POST' &&
        path.startsWith('$_groups/operation-results/')) {
      if (queries.length == 1) {
        return _reply({'errorCode': 'DEVICE_GROUP_RESULT_UNAVAILABLE'}, 404);
      }
      if (queries.length == 2) {
        return _reply({'errorCode': 'REAUTH_REQUIRED'}, 401);
      }
      return _reply({'operation': recoveryOperation,
        'committed': committed!, 'current': group});
    }
    if (recoveryOperation != null && request.method != 'GET') {
      if (committed != null) throw StateError('An unknown write must not be replayed');
      final body = request.body.isEmpty ? <String, dynamic>{}
          : jsonDecode(request.body) as Json;
      switch (recoveryOperation) {
        case 'CREATE':
          name = body['name'] as String;
          version = 0;
          break;
        case 'RENAME':
          name = body['name'] as String;
          version++;
          break;
        case 'ARCHIVE':
          state = 'ARCHIVED';
          version++;
          break;
        case 'ADD':
          members.add(_member(_devices.first));
          version++;
          break;
        case 'REMOVE':
          members.clear();
          version++;
          break;
        default:
          throw StateError('Unexpected recovery operation: $recoveryOperation');
      }
      committed = Map<String, dynamic>.of(group);
      if (recoveryOperation != 'ARCHIVE') {
        name = '后来核对的设备组';
        version++;
      }
      return _reply({'errorCode': 'REQUEST_TIMEOUT'}, 408);
    }
    if (request.method == 'POST' && path == '$_groupPath/devices/batches') {
      if (pending != null) throw StateError('A group mutation is already pending');
      pending = Completer<http.Response>();
      return pending!.future;
    }
    throw StateError('Unexpected device-group request: ${request.method} $path');
  }

  void completeWrite() {
    final gate = pending!;
    final body = jsonDecode(writes.last.body) as Json;
    for (final selected in body['devices'] as List<dynamic>) {
      final device = _devices.singleWhere((row) => row['id'] == selected['deviceId']);
      members.add(_member(device));
    }
    version++;
    pending = null;
    gate.complete(_reply(group));
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final gate = pending;
    if (gate != null && !gate.isCompleted) {
      gate.complete(_reply({'errorCode': 'TEST_CLEANUP'}, 503));
    }
    await _flush(tester);
    transport.close();
    session.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

Finder _button(String label) => find.ancestor(of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
Finder _chip(String label) => find.widgetWithText(ChoiceChip, label);
VoidCallback _callback(WidgetTester tester, String label) {
  final button = _button(label);
  expect(button, findsOneWidget);
  final callback = tester.widget<ButtonStyleButton>(button).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

bool _enabled(WidgetTester tester, String label) {
  final button = _button(label);
  return button.evaluate().length == 1 &&
      tester.widget<ButtonStyleButton>(button).onPressed != null;
}

bool _routeReady(WidgetTester tester, Finder finder) {
  if (finder.evaluate().length != 1) return false;
  final route = ModalRoute.of(tester.element(finder));
  return route?.isCurrent == true &&
      route?.animation?.status == AnimationStatus.completed;
}

Future<void> _flush(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 60 && !ready(); frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(ready(), isTrue, reason: 'The bounded device-group journey must finish.');
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _mount(WidgetTester tester, _Fixture fixture,
    {bool openGroup = true}) async {
  tester.view.physicalSize = const Size(1200, 1200);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(theme: consoleTheme(),
      home: Scaffold(body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: DeviceGroupsPage(session: fixture.session)))));
  await _until(tester, () => fixture.recoveryOperation == 'CREATE'
      ? find.text('暂无设备组').evaluate().length == 1
      : find.text('七年级设备组').evaluate().length == 1);
  if (openGroup) await _openGroup(tester, count: fixture.members.length);
}

Future<void> _openGroup(WidgetTester tester, {int count = 0}) async {
  await _tap(tester, find.text('七年级设备组'));
  await _until(tester, () => _enabled(tester, '加入设备') &&
      _chip('全部 $count').evaluate().length == 1);
}

Future<void> _pickerReady(WidgetTester tester) => _until(tester, () =>
    _routeReady(tester, find.byType(DeviceGroupBatchPicker)) &&
    find.byKey(ValueKey(_devices.first['id'] as String)).evaluate().length == 1);

Future<void> _openPicker(WidgetTester tester) async {
  await _tap(tester, _button('加入设备'));
  await _pickerReady(tester);
}

Future<void> _choose(WidgetTester tester, List<Json> devices) async {
  for (final device in devices) {
    await _tap(tester, find.byKey(ValueKey(device['id'] as String)));
  }
  await _tap(tester, _button('核对并加入 ${devices.length} 台'));
  await _until(tester, () => _enabled(tester, '确认加入 ${devices.length} 台') &&
      _routeReady(tester, _button('确认加入 ${devices.length} 台')));
}

Future<void> _cancel(WidgetTester tester, String label) async {
  await _tap(tester, _button(label));
  await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty &&
      _enabled(tester, '加入设备'));
}

Future<String> _openRecoveryOperation(WidgetTester tester, String operation) async {
  switch (operation) {
    case 'CREATE':
    case 'RENAME':
      await _tap(tester, _button(operation == 'CREATE' ? '新建设备组' : '修改名称'));
      final submit = operation == 'CREATE' ? '创建设备组' : '保存名称';
      await _until(tester, () => _enabled(tester, submit) &&
          _routeReady(tester, _button(submit)));
      await tester.enterText(find.descendant(of: find.byType(EditDialog),
          matching: find.byType(TextFormField)), '恢复目标名称');
      return submit;
    case 'ARCHIVE':
      await _tap(tester, _button('归档设备组'));
      break;
    case 'ADD':
      await _openPicker(tester);
      await _choose(tester, [_devices.first]);
      return '确认加入 1 台';
    case 'REMOVE':
      await _tap(tester, find.byWidgetPredicate((widget) => widget is IconButton &&
          widget.tooltip == '移出 阅读平板'));
      break;
    default:
      throw StateError('Unexpected recovery operation: $operation');
  }
  final submit = operation == 'ARCHIVE' ? '确认归档' : '确认移出';
  await _until(tester, () => _enabled(tester, submit) &&
      _routeReady(tester, _button(submit)));
  return submit;
}

void main() {
  testWidgets('one or several devices use one version-bound batch and cancellation writes nothing',
      (tester) async {
    final fixture = _Fixture();
    try {
      await _mount(tester, fixture);
      expect(find.text('批量加入'), findsNothing);
      final initialReads = fixture.reads(_groupPath).length;
      await _openPicker(tester);
      await _tap(tester, find.byKey(ValueKey(_devices.first['id'] as String)));
      await _cancel(tester, '取消');
      await _openPicker(tester);
      await _choose(tester, [_devices.first]);
      await _cancel(tester, '取消');
      expect(fixture.writes, isEmpty);
      expect(fixture.reads(_groupPath), hasLength(initialReads));

      final selections = [[_devices.first], [_devices[1], _devices[2]]];
      for (var index = 0; index < selections.length; index++) {
        final chosen = selections[index];
        await _openPicker(tester);
        await _choose(tester, chosen);
        final confirmation = find.byType(AlertDialog);
        for (final device in chosen) {
          expect(find.descendant(of: confirmation, matching: find.textContaining(
              '设备 ${device['id']}\n  注册 ${device['registrationId']}')), findsOneWidget);
        }
        final submit = _callback(tester, '确认加入 ${chosen.length} 台');
        submit();
        submit();
        await _until(tester, () => fixture.writes.length == index + 1);
        await _flush(tester);
        expect(fixture.writes, hasLength(index + 1));
        final request = fixture.writes.last;
        expect(request.method, 'POST');
        expect(request.url.path, '$_groupPath/devices/batches');
        expect(request.headers['If-Match'], '"${3 + index}"');
        expect(request.headers['Idempotency-Key'], isNotEmpty);
        expect(jsonDecode(request.body), {
          'devices': [for (final device in chosen) {
            'deviceId': device['id'], 'registrationId': device['registrationId'],
          }],
        });
        fixture.completeWrite();
        await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty &&
            _enabled(tester, '加入设备') &&
            find.text('编号 $_groupId · 版本 ${4 + index}').evaluate().length == 1);
      }
      expect(fixture.members, hasLength(3));
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('the add action opens once, unlocks after cancel and retires old detail callbacks',
      (tester) async {
    final fixture = _Fixture();
    try {
      await _mount(tester, fixture);
      final add = _callback(tester, '加入设备');
      final back = _callback(tester, '返回列表');
      final rename = _callback(tester, '修改名称');
      final archive = _callback(tester, '归档设备组');
      final remove = _callback(tester, '批量移出');
      final filter = tester.widget<ChoiceChip>(_chip('关联有效 0')).onSelected!;
      add();
      add();
      await _pickerReady(tester);
      back();
      filter(true);
      rename();
      archive();
      remove();
      await _flush(tester);
      expect(find.byType(DeviceGroupBatchPicker), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(fixture.reads('$_root/devices'), hasLength(1));
      expect(fixture.reads(_groupPath), hasLength(1));
      for (final label in ['加入设备', '返回列表', '修改名称', '归档设备组', '批量移出']) {
        expect(_enabled(tester, label), isFalse);
      }
      expect(tester.widget<ChoiceChip>(_chip('关联有效 0')).onSelected, isNull);

      await _cancel(tester, '取消');
      await _openPicker(tester);
      expect(fixture.reads('$_root/devices'), hasLength(2));
      await _cancel(tester, '取消');
      await _tap(tester, _button('返回列表'));
      await _until(tester, () => find.text('机构设备组').evaluate().length == 1 &&
          find.text('七年级设备组').evaluate().length == 1);
      await _openGroup(tester);
      final reads = fixture.requests.length;
      add();
      back();
      filter(true);
      rename();
      archive();
      remove();
      await _flush(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(_enabled(tester, '加入设备'), isTrue);
      expect(tester.widget<ChoiceChip>(_chip('全部 0')).selected, isTrue);
      expect(fixture.requests, hasLength(reads));
      expect(fixture.writes, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('all five uncertain group changes only query their fixed original operation',
      (tester) async {
    for (final operation in ['CREATE', 'RENAME', 'ARCHIVE', 'ADD', 'REMOVE']) {
      final fixture = _Fixture(recoveryOperation: operation);
      try {
        await _mount(tester, fixture, openGroup: operation != 'CREATE');
        var submit = await _openRecoveryOperation(tester, operation);
        if (operation == 'CREATE') {
          final listReads = fixture.reads(_groups).length;
          await _tap(tester, _button('取消'));
          await _until(tester, () => find.byType(EditDialog).evaluate().isEmpty &&
              _enabled(tester, '新建设备组'));
          expect(fixture.reads(_groups), hasLength(listReads));
          expect(fixture.writes, isEmpty);
          submit = await _openRecoveryOperation(tester, operation);
        }
        await _tap(tester, _button(submit));
        await _until(tester, () => fixture.writes.length == 1 &&
            _enabled(tester, '查询原操作结果'));
        expect(find.byType(EditDialog), findsOneWidget);
        final original = fixture.writes.single;
        final key = original.headers['Idempotency-Key'];
        expect(key, matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
        expect(original.headers['If-Match'], operation == 'CREATE' ? null : '"3"');
        final (method, path) = switch (operation) {
          'CREATE' => ('POST', _groups),
          'RENAME' => ('PATCH', _groupPath),
          'ARCHIVE' => ('POST', '$_groupPath/archive'),
          'ADD' => ('POST', '$_groupPath/devices/batches'),
          _ => ('POST', '$_groupPath/devices/removals'),
        };
        expect(original.method, method);
        expect(original.url.path, path);
        final targets = [<String, dynamic>{
          'deviceId': _devices.first['id'],
          'registrationId': _devices.first['registrationId'],
        }];
        final Json body = switch (operation) {
          'CREATE' || 'RENAME' => {'name': '恢复目标名称'},
          'ADD' || 'REMOVE' => {'devices': targets},
          _ => <String, dynamic>{},
        };
        if (operation == 'ARCHIVE') {
          expect(original.body, isEmpty);
        } else {
          expect(jsonDecode(original.body), body);
        }
        final expectedQuery = <String, dynamic>{
          'operation': operation,
          if (operation != 'CREATE') ...{'groupId': _groupId, 'version': 3},
          ...body,
        };
        expect(fixture.queries, isEmpty,
            reason: '$operation recovery starts only from an explicit query.');

        for (var query = 1; query <= 2; query++) {
          await _tap(tester, _button('查询原操作结果'));
          await _until(tester, () => fixture.queries.length == query &&
              _enabled(tester, '查询原操作结果'));
          expect(fixture.writes, hasLength(1));
          expect(find.byType(EditDialog), findsOneWidget);
          expect(find.text(submit), findsNothing);
          if (operation == 'CREATE' || operation == 'RENAME') {
            final input = tester.widget<TextFormField>(find.descendant(
                of: find.byType(EditDialog), matching: find.byType(TextFormField)));
            expect(input.enabled, isFalse);
            expect(input.controller!.text, '恢复目标名称');
          }
        }
        final beforeMfa = fixture.requests.length;
        await _tap(tester, _button('重新安全验证'));
        await _flush(tester);
        expect(fixture.session.stepUps, 1);
        expect(fixture.requests, hasLength(beforeMfa),
            reason: 'MFA must not automatically write or query the original operation.');
        expect(_enabled(tester, '查询原操作结果'), isTrue);

        await _tap(tester, _button('查询原操作结果'));
        await _until(tester, () => fixture.queries.length == 3 &&
            find.byType(EditDialog).evaluate().isEmpty &&
            find.text('编号 $_groupId · 版本 ${fixture.version}').evaluate().length == 1);
        expect(fixture.writes, hasLength(1));
        for (final query in fixture.queries) {
          expect(query.method, 'POST');
          expect(query.url.path, '$_groups/operation-results/$key/query');
          expect(query.headers['If-Match'], isNull);
          expect(query.headers['Idempotency-Key'], isNull);
          expect(jsonDecode(query.body), expectedQuery);
        }
        expect(find.text(fixture.name), findsOneWidget);
        expect(fixture.reads(_groupPath).last.method, 'GET');
        if (operation == 'ARCHIVE') {
          expect(find.text('加入设备'), findsNothing);
          expect(fixture.group['state'], 'ARCHIVED');
        } else {
          expect(fixture.version, greaterThan(fixture.committed!['version'] as int));
          expect(find.text('原操作已核对，设备组已有后续修改，请核对当前记录。'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.cleanup(tester);
      }
    }
  });
}
