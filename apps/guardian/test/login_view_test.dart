import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/login_view.dart';

Widget _host({required VoidCallback onLogin, Object? error, double scale = 1}) =>
    MaterialApp(
        theme: consoleTheme(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: LoginView(onLogin: onLogin, error: error));

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('wide short window keeps login reachable without layout errors',
      (tester) async {
    _viewport(tester, const Size(1440, 320));
    var logins = 0;
    await tester.pumpWidget(_host(onLogin: () => logins++));
    expect(tester.takeException(), isNull);
    expect(find.text('让每一次数字探索，\n都有安心的陪伴。'), findsOneWidget);
    await tester.ensureVisible(find.text('安全登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('安全登录'));
    expect(logins, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text in a short desktop window can reach both pane ends',
      (tester) async {
    _viewport(tester, const Size(1024, 400));
    var logins = 0;
    await tester.pumpWidget(_host(onLogin: () => logins++, scale: 1.8));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('AI MANAGER  /  家庭与教育设备管理'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('统一身份认证 · 按工作空间授权'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('安全登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('安全登录'));
    expect(logins, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow window and large text keep the primary login usable',
      (tester) async {
    _viewport(tester, const Size(320, 568));
    var logins = 0;
    await tester.pumpWidget(_host(onLogin: () => logins++, scale: 1.6));
    expect(find.text('让每一次数字探索，\n都有安心的陪伴。'), findsNothing);
    await tester.ensureVisible(find.text('安全登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('安全登录'));
    expect(logins, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login remains reachable after opening error details',
      (tester) async {
    _viewport(tester, const Size(320, 360));
    var logins = 0;
    await tester.pumpWidget(_host(
        onLogin: () => logins++,
        scale: 1.4,
        error: const ApiFailure(401, 'LOGIN_STATE_EXPIRED', 'login-trace')));
    expect(find.byType(SelectableText, skipOffstage: false), findsNothing);
    await tester.ensureVisible(find.text('错误详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('错误详情'));
    await tester.pumpAndSettle();
    expect(
        find.byWidgetPredicate((widget) =>
            widget is SelectableText &&
            widget.data == '错误代码：LOGIN_STATE_EXPIRED'),
        findsOneWidget);
    await tester.ensureVisible(find.text('安全登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('安全登录'));
    expect(logins, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard traversal activates login exactly once', (tester) async {
    _viewport(tester, const Size(1440, 320));
    var logins = 0;
    await tester.pumpWidget(_host(onLogin: () => logins++));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(logins, 1);
    expect(tester.takeException(), isNull);
  });
}
