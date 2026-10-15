import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/audit.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/audit_center.dart';

const tenant = '11111111-1111-1111-1111-111111111111';
const resource = '22222222-2222-2222-2222-222222222222';
const trace = '33333333-3333-3333-3333-333333333333';
String id(int n) =>
    '${n.toRadixString(16).padLeft(8, '0')}-1111-1111-1111-111111111111';
final now = DateTime.now().millisecondsSinceEpoch - 60000;
Json event(int n, {int? at}) => {
      'id': id(n),
      'actorId': 'guardian-01',
      'action': 'SUBJECT_CREATED',
      'resourceId': resource,
      'correlationId': trace,
      'occurredAt': at ?? now - (100 - n) * 1000
    };
http.Response response(Object data, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), status);
ParentApi api(FutureOr<http.Response> Function(http.Request) handle) =>
    ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((r) async => handle(r)));
ParentAuditRepository repo(ParentApi api, {bool Function()? current}) =>
    ParentAuditRepository(
        api: api, tenant: tenant, current: current ?? () => true);

class Session extends ParentSession {
  final ParentApi transport;
  Session(this.transport, {String grant = 'OWNER'}) {
    profile = {'subject': 'guardian-01'};
    this.tenant = {
      'id': '11111111-1111-1111-1111-111111111111',
      'kind': 'ORGANIZATION',
      'name': '晨光学校'
    };
    role = grant;
    ready = true;
  }
  @override
  ParentApi get api => transport;
  @override
  bool get authenticated => true;
  void change() {
    this.tenant = {...this.tenant!, 'id': resource};
    generation++;
    notifyListeners();
  }
}

Widget host(Session session, {GlobalKey? capture, String? font}) => MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF315E86),
        fontFamily: font),
    home: RepaintBoundary(key: capture, child: AuditCenter(session: session)));

void main() {
  testWidgets('detail retry then return reloads the cleared list', (t) async {
    int lists = 0, details = 0;
    final s = Session(api((r) {
      if (r.url.path.endsWith('/search')) {
        lists++;
        return response({
          'items': [event(1)],
          'nextCursor': null
        });
      }
      details++;
      return details == 1
          ? response({'errorCode': 'TEMPORARY'}, 503)
          : response(event(1));
    }));
    await t.pumpWidget(host(s));
    await t.pumpAndSettle();
    await t.tap(find.text('添加儿童或学生'));
    await t.pumpAndSettle();
    expect(find.text('添加儿童或学生'), findsNothing);
    await t.tap(find.text('重试此次读取'));
    await t.pumpAndSettle();
    expect(find.text('记录详情'), findsOneWidget);
    await t.tap(find.byTooltip('返回记录列表'));
    await t.pumpAndSettle();
    expect(lists, 2);
    expect(find.text('添加儿童或学生'), findsOneWidget);
  });
  testWidgets('revoked detail authorization clears previously visible records',
      (t) async {
    final s = Session(api((r) => r.url.path.endsWith('/search')
        ? response({
            'items': [event(1)],
            'nextCursor': null
          })
        : response({'errorCode': 'SCOPE_DENIED'}, 403)));
    await t.pumpWidget(host(s));
    await t.pumpAndSettle();
    await t.tap(find.text('添加儿童或学生'));
    await t.pumpAndSettle();
    expect(find.text('添加儿童或学生'), findsNothing);
    expect(find.text('当前账号没有此操作权限。'), findsOneWidget);
    expect(find.text('记录详情'), findsNothing);
  });

  testWidgets('reply from before background cannot replace the refreshed page',
      (t) async {
    final old = Completer<http.Response>();
    int calls = 0;
    final s = Session(api((r) {
      calls++;
      if (calls == 1) return old.future;
      return response({
        'items': [
          {...event(1), 'actorId': 'current-reader'}
        ],
        'nextCursor': null
      });
    }));
    await t.pumpWidget(host(s));
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(find.textContaining('current-reader'), findsOneWidget);
    old.complete(response({
      'items': [event(1)],
      'nextCursor': null
    }));
    await t.pumpAndSettle();
    expect(find.textContaining('current-reader'), findsOneWidget);
    expect(find.textContaining('guardian-01'), findsNothing);
  });
  test(
      'shared query and projection reject invalid dates filters and private fields',
      () {
    for (final q in [
      const AuditQuery(from: 0, to: 0),
      const AuditQuery(from: -1, to: 1),
      const AuditQuery(from: 0, to: 367 * 86400000),
      const AuditQuery(from: 0, to: 100, action: 'DROP;'),
      const AuditQuery(from: 0, to: 100, resourceId: 'other'),
      const AuditQuery(from: 0, to: 100, correlationId: 'other')
    ]) {
      expect(q.validate, throwsA(isA<AuditProtocolException>()));
    }
    for (final v in [
      {...event(1), 'secret': 'extra'},
      {...event(1), 'occurredAt': 9007199254740991},
      {...event(1), 'actorId': ''}
    ]) {
      expect(() => AuditEvent.parse(v), throwsA(isA<AuditProtocolException>()));
    }
    AuditQuery(from: 0, to: 100, resourceId: 'ab' * 32).validate();
  });

  test(
      'repository checks range filter sort duplicates cursor and selected detail',
      () async {
    final q =
        AuditQuery(from: now - 1000000, to: now + 10000, resourceId: resource);
    for (final data in [
      {
        'items': [event(1), event(2)],
        'nextCursor': null
      },
      {
        'items': [event(1), event(1)],
        'nextCursor': null
      },
      {
        'items': [
          {...event(1), 'resourceId': tenant}
        ],
        'nextCursor': null
      },
      {
        'items': [event(1, at: q.to)],
        'nextCursor': null
      },
      {
        'items': [event(1)],
        'nextCursor': 'next'
      },
      {'items': List.generate(20, (n) => event(100 - n)), 'nextCursor': 'same'},
    ]) {
      await expectLater(
          repo(api((r) => response(data))).load(q, cursor: 'same'),
          throwsA(isA<ParentApiException>()));
    }
    await expectLater(repo(api((r) => response(event(2)))).detail(id(1)),
        throwsA(isA<ParentApiException>()));
    int calls = 0;
    await expectLater(
        repo(api((r) {
          calls++;
          return response({});
        })).load(const AuditQuery(from: 0, to: 0)),
        throwsA(isA<ParentApiException>()));
    expect(calls, 0);
  });

  test('scope change during token refresh or response cannot return old data',
      () async {
    bool current = true;
    final token = Completer<String>();
    int calls = 0;
    final transport =
        ParentApi(() => token.future, baseUrl: 'https://fixture.invalid/api/v1',
            client: MockClient((r) async {
      calls++;
      return response(event(1));
    }));
    final pending = repo(transport, current: () => current).detail(id(1));
    current = false;
    token.complete('fixture');
    await expectLater(pending, throwsA(isA<ParentApiException>()));
    expect(calls, 0);
    current = true;
    final reply = Completer<http.Response>();
    final delayed =
        repo(api((r) => reply.future), current: () => current).detail(id(1));
    await Future<void>.delayed(Duration.zero);
    current = false;
    reply.complete(response(event(1)));
    await expectLater(delayed, throwsA(isA<ParentApiException>()));
  });

  testWidgets(
      'next page failure retries exact cursor and previous navigation remains usable',
      (t) async {
    final queries = <Map<String, String>>[];
    bool failed = false;
    final s = Session(api((r) {
      final p = r.url.queryParameters;
      queries.add(p);
      if (p['cursor'] == 'page2' && !failed) {
        failed = true;
        return response({'errorCode': 'TEMPORARY'}, 503);
      }
      return response({
        'items': p['cursor'] == null
            ? List.generate(20, (n) => event(100 - n))
            : [event(70)],
        'nextCursor': p['cursor'] == null ? 'page2' : null
      });
    }));
    await t.pumpWidget(host(s));
    await t.pumpAndSettle();
    await t.tap(find.text('下一页'));
    await t.pumpAndSettle();
    await t.tap(find.text('重试此次读取'));
    await t.pumpAndSettle();
    expect(queries.map((q) => q['cursor']).toList(), [null, 'page2', 'page2']);
    expect(queries[1], queries[2]);
    expect(find.text('第 2 页 · 1 条'), findsOneWidget);
    await t.tap(find.text('上一页'));
    await t.pumpAndSettle();
    await t.tap(find.text('下一页'));
    await t.pumpAndSettle();
    expect(find.text('第 2 页 · 1 条'), findsOneWidget);
  });

  testWidgets(
      'details reload from server and related records preserve the time window',
      (t) async {
    final requests = <Uri>[];
    final s = Session(api((r) {
      requests.add(r.url);
      return response(r.url.path.endsWith('/search')
          ? {
              'items': [event(1)],
              'nextCursor': null
            }
          : event(1));
    }));
    await t.pumpWidget(host(s));
    await t.pumpAndSettle();
    await t.tap(find.text('添加儿童或学生'));
    await t.pumpAndSettle();
    expect(requests.last.path.endsWith(id(1)), true);
    expect(find.text('记录详情'), findsOneWidget);
    await t.scrollUntilVisible(find.text('查看同一对象的记录'), 200,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await Scrollable.ensureVisible(t.element(find.text('查看同一对象的记录')),
        alignment: 0.5);
    await t.pumpAndSettle();
    await t.tap(find.text('查看同一对象的记录'));
    await t.pumpAndSettle();
    expect(requests.last.queryParameters['resourceId'], resource);
    expect(requests.last.queryParameters['from'],
        requests.first.queryParameters['from']);
    expect(requests.last.queryParameters['to'],
        requests.first.queryParameters['to']);
  });

  testWidgets(
      'filters validate calendar dates and submit exact half-open local range',
      (t) async {
    final requests = <Uri>[];
    final s = Session(api((r) {
      requests.add(r.url);
      return response({'items': [], 'nextCursor': null});
    }));
    await t.pumpWidget(host(s));
    await t.pumpAndSettle();
    await t.tap(find.text('筛选记录'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextFormField, '开始日期'), '2026-02-30');
    await t.tap(find.text('应用筛选'));
    await t.pumpAndSettle();
    expect(requests.length, 1);
    await t.enterText(find.widgetWithText(TextFormField, '开始日期'), '2026-10-01');
    await t.enterText(find.widgetWithText(TextFormField, '结束日期'), '2026-10-02');
    await t.enterText(
        find.widgetWithText(TextFormField, '操作对象编号（选填）'), 'ab' * 32);
    await t.tap(find.text('应用筛选'));
    await t.pumpAndSettle();
    final p = requests.last.queryParameters;
    expect(p['from'], '${DateTime(2026, 10, 1).millisecondsSinceEpoch}');
    expect(p['to'], '${DateTime(2026, 10, 3).millisecondsSinceEpoch}');
    expect(p['resourceId'], 'ab' * 32);
    await t.tap(find.text('最近 7 天'));
    await t.pumpAndSettle();
    expect(requests.last.queryParameters.containsKey('resourceId'), false);
  });

  testWidgets(
      'background closes filters clears records and reloads; tenant switch hides late reply',
      (t) async {
    Completer<http.Response>? reply;
    int calls = 0;
    final s = Session(api((r) {
      calls++;
      return reply?.future ??
          response({
            'items': [event(1)],
            'nextCursor': null
          });
    }));
    await t.pumpWidget(host(s));
    await t.pumpAndSettle();
    await t.tap(find.text('筛选记录'));
    await t.pumpAndSettle();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pumpAndSettle();
    expect(find.text('筛选操作记录'), findsNothing);
    expect(find.text('添加儿童或学生'), findsNothing);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(calls, 2);
    reply = Completer<http.Response>();
    await t.tap(find.byTooltip('刷新操作记录'));
    await t.pump();
    s.change();
    await t.pump();
    reply.complete(response({
      'items': [event(1)],
      'nextCursor': null
    }));
    await t.pumpAndSettle();
    expect(find.text('添加儿童或学生'), findsNothing);
  });

  testWidgets(
      'teachers and children cannot dispatch audit reads; auditors can read',
      (t) async {
    for (final role in ['TEACHER', 'CHILD', 'AUDITOR']) {
      int calls = 0;
      await t.pumpWidget(host(Session(api((r) {
        calls++;
        return response({'items': [], 'nextCursor': null});
      }), grant: role)));
      await t.pumpAndSettle();
      expect(calls, role == 'AUDITOR' ? 1 : 0);
      await t.pumpWidget(const SizedBox());
    }
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('portrait list detail filters at ${scale}x text', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(() {
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
        t.platformDispatcher.clearTextScaleFactorTestValue();
      });
      const font = String.fromEnvironment('UI_CAPTURE_FONT');
      if (font.isNotEmpty) {
        await t.runAsync(() async {
          for (final e in {
            'Capture': font,
            'MaterialIcons': const String.fromEnvironment('UI_CAPTURE_ICONS')
          }.entries) {
            if (e.value.isEmpty) continue;
            await (FontLoader(e.key)
                  ..addFont(Future.value(
                      ByteData.sublistView(await File(e.value).readAsBytes()))))
                .load();
          }
        });
      }
      final key = GlobalKey();
      final s = Session(api((r) => response(r.url.path.endsWith('/search')
          ? {
              'items': [event(1)],
              'nextCursor': null
            }
          : event(1))));
      await t.pumpWidget(
          host(s, capture: key, font: font.isEmpty ? null : 'Capture'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_AUDIT_UI') && scale == 1) {
        await t.runAsync(() async {
          final img = await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
          final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
          final output = File(const String.fromEnvironment('UI_CAPTURE_PATH',
              defaultValue: '../../.local/parent-audit-portrait.png'));
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes!.buffer.asUint8List());
          img.dispose();
        });
      }
      await t.scrollUntilVisible(find.text('添加儿童或学生'), 150);
      await t.pumpAndSettle();
      await Scrollable.ensureVisible(t.element(find.text('添加儿童或学生')),
          alignment: 0.5);
      await t.pumpAndSettle();
      expect(find.text('添加儿童或学生').hitTestable(), findsOneWidget);
      await t.tap(find.text('添加儿童或学生'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.byTooltip('返回记录列表'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('筛选记录'), -150);
      await t.pumpAndSettle();
      await Scrollable.ensureVisible(t.element(find.text('筛选记录')),
          alignment: 0.5);
      await t.pumpAndSettle();
      expect(find.text('筛选记录').hitTestable(), findsOneWidget);
      await t.tap(find.text('筛选记录'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.byTooltip('选择开始日期'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
    });
  }
}
