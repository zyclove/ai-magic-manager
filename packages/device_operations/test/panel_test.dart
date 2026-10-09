import 'package:device_operations/device_operations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'controller_test.dart'
    show TestGateway, TestJournal, makeController, ready;
import 'fixtures.dart';

Widget host(ExitController c,
        {double scale = 1, Future<void> Function()? reauthenticate}) =>
    MaterialApp(
        theme: ThemeData(
            useMaterial3: true,
            colorScheme:
                ColorScheme.fromSeed(seedColor: const Color(0xFF19335C))),
        home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
                body: SingleChildScrollView(
                    child: DeviceExitPanel(
                        controller: c,
                        deviceName: '学习平板',
                        reauthenticate: reauthenticate)))));

void main() {
  testWidgets('HTTP 401 offers verification without automatically replaying',
      (tester) async {
    var verified = 0;
    final api = TestGateway()
      ..confirmFailure = const ExitFailure('AUTHENTICATION_REQUIRED', '需要登录',
          status: 401, outcomeUnknown: true);
    final c = makeController(api, TestJournal());
    await ready(c);
    await c.confirm();
    await tester.pumpWidget(host(c, reauthenticate: () async {
      verified++;
    }));
    expect(find.text('重新安全验证'), findsOneWidget);
    await tester.ensureVisible(find.text('重新安全验证'));
    await tester.tap(find.text('重新安全验证'));
    await tester.pump();
    expect(verified, 1);
    expect(api.confirms, 1);
    expect(c.pending, isNotNull);
  });
  testWidgets('preview is readable and confirmation requires checkbox',
      (tester) async {
    final c = makeController(TestGateway(), TestJournal());
    await c.initialize();
    await c.prepare();
    await tester.pumpWidget(host(c));
    expect(find.text('退出设备管理'), findsOneWidget);
    expect(find.text('不擦除整机'), findsOneWidget);
    var button =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认退出'));
    expect(button.onPressed, null);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    button =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认退出'));
    expect(button.onPressed, isNotNull);
  });
  testWidgets(
      'uncertain outcome offers reconciliation instead of another confirm',
      (tester) async {
    final api = TestGateway()
      ..confirmFailure =
          const ExitFailure('NETWORK_TIMEOUT', '连接超时', outcomeUnknown: true);
    final c = makeController(api, TestJournal());
    await ready(c);
    await c.confirm();
    await tester.pumpWidget(host(c));
    expect(find.text('提交结果待确认'), findsOneWidget);
    expect(find.text('核对上次提交'), findsOneWidget);
    expect(find.text('确认退出'), findsNothing);
  });
  testWidgets('reported cleanup never becomes verified erasure',
      (tester) async {
    final api = TestGateway()
      ..operationData = operationJson(state: 'CLEANUP_REPORTED', version: 3);
    final c = makeController(api, TestJournal());
    await ready(c);
    await c.confirm();
    await tester.pumpWidget(host(c));
    expect(find.text('设备自报已清理（未独立验证）'), findsOneWidget);
    expect(find.text('已擦除'), findsNothing);
    expect(find.text('取消清理任务'), findsNothing);
  });
  testWidgets('narrow layout with large text has no overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = makeController(TestGateway(), TestJournal());
    await ready(c);
    await tester.pumpWidget(host(c, scale: 1.8));
    await tester.pump();
    expect(tester.takeException(), null);
  });
  testWidgets('unknown consequences do not expose destructive confirmation',
      (tester) async {
    final api = TestGateway()
      ..previewData = {
        ...previewJson(),
        'consequences': ['NEW_UNSUPPORTED_ACTION']
      };
    final c = makeController(api, TestJournal());
    await ready(c);
    await tester.pumpWidget(host(c));
    expect(find.text('设备能力已变化，请更新客户端或联系管理员。'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('确认退出'), findsNothing);
  });
}
