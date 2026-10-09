import 'package:child/ui/child_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/identity_fixture.dart';

void main() {
  testWidgets('pending credential rotation is visible and can be completed',
      (tester) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    await fixture.identity.rotate();
    await tester.pumpWidget(
        ChildApp(session: fixture.session(), nativeAvailable: true));
    await tester.pumpAndSettle();
    expect(find.text('连接更新待完成'), findsOneWidget);
    await tester.ensureVisible(find.text('完成连接更新'));
    await tester.tap(find.text('完成连接更新'));
    await tester.pumpAndSettle();
    expect(find.text('设备身份已确认'), findsOneWidget);
    expect(fixture.calls, 4);
    expect(tester.takeException(), isNull);
  });
  testWidgets('expired credential is not shown as a healthy connection',
      (tester) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    fixture.clock = IdentityFixture.now + 86400001;
    await tester.pumpWidget(
        ChildApp(session: fixture.session(), nativeAvailable: true));
    await tester.pumpAndSettle();
    expect(find.text('连接需要检查'), findsOneWidget);
    expect(find.text('设备身份已确认'), findsNothing);
    expect(fixture.calls, 2);
  });
  testWidgets('failed storage read offers retry instead of fresh registration',
      (tester) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    fixture.secrets.failRead = true;
    await tester.pumpWidget(
        ChildApp(session: fixture.session(), nativeAvailable: true));
    await tester.pumpAndSettle();
    expect(find.text('设备身份暂不可用'), findsOneWidget);
    expect(find.text('安全连接'), findsNothing);
    fixture.secrets.failRead = false;
    await tester.ensureVisible(find.text('重新读取状态'));
    await tester.tap(find.text('重新读取状态'));
    await tester.pumpAndSettle();
    expect(find.text('安全连接'), findsOneWidget);
    expect(fixture.calls, 0);
  });
  testWidgets('unconfigured installation explains the boundary and help opens',
      (tester) async {
    await tester.pumpWidget(const ChildApp());
    expect(find.text('设备端尚未配置'), findsOneWidget);
    await tester.tap(find.text('查看连接帮助'));
    await tester.pumpAndSettle();
    expect(find.text('连接设备需要监护人'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('连接设备需要监护人'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('narrow layout supports increased text and keyboard focus',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const ChildApp());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'form validates locally then actual identity component shows physical pairing',
      (tester) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await tester.pumpWidget(ChildApp(
        session: fixture.session(),
        nativeAvailable: true,
        serviceLabel: 'https://service.example/api/v1'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('安全连接'));
    await tester.tap(find.text('安全连接'));
    await tester.pumpAndSettle();
    expect(find.text('请输入设备名称'), findsOneWidget);
    expect(fixture.calls, 0);
    await tester.enterText(find.byType(TextFormField).at(0), '我的手机');
    await tester.enterText(find.byType(TextFormField).at(1), fixture.ticket);
    await tester.ensureVisible(find.text('安全连接'));
    await tester.tap(find.text('安全连接'));
    await tester.pumpAndSettle();
    expect(find.text('等待监护人确认'), findsOneWidget);
    expect(find.text('1234 5678'), findsOneWidget);
    expect(find.textContaining('系统管控能力'), findsOneWidget);
    expect(fixture.calls, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'guardian confirmation becomes connected; rule and help routes remain honest',
      (tester) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.pair();
    await tester.pumpWidget(
        ChildApp(session: fixture.session(), nativeAvailable: true));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('检查确认状态'));
    await tester.tap(find.text('检查确认状态'));
    await tester.pumpAndSettle();
    expect(find.textContaining('监护人尚未完成确认'), findsOneWidget);
    fixture.confirmed = true;
    await tester.ensureVisible(find.text('检查确认状态'));
    await tester.tap(find.text('检查确认状态'));
    await tester.pumpAndSettle();
    expect(find.text('我的设备'), findsOneWidget);
    await tester.tap(find.text('规则'));
    await tester.pumpAndSettle();
    expect(find.text('我的规则'), findsOneWidget);
    expect(find.textContaining('收到配置不代表'), findsOneWidget);
    await tester.tap(find.text('帮助'));
    await tester.pumpAndSettle();
    expect(find.text('设备帮助'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'unknown claim result offers original-key recovery, never another registration',
      (tester) async {
    final fixture = IdentityFixture()..loseClaim = true;
    addTearDown(fixture.close);
    final session = fixture.session();
    await session.initialize();
    await session.pair(fixture.ticket,
        displayName: '我的手机', osVersion: 'Android');
    await tester.pumpWidget(ChildApp(session: session, nativeAvailable: true));
    await tester.pumpAndSettle();
    expect(find.text('继续设备连接'), findsOneWidget);
    expect(find.text('安全连接'), findsNothing);
    await tester.ensureVisible(find.text('恢复原连接'));
    await tester.tap(find.text('恢复原连接'));
    await tester.pumpAndSettle();
    expect(find.text('等待监护人确认'), findsOneWidget);
    expect(fixture.calls, 2);
  });
  testWidgets(
      'active authentication rejection is not displayed as a healthy connection',
      (tester) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    await tester.pumpWidget(
        ChildApp(session: fixture.session(), nativeAvailable: true));
    await tester.pumpAndSettle();
    fixture.rejectAuthentication = true;
    await tester.ensureVisible(find.text('检查连接'));
    await tester.tap(find.text('检查连接'));
    await tester.pumpAndSettle();
    expect(find.text('连接需要检查'), findsOneWidget);
    expect(await fixture.identity.activeCredential(), isNull);
  });
  testWidgets(
      'remote select activates the focused help action on a wide display',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ChildApp());
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('连接设备需要监护人'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
