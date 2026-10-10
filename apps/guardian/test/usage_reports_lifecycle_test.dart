import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/usage_reports.dart';
import 'package:guardian/ui/usage_reports_view.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'usage_reports_test.dart' show target, subject, reportFixture;
import 'usage_reports_view_test.dart' show host;

http.Response emptyReport(http.Request request) {
  final q = request.url.queryParameters,
      from = int.parse(q['from']!),
      requested = int.parse(q['to']!),
      now = DateTime.now().millisecondsSinceEpoch;
  final to = requested < now ? requested : now;
  final body = reportFixture();
  body.addAll(
      {'generatedAt': now, 'from': from, 'to': to, 'requestedTo': requested});
  (body['devices'][0] as Json).addAll({
    'status': 'NO_DATA',
    'sourceBatchCount': 0,
    'sourceTimeZones': [],
    'applications': [],
    'latestObservedAt': null,
    'latestReceivedAt': null,
    'queryCoverageMillis': 0,
    'uncoveredQueryMillis': to - from,
    'retentionFrom': now - 30 * 86400000,
    'configurationState': {
      'checkedAt': now,
      'evidenceStatus': 'DELIVERY_ONLY_NOT_EXECUTION',
      'configurations': []
    }
  });
  return http.Response(jsonEncode(body), 200,
      headers: {'content-type': 'application/json'});
}

UsageReportRepository repository(
        FutureOr<http.Response> Function(http.Request) send) =>
    UsageReportRepository(
        api: Api(() async => MockClient((request) async => send(request))),
        root: '/tenants/$subject',
        current: () => true);

void main() {
  testWidgets('background clears displayed sync report and owned device picker',
      (t) async {
    int loads = 0;
    await t.pumpWidget(host(UsageReportsView(
        repository: repository(emptyReport),
        loadTargets: () async {
          loads++;
          return [target];
        },
        timeZone: 'UTC')));
    await t.pumpAndSettle();
    await t.tap(find.text('生成报表'));
    await t.pumpAndSettle();
    expect(find.text('暂无使用数据'), findsOneWidget);
    await t.ensureVisible(find.text('设备 · 1 台'));
    await t.tap(find.text('设备 · 1 台'));
    await t.pumpAndSettle();
    expect(find.text('选择设备'), findsOneWidget);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.scheduleForcedFrame();
    await t.pump();
    t.binding.scheduleForcedFrame();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('选择设备'), findsNothing);
    expect(find.text('暂无使用数据'), findsNothing);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(loads, 2);
    expect(find.text('暂无使用数据'), findsNothing);
    expect(find.text('生成报表'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  for (final afterResume in [false, true]) {
    testWidgets(
        'background rejects pending sync result afterResume=$afterResume',
        (t) async {
      final waiting = Completer<void>();
      int reads = 0, loads = 0;
      final repo = repository((r) async {
        reads++;
        await waiting.future;
        return emptyReport(r);
      });
      await t.pumpWidget(host(UsageReportsView(
          repository: repo,
          loadTargets: () async {
            loads++;
            return [target];
          },
          timeZone: 'UTC')));
      await t.pumpAndSettle();
      await t.tap(find.text('生成报表'));
      await t.pump();
      expect(reads, 1);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      if (afterResume) {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pump();
      }
      waiting.complete();
      await t.pump();
      if (!afterResume) {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      await t.pumpAndSettle();
      expect(find.text('暂无使用数据'), findsNothing);
      expect(loads, 2);
      expect(find.text('生成报表'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'late private device options cannot replace fresh resumed options',
      (t) async {
    final pending = Completer<List<UsageReportTarget>>();
    int loads = 0;
    await t.pumpWidget(host(UsageReportsView(
        repository: repository(emptyReport),
        loadTargets: () {
          loads++;
          return loads == 1 ? pending.future : Future.value([]);
        },
        timeZone: 'UTC')));
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    pending.complete([target]);
    await t.pumpAndSettle();
    expect(find.text('暂无可查询的设备'), findsOneWidget);
    expect(find.text('设备 · 1 台'), findsNothing);
    expect(loads, 2);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'initial hidden view waits for resume before loading private options',
      (t) async {
    int loads = 0;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await t.pumpWidget(host(UsageReportsView(
        repository: repository(emptyReport),
        loadTargets: () async {
          loads++;
          return [target];
        },
        timeZone: 'UTC')));
    expect(loads, 0);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(loads, 1);
    await t.pumpWidget(const SizedBox());
  });
}
