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
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/subjects.dart';
import 'package:parent/ui/subject_center.dart';

import 'support/parent_operation_journal_fixture.dart';

const id = '11111111-1111-4111-8111-111111111111';
Json subject({int version = 0, bool archived = false, String name = '小星'}) => {
      'id': id,
      'nickname': name,
      'ageBand': 'AGE_7_12',
      'version': version,
      'state': archived ? 'ARCHIVED' : 'ACTIVE'
    };
Json input(String op) => {
      'operation': op,
      if (op != 'CREATE') 'subjectId': id,
      if (op != 'CREATE') 'version': 0,
      if (op != 'ARCHIVE') 'nickname': '小星',
      if (op != 'ARCHIVE') 'ageBand': 'AGE_7_12'
    };
http.Response response(Json value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status,
        headers: {'content-type': 'application/json'});
ParentApi api(Future<http.Response> Function(http.Request) handler,
        {Future<String> Function()? token}) =>
    ParentApi(token ?? () async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1', client: MockClient(handler));

class Storage extends ParentDurableStorage with ParentAtomicJournalFixture {
  @override
  bool get fixtureWriteMayCommitBeforeFailure => true;
  final values = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
    if (fail) throw StateError('flush failed');
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

SubjectChangeController controller(ParentApi api, Storage storage,
        {bool Function()? current,
        bool Function()? foreground,
        Future<bool> Function()? reauth}) =>
    SubjectChangeController(
        api: api,
        store: SubjectChangeStore(storage: storage),
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: current ?? () => true,
        foreground: foreground ?? () => true,
        reauthenticate: reauth ?? () async => true);

class Session extends ParentSession {
  final ParentApi fixture;
  Session(this.fixture) {
    tenant = {'id': 'tenant', 'kind': 'FAMILY'};
    profile = {'subject': 'adult'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  @override
  Future<bool> reauthenticate() async => true;
  void revoke() {
    role = 'AUDITOR';
    notifyListeners();
  }
}

void main() {
  test(
      'same-version conflicting current snapshot is not accepted as recovered success',
      () async {
    final storage = Storage();
    final c = controller(
        api((r) async => response(r.url.path.endsWith('/changes')
            ? subject()
            : {
                'operation': 'CREATE',
                'committed': subject(),
                'current': subject(name: '不一致的当前状态')
              })),
        storage);
    await c.load();
    await c.execute(input('CREATE'));
    expect(c.result, isNull);
    expect(c.queried, isFalse);
    expect(c.pending, isNotNull);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
  });
  test('validates minimal age-band profiles and immutable response identity',
      () {
    for (final op in subjectOperations.keys) {
      validateSubjectChange(input(op));
    }
    for (final value in [
      {...input('CREATE'), 'nickname': ''},
      {...input('CREATE'), 'ageBand': 'UNKNOWN'},
      {...input('UPDATE'), 'version': -1},
      {...input('ARCHIVE'), 'nickname': 'extra'},
      {...input('CREATE'), 'subjectId': id}
    ]) {
      expect(() => validateSubjectChange(value), throwsFormatException);
    }
    expect(
        () =>
            readSubject(subject(), id: '22222222-2222-4222-8222-222222222222'),
        throwsA(isA<ParentApiException>()));
  });
  for (final op in subjectOperations.keys) {
    test('$op persists before one write and reads separate current result',
        () async {
      final storage = Storage();
      var writes = 0, reads = 0, auth = 0;
      final committed =
          subject(version: op == 'CREATE' ? 0 : 1, archived: op == 'ARCHIVE');
      final c = controller(
          api((r) async {
            if (r.method == 'GET') return response(subject());
            if (r.url.path.endsWith('/changes')) {
              expect(storage.values.length, 1);
              expect(r.headers['idempotency-key'], isNotEmpty);
              writes++;
              return response(committed);
            }
            reads++;
            return response({
              'operation': op,
              'committed': committed,
              'current': subject(version: 2, archived: true, name: '后来变更')
            });
          }),
          storage,
          reauth: () async {
            auth++;
            return true;
          });
      await c.load();
      await c.execute(input(op));
      expect(writes, 1);
      expect(reads, 1);
      expect(auth, 1);
      expect(c.queried, isTrue);
      expect(c.result!['committed']['nickname'], '小星');
      expect(c.result!['current']['nickname'], '后来变更');
      await c.execute(input(op));
      expect(writes, 1);
      expect(await c.acknowledge(), isTrue);
      expect(storage.values, isEmpty);
      c.dispose();
    });
  }
  test(
      'lost create response recovers original operation after controller restart',
      () async {
    final storage = Storage();
    var writes = 0;
    final backend = api((r) async {
      if (r.url.path.endsWith('/changes')) {
        writes++;
        throw http.ClientException('lost reply');
      }
      return response({
        'operation': 'CREATE',
        'committed': subject(),
        'current': subject()
      });
    });
    final first = controller(backend, storage);
    await first.load();
    await first.execute(input('CREATE'));
    final key = first.pending!['requestId'];
    first.dispose();
    final next = controller(backend, storage);
    await next.load();
    expect(next.pending!['requestId'], key);
    await next.query();
    expect(next.queried, isTrue);
    expect(writes, 1);
    expect(next.result!['current']['id'], id);
    next.dispose();
  });
  test('storage failure and cancelled authentication cannot dispatch writes',
      () async {
    for (final failStorage in [false, true]) {
      final storage = Storage()..fail = failStorage;
      var writes = 0;
      final c = controller(api((_) async {
        writes++;
        return response(subject());
      }), storage, reauth: () async => failStorage);
      await c.load();
      await c.execute(input('CREATE'));
      expect(writes, 0);
      if (failStorage) {
        storage.fail = false;
        await c.load();
        expect(c.pending, isNotNull);
      }
      c.dispose();
    }
  });
  test('changed preflight version stops edit before durable dispatch',
      () async {
    final storage = Storage();
    var writes = 0;
    final c = controller(api((r) async {
      if (r.method != 'GET') writes++;
      return response(subject(version: 2));
    }), storage);
    await c.load();
    await c.execute(input('UPDATE'));
    expect(writes, 0);
    expect(storage.values, isEmpty);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
  });
  for (final code in [
    'SUBJECT_RESULT_UNAVAILABLE',
    'IDEMPOTENCY_RESPONSE_ERASED'
  ]) {
    test('$code requires explicit acknowledgement and never repeats creation',
        () async {
      final storage = Storage();
      var writes = 0;
      final c = controller(api((r) async {
        if (r.url.path.endsWith('/changes')) {
          writes++;
          throw http.ClientException('unknown');
        }
        return code.startsWith('SUBJECT')
            ? response({'errorCode': code}, 404)
            : parentJournalTerminalProblem(code);
      }), storage);
      await c.load();
      await c.execute(input('CREATE'));
      await c.query();
      expect(c.queried, code.startsWith('SUBJECT') ? isTrue : isFalse);
      expect(c.result, isNull);
      expect(c.pending, isNotNull);
      await c.execute(input('CREATE'));
      expect(writes, 1);
      if (code.startsWith('SUBJECT')) {
        await c.acknowledge();
      } else {
        await c.endLocalCheck();
      }
      expect(storage.values, isEmpty);
      c.dispose();
    });
  }
  test(
      'background during write hides late response and preserves recovery evidence',
      () async {
    final storage = Storage(),
        arrived = Completer<void>(),
        reply = Completer<http.Response>();
    var foreground = true, queries = 0;
    final c = controller(api((r) async {
      if (r.url.path.endsWith('/changes')) {
        arrived.complete();
        return reply.future;
      }
      queries++;
      return response({});
    }), storage, foreground: () => foreground);
    await c.load();
    final operation = c.execute(input('CREATE'));
    await arrived.future;
    foreground = false;
    c.hide();
    reply.complete(response(subject()));
    await operation;
    expect(c.result, isNull);
    expect(queries, 0);
    expect(storage.values.length, 1);
    c.dispose();
  });
  test('role change during token wait prevents creation request', () async {
    final storage = Storage(), token = Completer<String>();
    var current = true, sent = 0;
    final c = controller(
        api((_) async {
          sent++;
          return response(subject());
        }, token: () => token.future),
        storage,
        current: () => current);
    await c.load();
    final operation = c.execute(input('CREATE'));
    await Future<void>.delayed(Duration.zero);
    current = false;
    token.complete('fixture');
    await operation;
    expect(sent, 0);
    expect(storage.values.length, 1);
    c.dispose();
  });
  testWidgets(
      'archive needs acknowledgement and returns original and current profile',
      (tester) async {
    var writes = 0;
    final fixture = api((r) async {
      if (r.method == 'GET') return response(subject());
      if (r.url.path.endsWith('/changes')) {
        writes++;
        return response(subject(version: 1, archived: true));
      }
      return response({
        'operation': 'ARCHIVE',
        'committed': subject(version: 1, archived: true),
        'current': subject(version: 1, archived: true)
      });
    });
    await tester.pumpWidget(MaterialApp(
        home: SubjectEditor(
            session: Session(fixture),
            input: {'operation': 'UPDATE', ...subject()},
            store: SubjectChangeStore(storage: Storage()))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('归档这个档案'));
    await tester.tap(find.text('归档这个档案'));
    await tester.pumpAndSettle();
    final submit = find.byKey(const Key('subject-submit'));
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.tap(find.text('已了解影响，确认归档'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text('原操作已提交（历史结果）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'editor hides on background and removes itself on role revocation',
      (tester) async {
    final session = Session(api((_) async => response(subject())));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    child: const Text('打开'),
                    onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) => SubjectEditor(
                            session: session,
                            input: input('CREATE'),
                            store:
                                SubjectChangeStore(storage: Storage())))))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('subject-nickname')), '私有昵称');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('私有昵称'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('读取 / 恢复'), findsOneWidget);
    session.revoke();
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'profile form supports phone large text without requesting exact identity',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const font = String.fromEnvironment('UI_CAPTURE_FONT'),
        icons = String.fromEnvironment('UI_CAPTURE_ICONS');
    for (final entry
        in {'LocalCaptureFont': font, 'MaterialIcons': icons}.entries) {
      if (entry.value.isNotEmpty) {
        await tester.runAsync(() async {
          final data = await File(entry.value).readAsBytes();
          await (FontLoader(entry.key)
                ..addFont(Future.value(ByteData.sublistView(data))))
              .load();
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
                fontFamily: font.isEmpty ? null : 'LocalCaptureFont'),
            builder: (ctx, child) => MediaQuery(
                data: MediaQuery.of(ctx)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!),
            home: SubjectEditor(
                session: Session(api((_) async => response({}))),
                input: input('CREATE'),
                store: SubjectChangeStore(storage: Storage())))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_SUBJECT_UI')) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/subject-form.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
