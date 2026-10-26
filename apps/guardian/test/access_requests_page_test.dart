import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/access_requests_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _path = '/tenants/workspace/access-requests';
const _subject = '00000000-0000-4000-8000-000000000101';
const _device = '00000000-0000-4000-8000-000000000102';
const _application = '00000000-0000-4000-8000-000000000103';

Json _row(String id, String state) => {
      'id': id,
      'subjectId': _subject,
      'deviceId': _device,
      'applicationId': _application,
      'requestedWindowSeconds': 600,
      'reason': '完成今天的绘画练习',
      'state': state,
      'createdAt': 1700000000000,
    };

http.Response _page(List<Json> rows, {String? cursor}) => http.Response.bytes(
    utf8.encode(jsonEncode({'items': rows, 'nextCursor': cursor})), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Widget _host(Api api, String role, bool Function() isCurrent,
        Future<void> Function(Json) onOpen) =>
    MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: AccessRequestsPage(
                    key: ValueKey(role),
                    api: api,
                    path: _path,
                    role: role,
                    isCurrent: isCurrent,
                    onOpen: onOpen))));

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('pending requests retain pagination after a reconciled empty page',
      (tester) async {
    _wide(tester);
    final requests = <http.Request>[];
    final detail = Completer<void>();
    final pending = {
      ..._row('request-pending', 'PENDING'),
      'subjectName': '小明',
      'deviceName': '客厅平板',
      'applicationName': '绘画应用',
      'applicationPackageName': 'com.example.draw',
    };
    final client = MockClient((request) async {
      requests.add(request);
      expect(request.method, 'GET');
      expect(request.url.queryParameters['state'], 'PENDING');
      return request.url.queryParameters['cursor'] == null
          ? _page([
              {..._row('request-expired', 'EXPIRED'), 'subjectName': '已到期成员'}
            ], cursor: 'next-requests')
          : _page([pending]);
    });
    addTearDown(client.close);
    addTearDown(() {
      if (!detail.isCompleted) detail.complete();
    });
    Json? opened;
    await tester.pumpWidget(_host(Api(() async => client), 'OWNER', () => true,
        (row) {
      opened = row;
      return detail.future;
    }));
    await tester.pumpAndSettle();
    expect(find.text('成员：已到期成员'), findsNothing);
    expect(find.text('加载更多'), findsOneWidget);
    await tester.ensureVisible(find.text('加载更多'));
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('成员：小明'), findsOneWidget);
    expect(find.text('设备：客厅平板'), findsOneWidget);
    expect(find.text('绘画应用'), findsOneWidget);
    expect(find.text('软件包：com.example.draw'), findsOneWidget);
    expect(requests, hasLength(2));
    expect(requests.last.url.queryParameters['cursor'], 'next-requests');
    final open = find.ancestor(
        of: find.text('查看详情'),
        matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pump();
    expect(opened, pending);
    expect(find.text('正在处理，请稍候'), findsOneWidget);
    expect(tester.widget<SegmentedButton<bool>>(
            find.byType(SegmentedButton<bool>)).onSelectionChanged,
        isNull, reason: 'An open operation blocks filter changes.');
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    detail.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('request readers start with all and isolate old filters and owners',
      (tester) async {
    _wide(tester);
    for (final role in ['CHILD', 'TEACHER', 'AUDITOR']) {
      var current = true;
      final requests = <http.Request>[];
      final latePending = Completer<http.Response>();
      final original = _row('request-$role', 'DENIED');
      original.addAll(role == 'AUDITOR'
          ? {'subjectName': '隐藏的成员名', 'deviceName': '隐藏的设备名',
              'applicationName': '隐藏的应用名', 'applicationPackageName': 'hidden.package'}
          : {'subjectName': {'private': 'do-not-echo'}, 'deviceName': 17,
              'applicationName': false, 'applicationPackageName': {'private': 'do-not-echo'}});
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.queryParameters['state'] == 'PENDING') {
          return latePending.future;
        }
        return _page([original]);
      });
      addTearDown(client.close);
      addTearDown(() {
        if (!latePending.isCompleted) latePending.complete(_page([]));
      });
      final api = Api(() async => client);
      Widget host() => _host(api, role, () => current, (_) async {});
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(requests.single.url.queryParameters['state'], isNull);
      expect(find.text('已拒绝'), findsOneWidget);
      expect(find.textContaining(_subject), findsOneWidget);
      expect(find.textContaining(_device), findsOneWidget);
      expect(find.text(_application), findsOneWidget);
      expect(find.textContaining('do-not-echo'), findsNothing);
      expect(find.textContaining('隐藏的'), findsNothing);
      expect(find.textContaining('hidden.package'), findsNothing);
      if (role == 'TEACHER') {
        expect(find.text('我的访问申请'), findsOneWidget);
      }
      final selector = find.byType(SegmentedButton<bool>);
      final heldFilter = tester.widget<SegmentedButton<bool>>(selector)
          .onSelectionChanged!;
      heldFilter({true});
      await tester.pump();
      expect(requests, hasLength(2));
      final switchBack = tester.widget<SegmentedButton<bool>>(selector)
          .onSelectionChanged;
      expect(switchBack, isNotNull,
          reason: 'Reading a list must not block changing its filter.');
      switchBack!({false});
      await tester.pumpAndSettle();
      expect(requests, hasLength(3));
      latePending.complete(_page([
        {..._row('late-private', 'PENDING'), 'subjectName': '迟到的私有名称'}
      ]));
      await tester.pumpAndSettle();
      expect(find.textContaining('迟到的私有名称'), findsNothing);
      expect(find.text('已拒绝'), findsOneWidget);
      expect(find.textContaining(_subject), findsOneWidget);
      current = false;
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      heldFilter({true});
      await tester.pump();
      expect(requests, hasLength(3));
      expect(requests.every((request) => request.method == 'GET'), isTrue);
      expect(find.textContaining(_subject), findsNothing);
      expect(find.text('工作空间或权限已变化'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    }
  });
}
