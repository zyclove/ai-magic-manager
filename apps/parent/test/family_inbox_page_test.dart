import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family_requests.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/ui/family_inbox_page.dart';
import 'package:parent/ui/family_workspace.dart';
import 'family_device_access_test.dart'
    show SelectionMemoryStorage, jsonResponse, deviceAccessView;
import 'family_workspace_test.dart' show FamilySession, familyDashboard;
import 'family_requests_test.dart' show row;

Json inboxDashboard({bool child = true}) {
  final result = jsonDecode(jsonEncode(familyDashboard(child: child))) as Json;
  if (child) {
    result['children'][0]['devices'][0]['ruleState'] = 'PERMISSION_MISSING';
    result['children'][0]['devices'][0]['runtime'] = {
      'health': 'PERMISSION_MISSING',
      'observedAt': 1790000000000,
      'stale': false
    };
  }
  result['deviceAccess'] = deviceAccessView();
  return result;
}

Future<void> mount(WidgetTester tester, FamilySession session,
    {double scale = 1, bool shortcut = false}) async {
  await tester.pumpWidget(MaterialApp(
      theme: familyTheme(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: shortcut
          ? Scaffold(
              appBar: AppBar(actions: [FamilyInboxShortcut(session: session)]),
              body: const Text('家庭首页'))
          : FamilyInboxPage(
              session: session,
              decisionJournal:
                  FamilyDecisionJournal(storage: SelectionMemoryStorage()))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'family inbox displays live counts and opens actual family requests rather than legacy notification IDs',
      (t) async {
    final paths = <String>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      paths.add(r.url.path);
      if (r.url.path.endsWith('/family-access-requests')) {
        return jsonResponse({
          'items': [row()],
          'nextCursor': null
        });
      }
      return jsonResponse(inboxDashboard());
    })));
    addTearDown(session.dispose);
    await mount(t, session);
    expect(find.text('2 项待处理'), findsOneWidget);
    expect(find.text('1 条待查看'), findsOneWidget);
    await t.scrollUntilVisible(find.textContaining('需要在儿童设备补充授权'), 160);
    expect(find.textContaining('需要在儿童设备补充授权'), findsOneWidget);
    await t.scrollUntilVisible(
        find.byKey(const ValueKey('family-inbox-requests')), -160);
    await t.tap(find.byKey(const ValueKey('family-inbox-requests')));
    await t.pumpAndSettle();
    expect(find.text('想完成这一局'), findsOneWidget);
    expect(paths.any((p) => p.endsWith('/family-access-requests')), true);
    expect(paths.any((p) => p.contains('/notifications')), false);
  });
  testWidgets(
      'loading failure never invents zero pending requests and offers retry',
      (t) async {
    var fail = true;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => fail
            ? jsonResponse({'errorCode': 'UNAVAILABLE'}, status: 503)
            : jsonResponse(inboxDashboard()))));
    addTearDown(session.dispose);
    await mount(t, session);
    expect(find.text('0 项待处理'), findsNothing);
    expect(find.text('2 项待处理'), findsNothing);
    fail = false;
    await t.tap(find.text('重新读取'));
    await t.pumpAndSettle();
    expect(find.text('2 项待处理'), findsOneWidget);
  });
  testWidgets(
      'missing runtime and empty family are described separately from healthy devices',
      (t) async {
    var empty = false;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      final value = inboxDashboard(child: !empty);
      if (empty) {
        value['pendingRequestCount'] = 0;
        value['openHelpRequestCount'] = 0;
        value['deviceAccess'] = null;
      } else {
        value['children'][0]['devices'][0]['runtime'] = null;
        value['children'][0]['devices'][0]['ruleState'] = 'UNKNOWN';
      }
      return jsonResponse(value);
    })));
    addTearDown(session.dispose);
    await mount(t, session);
    await t.scrollUntilVisible(find.text('运行状态待核对'), 160);
    expect(find.text('运行状态待核对'), findsOneWidget);
    expect(find.textContaining('辅助限制已启用'), findsNothing);
    empty = true;
    await t.tap(find.byTooltip('刷新家庭待办'));
    await t.pumpAndSettle();
    expect(find.textContaining('还没有孩子和设备'), findsOneWidget);
    expect(find.text('当前没有待处理申请'), findsOneWidget);
  });
  testWidgets(
      'background responses stay hidden and old family cannot revive after leaving and returning',
      (t) async {
    final pending = Completer<http.Response>();
    var reads = 0;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      reads++;
      return reads == 1 ? pending.future : jsonResponse(inboxDashboard());
    })));
    addTearDown(session.dispose);
    await t.pumpWidget(MaterialApp(
        theme: familyTheme(), home: FamilyInboxPage(session: session)));
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    pending.complete(jsonResponse(inboxDashboard()));
    await t.pumpAndSettle();
    expect(find.text('小明 · 学习手机'), findsNothing);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(reads, 2);
    await t.scrollUntilVisible(find.text('小明 · 学习手机'), 160);
    expect(find.text('小明 · 学习手机'), findsOneWidget);
    session.leaveAndReturn();
    await t.pumpAndSettle();
    expect(find.text('小明 · 学习手机'), findsNothing);
    expect(find.textContaining('当前家庭或权限已变化'), findsOneWidget);
  });
  testWidgets(
      'inbox supports 320 pixel width and doubled text without overflow',
      (t) async {
    t.view.physicalSize = const Size(320, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => jsonResponse(inboxDashboard()))));
    addTearDown(session.dispose);
    await mount(t, session, scale: 2);
    await t.scrollUntilVisible(find.text('运行状态由儿童设备最近上报，实际效果仍需在设备上核对。'), 180);
    expect(t.takeException(), null);
  });
  testWidgets(
      'home shortcut adds no polling and opens scoped current facts on explicit tap',
      (t) async {
    final paths = <String>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      paths.add(r.url.path);
      return jsonResponse(inboxDashboard());
    })));
    addTearDown(session.dispose);
    await mount(t, session, shortcut: true);
    expect(paths, isEmpty);
    await t.tap(find.byTooltip('消息与待办'));
    await t.pumpAndSettle();
    expect(paths.single, '/tenants/family/family-dashboard');
    expect(find.text('2 项待处理'), findsOneWidget);
  });
  testWidgets(
      'server membership denial on refresh removes old family facts and actions',
      (t) async {
    var authorized = true;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => authorized
            ? jsonResponse(inboxDashboard())
            : jsonResponse({'errorCode': 'SCOPE_DENIED'}, status: 403))));
    addTearDown(session.dispose);
    await mount(t, session);
    expect(find.text('2 项待处理'), findsOneWidget);
    await t.scrollUntilVisible(find.text('小明 · 学习手机'), 160);
    expect(find.text('小明 · 学习手机'), findsOneWidget);
    authorized = false;
    await t.tap(find.byTooltip('刷新家庭待办'));
    await t.pumpAndSettle();
    expect(find.text('小明 · 学习手机'), findsNothing);
    expect(find.text('2 项待处理'), findsNothing);
    expect(find.byKey(const ValueKey('family-inbox-requests')), findsNothing);
    expect(find.text('查看设备名额'), findsNothing);
    expect(find.text('重新读取'), findsOneWidget);
  });
}
