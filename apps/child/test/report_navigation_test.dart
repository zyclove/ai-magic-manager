import 'dart:async';
import 'package:child/core/report_loader.dart';
import 'package:child/ui/child_app.dart';
import 'package:device_reports/device_reports.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:usage_report_ui/usage_report_ui.dart';
import 'support/identity_fixture.dart';

UsageReport emptyReport(DeviceReportWindow window) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final end = window.to < now ? window.to : now;
  const target = UsageReportTarget(
      IdentityFixture.device,
      IdentityFixture.registration,
      '55555555-5555-5555-5555-555555555555',
      '我的手机');
  return UsageReport.parse(
      {
        'schemaVersion': 1,
        'scope': {'kind': 'DEVICES', 'id': null, 'version': null},
        'generatedAt': now,
        'from': window.from,
        'to': end,
        'requestedTo': window.to,
        'timeZone': window.timeZone,
        'period': window.period,
        'precision': 'OS_AGGREGATE',
        'evidenceStatus': 'AGENT_REPORTED_UNVERIFIED',
        'devices': [
          {
            'deviceId': target.deviceId,
            'registrationId': target.registrationId,
            'subjectId': target.subjectId,
            'displayName': '我的手机',
            'status': 'NO_DATA',
            'authorizationVersion': 1,
            'retentionFrom': now - 30 * 86400000,
            'sourceBatchCount': 0,
            'sourceTimeZones': [],
            'latestObservedAt': null,
            'latestReceivedAt': null,
            'queryCoverageMillis': 0,
            'uncoveredQueryMillis': end - window.from,
            'applications': [],
            'configurationState': {
              'checkedAt': now,
              'evidenceStatus': 'DELIVERY_ONLY_NOT_EXECUTION',
              'configurations': []
            },
          }
        ],
      },
      UsageReportQuery(
          targets: [target],
          from: window.from,
          to: window.to,
          timeZone: window.timeZone,
          period: window.period));
}

class ReportStub implements ChildReports {
  int loads = 0, cancels = 0, closes = 0;
  DeviceReportWindow? window;
  Completer<UsageReport>? pending;
  @override
  Future<UsageReport> load(DeviceReportWindow value) {
    loads++;
    window = value;
    return pending?.future ?? Future.value(emptyReport(value));
  }

  @override
  void cancel() {
    cancels++;
  }

  @override
  void close() {
    closes++;
    cancel();
  }
}

void main() {
  testWidgets(
      'native usage navigation loads report and closes loader on leaving',
      (t) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final reports = ReportStub();
    await t.pumpWidget(ChildApp(
        session: fixture.session(),
        nativeAvailable: true,
        reportFactory: (_) => reports));
    await t.pumpAndSettle();
    await t.tap(find.text('使用'));
    await t.pumpAndSettle();
    expect(reports.loads, 1);
    expect(find.text('我的使用情况'), findsOneWidget);
    expect(find.text('暂无使用记录'), findsOneWidget);
    await t.tap(find.text('设备'));
    await t.pumpAndSettle();
    expect(reports.closes, 1);
    expect(find.text('暂无使用记录'), findsNothing);
  });
  testWidgets('browser preview never creates a private report receiver',
      (t) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    var created = 0;
    await t.pumpWidget(ChildApp(
        session: fixture.session(),
        nativeAvailable: false,
        reportFactory: (_) {
          created++;
          return ReportStub();
        }));
    await t.pumpAndSettle();
    await t.tap(find.text('使用'));
    await t.pumpAndSettle();
    expect(created, 0);
    expect(find.text('本设备报表尚不可用'), findsOneWidget);
  });
  testWidgets('server authentication failure removes already displayed report',
      (t) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final session = fixture.session(), reports = ReportStub();
    await t.pumpWidget(ChildApp(
        session: session,
        nativeAvailable: true,
        reportFactory: (_) => reports));
    await t.pumpAndSettle();
    await t.tap(find.text('使用'));
    await t.pumpAndSettle();
    expect(find.text('暂无使用记录'), findsOneWidget);
    fixture.rejectAuthentication = true;
    await session.checkConnection();
    await t.pumpAndSettle();
    expect(find.text('暂无使用记录'), findsNothing);
    expect(find.text('报表暂不可用'), findsOneWidget);
  });
  testWidgets('backgrounded host discards a report that arrives late',
      (t) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final session = fixture.session(),
        reports = ReportStub()..pending = Completer<UsageReport>();
    await t.pumpWidget(ChildApp(
        session: session,
        nativeAvailable: true,
        reportFactory: (_) => reports));
    await t.pumpAndSettle();
    await t.tap(find.text('使用'));
    await t.pump();
    await t.pump();
    await session.setForeground(false);
    await t.pump();
    reports.pending!.complete(emptyReport(reports.window!));
    await t.pumpAndSettle();
    expect(find.text('暂无使用记录'), findsNothing);
    expect(reports.cancels, greaterThan(0));
    await session.setForeground(true);
    await t.pumpAndSettle();
    expect(find.text('暂无使用记录'), findsNothing);
  });
}
