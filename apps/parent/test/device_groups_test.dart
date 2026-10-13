import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/device_groups.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/device_group_center.dart';
import 'package:parent/ui/group_operation_page.dart';

const groupId = '00000000-0000-4000-8000-000000000001';
const deviceId = '00000000-0000-4000-8000-000000000002';
const registrationId = '00000000-0000-4000-8000-000000000003';
const nextDevice = '00000000-0000-4000-8000-000000000004';
Json group({int version = 0, String name = '学习设备', String state = 'ACTIVE'}) =>
    {
      'id': groupId,
      'name': name,
      'version': version,
      'state': state,
      'deviceCount': 0,
    };
Json input(String op) => {
      'operation': op,
      if (op != 'CREATE') 'groupId': groupId,
      if (op != 'CREATE') 'version': 0,
      if (const {'CREATE', 'RENAME'}.contains(op)) 'name': '学习设备',
      if (const {'ADD', 'REMOVE'}.contains(op))
        'devices': [
          {'deviceId': deviceId, 'registrationId': registrationId}
        ],
    };
http.Response response(Json data, [int code = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), code);

class _Storage extends ParentDurableStorage {
  final values = <String, String>{};
  bool failWrite = false;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
    if (failWrite) throw StateError('flush failed');
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

class _Session extends ParentSession {
  final ParentApi fixture;
  int authentications = 0;
  _Session(this.fixture) {
    tenant = {'id': 'tenant', 'kind': 'ORGANIZATION'};
    profile = {'subject': 'admin'};
    role = 'ORG_ADMIN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  @override
  Future<bool> reauthenticate() async {
    authentications++;
    return true;
  }

  void revoke() {
    role = 'AUDITOR';
    notifyListeners();
  }
}

GroupOperationController _controller(ParentApi api, _Storage storage,
        {Future<bool> Function()? auth, bool Function()? current}) =>
    GroupOperationController(
        api: api,
        store: GroupOperationStore(storage: storage),
        tenant: 'tenant',
        actor: 'admin',
        isCurrent: current ?? () => true,
        reauthenticate: auth ?? () async => true);

void main() {
  testWidgets('portrait group detail supports large text without layout errors',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const fontFile = String.fromEnvironment('UI_CAPTURE_FONT');
    const iconFile = String.fromEnvironment('UI_CAPTURE_ICONS');
    if (fontFile.isNotEmpty) {
      await tester.runAsync(() async {
        final bytes = await File(fontFile).readAsBytes();
        final loader = FontLoader('LocalCaptureFont')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      });
    }
    if (iconFile.isNotEmpty) {
      await tester.runAsync(() async {
        final bytes = await File(iconFile).readAsBytes();
        final loader = FontLoader('MaterialIcons')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      });
    }
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/devices')) {
        return response({
          'items': [
            {
              'deviceId': deviceId,
              'registrationId': registrationId,
              'displayName': '三年级一班平板 01',
              'platform': 'ANDROID',
              'membershipStatus': 'STALE_REGISTRATION',
              'state': 'ACTIVE',
            }
          ],
          'nextCursor': null
        });
      }
      return response({...group(name: '三年级一班学习设备'), 'deviceCount': 1});
    }));
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
                fontFamily: fontFile.isEmpty ? null : 'LocalCaptureFont',
                colorSchemeSeed: const Color(0xFF315E86),
                useMaterial3: true),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!),
            home: DeviceGroupDetail(session: _Session(api), id: groupId))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_GROUP_UI')) {
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/parent-group-portrait.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
  test('requires exact bounded registration targets and rejects duplicate IDs',
      () {
    for (final op in groupOperations.keys) {
      validateGroupOperation(input(op));
    }
    final value = input('ADD');
    value['devices'].add(value['devices'][0]);
    expect(() => validateGroupOperation(value), throwsFormatException);
    value['devices'] = List.generate(
        51, (i) => {'deviceId': deviceId, 'registrationId': registrationId});
    expect(() => validateGroupOperation(value), throwsFormatException);
    expect(
        () => validateGroupOperation(
            {'operation': 'CREATE', 'name': '组', 'version': 0}),
        throwsFormatException);
  });
  for (final op in groupOperations.keys) {
    test(
        '$op writes original key/version only after authentication and durable save',
        () async {
      final storage = _Storage();
      var authentications = 0;
      final requests = <http.Request>[];
      final api = ParentApi(() async => 'fixture',
          baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
        requests.add(r);
        expect(authentications, 1);
        expect(storage.values, hasLength(1));
        final marker = jsonDecode(storage.values.values.single);
        expect(r.headers['Idempotency-Key'], marker['requestId']);
        expect(r.headers['If-Match'], op == 'CREATE' ? null : '"0"');
        expect(r.method, op == 'RENAME' ? 'PATCH' : 'POST');
        if (op == 'ADD' || op == 'REMOVE') {
          expect(jsonDecode(r.body)['devices'], input(op)['devices']);
          expect(r.url.path.endsWith(op == 'ADD' ? '/batches' : '/removals'),
              isTrue);
        }
        return response(group(state: op == 'ARCHIVE' ? 'ARCHIVED' : 'ACTIVE'));
      }));
      final c = _controller(api, storage, auth: () async {
        authentications++;
        return true;
      });
      await c.load();
      await c.execute(input(op));
      await c.execute(input(op));
      expect(requests, hasLength(1));
      expect(c.result, isNotNull);
      expect(await c.acknowledge(), isTrue);
      expect(storage.values, isEmpty);
    });
  }
  test('cancelled MFA and failed durable storage cannot issue a mutation',
      () async {
    var writes = 0;
    final storage = _Storage();
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      writes++;
      return response(group());
    }));
    final cancel = _controller(api, storage, auth: () async => false);
    await cancel.load();
    await cancel.execute(input('CREATE'));
    expect(writes, 0);
    expect(storage.values, isEmpty);
    storage.failWrite = true;
    final fail = _controller(api, storage);
    await fail.load();
    await fail.execute(input('CREATE'));
    expect(writes, 0);
    expect(fail.loaded, isFalse);
    expect(storage.values, hasLength(1));
  });
  test(
      'restores original request after lost response and distinguishes later group state',
      () async {
    final storage = _Storage();
    final requests = <http.Request>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      requests.add(r);
      if (!r.url.path.endsWith('/query')) throw http.ClientException('lost');
      expect(jsonDecode(r.body), input('CREATE'));
      return response({
        'operation': 'CREATE',
        'committed': group(),
        'current': group(version: 3, name: '后来改名', state: 'ARCHIVED')
      });
    }));
    final first = _controller(api, storage);
    await first.load();
    await first.execute(input('CREATE'));
    final key = first.pending!['requestId'];
    first.dispose();
    final restored = _controller(api, storage);
    await restored.load();
    await restored.query();
    expect(requests, hasLength(2));
    expect(requests.last.url.path.endsWith('/$key/query'), isTrue);
    expect(restored.result!['committed']['version'], 0);
    expect(restored.result!['current']['version'], 3);
    expect(await restored.acknowledge(), isTrue);
  });
  test('404 does not clear pending or replay until adult acknowledges',
      () async {
    final storage = _Storage();
    var calls = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      calls++;
      return response({
        'errorCode': r.url.path.endsWith('/query')
            ? 'DEVICE_GROUP_RESULT_UNAVAILABLE'
            : 'UNAVAILABLE'
      }, r.url.path.endsWith('/query') ? 404 : 503);
    }));
    final c = _controller(api, storage);
    await c.load();
    await c.execute(input('CREATE'));
    expect(await c.acknowledge(), isFalse);
    await c.query();
    expect(c.pending, isNotNull);
    expect(c.queried, isTrue);
    await c.execute(input('CREATE'));
    expect(calls, 2);
    expect(await c.acknowledge(), isTrue);
  });
  test('scope change while obtaining a token stops request dispatch', () async {
    final token = Completer<String>();
    var current = true, calls = 0;
    final storage = _Storage();
    final api = ParentApi(() => token.future,
        baseUrl: 'https://fixture.invalid', client: MockClient((_) async {
      calls++;
      return response(group());
    }));
    final c = _controller(api, storage, current: () => current);
    await c.load();
    final pending = c.execute(input('CREATE'));
    await Future<void>.delayed(Duration.zero);
    current = false;
    token.complete('new-identity-token');
    await pending;
    expect(calls, 0);
    expect(storage.values, hasLength(1));
  });
  test('wrong group in recovered current result cannot unlock pending command',
      () async {
    final storage = _Storage();
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (!r.url.path.endsWith('/query')) throw http.ClientException('lost');
      return response({
        'operation': 'ADD',
        'committed': group(),
        'current': {...group(), 'id': deviceId}
      });
    }));
    final c = _controller(api, storage);
    await c.load();
    await c.execute(input('ADD'));
    await c.query();
    expect(c.result, isNull);
    expect(c.queried, isFalse);
    expect(await c.acknowledge(), isFalse);
  });
  testWidgets(
      'operation page confirms MFA and opens current group only after acknowledgement',
      (tester) async {
    final storage = _Storage();
    Json? opened;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => response(group())));
    final session = _Session(api);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      opened = await Navigator.of(ctx).push<Json>(
                          MaterialPageRoute(
                              builder: (_) => GroupOperationPage(
                                  session: session,
                                  input: const {'operation': 'CREATE'},
                                  store:
                                      GroupOperationStore(storage: storage))));
                    },
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '学习设备');
    await tester.tap(find.text('确认并进行安全验证'));
    await tester.pumpAndSettle();
    expect(session.authentications, 1);
    expect(opened, isNull);
    expect(storage.values, hasLength(1));
    await tester.ensureVisible(find.text('完成核对，打开当前详情'));
    await tester.tap(find.text('完成核对，打开当前详情'));
    await tester.pumpAndSettle();
    expect(opened!['id'], groupId);
    expect(storage.values, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'paged member removal preserves historical registrations across pages',
      (tester) async {
    List<Json>? selected;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      final more = r.url.queryParameters['cursor'] != null;
      return response({
        'items': [
          {
            'deviceId': more ? nextDevice : deviceId,
            'registrationId': registrationId,
            'displayName': more ? '第二台' : '旧注册设备',
            'state': 'ACTIVE',
            'membershipStatus': 'STALE_REGISTRATION'
          }
        ],
        'nextCursor': more ? null : deviceId
      });
    }));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      selected = await Navigator.of(ctx).push<List<Json>>(
                          MaterialPageRoute(
                              builder: (_) => GroupMemberPicker(
                                  session: _Session(api),
                                  groupId: groupId,
                                  removing: true)));
                    },
                    child: const Text('选择'))))));
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旧注册设备'));
    await tester.tap(find.text('加载更多设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二台'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对所选 2 台'));
    await tester.pumpAndSettle();
    expect(selected!.map((d) => d['deviceId']), [deviceId, nextDevice]);
    expect(
        selected!.every((d) => d['registrationId'] == registrationId), isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets('revoked institution role closes nested group details',
      (tester) async {
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/devices')) {
        return response({'items': [], 'nextCursor': null});
      }
      if (r.url.path.endsWith('/device-groups')) {
        return response({
          'items': [group()],
          'nextCursor': null
        });
      }
      return response(group());
    }));
    final session = _Session(api);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) => DeviceGroupCenter(session: session))),
                    child: const Text('目录'))))));
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习设备'));
    await tester.pumpAndSettle();
    session.revoke();
    await tester.pumpAndSettle();
    expect(find.text('目录'), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '));
    expect(find.text('设备组详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
