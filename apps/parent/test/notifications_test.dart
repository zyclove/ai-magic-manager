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
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/notifications.dart';
import 'package:parent/ui/notification_center.dart';

const first = '11111111-1111-4111-8111-111111111111';
const second = '22222222-2222-4222-8222-222222222222';
const requestId = '33333333-3333-4333-8333-333333333333';
const epoch = 1791940000000;
Json notice(
        {String id = first,
        int time = epoch,
        String state = 'APPROVED_PENDING_DELIVERY',
        int? readAt}) =>
    {
      'id': id,
      'requestId': requestId,
      'subjectId': first,
      'deviceId': second,
      'requestVersion': 1,
      'state': state,
      'occurredAt': time,
      'readAt': readAt
    };
http.Response reply(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status,
        headers: {'content-type': 'application/json'});
ParentApi api(Future<http.Response> Function(http.Request) run,
        {Future<String> Function()? token}) =>
    ParentApi(token ?? () async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1', client: MockClient(run));
ParentNotificationInbox inbox(ParentApi a, {bool Function()? current}) =>
    ParentNotificationInbox(
        api: a, root: '/tenants/$first', isCurrent: current ?? () => true);
Future<http.Response> success(http.Request r) async =>
    r.url.path.endsWith('/unread-count')
        ? reply({'count': 1, 'capped': false})
        : reply({
            'items': [notice()],
            'nextCursor': null
          });

class Session extends ParentSession {
  final ParentApi fixture;
  Session(this.fixture) {
    tenant = {'id': first};
    profile = {'subject': 'adult'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  void revoke() {
    role = 'AUDITOR';
    notifyListeners();
  }
}

Widget host(Session s, {Future<void> Function(String)? open}) =>
    MaterialApp(home: ParentNotificationCenter(session: s, onOpen: open));

void main() {
  test('default inbox uses unread scope and a bounded page', () async {
    final paths = <Uri>[];
    final c = inbox(api((r) {
      paths.add(r.url);
      return success(r);
    }));
    await c.load();
    expect(c.snapshot!.unread.count, 1);
    expect(paths.singleWhere((p) => p.query.isNotEmpty).queryParameters,
        {'limit': '20', 'unreadOnly': 'true'});
    c.dispose();
  });
  test('count failure is not displayed as zero or a partial successful inbox',
      () async {
    final c = inbox(api((r) async => r.url.path.endsWith('/unread-count')
        ? reply({'errorCode': 'FAILED'}, 503)
        : reply({
            'items': [notice()],
            'nextCursor': null
          })));
    await c.load();
    expect(c.snapshot, isNull);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
  });
  test('private or malformed notification response is rejected', () async {
    final c = inbox(api((r) async => r.url.path.endsWith('/unread-count')
        ? reply({'count': 1, 'capped': false})
        : reply({
            'items': [
              {...notice(), 'reason': 'private'}
            ],
            'nextCursor': null
          })));
    await c.load();
    expect(c.snapshot, isNull);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
  });
  test('unknown read outcome retains exact immutable IDs for explicit retry',
      () async {
    final writes = <List<dynamic>>[];
    var fail = true;
    final c = inbox(api((r) async {
      if (r.method == 'POST') {
        final ids = jsonDecode(r.body)['ids'] as List<dynamic>;
        writes.add(ids);
        if (fail) {
          fail = false;
          throw http.ClientException('lost response');
        }
        return reply({
          'items': ids.map((id) => {'id': id, 'readAt': epoch}).toList()
        });
      }
      return success(r);
    }));
    final selected = [first, second];
    await c.read(selected, open: (_) async {});
    selected.clear();
    expect(c.retryIds, [first, second]);
    expect(writes.length, 1);
    await c.read(c.retryIds!, open: (_) async {});
    expect(writes, [
      [first, second],
      [first, second]
    ]);
    expect(c.error, isNull);
    c.dispose();
  });
  test('read receipt must cover the exact selected IDs', () async {
    final c = inbox(api((r) async => reply({'id': second, 'readAt': epoch})));
    var opened = false;
    await c.read([first], requestId: requestId, open: (_) async {
      opened = true;
    });
    expect(opened, isFalse);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
  });
  test('token wait cannot dispatch after background and foreground transition',
      () async {
    final token = Completer<String>();
    var calls = 0;
    final c = inbox(api((r) {
      calls++;
      return success(r);
    }, token: () => token.future));
    final operation = c.load();
    c.setForeground(false);
    c.setForeground(true);
    token.complete('fixture');
    await operation;
    expect(calls, 0);
    expect(c.snapshot, isNull);
    c.dispose();
  });
  test('late responses after revocation cannot restore data', () async {
    final wait = Completer<http.Response>();
    var current = true;
    final c = inbox(
        api((r) async => r.url.path.endsWith('/unread-count')
            ? reply({'count': 1, 'capped': false})
            : wait.future),
        current: () => current);
    final operation = c.load();
    await Future<void>.delayed(Duration.zero);
    current = false;
    c.invalidate();
    wait.complete(reply({
      'items': [notice()],
      'nextCursor': null
    }));
    await operation;
    expect(c.snapshot, isNull);
    c.dispose();
  });
  test('multi-page cursor cycle is rejected', () async {
    final c = inbox(api((r) async => r.url.path.endsWith('/unread-count')
        ? reply({'count': 1, 'capped': false})
        : reply({
            'items': [notice()],
            'nextCursor': r.url.queryParameters['cursor'] == 'page_a'
                ? 'page_b'
                : 'page_a'
          })));
    await c.load();
    await c.next();
    await c.next();
    expect(c.snapshot, isNull);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
  });
  testWidgets(
      'opening a notification marks exact item then opens original request',
      (tester) async {
    final calls = <String>[];
    final s = Session(api((r) async {
      if (r.method == 'PUT') {
        calls.add(r.url.path);
        return reply({'id': first, 'readAt': epoch});
      }
      return success(r);
    }));
    await tester.pumpWidget(host(s, open: (id) async {
      calls.add(id);
    }));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看当前申请'));
    await tester.pumpAndSettle();
    expect(
        calls, ['/api/v1/tenants/$first/notifications/$first/read', requestId]);
  });
  testWidgets(
      'old approval opens latest revoked request and detail hides in background',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/storage'),
            (_) async => true);
    final s = Session(api((r) async {
      if (r.method == 'PUT') return reply({'id': first, 'readAt': epoch});
      if (r.url.path.endsWith('/delivery')) {
        return reply({
          'requestId': requestId,
          'approvalVersion': 2,
          'deliveryState': 'PENDING',
          'executionState': 'UNKNOWN'
        });
      }
      if (r.url.path.endsWith('/access-requests/$requestId')) {
        return reply({
          'id': requestId,
          'version': 2,
          'state': 'REVOKED',
          'subjectName': '小禾',
          'applicationName': '学习应用',
          'createdAt': epoch
        });
      }
      return success(r);
    }));
    await tester.pumpWidget(host(s));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看当前申请'));
    await tester.pumpAndSettle();
    expect(find.text('小禾 · 学习应用'), findsOneWidget);
    expect(find.text('已撤销'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('小禾 · 学习应用'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('小禾 · 学习应用'), findsOneWidget);
    s.revoke();
    await tester.pumpAndSettle();
    expect(find.text('小禾 · 学习应用'), findsNothing);
  });
  testWidgets('shortcut hides count and stops polling while background',
      (tester) async {
    var calls = 0;
    final s = Session(api((r) {
      calls++;
      return success(r);
    }));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            appBar:
                AppBar(actions: [ParentNotificationShortcut(session: s)]))));
    await tester.pumpAndSettle();
    expect(find.byTooltip('消息中心，1 条未读'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 1);
    expect(find.byTooltip('消息中心，1 条未读'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('phone inbox remains usable at large font size', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const font = String.fromEnvironment('UI_CAPTURE_FONT'),
        icons = String.fromEnvironment('UI_CAPTURE_ICONS');
    for (final e
        in {'LocalCaptureFont': font, 'MaterialIcons': icons}.entries) {
      if (e.value.isNotEmpty) {
        await tester.runAsync(() async {
          final data = await File(e.value).readAsBytes();
          await (FontLoader(e.key)
                ..addFont(Future.value(ByteData.sublistView(data))))
              .load();
        });
      }
    }
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: key,
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
            home: ParentNotificationCenter(session: Session(api(success))))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_NOTIFICATION_UI')) {
      await tester.runAsync(() async {
        final img = await (key.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/notification-center.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        img.dispose();
      });
    }
  });
}
