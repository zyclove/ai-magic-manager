import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/devices_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/resource_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _path = '/tenants/workspace/devices';

Json _device(String id, String name, String observation) => {
      'id': id,
      'displayName': name,
      'platform': 'ANDROID',
      'state': 'ACTIVE',
      'observationStatus': observation,
      'lastHeartbeatAt': '2026-10-26T00:00:00Z',
    };

http.Response _page(List<Json> rows, {String? cursor}) => http.Response.bytes(
    utf8.encode(jsonEncode({'items': rows, 'nextCursor': cursor})), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Finder _button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

void main() {
  testWidgets('server connection queue keeps controlled filters and action scope',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var current = true, filtered = true, writable = false;
    final changes = <bool>[];
    final requests = <http.Request>[];
    var detail = Completer<bool>(), lookup = Completer<bool>();
    var creation = Completer<bool>();
    addTearDown(() {
      if (!detail.isCompleted) detail.complete(false);
      if (!lookup.isCompleted) lookup.complete(false);
      if (!creation.isCompleted) creation.complete(false);
    });
    final stale = _device('stale-device', '客厅平板', 'STALE');
    final recent = _device('recent-device', '书房平板', 'RECENT');
    final client = MockClient((request) async {
      requests.add(request);
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1$_path');
      final needsCheck = request.url.queryParameters['connection'] == 'NEEDS_CHECK';
      final cursor = request.url.queryParameters['cursor'];
      if (cursor == null) {
        return _page([], cursor: needsCheck ? 'queue-next' : 'all-next');
      }
      expect(cursor, needsCheck ? 'queue-next' : 'all-next');
      return _page([needsCheck ? stale : recent]);
    });
    addTearDown(client.close);
    final api = Api(() async => client,
        baseUrl: 'https://fixture.invalid/api/v1');
    Json? opened;
    ResourceActionLease? detailLease;
    var opens = 0, creations = 0, lookups = 0;
    Widget host() => MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: DevicesPage(
                    api: api,
                    path: _path,
                    needsConnectionCheck: filtered,
                    isCurrent: () => current,
                    onFilterChanged: changes.add,
                    onOpenChanged: (row, lease) {
                      expect(lease.current, isTrue);
                      detailLease = lease;
                      opens++;
                      opened = row;
                      return detail.future;
                    },
                    createChanged: writable ? (lease) {
                      expect(lease.current, isTrue);
                      creations++;
                      return creation.future;
                    } : null,
                    findEnrollmentChanged: writable ? (lease) {
                      expect(lease.current, isTrue);
                      lookups++;
                      return lookup.future;
                    } : null))));

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(requests.single.url.queryParameters['connection'], 'NEEDS_CHECK');
    expect(find.text('暂无待检查连接的设备'), findsOneWidget);
    expect(find.text('添加设备'), findsNothing);
    expect(find.text('查询注册进度'), findsNothing);
    await tester.ensureVisible(_button('加载更多'));
    await tester.tap(_button('加载更多'));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters['cursor'], 'queue-next');
    expect(find.text('客厅平板'), findsOneWidget);

    final selector = find.byKey(const Key('devices-connection-filter'));
    final heldFilter = tester.widget<SegmentedButton<bool>>(selector)
        .onSelectionChanged!;
    heldFilter({false});
    heldFilter({false});
    await tester.pumpAndSettle();
    expect(changes, [false]);
    expect(tester.widget<SegmentedButton<bool>>(selector).selected, {true});
    expect(requests, hasLength(2), reason: 'The host must accept the new URL first.');
    filtered = false;
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters['connection'], isNull);
    expect(find.text('尚未连接设备'), findsOneWidget);
    expect(find.textContaining('管理员添加后'), findsOneWidget);
    await tester.ensureVisible(_button('加载更多'));
    await tester.tap(_button('加载更多'));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters['cursor'], 'all-next');
    expect(find.text('书房平板'), findsOneWidget);
    heldFilter({true});
    await tester.pump();
    expect(changes, [false], reason: 'The previous view cannot change the new filter.');
    await tester.enterText(find.byType(TextField), '书房');
    await tester.pump();
    final secondPageReads = requests.length;
    final expiredLease = ResourceActionLease(isCurrent: () => false);
    expect(await tester.widget<ResourcePage>(find.byType(ResourcePage))
        .onOpenChanged!(recent, expiredLease), isFalse);
    expiredLease.dispose();
    expect(opens, 0, reason: 'An external lease must be current at entry.');
    final heldOpen = tester.widget<ButtonStyleButton>(_button('查看详情')).onPressed!;
    heldOpen();
    await tester.pump();
    expect(opened, recent);
    expect(opens, 1);
    expect(find.text('正在处理，请稍候'), findsOneWidget);
    expect(tester.widget<SegmentedButton<bool>>(selector).onSelectionChanged, isNull);
    heldFilter({true});
    heldOpen();
    await tester.pump();
    expect(changes, [false]);
    expect(opens, 1);
    detail.complete(false);
    await tester.pumpAndSettle();
    expect(requests, hasLength(secondPageReads));
    expect(find.text('书房平板'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '书房');

    // Registration lookup shares the table's action boundary and adds no list read.
    writable = true;
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final currentOpen = tester.widget<ButtonStyleButton>(_button('查看详情')).onPressed!;
    final heldCreate = tester.widget<ButtonStyleButton>(_button('添加设备')).onPressed!;
    final lookupButton = find.byKey(const Key('devices-find-enrollment'));
    final heldLookup = tester.widget<TextButton>(lookupButton).onPressed!;
    final requestCount = requests.length;
    heldLookup();
    await tester.pump();
    expect(lookups, 1);
    expect(find.text('正在处理，请稍候'), findsOneWidget);
    expect(tester.widget<SegmentedButton<bool>>(selector).onSelectionChanged, isNull);
    heldCreate();
    currentOpen();
    heldLookup();
    heldFilter({true});
    await tester.pump();
    expect(creations, 0);
    expect(opens, 1);
    expect(lookups, 1);
    expect(changes, [false]);
    lookup.complete(false);
    await tester.pumpAndSettle();
    expect(requests, hasLength(requestCount));
    expect(find.text('书房平板'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '书房');

    // An ordinary create cancellation also keeps the loaded page and search.
    tester.widget<ButtonStyleButton>(_button('添加设备')).onPressed!();
    await tester.pump();
    expect(creations, 1);
    creation.complete(false);
    await tester.pumpAndSettle();
    expect(requests, hasLength(requestCount));
    expect(find.text('书房平板'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '书房');

    // Each change signal performs exactly one current-list reconciliation.
    detail = Completer<bool>();
    tester.widget<ButtonStyleButton>(_button('查看详情')).onPressed!();
    await tester.pump();
    expect(opens, 2);
    detail.complete(true);
    await tester.pumpAndSettle();
    expect(requests, hasLength(requestCount + 1));
    expect(requests.last.url.queryParameters['cursor'], isNull);
    expect(find.text('书房平板'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '书房');

    await tester.ensureVisible(_button('加载更多'));
    await tester.tap(_button('加载更多'));
    await tester.pumpAndSettle();
    creation = Completer<bool>();
    tester.widget<ButtonStyleButton>(_button('添加设备')).onPressed!();
    await tester.pump();
    expect(creations, 2);
    creation.complete(true);
    await tester.pumpAndSettle();
    expect(requests, hasLength(requestCount + 3));
    expect(requests.last.url.queryParameters['cursor'], isNull);

    await tester.ensureVisible(_button('加载更多'));
    await tester.tap(_button('加载更多'));
    await tester.pumpAndSettle();
    lookup = Completer<bool>();
    tester.widget<TextButton>(lookupButton).onPressed!();
    await tester.pump();
    expect(lookups, 2);
    lookup.complete(true);
    await tester.pumpAndSettle();
    expect(requests, hasLength(requestCount + 5));
    expect(requests.last.url.queryParameters['cursor'], isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '书房');

    await tester.ensureVisible(_button('加载更多'));
    await tester.tap(_button('加载更多'));
    await tester.pumpAndSettle();
    final finalReadCount = requests.length;
    final finalOpen = tester.widget<ButtonStyleButton>(_button('查看详情')).onPressed!;
    final finalCreate = tester.widget<ButtonStyleButton>(_button('添加设备')).onPressed!;
    final finalLookup = tester.widget<TextButton>(lookupButton).onPressed!;
    final finalFilter = tester.widget<SegmentedButton<bool>>(selector)
        .onSelectionChanged!;
    detail = Completer<bool>();
    finalOpen();
    await tester.pump();
    expect(opens, 3);

    current = false;
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    heldCreate();
    currentOpen();
    heldLookup();
    heldFilter({true});
    finalCreate();
    finalOpen();
    finalLookup();
    finalFilter({true});
    expect(detailLease!.current, isFalse);
    detail.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    expect(find.text('书房平板'), findsNothing);
    expect(creations, 2);
    expect(opens, 3);
    expect(lookups, 2);
    expect(changes, [false]);
    expect(requests, hasLength(finalReadCount));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
