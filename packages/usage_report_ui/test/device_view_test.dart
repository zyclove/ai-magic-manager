import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:usage_report_ui/usage_report_ui.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'fixture.dart';

UsageReport result(DeviceReportWindow window, {String status = 'OBSERVED'}) {
  final value = reportFixture();
  final end = window.to < now ? window.to : now;
  value.addAll({
    'from': window.from,
    'to': end,
    'requestedTo': window.to,
    'timeZone': window.timeZone,
    'period': window.period
  });
  final d = value['devices'][0];
  d['queryCoverageMillis'] = end - window.from;
  var cursor = window.from;
  final buckets = <ReportJson>[];
  while (cursor < end) {
    final local = usageLocalTime(cursor, window.timeZone);
    final day = DateTime(local.year, local.month, local.day);
    final last = window.period == 'WEEK'
        ? day.add(Duration(days: 7 - local.weekday))
        : day;
    final boundary = usageCalendarWindow(day, last, window.timeZone).$2;
    final stop = boundary < end ? boundary : end;
    buckets.add({
      'start': cursor,
      'end': stop,
      'lowerMillis': 1000,
      'upperMillis': 2000,
      'coveredMillis': stop - cursor - 1000,
      'status': 'REPORTED_RANGE'
    });
    cursor = stop;
  }
  d['applications'][0]['buckets'] = buckets;
  d['status'] = status;
  if (status != 'OBSERVED') {
    d.addAll({
      'applications': [],
      'sourceBatchCount': 0,
      'sourceTimeZones': [],
      'latestObservedAt': null,
      'latestReceivedAt': null,
      'queryCoverageMillis': 0,
      'uncoveredQueryMillis': end - window.from
    });
  }
  return UsageReport.parse(
      value,
      UsageReportQuery(
          targets: [target],
          from: window.from,
          to: window.to,
          timeZone: window.timeZone,
          period: window.period));
}

void main() {
  Future<void> mount(WidgetTester tester,
      Future<UsageReport> Function(DeviceReportWindow) load,
      {ValueNotifier<bool>? access, VoidCallback? cancel}) async {
    final permitted = access ?? ValueNotifier(true);
    if (access == null) addTearDown(permitted.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
            body: SingleChildScrollView(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: DeviceUsageReportView(
                        accessChanges: permitted,
                        available: () => permitted.value,
                        load: load,
                        cancel: cancel ?? () {},
                        timeZone: 'UTC',
                        now: () =>
                            DateTime.fromMillisecondsSinceEpoch(now)))))));
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  testWidgets('mobile view loads own report and exposes source and range',
      (t) async {
    await mount(t, (w) async => result(w));
    await t.pumpAndSettle();
    expect(find.text('我的使用情况'), findsOneWidget);
    expect(find.textContaining('更新于'), findsOneWidget);
    await t.ensureVisible(find.text('应用与系统资料'));
    await t.pumpAndSettle();
    expect(find.textContaining('阅读'), findsWidgets);
    expect(find.text('使用趋势'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('failure removes stale usage and retry preserves exact window',
      (t) async {
    final calls = <DeviceReportWindow>[];
    await mount(t, (w) async {
      calls.add(w);
      if (calls.length == 2) {
        throw const UsageReportFailure(0, 'CONNECTION_FAILED');
      }
      return result(w);
    });
    await t.pumpAndSettle();
    await tap(t, const Key('report-query'));
    expect(find.textContaining('阅读'), findsNothing);
    expect(find.textContaining('无法连接'), findsOneWidget);
    await tap(t, const Key('report-retry'));
    expect(calls[2].from, calls[1].from);
    expect(calls[2].to, calls[1].to);
    expect(calls[2].timeZone, calls[1].timeZone);
    expect(calls[2].period, calls[1].period);
  });
  testWidgets('access loss closes date dialog and clears private data',
      (t) async {
    final access = ValueNotifier(true);
    addTearDown(access.dispose);
    await mount(t, (w) async => result(w), access: access);
    await t.pumpAndSettle();
    await tap(t, const Key('report-dates'));
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    access.value = false;
    await t.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsNothing);
    expect(find.textContaining('阅读'), findsNothing);
    expect(find.text('报表暂不可用'), findsOneWidget);
  });
  testWidgets('background cancels pending reads and ignores late response',
      (t) async {
    final pending = Completer<UsageReport>();
    DeviceReportWindow? query;
    var cancelled = 0;
    await mount(t, (w) {
      query = w;
      return pending.future;
    }, cancel: () => cancelled++);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    pending.complete(result(query!));
    await t.pumpAndSettle();
    expect(cancelled, greaterThan(0));
    expect(find.textContaining('阅读'), findsNothing);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(find.textContaining('阅读'), findsNothing);
  });
  testWidgets(
      'period changes require fresh data and unknown zones stay in editor',
      (t) async {
    final calls = <DeviceReportWindow>[];
    await mount(t, (w) async {
      calls.add(w);
      return result(w);
    });
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('周'));
    await t.tap(find.text('周'));
    await t.pumpAndSettle();
    expect(find.textContaining('阅读'), findsNothing);
    await tap(t, const Key('report-query'));
    expect(calls.last.period, 'WEEK');
    await tap(t, const Key('report-timezone'));
    await t.enterText(
        find.byKey(const Key('report-zone-input')), 'Invalid/Zone');
    await t.tap(find.text('使用此时区'));
    await t.pumpAndSettle();
    expect(find.text('请输入有效的 IANA 时区'), findsOneWidget);
  });
  testWidgets(
      'category filter is local and losing access closes private app picker',
      (t) async {
    final access = ValueNotifier(true);
    addTearDown(access.dispose);
    var requests = 0;
    await mount(t, (w) async {
      requests++;
      return result(w);
    }, access: access);
    await t.pumpAndSettle();
    await t.ensureVisible(find.byType(DropdownButtonFormField<String>));
    await t.tap(find.text('全部类别'));
    await t.pumpAndSettle();
    await t.tap(find.text('游戏').last);
    await t.pumpAndSettle();
    expect(find.text('该类别暂无匹配应用'), findsOneWidget);
    expect(requests, 1);
    await t.tap(find.text('游戏').first);
    await t.pumpAndSettle();
    await t.tap(find.text('全部类别').last);
    await t.pumpAndSettle();
    final selected = find.widgetWithText(OutlinedButton, '阅读 · 主空间');
    await t.ensureVisible(selected);
    await t.tap(selected);
    await t.pumpAndSettle();
    expect(find.text('选择应用'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'not-present');
    await t.pumpAndSettle();
    expect(find.text('没有匹配的应用'), findsOneWidget);
    expect(requests, 1);
    access.value = false;
    await t.pumpAndSettle();
    expect(find.text('选择应用'), findsNothing);
    expect(find.textContaining('阅读'), findsNothing);
  });
  for (final state in ['NO_DATA', 'NOT_AUTHORIZED']) {
    testWidgets('$state is distinct from zero usage', (t) async {
      await mount(t, (w) async => result(w, status: state));
      await t.pumpAndSettle();
      expect(find.text(state == 'NO_DATA' ? '暂无使用记录' : '使用观察尚未授权'),
          findsOneWidget);
      expect(find.text('使用趋势'), findsNothing);
    });
  }
}
