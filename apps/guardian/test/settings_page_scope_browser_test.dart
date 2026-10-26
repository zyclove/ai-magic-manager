@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/settings_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:http/http.dart' as http;

import 'device_management_entry_test.dart' show EntrySession, settleReads, tenantId;

class _SettingsSession extends EntrySession {
  int accounts = 0, verifications = 0, logouts = 0, reloads = 0;

  _SettingsSession(super.handler) {
    profile = {
      'subject': 'adult-a', 'name': '测试监护人',
      'email': 'settings-a@fixture.invalid', 'canCreateTenant': true,
    };
    tenant = {
      ...tenant!, 'name': '原始家庭', 'timeZone': 'Asia/Shanghai', 'version': 7,
    };
  }

  void actorAwayAndBack() {
    profile = {...profile!, 'subject': 'adult-b'};
    notifyListeners();
    profile = {...profile!, 'subject': 'adult-a'};
    notifyListeners();
  }

  void updateVersion() {
    tenant = {...tenant!, 'version': 8};
    notifyListeners();
  }

  @override
  void account() { accounts++; }
  @override
  void login({bool stepUp = false}) {
    expect(stepUp, isTrue);
    verifications++;
  }
  @override
  void logout() { logouts++; }
  @override
  Future<void> loadTenants({String? preferredTenantId}) async { reloads++; }
}

Finder _button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

VoidCallback _held(WidgetTester tester, String label) =>
    tester.widget<ButtonStyleButton>(_button(label)).onPressed!;

http.Response _reply() => http.Response(jsonEncode({
      'id': tenantId, 'name': '已修改家庭', 'timeZone': 'Asia/Shanghai', 'version': 8,
    }), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Widget _host(_SettingsSession session,
        {Key? pageKey, Future<void> Function()? create,
        Future<void> Function()? invite}) =>
    MaterialApp(theme: consoleTheme(), home: Scaffold(
        body: SingleChildScrollView(child: SettingsPage(
            key: pageKey, session: session,
            onCreateWorkspace: create ?? () async {},
            onAcceptInvitation: invite ?? () async {}))));

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('settings account ABA retires every retained action and private value',
      (tester) async {
    _wide(tester);
    final requests = <http.Request>[];
    final session = _SettingsSession((request) async {
      requests.add(request);
      throw StateError('Unexpected request after settings capture was retired.');
    });
    var creations = 0, invitations = 0;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReads(tester);
      session.transport.close();
      session.dispose();
    });
    await tester.pumpWidget(_host(session,
        create: () async { creations++; }, invite: () async { invitations++; }));
    await settleReads(tester);
    final callbacks = [
      for (final label in ['编辑资料', '新建工作空间', '接受邀请',
          '账户与验证器', '重新安全验证', '退出登录']) _held(tester, label),
    ];
    final generation = session.scopeGeneration;
    session.actorAwayAndBack();
    for (final callback in callbacks) { callback(); }
    await settleReads(tester);
    expect(session.scopeGeneration, generation);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    expect(find.text('原始家庭'), findsNothing);
    expect(find.text('settings-a@fixture.invalid'), findsNothing);
    expect(creations, 0);
    expect(invitations, 0);
    expect(session.accounts, 0);
    expect(session.verifications, 0);
    expect(session.logouts, 0);
    expect(session.reloads, 0);
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings edit keeps its version and rejects a late retired response',
      (tester) async {
    _wide(tester);
    final pending = Completer<http.Response>();
    final requests = <http.Request>[];
    final session = _SettingsSession((request) async {
      requests.add(request);
      expect(request.method, 'PATCH');
      expect(request.url.path, '/api/v1/tenants/$tenantId');
      if (requests.length == 1) return pending.future;
      return _reply();
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!pending.isCompleted) pending.complete(_reply());
      await settleReads(tester);
      session.transport.close();
      session.dispose();
    });
    await tester.pumpWidget(_host(session));
    await settleReads(tester);
    // Retire only the page capture while the pushed form has not built yet.
    // No Session notification is available to hide or wake that old form.
    _held(tester, '编辑资料')();
    await tester.pumpWidget(_host(session,
        pageKey: const ValueKey('replaced-before-form-build')));
    await settleReads(tester);
    expect(requests, isEmpty);
    expect(session.reloads, 0);
    expect(find.descendant(of: find.byType(AlertDialog),
        matching: find.byType(TextFormField)), findsNothing);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    expect(tester.takeException(), isNull);
    _held(tester, '关闭')();
    await settleReads(tester);
    _held(tester, '编辑资料')();
    await settleReads(tester);
    final name = find.widgetWithText(TextFormField, '名称');
    await tester.enterText(name, '调整后的家庭');
    session.updateVersion();
    _held(tester, '保存')();
    for (var attempt = 0; attempt < 24 && requests.isEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(requests, hasLength(1));
    expect(requests.single.headers['if-match'], '"7"');
    expect(jsonDecode(requests.single.body),
        {'name': '调整后的家庭', 'timeZone': 'Asia/Shanghai'});
    session.actorAwayAndBack();
    pending.complete(_reply());
    await settleReads(tester);
    expect(session.reloads, 0);
    expect(requests, hasLength(1));
    expect(find.byType(TextFormField), findsNothing);
    _held(tester, '关闭')();
    await settleReads(tester);
    await tester.pumpWidget(_host(session, pageKey: const ValueKey('fresh-settings')));
    await settleReads(tester);
    _held(tester, '编辑资料')();
    await settleReads(tester);
    await tester.enterText(find.widgetWithText(TextFormField, '名称'), '当前家庭');
    _held(tester, '保存')();
    for (var attempt = 0; attempt < 24 && session.reloads != 1; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settleReads(tester);
    expect(requests, hasLength(2));
    expect(requests.last.headers['if-match'], '"8"');
    expect(jsonDecode(requests.last.body),
        {'name': '当前家庭', 'timeZone': 'Asia/Shanghai'});
    expect(session.reloads, 1);
    _held(tester, '账户与验证器')();
    await settleReads(tester);
    expect(session.accounts, 1);
    expect(tester.takeException(), isNull);
  });
}
