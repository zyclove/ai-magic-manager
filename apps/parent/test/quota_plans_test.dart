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
import 'package:parent/core/quotas.dart';
import 'package:parent/ui/quota_center.dart';

import 'support/parent_operation_journal_fixture.dart';

const subject = '00000000-0000-4000-8000-000000000001';
const planId = '00000000-0000-4000-8000-000000000002';
Json input() => {
      'name': '每周安排',
      'subjectId': subject,
      'scope': 'TOTAL',
      'timeZone': 'Asia/Shanghai',
      'effectiveFrom': '2026-10-15',
      'weeklyLimits': {for (final d in quotaWeekDays) d: 3600},
      'dateOverrides': <String, int>{}
    };
Json plan({int version = 0, String state = 'ACTIVE'}) => {
      ...input(),
      'id': planId,
      'version': version,
      'state': state,
      'createdAt': 1791907200000
    };
Json update({String state = 'PAUSED'}) => {
      'name': '每周安排',
      'state': state,
      'weeklyLimits': input()['weeklyLimits'],
      'dateOverrides': <String, int>{}
    };
http.Response response(Object data, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), status);

class Storage extends ParentDurableStorage with ParentAtomicJournalFixture {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
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
    tenant = {'id': 'tenant', 'timeZone': 'Asia/Shanghai'};
    profile = {'subject': 'adult'};
    role = 'GUARDIAN';
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

ParentApi apiFor(Future<http.Response> Function(http.Request) handler) =>
    ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1', client: MockClient(handler));
void main() {
  test(
      'weekly contract rejects missing days, extra days, negative and malformed date',
      () {
    expect(readQuotaPlan(plan())['id'], planId);
    for (final bad in [
      {
        ...plan(),
        'weeklyLimits': {'MONDAY': 10}
      },
      {
        ...plan(),
        'weeklyLimits': {...input()['weeklyLimits'], 'OTHER': 0}
      },
      {
        ...plan(),
        'weeklyLimits': {...input()['weeklyLimits'], 'MONDAY': -1}
      },
      {
        ...plan(),
        'dateOverrides': {'2026-02-30': 600}
      },
      {...plan(), 'state': 'EXECUTED'},
    ]) {
      expect(() => readQuotaPlan(bad), throwsA(isA<ParentApiException>()));
    }
  });
  test('input preserves second precision and validates upper bound', () {
    expect(quotaMinutesInput(1815), '30:15');
    expect(parseQuotaMinutes('30:15'), 1815);
    expect(parseQuotaMinutes('1440'), 86400);
    for (final v in ['1440:01', '30:60', '-1', '0.5', '']) {
      expect(parseQuotaMinutes(v), isNull);
    }
    expect(() => validateQuotaInput('PLAN_UPDATE', update(), null),
        throwsA(isA<ParentApiException>()));
  });
  test(
      'lost creation is recovered from durable original body with separate latest version',
      () async {
    final requests = <http.Request>[];
    final api = apiFor((r) async {
      requests.add(r);
      if (!r.url.path.endsWith('/query')) throw http.ClientException('lost');
      return response({
        'requestId': r.url.pathSegments[r.url.pathSegments.length - 2],
        'operation': 'PLAN_CREATE',
        'committed': plan(),
        'current': plan(version: 1, state: 'PAUSED')
      });
    });
    final store = QuotaOperationStore(storage: Storage());
    QuotaOperationController make() => QuotaOperationController(
        api: api,
        store: store,
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: () => true);
    var c = make();
    await c.load();
    await c.submit('PLAN_CREATE', input());
    expect(c.committed, isNull);
    c.dispose();
    c = make();
    await c.load();
    expect(requests, hasLength(1));
    await c.query();
    expect(c.error, isNull);
    expect(c.committed!['version'], 0);
    expect(c.latest!['version'], 1);
    expect(jsonDecode(requests.last.body), input());
    expect(await c.acknowledge(), isTrue);
    c.dispose();
  });
  test('update retries exact PUT body key and version after recreation',
      () async {
    final requests = <http.Request>[];
    final api = apiFor((r) async {
      requests.add(r);
      if (requests.length == 1) throw http.ClientException('lost');
      if (r.method == 'PUT') return response(plan(version: 1, state: 'PAUSED'));
      return response({
        'requestId': r.url.pathSegments[r.url.pathSegments.length - 2],
        'operation': 'PLAN_UPDATE',
        'committed': plan(version: 1, state: 'PAUSED'),
        'current': plan(version: 2)
      });
    });
    final store = QuotaOperationStore(storage: Storage());
    QuotaOperationController make() => QuotaOperationController(
        api: api,
        store: store,
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: () => true);
    var c = make();
    await c.load();
    await c.submit('PLAN_UPDATE', update(), before: plan());
    c.dispose();
    c = make();
    await c.load();
    await c.retry();
    expect(c.error, isNull);
    expect(requests[0].method, 'PUT');
    expect(requests[0].body, requests[1].body);
    expect(requests[0].headers['Idempotency-Key'],
        requests[1].headers['Idempotency-Key']);
    expect(requests[1].headers['If-Match'], '"0"');
    expect(requests[2].url.path, contains('/update-results/'));
    expect(c.committed!['state'], 'PAUSED');
    expect(c.latest!['state'], 'ACTIVE');
    c.dispose();
  });
  test('wrong committed configuration remains unresolved', () async {
    final c = QuotaOperationController(
        api: apiFor((_) async => response({
              ...plan(),
              'weeklyLimits': {for (final d in quotaWeekDays) d: 5}
            })),
        store: QuotaOperationStore(storage: Storage()),
        tenant: 't',
        actor: 'a',
        isCurrent: () => true);
    await c.load();
    await c.submit('PLAN_CREATE', input());
    expect(c.committed, isNull);
    expect(c.error, isA<ParentApiException>());
    expect(c.pending, isNotNull);
    c.dispose();
  });
  test(
      'revision pages reject repeated and ascending versions without adding them',
      () async {
    var count = 0;
    final api = apiFor((_) async {
      count++;
      return response({
        'items': [
          {
            'version': 2,
            'effectiveFrom': '2026-10-15',
            'createdAt': 1,
            'configuration': update()
          }
        ],
        'nextCursor': '2'
      });
    });
    final c = QuotaRevisionController(api, '/revisions', () => true);
    await c.load();
    await c.load();
    expect(count, 2);
    expect(c.items, hasLength(1));
    expect(c.error, isA<ParentApiException>());
    c.dispose();
  });
  test('late revision reply after workspace change is ignored', () async {
    final reply = Completer<http.Response>();
    var current = true;
    final c = QuotaRevisionController(
        apiFor((_) => reply.future), '/revisions', () => current);
    final pending = c.load();
    await Future<void>.delayed(Duration.zero);
    current = false;
    reply.complete(response({'items': [], 'nextCursor': null}));
    await pending;
    expect(c.loaded, isFalse);
    expect(c.items, isEmpty);
    c.dispose();
  });
  testWidgets(
      'weekly overview fits narrow screen and large text without color-only meaning',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
                body: Padding(
                    padding: const EdgeInsets.all(20),
                    child:
                        QuotaWeekOverview(limits: input()['weeklyLimits']))))));
    expect(find.text('周一'), findsOneWidget);
    expect(find.text('60 分钟'), findsNWidgets(7));
    expect(tester.takeException(), isNull);
  });
  testWidgets('auditor sees plans and weekly chart but cannot create or pause',
      (tester) async {
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
    final api = apiFor((r) async {
      expect(r.method, 'GET');
      if (r.url.path.endsWith(planId)) return response(plan());
      return response({
        'items': r.url.path.endsWith('/quota-plans') ? [plan()] : [],
        'nextCursor': null
      });
    });
    final session = Session(api)..role = 'AUDITOR';
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
                useMaterial3: true,
                colorSchemeSeed: const Color(0xFF315E86),
                fontFamily: fontFile.isEmpty ? null : 'LocalCaptureFont'),
            home: QuotaCenter(session: session))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每周自动安排'));
    await tester.pumpAndSettle();
    expect(find.text('创建每周计划'), findsNothing);
    await tester.tap(find.text('每周安排'));
    await tester.pumpAndSettle();
    expect(find.text('周一'), findsOneWidget);
    expect(find.text('明天暂停'), findsNothing);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_QUOTA_PLAN_UI')) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/parent-quota-plan-portrait.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
  testWidgets(
      'guardian confirms pause with original version and completes result review',
      (tester) async {
    final requests = <http.Request>[];
    var current = plan();
    final api = apiFor((r) async {
      requests.add(r);
      if (r.method == 'PUT') {
        current = plan(version: 1, state: 'PAUSED');
        return response(current);
      }
      if (r.url.path.endsWith('/query')) {
        return response({
          'requestId': r.url.pathSegments[r.url.pathSegments.length - 2],
          'operation': 'PLAN_UPDATE',
          'committed': current,
          'current': current
        });
      }
      if (r.url.path.endsWith(planId)) return response(current);
      return response({
        'items': r.url.path.endsWith('/quota-plans') ? [current] : [],
        'nextCursor': null
      });
    });
    await tester.pumpWidget(MaterialApp(
        home: QuotaCenter(
            session: Session(api),
            store: QuotaOperationStore(storage: Storage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每周自动安排'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每周安排'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('明天暂停'));
    await tester.tap(find.text('明天暂停'));
    await tester.pumpAndSettle();
    expect(find.text('从明天暂停计划？'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('明天暂停')));
    await tester.pumpAndSettle();
    final write = requests.singleWhere((r) => r.method == 'PUT');
    expect(write.headers['If-Match'], '"0"');
    expect(jsonDecode(write.body)['state'], 'PAUSED');
    await tester.ensureVisible(find.text('完成核对'));
    await tester.tap(find.text('完成核对'));
    await tester.pumpAndSettle();
    expect(find.text('明天恢复'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'create uses server date and batch weekday values; scope change closes active dialog',
      (tester) async {
    final api = apiFor((r) async {
      if (r.url.path.endsWith('/subjects')) {
        return response({
          'items': [
            {'id': subject, 'nickname': '孩子'}
          ],
          'nextCursor': null
        });
      }
      if (r.url.path.endsWith('/calendar')) {
        return response({
          'subjectId': subject,
          'timeZone': 'Asia/Shanghai',
          'currentDate': '2026-10-14'
        });
      }
      return response({'items': [], 'nextCursor': null});
    });
    final session = Session(api);
    await tester.pumpWidget(MaterialApp(
        home: QuotaCenter(
            session: session, store: QuotaOperationStore(storage: Storage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每周自动安排'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建每周计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择儿童或学生'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('孩子'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('填写工作日'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextFormField)),
        '30:15');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(find.text('30:15'), findsWidgets);
    await tester.tap(find.text('填写周末'));
    await tester.pumpAndSettle();
    session.change();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
