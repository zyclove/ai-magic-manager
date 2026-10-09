import 'package:child/ui/observation_section.dart';
import 'package:child/ui/design.dart';
import 'package:device_observation/device_observation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const authorization = ObservationAuthorization(
    deviceId: 'device',
    registrationId: 'registration',
    version: 1,
    inventoryEnabled: false,
    usageEnabled: true,
    updatedAt: 1800000000000);
Widget surface(ObservationSection child) => MaterialApp(
    theme: childTheme(),
    home: Scaffold(
        body: SingleChildScrollView(
            child: Padding(padding: const EdgeInsets.all(20), child: child))));
void main() {
  testWidgets('默认未核对时不显示开启或提供采集入口', (tester) async {
    await tester.pumpWidget(surface(
        ObservationSection(view: const ObservationView(), refresh: () {})));
    expect(find.text('使用情况与隐私'), findsOneWidget);
    expect(find.textContaining('尚未在线核对'), findsOneWidget);
    final button = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '同步已授权数据'));
    expect(button.onPressed, isNull);
    expect(find.text('前往系统设置'), findsNothing);
  });
  testWidgets('管理员允许但系统未授予时明确提示，设置需主动确认', (tester) async {
    var opened = 0;
    await tester.pumpWidget(surface(ObservationSection(
        view: const ObservationView(
            authorization: authorization,
            onlineConfirmed: true,
            platform:
                ObservationPlatformState(usageGranted: false, unlocked: true)),
        openSettings: () => opened++,
        refresh: () {})));
    expect(find.text('系统访问未授予'), findsOneWidget);
    await tester.ensureVisible(find.text('打开系统使用情况访问'));
    await tester.tap(find.text('打开系统使用情况访问'));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.text('前往系统设置'), findsOneWidget);
    await tester.tap(find.text('前往系统设置'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });
  testWidgets('缓存授权不当作当前授权，离线错误可解释', (tester) async {
    await tester.pumpWidget(surface(ObservationSection(
        view: const ObservationView(
            authorization: authorization, pendingReports: 1),
        errorCode: 'CONNECTION_FAILED',
        refresh: () {})));
    expect(find.textContaining('已暂停新采集'), findsOneWidget);
    expect(find.textContaining('等待确认的请求：1'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '同步已授权数据'))
            .onPressed,
        isNull);
  });
  testWidgets('窄屏大字体下授权和隐私说明无溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(surface(ObservationSection(
        view: const ObservationView(
            authorization: authorization,
            onlineConfirmed: true,
            platform:
                ObservationPlatformState(usageGranted: true, unlocked: true)),
        refresh: () {},
        synchronize: () {})));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('系统聚合'), findsWidgets);
  });
}
