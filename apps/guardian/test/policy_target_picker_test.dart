@TestOn('browser')
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/policy_target_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The real picker and API parser with HTTP fixtures; no login or device writes.
class PickerSession extends Session {
  PickerSession({this.groups = false, this.failDevices = false}) {
    profile = {'subject': 'admin'};
    tenant = {'id': 'tenant-a', 'kind': groups ? 'ORGANIZATION' : 'FAMILY'};
    role = 'OWNER';
  }
  final bool groups;
  bool failDevices;
  bool failGroup = false;
  int epoch = 0;
  final requests = <http.Request>[];
  final group = <String, dynamic>{
    'id': 'group-a',
    'name': '一年级',
    'state': 'ACTIVE',
    'version': 3,
    'deviceCount': 2,
  };
  late final client = MockClient((request) async {
    requests.add(request);
    if (request.method != 'GET') throw StateError('Unexpected mutation');
    final path = request.url.path;
    if (path.endsWith('/device-groups')) return reply(page([group]));
    if (path.endsWith('/device-groups/group-a')) {
      return failGroup
          ? reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503)
          : reply(group);
    }
    if (path.endsWith('/summary')) {
      return reply({
        'groupId': 'group-a',
        'version': 3,
        'total': 2,
        'current': 2,
        'staleRegistration': 0,
        'deviceInactive': 0,
        'profileArchived': 0
      });
    }
    if (path.endsWith('/device-groups/group-a/devices')) {
      return reply(page([
        for (final id in ['group-1', 'group-2'])
          {
            'deviceId': id,
            'registrationId': 'registration-$id',
            'displayName': '班级平板 $id',
            'state': 'ACTIVE',
            'membershipStatus': 'CURRENT'
          }
      ]));
    }
    if (failDevices) return reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503);
    if (request.url.queryParameters['cursor'] == 'next') {
      return reply(page([device('tablet-b', '学习平板 B')]));
    }
    return reply(page(
        [device('tablet-a', '学习平板 A'), device('tv', '客厅电视', state: 'REVOKED')],
        cursor: 'next'));
  });
  late final testApi =
      Api(() async => client, baseUrl: 'https://fixture.invalid/api/v1');
  @override
  Api get api => testApi;
  @override
  bool get authenticated => true;
  @override
  int get scopeGeneration => epoch;
  void renewScope() {
    epoch++;
    notifyListeners();
  }
}

Json device(String id, String name, {String state = 'ACTIVE'}) =>
    {'id': id, 'displayName': name, 'state': state, 'platform': 'ANDROID'};
Json page(List<Json> items, {String? cursor}) =>
    {'items': items, 'nextCursor': cursor};
http.Response reply(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle(const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
}

Future<void> mount(WidgetTester tester, PickerSession session,
    {double width = 1100,
    double scale = 1,
    ValueChanged<PolicyTargetSelection?>? onResult}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    session.client.close();
    session.dispose();
  });
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    final result = await showDialog<PolicyTargetSelection>(
                        context: context,
                        builder: (_) => PolicyTargetPicker(
                            session: session,
                            root: session.root,
                            actor: 'admin',
                            role: 'OWNER'));
                    onResult?.call(result);
                  },
                  child: const Text('选择设备'))))));
  await tester.tap(find.text('选择设备'));
  await settle(tester);
}

void main() {
  testWidgets('failed group replacement preserves the previous explicit choice',
      (tester) async {
    final session = PickerSession(groups: true)..failGroup = true;
    PolicyTargetSelection? result;
    await mount(tester, session, onResult: (value) => result = value);
    await tester.ensureVisible(find.text('学习平板 A'));
    await tester.tap(find.text('学习平板 A'));
    await tester.pump();
    await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一年级 · 2 台').last);
    await settle(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(result?.deviceIds, ['tablet-a']);
    expect(result?.groupId, isNull);
  });
  testWidgets('search preserves choice and only explicit preview returns it',
      (tester) async {
    final session = PickerSession();
    PolicyTargetSelection? result;
    await mount(tester, session, onResult: (value) => result = value);
    await tester.tap(find.text('学习平板 A'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pump();
    expect(find.text('没有匹配的设备'), findsOneWidget);
    expect(find.text('已选 1 / 50 台'), findsOneWidget);
    expect(session.requests.length, 1);
    expect(result, isNull);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(result?.deviceIds, ['tablet-a']);
    expect(session.requests.every((r) => r.method == 'GET'), isTrue);
  });
  testWidgets('filtered paging and clear search preserve selected devices',
      (tester) async {
    final session = PickerSession();
    await mount(tester, session);
    await tester.tap(find.text('学习平板 A'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '平板 B');
    await tester.pump();
    expect(find.textContaining('仅搜索已加载设备'), findsOneWidget);
    await tester.ensureVisible(find.text('加载更多设备'));
    await tester.tap(find.text('加载更多设备'));
    await settle(tester);
    expect(find.text('学习平板 B'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('清除搜索'));
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    expect(find.text('已选 1 / 50 台'), findsOneWidget);
    expect(find.text('学习平板 A'), findsOneWidget);
    expect(session.requests.length, 2);
  });
  testWidgets('group selection review includes members outside loaded page',
      (tester) async {
    final session = PickerSession(groups: true);
    PolicyTargetSelection? result;
    await mount(tester, session, onResult: (value) => result = value);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一年级 · 2 台').last);
    await settle(tester);
    expect(find.text('班级平板 group-1'), findsOneWidget);
    expect(find.text('班级平板 group-2'), findsOneWidget);
    expect(find.text('学习平板 A'), findsNothing);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(result?.deviceIds, ['group-1', 'group-2']);
    expect(result?.groupId, 'group-a');
    expect(result?.groupVersion, 3);
    expect(result?.groupRegistrations.length, 2);
  });
  testWidgets(
      'selected-only mode can remove a group member without hidden selection',
      (tester) async {
    final session = PickerSession(groups: true);
    PolicyTargetSelection? result;
    await mount(tester, session, onResult: (value) => result = value);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一年级 · 2 台').last);
    await settle(tester);
    await tester.ensureVisible(find.text('班级平板 group-1'));
    await tester.tap(find.text('班级平板 group-1'));
    await tester.pump();
    expect(find.text('班级平板 group-1'), findsNothing);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(result?.deviceIds, ['group-2']);
    expect(result?.groupId, isNull);
    expect(result?.groupRegistrations, isEmpty);
  });
  testWidgets(
      'narrow large text keeps content scrollable and preview reachable',
      (tester) async {
    await mount(tester, PickerSession(), width: 390, scale: 2);
    expect(tester.takeException(), isNull);
    final content = find.descendant(
        of: find.byType(PolicyTargetPicker), matching: find.byType(Scrollable));
    // ListView builds offscreen rows lazily; scroll to build the target first.
    await tester.scrollUntilVisible(find.text('学习平板 A'), 120,
        scrollable: content.first);
    await tester.tap(find.text('学习平板 A'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('只看已选'), -120,
        scrollable: content.first);
    await tester.tap(find.text('只看已选'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
  testWidgets('failure is not presented as an empty device list',
      (tester) async {
    await mount(tester, PickerSession(failDevices: true));
    expect(find.text('尚无可选择设备'), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
  });
  testWidgets('same-identity session renewal closes stale selection',
      (tester) async {
    final session = PickerSession();
    await mount(tester, session);
    session.renewScope();
    await settle(tester);
    expect(find.byType(PolicyTargetPicker), findsNothing);
  });
}
