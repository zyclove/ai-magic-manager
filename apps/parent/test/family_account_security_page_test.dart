import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/family_account_security.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/family_account_security_page.dart';
import 'package:parent/ui/family_workspace.dart';

import 'family_account_security_test.dart';

bool _fixtureFontsLoaded = false;
ThemeData _fixtureTheme() => !_fixtureFontsLoaded
    ? familyTheme()
    : familyTheme().copyWith(
        textTheme:
            familyTheme().textTheme.apply(fontFamily: 'AccountChineseFixture'),
        primaryTextTheme: familyTheme()
            .primaryTextTheme
            .apply(fontFamily: 'AccountChineseFixture'));

class _AccountSession extends ParentSession {
  bool loggedIn;
  _AccountSession({this.loggedIn = true}) {
    profile = loggedIn ? {'subject': 'adult'} : null;
  }
  @override
  bool get authenticated => loggedIn;
  void switchAccount() {
    profile = {'subject': 'other-adult'};
    generation++;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!kIsWeb) {
      final chinese = File('C:/Windows/Fonts/msyh.ttc');
      if (await chinese.exists()) {
        final font = FontLoader('AccountChineseFixture')
          ..addFont(
              Future.value(ByteData.sublistView(await chinese.readAsBytes())));
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        _fixtureFontsLoaded = true;
      }
    }
  });
  testWidgets('account actions fit a 320 wide screen at twice the text size',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = _AccountSession();
    final controller = FamilyAccountSecurityCoordinator(
        api: accountApi(
            (_) async => http.Response(jsonEncode(accountStatus()), 200)),
        identity: () => const FamilyAccountIdentity('adult', 0, true),
        storage: AccountMemoryStorage(),
        runAction: (
                {required action,
                required operationId,
                expectedRevision,
                expectedActor}) async =>
            false);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: _fixtureTheme(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: FamilyAccountSecurityPage(
            session: session, coordinator: controller)));
    await tester.pumpAndSettle();
    expect(find.text('138****1234'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('解绑微信'), 250);
    expect(tester.takeException(), isNull);
    final button = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('解绑微信'), matching: find.byType(OutlinedButton)));
    expect(button.onPressed, isNotNull);
    expect(
        tester
            .getSize(find.ancestor(
                of: find.text('解绑微信'), matching: find.byType(OutlinedButton)))
            .height,
        greaterThanOrEqualTo(48));
  });

  testWidgets(
      'revoked session offers login rather than an unusable refresh loop',
      (tester) async {
    final session = _AccountSession();
    final controller = FamilyAccountSecurityCoordinator(
        api: accountApi((_) async =>
            http.Response('{"errorCode":"CONSUMER_SESSION_STALE"}', 401)),
        identity: () => const FamilyAccountIdentity('adult', 0, true),
        storage: AccountMemoryStorage(),
        runAction: (
                {required action,
                required operationId,
                expectedRevision,
                expectedActor}) async =>
            false);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: _fixtureTheme(),
        home: FamilyAccountSecurityPage(
            session: session, coordinator: controller)));
    await tester.pumpAndSettle();
    expect(find.text('重新登录'), findsOneWidget);
    expect(find.text('更换手机号'), findsNothing);
    expect(find.textContaining('登录状态已变化'), findsOneWidget);
  });

  testWidgets('canceled secure browser keeps the original operation for lookup',
      (tester) async {
    final session = _AccountSession();
    var calls = 0;
    final controller = FamilyAccountSecurityCoordinator(
        api: accountApi(
            (_) async => http.Response(jsonEncode(accountStatus()), 200)),
        identity: () => const FamilyAccountIdentity('adult', 0, true),
        storage: AccountMemoryStorage(),
        runAction: (
            {required action,
            required operationId,
            expectedRevision,
            expectedActor}) async {
          calls++;
          return false;
        });
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: _fixtureTheme(),
        home: FamilyAccountSecurityPage(
            session: session, coordinator: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更换手机号'));
    await tester.pumpAndSettle();
    expect(find.textContaining('家庭、设备、订单和会员保留'), findsOneWidget);
    await tester.tap(find.text('验证并继续'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('上次操作的结果还需核对'), findsOneWidget);
    expect(find.textContaining('手机号已更换'), findsNothing);
    expect(find.text('已核对当前账号，结束本次操作'), findsNothing);
  });

  testWidgets('recovery explains both existing methods and no-credential help',
      (tester) async {
    final session = _AccountSession(loggedIn: false);
    final controller = FamilyAccountSecurityCoordinator(
        api: accountApi(
            (_) async => throw StateError('must not read while signed out')),
        identity: () => const FamilyAccountIdentity(null, 0, false),
        storage: AccountMemoryStorage(),
        recoveryAvailable: false,
        runAction: (
                {required action,
                required operationId,
                expectedRevision,
                expectedActor}) async =>
            false);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: _fixtureTheme(),
        home: FamilyAccountRecoveryPage(
            session: session, coordinator: controller)));
    await tester.pumpAndSettle();
    expect(find.text('原手机号还能收短信'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('用已绑定微信找回'), 150);
    expect(
        tester
            .widget<OutlinedButton>(find.ancestor(
                of: find.text('用已绑定微信找回'),
                matching: find.byType(OutlinedButton)))
            .onPressed,
        isNull);
    await tester.scrollUntilVisible(find.textContaining('不要发送验证码或密码'), 150);
    expect(find.textContaining('不要发送验证码或密码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final unavailable in [false, true]) {
    testWidgets(
        unavailable
            ? 'unavailable service keeps account actions disabled'
            : 'unbound account offers bind rather than unlink', (tester) async {
      final data = {
        ...accountStatus(),
        'wechatBound': false,
        'canBindWechat': !unavailable,
        'canUnbindWechat': false,
        'canRecoverByWechat': false,
        'canChangePhone': !unavailable,
        'accountSecurityAvailable': !unavailable
      };
      final session = _AccountSession();
      final controller = FamilyAccountSecurityCoordinator(
          api: accountApi((_) async => http.Response(jsonEncode(data), 200)),
          identity: () => const FamilyAccountIdentity('adult', 0, true),
          storage: AccountMemoryStorage(),
          runAction: (
                  {required action,
                  required operationId,
                  expectedRevision,
                  expectedActor}) async =>
              false);
      addTearDown(session.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
          theme: _fixtureTheme(),
          home: FamilyAccountSecurityPage(
              session: session, coordinator: controller)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('绑定微信'), 150);
      expect(find.text('解绑微信'), findsNothing);
      final button = tester.widget<OutlinedButton>(find.ancestor(
          of: find.text('绑定微信'), matching: find.byType(OutlinedButton)));
      expect(button.onPressed, unavailable ? isNull : isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('changing account dismisses an obsolete security confirmation',
      (tester) async {
    final session = _AccountSession();
    var calls = 0;
    final controller = FamilyAccountSecurityCoordinator(
        api: accountApi(
            (_) async => http.Response(jsonEncode(accountStatus()), 200)),
        identity: () => FamilyAccountIdentity(
            session.profile?['subject'] as String?,
            session.generation,
            session.authenticated),
        storage: AccountMemoryStorage(),
        runAction: (
            {required action,
            required operationId,
            expectedRevision,
            expectedActor}) async {
          calls++;
          return true;
        });
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: _fixtureTheme(),
        home: FamilyAccountSecurityPage(
            session: session, coordinator: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更换手机号'));
    await tester.pumpAndSettle();
    expect(find.text('验证并继续'), findsOneWidget);
    session.switchAccount();
    await tester.pumpAndSettle();
    expect(find.text('验证并继续'), findsNothing);
    expect(calls, 0);
  });

  testWidgets('capture a clearly fictional account security screen',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = _AccountSession();
    final boundary = GlobalKey();
    final controller = FamilyAccountSecurityCoordinator(
        api: accountApi(
            (_) async => http.Response(jsonEncode(accountStatus()), 200)),
        identity: () => const FamilyAccountIdentity('adult', 0, true),
        storage: AccountMemoryStorage(),
        runAction: (
                {required action,
                required operationId,
                expectedRevision,
                expectedActor}) async =>
            false);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
            theme: _fixtureTheme(),
            builder: (context, child) => Column(children: [
                  const Material(
                      color: Color(0xFFEAF1F5),
                      child: SizedBox(
                          width: double.infinity,
                          height: 30,
                          child: Center(child: Text('界面验证 · 虚构示例账号')))),
                  Expanded(child: child!),
                ]),
            home: FamilyAccountSecurityPage(
                session: session, coordinator: controller))));
    await tester.pumpAndSettle();
    if (const bool.fromEnvironment('CAPTURE_ACCOUNT_SECURITY')) {
      await tester.runAsync(() async {
        final frame = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File(
                'D:/codes/mobile/ai-manager/.local/family-p0-account-security-20261016/account-security-fictional.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        frame.dispose();
      });
    }
    expect(tester.takeException(), isNull);
  });
}
