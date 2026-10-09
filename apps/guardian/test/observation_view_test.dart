import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/observation.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/observation_view.dart';
import 'observation_model_test.dart' as fixtures;

ObservationSnapshot snapshot({bool enabled = true, bool rows = false}) =>
    ObservationSnapshot(
        ManagedObservationSettings.parse(fixtures.settings(enabled: enabled),
            deviceId: fixtures.device, registrationId: fixtures.registration),
        rows
            ? [
                ObservedUsageBatch.parse(
                    fixtures.batch(9), fixtures.registration)
              ]
            : [],
        null);
void main() {
  testWidgets('aggregate row exposes one explicit readable accessibility label',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(
          theme: consoleTheme(),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: ObservationView(
                      deviceName: '学习平板', snapshot: snapshot(rows: true))))));
      await tester.ensureVisible(find.text('报告 #9 · 1 条聚合'));
      await tester.tap(find.text('报告 #9 · 1 条聚合'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'阅读，org\.example\.reader，前台 2 分钟')),
          findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });
  testWidgets(
      'disabled observation distinguishes no consent from no installed apps',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: ObservationView(
                    deviceName: '学习平板', snapshot: snapshot(enabled: false))))));
    expect(find.text('使用摘要未授权'), findsOneWidget);
    expect(find.textContaining('不能据此判断没有使用应用'), findsOneWidget);
    expect(find.text('修改观察授权'), findsNothing);
  });
  testWidgets(
      'batch presents actual bins and unverified evidence without daily total',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: ObservationView(
                    deviceName: '学习平板', snapshot: snapshot(rows: true))))));
    expect(find.textContaining('系统聚合'), findsWidgets);
    expect(find.textContaining('设备自报，尚未验证'), findsWidgets);
    expect(find.textContaining('今日总计'), findsNothing);
    await tester.ensureVisible(find.text('报告 #9 · 1 条聚合'));
    await tester.tap(find.text('报告 #9 · 1 条聚合'));
    await tester.pumpAndSettle();
    expect(find.text('阅读'), findsOneWidget);
    expect(find.textContaining('120'), findsNothing);
    expect(find.text('前台 2 分钟'), findsOneWidget);
    expect(find.textContaining('实际系统区间'), findsWidgets);
  });
  testWidgets(
      'malformed response hides rows and offers fresh load without raw details',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: ObservationView(
                    deviceName: '学习平板',
                    error:
                        const ApiFailure(502, 'INVALID_OBSERVATION_RESPONSE'),
                    refresh: () {})))));
    expect(find.textContaining('未通过校验'), findsOneWidget);
    expect(find.text('刷新状态'), findsOneWidget);
    expect(find.textContaining('报告 #'), findsNothing);
  });
  testWidgets('small screen large text does not overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(320, 740), textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
                body: SingleChildScrollView(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: ObservationView(
                            deviceName: '机构配发学习平板',
                            snapshot: snapshot(rows: true),
                            canEdit: true,
                            edit: () {},
                            refresh: () {})))))));
    expect(tester.takeException(), isNull);
    expect(find.text('修改观察授权'), findsOneWidget);
  });
}
