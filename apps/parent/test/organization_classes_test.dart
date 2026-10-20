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
import 'package:parent/core/organization_classes.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/class_center.dart';

import 'support/parent_operation_journal_fixture.dart';

const a = '00000000-0000-4000-8000-000000000001',
    b = '00000000-0000-4000-8000-000000000002',
    studentId = '00000000-0000-4000-8000-000000000003';
Json classroom(
        {String id = a,
        int version = 3,
        int count = 1,
        String name = '一班',
        String state = 'ACTIVE'}) =>
    {
      'id': id,
      'version': version,
      'studentCount': count,
      'name': name,
      'state': state,
      'createdAt': 1,
      'updatedAt': 2
    };
Json target() => classroom(id: b, version: 2, name: '二班');
Json student() => {
      'id': studentId,
      'nickname': '小明',
      'ageBand': 'AGE_7_12',
      'archived': false,
      'addedAt': 1
    };
Json descriptor(String op) => {
      'operation': op,
      if (op == 'CREATE' || op == 'RENAME') 'name': '新班级',
      if (op != 'CREATE') ...{'classId': a, 'version': 3},
      if (const {'ADD', 'REMOVE', 'TRANSFER'}.contains(op))
        'subjectId': studentId,
      if (op == 'TRANSFER') ...{'targetClassId': b, 'targetVersion': 2}
    };
List<Json> result(String op) => switch (op) {
      'CREATE' => [classroom(version: 0, count: 0, name: '新班级')],
      'RENAME' => [classroom(version: 4, name: '新班级')],
      'ADD' => [classroom(version: 4, count: 2)],
      'REMOVE' => [classroom(version: 4, count: 0)],
      'ARCHIVE' => [classroom(version: 4, state: 'ARCHIVED')],
      _ => [
          classroom(version: 4, count: 0),
          classroom(id: b, version: 3, count: 2, name: '二班')
        ],
    };
http.Response response(Object data, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), status);
ParentApi apiFor(Future<http.Response> Function(http.Request) handler) =>
    ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1', client: MockClient(handler));

class Storage extends ParentDurableStorage with ParentAtomicJournalFixture {
  final values = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    if (fail) throw StateError('disk');
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

class Session extends ParentSession {
  final ParentApi fixture;
  Session(this.fixture) {
    tenant = {'id': 'tenant', 'kind': 'ORGANIZATION'};
    profile = {'subject': 'adult'};
    role = 'ORG_ADMIN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  void change() {
    generation++;
    notifyListeners();
  }
}

void main() {
  test('contracts enforce scope, versions, exact fields and roster types', () {
    expect(readSchoolClass(classroom())['id'], a);
    validateClassStudent(student());
    expect(() => readSchoolClass({...classroom(), 'studentCount': 501}),
        throwsA(isA<ParentApiException>()));
    expect(() => validateClassStudent({...student(), 'archived': 'false'}),
        throwsA(isA<ParentApiException>()));
    expect(
        () => validateClassOperation(
            {...descriptor('TRANSFER'), 'targetClassId': a},
            classroom(),
            target()),
        throwsA(isA<ParentApiException>()));
    expect(
        () => validateClassOperation(
            {...descriptor('CREATE'), 'version': 0}, null, null),
        throwsFormatException);
  });
  for (final op in classOperations) {
    test(
        '$op lost reply retries exact body method key and both versions after recreation',
        () async {
      final calls = <http.Request>[], rows = result(op);
      final api = apiFor((r) async {
        calls.add(r);
        if (calls.length == 1) throw http.ClientException('lost');
        if (r.url.path.endsWith('/query')) {
          return response({
            'requestId': r.url.pathSegments[r.url.pathSegments.length - 2],
            'operation': op,
            'committed': rows,
            'current': rows
          });
        }
        return response(op == 'TRANSFER'
            ? {'source': rows.first, 'target': rows.last}
            : rows.first);
      });
      final storage = Storage(), store = ClassOperationStore(storage: storage);
      ClassOperationController make() => ClassOperationController(
          api: api,
          tenant: 't',
          actor: 'a',
          store: store,
          isCurrent: () => true);
      var c = make();
      await c.load();
      await c.submit(descriptor(op),
          before: op == 'CREATE' ? null : classroom(),
          target: op == 'TRANSFER' ? target() : null);
      expect(c.committed, isNull);
      expect(c.pending, isNotNull);
      c.dispose();
      c = make();
      await c.load();
      expect(calls, hasLength(1));
      await c.recover(retry: true);
      expect(c.error, isNull);
      expect(c.committed, rows);
      expect(calls, hasLength(3));
      expect(calls[0].method, calls[1].method);
      expect(calls[0].body, calls[1].body);
      expect(calls[0].headers['Idempotency-Key'],
          calls[1].headers['Idempotency-Key']);
      expect(calls[1].headers['If-Match'], op == 'CREATE' ? null : '"3"');
      expect(jsonDecode(calls.last.body), descriptor(op));
      if (op == 'TRANSFER') {
        expect(jsonDecode(calls[1].body)['targetVersion'], 2);
      }
      expect(await c.acknowledge(), isTrue);
      expect(storage.values, isEmpty);
      c.dispose();
    });
  }
  test('read recovery keeps original separate from newer class', () async {
    final api = apiFor((r) async {
      if (!r.url.path.endsWith('/query')) throw http.ClientException('lost');
      return response({
        'requestId': r.url.pathSegments[r.url.pathSegments.length - 2],
        'operation': 'RENAME',
        'committed': result('RENAME'),
        'current': [classroom(version: 8, count: 8, name: '后续名称')]
      });
    });
    final c = ClassOperationController(
        api: api,
        tenant: 't',
        actor: 'a',
        store: ClassOperationStore(storage: Storage()),
        isCurrent: () => true);
    await c.load();
    await c.submit(descriptor('RENAME'), before: classroom());
    await c.recover();
    expect(c.committed!.single['version'], 4);
    expect(c.latest!.single['version'], 8);
    c.dispose();
  });
  test(
      'failed durable write prevents network and tenant/actor markers stay isolated',
      () async {
    var calls = 0;
    final storage = Storage()..fail = true;
    final c = ClassOperationController(
        api: apiFor((_) async {
          calls++;
          return response({});
        }),
        tenant: 't',
        actor: 'a',
        store: ClassOperationStore(storage: storage),
        isCurrent: () => true);
    await c.load();
    await c.submit(descriptor('CREATE'));
    expect(calls, 0);
    expect(c.loaded, isFalse);
    c.dispose();
    storage.fail = false;
    final store = ClassOperationStore(storage: storage);
    await store.save('t', 'a', {
      'requestId': a,
      'input': descriptor('CREATE'),
      'before': null,
      'target': null
    });
    expect(await store.load('t', 'b'), isNull);
    expect(await store.load('other', 'a'), isNull);
  });
  test('scope changed while token refresh prevents write', () async {
    var current = true, calls = 0;
    final token = Completer<String>();
    final api =
        ParentApi(() => token.future, baseUrl: 'https://fixture.invalid/api/v1',
            client: MockClient((_) async {
      calls++;
      return response({});
    }));
    final c = ClassOperationController(
        api: api,
        tenant: 't',
        actor: 'a',
        store: ClassOperationStore(storage: Storage()),
        isCurrent: () => current);
    await c.load();
    final writing = c.submit(descriptor('CREATE'));
    await Future<void>.delayed(Duration.zero);
    current = false;
    token.complete('token');
    await writing;
    expect(calls, 0);
    expect(c.pending, isNotNull);
    c.dispose();
  });
  testWidgets(
      'unauthorized mobile class route shows no private data or network',
      (tester) async {
    var calls = 0;
    final session = Session(apiFor((_) async {
      calls++;
      return response({});
    }))
      ..role = 'GUARDIAN';
    await tester.pumpWidget(MaterialApp(
        home: ClassCenter(
            session: session, store: ClassOperationStore(storage: Storage()))));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('新建班级'), findsNothing);
  });
  testWidgets(
      'create remains simple and generation changes close confirmation without write',
      (tester) async {
    var writes = 0;
    final session = Session(apiFor((r) async {
      if (r.method != 'GET') writes++;
      return response({'items': [], 'nextCursor': null});
    }));
    await tester.pumpWidget(MaterialApp(
        home: ClassCenter(
            session: session, store: ClassOperationStore(storage: Storage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建班级'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '一年级一班');
    await tester.tap(find.text('核对并新建班级'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    session.change();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(writes, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'transfer selects target and posts both versions then refreshes roster',
      (tester) async {
    var source = classroom(), destination = target(), transferred = false;
    final calls = <http.Request>[];
    final api = apiFor((r) async {
      calls.add(r);
      if (r.url.path.endsWith('/transfer')) {
        transferred = true;
        source = result('TRANSFER').first;
        destination = result('TRANSFER').last;
        return response({'source': source, 'target': destination});
      }
      if (r.url.path.endsWith('/query')) {
        return response({
          'requestId': r.url.pathSegments[r.url.pathSegments.length - 2],
          'operation': 'TRANSFER',
          'committed': [source, destination],
          'current': [source, destination]
        });
      }
      if (r.url.path.endsWith('/students')) {
        return response({
          'items': transferred ? [] : [student()],
          'nextCursor': null
        });
      }
      if (r.url.path.endsWith(a)) return response(source);
      return response({
        'items': [source, destination],
        'nextCursor': null
      });
    });
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const fontFile = String.fromEnvironment('UI_CAPTURE_FONT');
    const iconFile = String.fromEnvironment('UI_CAPTURE_ICONS');
    for (final entry
        in {'LocalCaptureFont': fontFile, 'MaterialIcons': iconFile}.entries) {
      if (entry.value.isNotEmpty) {
        await tester.runAsync(() async {
          final loader = FontLoader(entry.key)
            ..addFont(Future.value(
                ByteData.sublistView(await File(entry.value).readAsBytes())));
          await loader.load();
        });
      }
    }
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
                useMaterial3: true,
                colorSchemeSeed: const Color(0xFF315E86),
                fontFamily: fontFile.isEmpty ? null : 'LocalCaptureFont'),
            home: ClassCenter(
                session: Session(api),
                store: ClassOperationStore(storage: Storage())))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一班'));
    await tester.pumpAndSettle();
    if (const bool.fromEnvironment('CAPTURE_CLASS_UI')) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/parent-class-portrait.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.ensureVisible(find.byTooltip('管理 小明 的班级关联'));
    await tester.tap(find.byTooltip('管理 小明 的班级关联'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('转到其他班级'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择目标班级'));
    await tester.pumpAndSettle();
    expect(find.text('一班'), findsNothing);
    await tester.tap(find.text('二班'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对并转班'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();
    final write = calls.singleWhere((r) => r.url.path.endsWith('/transfer'));
    expect(write.headers['If-Match'], '"3"');
    expect(jsonDecode(write.body), {'targetClassId': b, 'targetVersion': 2});
    await tester.ensureVisible(find.text('完成核对'));
    await tester.tap(find.text('完成核对'));
    await tester.pumpAndSettle();
    expect(find.text('小明'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
