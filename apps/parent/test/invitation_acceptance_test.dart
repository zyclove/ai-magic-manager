import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/invitation_acceptance.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/invitation_acceptance.dart';
import 'package:parent/ui/family_invitation_page.dart';
import 'package:parent/main.dart';

import 'support/parent_operation_journal_fixture.dart';

const invitationId = '00000000-0000-4000-8000-000000000001',
    tenantId = '00000000-0000-4000-8000-000000000002',
    classId = '00000000-0000-4000-8000-000000000003';
final secret = 'a' * 43;
Json preview() => {
      'invitationId': invitationId,
      'tenantId': tenantId,
      'tenantName': '晨光学校',
      'tenantKind': 'ORGANIZATION',
      'role': 'TEACHER',
      'subjectId': null,
      'subjectName': null,
      'classes': [
        {'id': classId, 'name': '一年级一班'}
      ],
      'expiresAt': 4102444800000,
      'requiresRecentAuthentication': true
    };
Json result(String id,
        {String state = 'ACTIVE', String role = 'TEACHER', int version = 0}) =>
    {
      'requestId': id,
      'actorId': 'recipient',
      'accepted': {
        'invitationId': invitationId,
        'tenantId': tenantId,
        'role': 'TEACHER',
        'memberVersion': 0
      },
      'current': {
        'state': state,
        'role': state == 'MISSING' ? null : role,
        'version': state == 'MISSING' ? null : version
      }
    };
http.Response response(Object? value, [int status = 200]) => value == null
    ? http.Response('', status)
    : http.Response.bytes(utf8.encode(jsonEncode(value)), status);
ParentApi apiFor(Future<http.Response> Function(http.Request) handle) =>
    ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1', client: MockClient(handle));

class Storage extends ParentDurableStorage with ParentAtomicJournalFixture {
  final values = <String, String>{};
  bool fail = false;
  Completer<void>? barrier;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    if (fail) throw StateError('disk');
    values[key] = value;
    await barrier?.future;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

class Session extends ParentSession {
  final ParentApi fixture;
  int refreshes = 0;
  Session(this.fixture) {
    profile = {'subject': 'recipient', 'canCreateTenant': true};
    ready = true;
    role = '';
    tenant = null;
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  void change() {
    generation++;
    notifyListeners();
  }

  @override
  Future<void> initialize() async {
    refreshes++;
    change();
  }
}

InvitationAcceptanceController make(ParentApi api, Storage storage,
        {bool Function()? current}) =>
    InvitationAcceptanceController(
        api: api,
        actor: 'recipient',
        store: InvitationAcceptanceStore(storage: storage),
        isCurrent: current ?? () => true);

void main() {
  test('preview validates role scope names and immutable identifiers', () {
    expect(readInvitationPreview(preview())['tenantId'], tenantId);
    for (final row in [
      {...preview(), 'role': 'OWNER'},
      {...preview(), 'tenantKind': 'FAMILY'},
      {
        ...preview(),
        'classes': [
          {'id': classId, 'name': 'A'},
          {'id': classId, 'name': 'B'}
        ]
      },
      {...preview(), 'expiresAt': 1.0},
      {...preview(), 'requiresRecentAuthentication': false}
    ]) {
      expect(
          () => readInvitationPreview(row), throwsA(isA<ParentApiException>()));
    }
  });
  test('expired preview cannot silently send acceptance', () async {
    var joins = 0;
    final c = make(apiFor((r) async {
      if (!r.url.path.endsWith('/preview')) joins++;
      return response({...preview(), 'expiresAt': 1});
    }), Storage());
    await c.load();
    await c.inspect(secret);
    expect(c.canAccept, isFalse);
    await c.accept();
    expect(joins, 0);
    expect(c.preview, isNull);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
  });
  test('preview never joins and no token enters durable records', () async {
    final storage = Storage(), calls = <http.Request>[];
    final c = make(apiFor((r) async {
      calls.add(r);
      return response(preview());
    }), storage);
    await c.load();
    await c.inspect(secret);
    expect(c.canAccept, isTrue);
    expect(calls.single.url.path.endsWith('/preview'), isTrue);
    expect(storage.values, isEmpty);
    c.forgetSecret();
    expect(c.preview, isNull);
    expect(c.canAccept, isFalse);
    c.dispose();
  });
  test(
      'lost acceptance is recovered after restart even when membership is revoked',
      () async {
    final storage = Storage();
    var writes = 0;
    final api = apiFor((r) async {
      if (r.url.path.endsWith('/preview')) return response(preview());
      if (r.method == 'POST') {
        writes++;
        throw http.ClientException('lost');
      }
      return response(
          result(r.url.pathSegments.last, state: 'REVOKED', version: 1));
    });
    var c = make(api, storage);
    await c.load();
    await c.inspect(secret);
    await c.accept();
    expect(c.error, isA<ParentApiException>());
    expect(c.committed, isFalse);
    expect(storage.values.values.single, isNot(contains(secret)));
    expect(storage.values.values.single, isNot(contains('晨光学校')));
    c.dispose();
    c = make(api, storage);
    await c.load();
    expect(writes, 1);
    await c.recover();
    expect(c.error, isNull);
    expect(c.committed, isTrue);
    expect(c.result!['current']['state'], 'REVOKED');
    expect(c.result!['accepted']['role'], 'TEACHER');
    expect(writes, 1);
    expect(await c.acknowledge(), isTrue);
    c.dispose();
  });
  test(
      'manual retry uses original key and invitation with freshly entered token',
      () async {
    final storage = Storage(), writes = <http.Request>[];
    final api = apiFor((r) async {
      if (r.url.path.endsWith('/preview')) return response(preview());
      writes.add(r);
      if (writes.length == 1) throw http.ClientException('lost');
      return response(
          result(r.headers['Idempotency-Key']!, role: 'AUDITOR', version: 2));
    });
    var c = make(api, storage);
    await c.load();
    await c.inspect(secret);
    await c.accept();
    c.dispose();
    c = make(api, storage);
    await c.load();
    await c.recover(retryToken: 'invalid');
    expect(writes, hasLength(1));
    await c.recover(retryToken: secret);
    expect(c.error, isNull);
    expect(c.result!['current']['role'], 'AUDITOR');
    expect(writes[0].body, writes[1].body);
    expect(writes[0].headers['Idempotency-Key'],
        writes[1].headers['Idempotency-Key']);
    c.dispose();
  });
  test('late preview cannot return after background clearing', () async {
    final reply = Completer<http.Response>(),
        c = make(apiFor((_) => reply.future), Storage());
    await c.load();
    final pending = c.inspect(secret);
    await Future<void>.delayed(Duration.zero);
    c.forgetSecret();
    reply.complete(response(preview()));
    await pending;
    expect(c.preview, isNull);
    expect(c.canAccept, isFalse);
    c.dispose();
  });
  test(
      'background during persistence preserves recovery but prevents acceptance dispatch',
      () async {
    final storage = Storage()..barrier = Completer<void>();
    var writes = 0;
    final c = make(apiFor((r) async {
      if (!r.url.path.endsWith('/preview')) writes++;
      return response(preview());
    }), storage);
    await c.load();
    await c.inspect(secret);
    final pending = c.accept();
    await Future<void>.delayed(Duration.zero);
    c.forgetSecret();
    storage.barrier!.complete();
    await pending;
    expect(writes, 0);
    expect(c.loaded, isFalse);
    await c.load();
    expect(c.pending, isNotNull);
    c.dispose();
  });
  test('storage failure and identity loss block acceptance writes', () async {
    var calls = 0;
    final c = make(apiFor((r) async {
      if (!r.url.path.endsWith('/preview')) calls++;
      return response(preview());
    }), Storage()..fail = true);
    await c.load();
    await c.inspect(secret);
    await c.accept();
    expect(calls, 0);
    expect(c.loaded, isFalse);
    c.dispose();
    var refreshes = 0, current = true;
    final token = Completer<String>();
    final api = ParentApi(
        () async {
          refreshes++;
          return refreshes == 1 ? 'token' : await token.future;
        },
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((r) async {
          if (!r.url.path.endsWith('/preview')) calls++;
          return response(preview());
        }));
    final d = make(api, Storage(), current: () => current);
    await d.load();
    await d.inspect(secret);
    final sending = d.accept();
    await Future<void>.delayed(Duration.zero);
    current = false;
    token.complete('token');
    await sending;
    expect(calls, 0);
    d.dispose();
  });
  test('wrong actor response cannot be marked committed', () async {
    final c = make(apiFor((r) async {
      if (r.url.path.endsWith('/preview')) return response(preview());
      return response(
          {...result(r.headers['Idempotency-Key']!), 'actorId': 'other'});
    }), Storage());
    await c.load();
    await c.inspect(secret);
    await c.accept();
    expect(c.error, isA<ParentApiException>());
    expect(c.committed, isFalse);
    expect(await c.acknowledge(), isFalse);
    c.dispose();
  });
  for (final status in [404, 410]) {
    test('unavailable or erased $status results never grant membership',
        () async {
      final c = make(apiFor((r) async {
        if (r.url.path.endsWith('/preview')) return response(preview());
        if (r.method == 'POST') throw http.ClientException('lost');
        return status == 404
            ? response({'errorCode': 'INVITATION_ACCEPTANCE_RESULT_UNAVAILABLE'}, status)
            : parentJournalTerminalProblem('IDEMPOTENCY_RESPONSE_ERASED');
      }), Storage());
      await c.load();
      await c.inspect(secret);
      await c.accept();
      await c.recover();
      expect(c.queried, status == 404 ? isTrue : isFalse);
      expect(c.committed, isFalse);
      expect(c.result, isNull);
      expect(await (status == 404 ? c.acknowledge() : c.endLocalCheck()), isTrue);
      c.dispose();
    });
  }
  test('durable reference rejects extra token and is actor scoped', () async {
    final storage = Storage(),
        store = InvitationAcceptanceStore(storage: Storage());
    final actual = InvitationAcceptanceStore(storage: storage);
    await actual.save('a', {
      'requestId': invitationId,
      'invitationId': invitationId,
      'tenantId': tenantId,
      'role': 'TEACHER'
    });
    expect(await actual.load('b'), isNull);
    storage.values[actual.key('a')] = jsonEncode(
        {...jsonDecode(storage.values.values.single), 'token': secret});
    expect(() => actual.load('a'), throwsFormatException);
    expect(await store.load('a'), isNull);
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'recipient checks named scope and joins without a workspace at scale $scale',
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const font = String.fromEnvironment('UI_CAPTURE_FONT'),
          icons = String.fromEnvironment('UI_CAPTURE_ICONS');
      for (final e
          in {'LocalCaptureFont': font, 'MaterialIcons': icons}.entries) {
        if (e.value.isNotEmpty) {
          await tester.runAsync(() async {
            final loader = FontLoader(e.key)
              ..addFont(Future.value(
                  ByteData.sublistView(await File(e.value).readAsBytes())));
            await loader.load();
          });
        }
      }
      final writes = <http.Request>[], storage = Storage();
      final session = Session(apiFor((r) async {
        if (r.url.path.endsWith('/preview')) return response(preview());
        writes.add(r);
        return response(result(r.headers['Idempotency-Key']!));
      }));
      final boundary = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: ThemeData(
                  useMaterial3: true,
                  colorSchemeSeed: const Color(0xFF315E86),
                  fontFamily: font.isEmpty ? null : 'LocalCaptureFont'),
              home: Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(
                          onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                  builder: (_) => InvitationAcceptancePage(
                                      session: session,
                                      store: InvitationAcceptanceStore(
                                          storage: storage)))),
                          child: const Text('打开加入')))))));
      await tester.tap(find.text('打开加入'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), secret);
      await tester.tap(find.text('查看邀请内容'));
      await tester.pumpAndSettle();
      expect(find.text('晨光学校'), findsOneWidget);
      expect(find.text('一年级一班'), findsOneWidget);
      expect(writes, isEmpty);
      if (const bool.fromEnvironment('CAPTURE_ACCEPTANCE_UI') && scale == 1.0) {
        await tester.runAsync(() async {
          final image = await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('../../.local/parent-acceptance-portrait.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('核对并加入'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认加入'));
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));
      expect(jsonDecode(writes.single.body),
          {'invitationId': invitationId, 'token': secret});
      expect(storage.values.values.single, isNot(contains(secret)));
      await tester.scrollUntilVisible(find.text('完成并刷新工作空间'), 200);
      await tester.tap(find.text('完成并刷新工作空间'));
      await tester.pumpAndSettle();
      expect(session.refreshes, 1);
      expect(storage.values, isEmpty);
      expect(find.text('打开加入'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('background clears the input and preview without joining',
      (tester) async {
    var writes = 0;
    final session = Session(apiFor((r) async {
      if (!r.url.path.endsWith('/preview')) writes++;
      return response(preview());
    }));
    await tester.pumpWidget(MaterialApp(
        home: InvitationAcceptancePage(
            session: session,
            store: InvitationAcceptanceStore(storage: Storage()))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), secret);
    await tester.tap(find.text('查看邀请内容'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('晨光学校'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('晨光学校'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(writes, 0);
  });
  testWidgets('session change closes acceptance confirmation', (tester) async {
    var writes = 0;
    final session = Session(apiFor((r) async {
      if (!r.url.path.endsWith('/preview')) writes++;
      return response(preview());
    }));
    await tester.pumpWidget(MaterialApp(
        home: InvitationAcceptancePage(
            session: session,
            store: InvitationAcceptanceStore(storage: Storage()))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), secret);
    await tester.tap(find.text('查看邀请内容'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对并加入'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    session.change();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(writes, 0);
  });
  testWidgets(
      'main app exposes phone family join entry before any workspace exists',
      (tester) async {
    // The concurrent first-use widget uses native storage; this test covers only join entry routing.
    const secure =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    const durability = MethodChannel('com.aimanager.parent/storage');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (_) async => null);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(durability, (_) async => true);
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(secure, null);
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(durability, null);
    });
    final session = Session(
        apiFor((_) async => response({'items': [], 'nextCursor': null})));
    await tester.pumpWidget(ParentApp(session: session));
    await tester.pumpAndSettle();
    expect(find.byType(FamilyInvitationEntry), findsOneWidget);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.byType(FamilyInvitationEntry), findsOneWidget);
  });
}
