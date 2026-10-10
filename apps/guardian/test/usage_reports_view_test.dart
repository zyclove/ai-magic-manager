import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/usage_reports.dart';
import 'package:guardian/core/usage_report_jobs.dart';
import 'package:guardian/ui/usage_reports_view.dart';
import 'package:guardian/ui/design.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'usage_reports_test.dart'
    show target, device, registration, subject, reportFixture;

Widget host(Widget child) => MaterialApp(
    theme: consoleTheme(),
    home: Scaffold(body: SingleChildScrollView(child: child)));
void main() {
  testWidgets(
      'background selection supports 200 and disables synchronous generation above 20',
      (tester) async {
    UsageReportJobDraft? submitted;
    final devices = List.generate(
        21,
        (i) => UsageReportTarget(
            '${i.toString().padLeft(8, '0')}-1111-1111-1111-111111111111',
            registration,
            subject,
            '设备 $i'));
    final repo = UsageReportRepository(
        api: Api(() async =>
            MockClient((r) async => throw StateError('unexpected HTTP'))),
        root: '/tenants/$subject',
        current: () => true);
    await tester.pumpWidget(host(UsageReportsView(
        repository: repo,
        loadTargets: () async => devices,
        timeZone: 'UTC',
        onBackground: (draft) => submitted = draft)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设备 · 1 台'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择筛选结果'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认选择'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.ancestor(
                of: find.text('生成报表'),
                matching: find.byWidgetPredicate((w) => w is FilledButton)))
            .onPressed,
        isNull);
    await tester.ensureVisible(find.text('后台生成'));
    await tester.tap(find.text('后台生成'));
    await tester.pumpAndSettle();
    expect(submitted!.deviceIds.length, 21);
    expect(submitted!.timeZone, 'UTC');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'category filters apply to loaded results and never turn missing matches into zero use',
      (tester) async {
    int requests = 0;
    final repo = UsageReportRepository(
        api: Api(() async => MockClient((request) async {
              requests++;
              final q = request.url.queryParameters,
                  from = int.parse(q['from']!),
                  requested = int.parse(q['to']!),
                  generated = DateTime.now().millisecondsSinceEpoch,
                  to = requested < generated ? requested : generated;
              final value = reportFixture();
              value.addAll({
                'from': from,
                'to': to,
                'requestedTo': requested,
                'generatedAt': generated
              });
              final d = value['devices'][0] as Json;
              d.addAll({
                'configurationState': {
                  'checkedAt': generated,
                  'evidenceStatus': 'DELIVERY_ONLY_NOT_EXECUTION',
                  'configurations': []
                },
                'retentionFrom': generated - 30 * 86400000,
                'latestObservedAt': to,
                'latestReceivedAt': generated,
                'queryCoverageMillis': to - from,
                'uncoveredQueryMillis': 0
              });
              final buckets = <Json>[];
              for (var cursor = from; cursor < to;) {
                final date =
                    DateTime.fromMillisecondsSinceEpoch(cursor, isUtc: true);
                final boundary =
                    DateTime.utc(date.year, date.month, date.day + 1)
                        .millisecondsSinceEpoch;
                final end = boundary < to ? boundary : to,
                    duration = end - cursor;
                buckets.add({
                  'start': cursor,
                  'end': end,
                  'lowerMillis': duration < 1000 ? duration : 1000,
                  'upperMillis': duration < 1000 ? duration : 1000,
                  'coveredMillis': duration,
                  'status': 'REPORTED_TOTAL'
                });
                cursor = end;
              }
              final app = d['applications'][0] as Json;
              app['buckets'] = buckets;
              app['classification'].addAll({
                'category': 'EDUCATION',
                'source': 'ADMIN_DECLARED',
                'version': 1,
                'updatedAt': generated
              });
              return http.Response(jsonEncode(value), 200,
                  headers: {'content-type': 'application/json'});
            })),
        root: '/tenants/$subject',
        current: () => true);
    await tester.pumpWidget(host(UsageReportsView(
        repository: repo, loadTargets: () async => [target], timeZone: 'UTC')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成报表'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('usage-report-category')));
    await tester.tap(find.byKey(const Key('usage-report-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('实用工具').last);
    await tester.pumpAndSettle();
    expect(find.text('此类别下暂无应用记录'), findsOneWidget);
    expect(find.text('暂无使用数据'), findsNothing);
    expect(find.text('0 秒'), findsNothing);
    expect(requests, 1);
    await tester.ensureVisible(find.byKey(const Key('usage-report-category')));
    await tester.tap(find.byKey(const Key('usage-report-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习教育').last);
    await tester.pumpAndSettle();
    expect(find.text('此类别下暂无应用记录'), findsNothing);
    expect(find.textContaining('来源：管理员声明'), findsOneWidget);
    expect(requests, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('malformed and duplicate devices fail before opening a selector',
      (tester) async {
    final repo = UsageReportRepository(
        api: Api(() async =>
            MockClient((_) async => throw StateError('must not request'))),
        root: '/tenants/$subject',
        current: () => true);
    for (final devices in <List<UsageReportTarget>>[
      [const UsageReportTarget('x', registration, subject, '平板')],
      [const UsageReportTarget(device, 'x', subject, '平板')],
      [const UsageReportTarget(device, registration, 'x', '平板')],
      [const UsageReportTarget(device, registration, subject, '')],
      [target, target],
    ]) {
      await tester.pumpWidget(host(UsageReportsView(
          key: UniqueKey(),
          repository: repo,
          loadTargets: () async => devices,
          timeZone: 'UTC')));
      await tester.pumpAndSettle();
      expect(find.text('INVALID_USAGE_REPORT_RESPONSE'), findsOneWidget);
      expect(find.text('生成报表'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('failed roster resolution never falls back to an unscoped query',
      (tester) async {
    final repo = UsageReportRepository(
        api: Api(() async =>
            MockClient((_) async => throw StateError('must not request'))),
        root: '/tenants/$subject',
        current: () => true);
    await tester.pumpWidget(host(UsageReportsView(
        repository: repo,
        loadTargets: () async => [target],
        loadScopes: () async => [
              UsageReportScope(
                  kind: 'CLASS', id: registration, version: 0, label: '已变更班级')
            ],
        resolveScope: (_) async =>
            throw const ApiFailure(409, 'REPORT_SCOPE_CHANGED'),
        timeZone: 'UTC')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('usage-report-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已变更班级').last);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ButtonStyleButton>(find
                .ancestor(
                    of: find.text('生成报表'),
                    matching:
                        find.byWidgetPredicate((w) => w is ButtonStyleButton))
                .first)
            .onPressed,
        isNull);
    expect(find.textContaining('班级名册或设备所属档案已变化'), findsOneWidget);
    expect(find.text('刷新设备与范围'), findsOneWidget);
  });
  testWidgets(
      'large subject scopes require explicit device selection rather than truncating',
      (tester) async {
    final repo = UsageReportRepository(
        api: Api(() async =>
            MockClient((_) async => throw StateError('must not request'))),
        root: '/tenants/$subject',
        current: () => true);
    final targets = [
      for (int i = 0; i < 21; i++)
        UsageReportTarget(
            '11111111-1111-1111-1111-${i.toString().padLeft(12, '0')}',
            registration,
            subject,
            '设备$i')
    ];
    await tester.pumpWidget(host(UsageReportsView(
        repository: repo,
        loadTargets: () async => targets,
        loadScopes: () async =>
            [UsageReportScope(kind: 'SUBJECT', id: subject, label: '儿童 · 小林')],
        timeZone: 'UTC')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('usage-report-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('儿童 · 小林').last);
    await tester.pumpAndSettle();
    expect(find.text('设备 · 0 台'), findsOneWidget);
    expect(find.textContaining('范围内共 21 台'), findsOneWidget);
    expect(
        tester
            .widget<ButtonStyleButton>(find
                .ancestor(
                    of: find.text('生成报表'),
                    matching:
                        find.byWidgetPredicate((w) => w is ButtonStyleButton))
                .first)
            .onPressed,
        isNull);
  });
  testWidgets(
      'class scope resolves its current roster and sends only matching devices',
      (tester) async {
    Uri? sent;
    final repo = UsageReportRepository(
        api: Api(() async => MockClient((r) async {
              sent = r.url;
              return http.Response('{"errorCode":"TEMPORARY_FAILURE"}', 503);
            })),
        root: '/tenants/$subject',
        current: () => true);
    final scope = UsageReportScope(
        kind: 'CLASS', id: registration, version: 4, label: '一班');
    await tester.pumpWidget(host(UsageReportsView(
        repository: repo,
        loadTargets: () async => [
              target,
              const UsageReportTarget(subject, registration, device, '其他设备')
            ],
        loadScopes: () async => [scope],
        resolveScope: (value) async => UsageReportScope(
            kind: value.kind,
            id: value.id,
            version: value.version,
            label: value.label,
            subjectIds: [subject]),
        timeZone: 'UTC')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('usage-report-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一班').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('生成报表'));
    await tester.tap(find.text('生成报表'));
    await tester.pumpAndSettle();
    expect(sent!.queryParameters['scopeKind'], 'CLASS');
    expect(sent!.queryParameters['scopeVersion'], '4');
    expect(sent!.queryParametersAll['deviceId'], [device]);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'permission change closes the device chooser and clears old names',
      (tester) async {
    var active = true;
    final changes = ValueNotifier<int>(0);
    addTearDown(changes.dispose);
    final repo = UsageReportRepository(
        api: Api(() async =>
            MockClient((_) async => throw StateError('unexpected'))),
        root: '/tenants/$subject',
        current: () => active);
    await tester.pumpWidget(host(UsageReportsView(
        repository: repo,
        loadTargets: () async => [target],
        timeZone: 'UTC',
        accessChanges: changes)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设备 · 1 台'));
    await tester.pumpAndSettle();
    expect(find.text('选择设备'), findsOneWidget);
    active = false;
    changes.value++;
    await tester.pumpAndSettle();
    expect(find.text('选择设备'), findsNothing);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty devices offer setup guidance without requesting a report',
      (tester) async {
    final repo = UsageReportRepository(
        api: Api(() async =>
            MockClient((_) async => throw StateError('unexpected'))),
        root: '/tenants/$subject',
        current: () => true);
    await tester.pumpWidget(host(UsageReportsView(
        repository: repo, loadTargets: () async => [], timeZone: 'UTC')));
    await tester.pumpAndSettle();
    expect(find.text('暂无可查询的设备'), findsOneWidget);
    expect(find.text('生成报表'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'narrow report distinguishes no data and consent off and retries exact applied query',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <Uri>[];
    var fail = true;
    var state = 'NO_DATA';
    final repo = UsageReportRepository(
        api: Api(() async => MockClient((request) async {
              requests.add(request.url);
              if (fail) {
                return http.Response('{"errorCode":"TEMPORARY_FAILURE"}', 503);
              }
              final q = request.url.queryParameters,
                  from = int.parse(q['from']!),
                  requested = int.parse(q['to']!),
                  now = DateTime.now().millisecondsSinceEpoch,
                  to = requested < now ? requested : now;
              return http.Response(
                  jsonEncode({
                    'schemaVersion': 1,
                    'scope': {
                      'kind': q['scopeKind'] ?? 'DEVICES',
                      'id': q['scopeId'],
                      'version': q['scopeVersion'] == null
                          ? null
                          : int.parse(q['scopeVersion']!)
                    },
                    'generatedAt': now,
                    'from': from,
                    'to': to,
                    'requestedTo': requested,
                    'timeZone': q['timeZone'],
                    'period': q['period'],
                    'precision': 'OS_AGGREGATE',
                    'evidenceStatus': 'AGENT_REPORTED_UNVERIFIED',
                    'devices': [
                      {
                        'deviceId': device,
                        'registrationId': registration,
                        'subjectId': subject,
                        'displayName': '平板',
                        'status': state,
                        'authorizationVersion': 1,
                        'retentionFrom': now - 30 * 86400000,
                        'sourceBatchCount': 0,
                        'configurationState': {
                          'checkedAt': now,
                          'evidenceStatus': 'DELIVERY_ONLY_NOT_EXECUTION',
                          'configurations': []
                        },
                        'sourceTimeZones': [],
                        'latestObservedAt': null,
                        'latestReceivedAt': null,
                        'queryCoverageMillis': 0,
                        'uncoveredQueryMillis': to - from,
                        'applications': []
                      }
                    ]
                  }),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            })),
        root: '/tenants/$subject',
        current: () => true);
    await tester.pumpWidget(host(UsageReportsView(
        repository: repo, loadTargets: () async => [target], timeZone: 'UTC')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('生成报表'));
    await tester.tap(find.text('生成报表'));
    await tester.pumpAndSettle();
    fail = false;
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(requests[0], requests[1]);
    expect(find.text('暂无使用数据'), findsOneWidget);
    state = 'NOT_AUTHORIZED';
    await tester.ensureVisible(find.text('生成报表'));
    await tester.tap(find.text('生成报表'));
    await tester.pumpAndSettle();
    expect(find.text('尚未授权使用观察'), findsOneWidget);
    expect(find.text('暂无使用数据'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
