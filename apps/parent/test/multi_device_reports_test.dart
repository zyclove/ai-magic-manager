import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/paged_collection.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/report_selection.dart';
import 'package:parent/core/usage_reports.dart';
import 'package:parent/ui/multi_device_reports.dart';
import 'package:usage_reporting/usage_reporting.dart';
import '../../../packages/usage_report_ui/test/fixture.dart' as fixture;

String id(int n) => '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
UsageReportTarget target(int n) =>
    UsageReportTarget(id(n), id(n + 100), id(n + 200), '学习设备 $n',
        platform: 'ANDROID');
Json device(int n) => {
      'id': id(n),
      'registrationId': id(n + 100),
      'subjectId': id(n + 200),
      'displayName': '学习设备 $n',
      'platform': 'ANDROID',
      'state': 'ACTIVE'
    };
http.Response response(Json raw) =>
    http.Response.bytes(utf8.encode(jsonEncode(raw)), 200,
        headers: {'content-type': 'application/json'});
Json report(UsageReportQuery query) {
  final raw = fixture.reportFixture();
  raw['devices'] = [
    for (final t in query.targets)
      {
        ...fixture.reportFixture()['devices'][0] as Json,
        'deviceId': t.deviceId,
        'registrationId': t.registrationId,
        'subjectId': t.subjectId,
        'displayName': t.displayName,
        'status': 'NO_DATA',
        'applications': [],
        'sourceBatchCount': 0,
        'sourceTimeZones': [],
        'latestObservedAt': null,
        'latestReceivedAt': null,
        'queryCoverageMillis': 0,
        'uncoveredQueryMillis': query.to - query.from,
      }
  ];
  return raw;
}

UsageReportQuery query(int count) => UsageReportQuery(
    targets: List.generate(count, (i) => target(i + 1)),
    from: fixture.now - 3600000,
    to: fixture.now,
    timeZone: 'UTC',
    period: 'DAY');

class Session extends ParentSession {
  final ParentApi fixtureApi;
  Session(this.fixtureApi) {
    tenant = {'id': 'tenant', 'timeZone': 'UTC'};
    profile = {'subject': 'adult'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => fixtureApi;
  @override
  bool get authenticated => true;
  void revoke() {
    role = 'AUDITOR';
    notifyListeners();
  }
}

void main() {
  testWidgets(
      'phone picker supports large text and bounded scrollable controls',
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
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((_) async => response({
              'items': [device(1), device(2), device(3)],
              'nextCursor': null
            })));
    final boundary = GlobalKey();
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
            home: ParentReportDevicePicker(
                session: Session(api),
                browseFirst: true,
                onSelected: (_) async {}))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_MULTI_REPORT_UI')) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/parent-report-browse.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择筛选结果'));
    await tester.pumpAndSettle();
    expect(find.text('已明确选择 3 / 20 台'), findsOneWidget);
    if (const bool.fromEnvironment('CAPTURE_MULTI_REPORT_UI')) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/parent-multi-report-picker.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.scrollUntilVisible(
        find.byKey(ValueKey(id(3))).hitTestable(), 150,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
    api.close();
  });
  test('directory token wait cannot dispatch after scope loss or disposal',
      () async {
    for (final dispose in [false, true]) {
      final token = Completer<String>();
      var current = true, requests = 0;
      final api = ParentApi(() => token.future,
          baseUrl: 'https://fixture.invalid/api/v1',
          client: MockClient((_) async {
        requests++;
        return response({
          'items': [device(1)],
          'nextCursor': null
        });
      }));
      final collection = PagedCollection(api, '/tenants/tenant/devices',
          isCurrent: () => current);
      if (dispose) {
        collection.dispose();
      } else {
        current = false;
      }
      token.complete('fixture');
      await Future<void>.delayed(Duration.zero);
      expect(requests, 0);
      expect(collection.items, isEmpty);
      if (!dispose) collection.dispose();
      api.close();
    }
  });
  testWidgets(
      'revoking adult access closes picker during a pending token refresh',
      (tester) async {
    final token = Completer<String>();
    var requests = 0;
    final api =
        ParentApi(() => token.future, baseUrl: 'https://fixture.invalid/api/v1',
            client: MockClient((_) async {
      requests++;
      return response({
        'items': [device(1)],
        'nextCursor': null
      });
    }));
    final session = Session(api);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    child: const Text('打开'),
                    onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) =>
                            ParentReportDevicePicker(session: session))))))));
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    session.revoke();
    token.complete('fixture');
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    expect(find.text('选择报告设备'), findsNothing);
    expect(requests, 0);
    expect(tester.takeException(), isNull);
    api.close();
  });
  test('selection is bounded, atomic and keeps exact original registrations',
      () {
    final selected = ParentReportSelection();
    selected.add([target(1)]);
    expect(() => selected.add(List.generate(21, (i) => target(i + 1))),
        throwsFormatException);
    expect(selected.length, 1);
    selected.add(List.generate(20, (i) => target(i + 1)));
    expect(selected.length, 20);
    expect(() => selected.targets.clear(), throwsUnsupportedError);
    final changed = UsageReportTarget(id(1), id(999), id(201), '变化的设备');
    expect(() => selected.add([changed]), throwsA(isA<ParentApiException>()));
    expect(selected.targets.first.registrationId, id(101));
    selected.remove(id(1));
    selected.add([target(21)]);
    expect(selected.length, 20);
    selected.clear();
    expect(selected.length, 0);
  });
  test(
      'inactive unsupported and malformed directory entries cannot be selected',
      () {
    for (final value in [
      {...device(1), 'state': 'REVOKED'},
      {...device(1), 'platform': 'IOS'},
      {...device(1), 'subjectId': 'unknown'},
      {...device(1), 'registrationId': null}
    ]) {
      expect(parentReportTarget(value), isNull);
    }
    expect(parentReportTarget(device(1))!.deviceId, id(1));
  });
  test(
      'directory preflight is bounded at four and all devices precede the report',
      () async {
    final gates = <String, Completer<void>>{}, q = query(7);
    var active = 0, peak = 0, reports = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((r) async {
      final requested = r.url.pathSegments.last;
      final index = q.targets.indexWhere((t) => t.deviceId == requested) + 1;
      active++;
      if (active > peak) peak = active;
      final gate = Completer<void>();
      gates[requested] = gate;
      await gate.future;
      active--;
      return response(device(index));
    }));
    final loader = ParentUsageReportLoader(
        api: api,
        tenant: 'tenant',
        token: () async => 'fixture',
        available: () => true,
        clientFactory: () => MockClient((r) async {
              reports++;
              expect(active, 0);
              expect(gates.length, 7);
              expect(r.url.queryParametersAll['deviceId'],
                  q.targets.map((t) => t.deviceId).toList());
              return response(report(q));
            }));
    final result = loader.load(q);
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 4);
    expect(reports, 0);
    for (final g in gates.values.toList()) {
      g.complete();
    }
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 7);
    expect(reports, 0);
    for (final g in gates.values.where((g) => !g.isCompleted).toList()) {
      g.complete();
    }
    expect((await result).devices.length, 7);
    expect(peak, 4);
    expect(reports, 1);
    api.close();
    loader.cancel();
  });
  test('any changed registration prevents the complete report request',
      () async {
    var reports = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((r) async {
      final index = int.parse(r.url.pathSegments.last.substring(24));
      return response(
          {...device(index), if (index == 3) 'registrationId': id(999)});
    }));
    final loader = ParentUsageReportLoader(
        api: api,
        tenant: 'tenant',
        token: () async => 'fixture',
        available: () => true,
        clientFactory: () {
          reports++;
          return MockClient((_) async => response({}));
        });
    await expectLater(
        loader.load(query(7)),
        throwsA(isA<UsageReportFailure>()
            .having((e) => e.code, 'code', 'REPORT_SCOPE_CHANGED')));
    expect(reports, 0);
    api.close();
    loader.cancel();
  });
  test('cancelling a preflight batch does not start later device requests',
      () async {
    final gates = <Completer<void>>[];
    var reports = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((r) async {
      final index = int.parse(r.url.pathSegments.last.substring(24));
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      return response(device(index));
    }));
    final loader = ParentUsageReportLoader(
        api: api,
        tenant: 'tenant',
        token: () async => 'fixture',
        available: () => true,
        clientFactory: () {
          reports++;
          return MockClient((_) async => response({}));
        });
    final result = loader.load(query(7));
    final expected = expectLater(result, throwsA(isA<UsageReportFailure>()));
    await Future<void>.delayed(Duration.zero);
    loader.cancel();
    for (final g in gates) {
      g.complete();
    }
    await expected;
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 4);
    expect(reports, 0);
    api.close();
  });
  testWidgets(
      'device picker keeps explicit selections across pages and filters',
      (tester) async {
    var pages = 0;
    List<UsageReportTarget>? chosen;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((r) async {
      pages++;
      return response({
        'items': r.url.queryParameters['cursor'] == null
            ? [device(1), device(2)]
            : [device(3)],
        'nextCursor': r.url.queryParameters['cursor'] == null ? 'next' : null
      });
    }));
    final session = Session(api);
    await tester.pumpWidget(MaterialApp(
        home: ParentReportDevicePicker(
            session: session, onSelected: (value) async => chosen = value)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(ValueKey(id(1))), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(CheckboxListTile, '学习设备 1'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('加载更多设备').hitTestable(), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('加载更多设备'));
    await tester.pumpAndSettle();
    expect(pages, 2);
    await tester.scrollUntilVisible(find.byKey(ValueKey(id(3))), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(CheckboxListTile, '学习设备 3'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byType(TextField), -150,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byType(TextField), '学习设备 2');
    await tester.pumpAndSettle();
    expect(find.text('已明确选择 2 / 20 台'), findsOneWidget);
    await tester.tap(find.text('查看所选设备报告'));
    await tester.pumpAndSettle();
    expect(chosen!.map((t) => t.deviceId), [id(1), id(3)]);
    expect(chosen![1].registrationId, id(103));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('学习设备 1'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('已明确选择 0 / 20 台'), findsOneWidget);
    expect(find.text('重新读取设备'), findsOneWidget);
    expect(pages, 2);
    expect(tester.takeException(), isNull);
  });
}
