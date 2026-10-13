import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:usage_report_ui/usage_report_ui.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'fixture.dart';
import 'device_view_test.dart' show result;

const second = UsageReportTarget('44444444-4444-4444-4444-444444444444',
    '55555555-5555-5555-5555-555555555555', subject, '卧室电视',
    platform: 'ANDROID_TV');
UsageReport multi(DeviceReportWindow window,
    {String status = 'NOT_AUTHORIZED', String? registrationOverride}) {
  final single = result(window), d = single.devices.single;
  return UsageReport(
      single.generatedAt,
      single.from,
      single.to,
      single.timeZone,
      single.period,
      [
        d,
        UsageReportDevice(
            second.deviceId,
            registrationOverride ?? second.registrationId,
            second.subjectId,
            second.displayName,
            status,
            0,
            d.retentionFrom,
            0,
            const [],
            null,
            null,
            0,
            single.to - single.from,
            const [],
            d.configurationState)
      ],
      const UsageReportScope.devices());
}

void main() {
  testWidgets('phone device switcher stays readable with large text',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const font = String.fromEnvironment('UI_CAPTURE_FONT'),
        icons = String.fromEnvironment('UI_CAPTURE_ICONS');
    for (final entry
        in {'LocalCaptureFont': font, 'MaterialIcons': icons}.entries) {
      if (entry.value.isNotEmpty) {
        await tester.runAsync(() async {
          final data = await File(entry.value).readAsBytes();
          await (FontLoader(entry.key)
                ..addFont(Future.value(ByteData.sublistView(data))))
              .load();
        });
      }
    }
    final scope = ValueNotifier(true), boundary = GlobalKey();
    addTearDown(scope.dispose);
    await tester.pumpWidget(RepaintBoundary(
        key: boundary,
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
            home: Scaffold(
                appBar: AppBar(title: const Text('所选设备报告')),
                body: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: DeviceUsageReportView(
                        targets: const [target, second],
                        accessChanges: scope,
                        available: () => true,
                        load: (w) async => multi(w),
                        cancel: () {},
                        title: '多设备使用情况',
                        timeZone: 'UTC',
                        now: () =>
                            DateTime.fromMillisecondsSinceEpoch(now)))))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('report-device-picker')));
    await tester.tap(find.byKey(const Key('report-device-picker')));
    await tester.pumpAndSettle();
    expect(find.text('卧室电视'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_MULTI_REPORT_UI')) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/parent-multi-report-switcher.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('卧室电视'));
    await tester.pumpAndSettle();
    expect(find.text('使用观察尚未授权'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  Future<void> mount(WidgetTester tester,
      Future<UsageReport> Function(DeviceReportWindow) load,
      {List<UsageReportTarget>? targets = const [target, second],
      ValueNotifier<bool>? access,
      VoidCallback? cancel}) async {
    final scope = access ?? ValueNotifier(true);
    if (access == null) addTearDown(scope.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: DeviceUsageReportView(
                    targets: targets,
                    accessChanges: scope,
                    available: () => scope.value,
                    load: load,
                    cancel: cancel ?? () {},
                    timeZone: 'UTC',
                    now: () => DateTime.fromMillisecondsSinceEpoch(now))))));
    await tester.pump();
  }

  testWidgets(
      'explicit devices show status overview and switch without summing usage',
      (tester) async {
    var queries = 0;
    await mount(tester, (window) async {
      queries++;
      return multi(window);
    });
    await tester.pumpAndSettle();
    expect(find.text('设备概览 · 2 台'), findsOneWidget);
    expect(find.textContaining('有记录 1 台 · 暂无数据 0 台 · 未授权 1 台'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('report-device-picker')));
    await tester.tap(find.byKey(const Key('report-device-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('卧室电视'));
    await tester.pumpAndSettle();
    expect(find.text('使用观察尚未授权'), findsOneWidget);
    expect(find.textContaining('阅读'), findsNothing);
    expect(find.text('0 分钟'), findsNothing);
    expect(queries, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('child host still refuses a multi-device response',
      (tester) async {
    await mount(tester, (window) async => multi(window), targets: null);
    await tester.pumpAndSettle();
    expect(find.text('未能读取报表'), findsOneWidget);
    expect(find.text('设备概览 · 2 台'), findsNothing);
  });
  testWidgets('wrong registration in any device rejects the complete result',
      (tester) async {
    await mount(tester,
        (window) async => multi(window, registrationOverride: registration));
    await tester.pumpAndSettle();
    expect(find.text('未能读取报表'), findsOneWidget);
    expect(find.textContaining('阅读'), findsNothing);
  });
  testWidgets(
      'background closes private device dialog and requires explicit reload',
      (tester) async {
    var cancelled = 0, requests = 0;
    await mount(tester, (window) async {
      requests++;
      return multi(window);
    }, cancel: () => cancelled++);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('report-device-picker')));
    await tester.tap(find.byKey(const Key('report-device-picker')));
    await tester.pumpAndSettle();
    expect(find.text('卧室电视'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('卧室电视'), findsNothing);
    expect(cancelled, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('设备概览 · 2 台'), findsNothing);
    expect(requests, 1);
  });
  testWidgets('changing explicit scope invalidates a pending response',
      (tester) async {
    final pending = Completer<UsageReport>(), access = ValueNotifier(true);
    addTearDown(access.dispose);
    DeviceReportWindow? window;
    await mount(tester, (w) {
      window = w;
      return pending.future;
    }, access: access);
    await mount(tester, (w) async => result(w),
        access: access, targets: const [target]);
    pending.complete(multi(window!));
    await tester.pumpAndSettle();
    expect(find.text('设备概览 · 2 台'), findsNothing);
    expect(find.textContaining('阅读'), findsNothing);
    expect(find.text('尚未读取当前条件'), findsOneWidget);
  });
  testWidgets('invalid explicit selection never invokes the loader',
      (tester) async {
    var calls = 0;
    await mount(tester, (w) async {
      calls++;
      return result(w);
    }, targets: const [target, target]);
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('未能读取报表'), findsOneWidget);
  });
}
