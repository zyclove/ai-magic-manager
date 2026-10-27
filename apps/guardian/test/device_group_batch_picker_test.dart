@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/device_group_batch_picker.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'policy_target_picker_test.dart' show reply;

Json _device(int index) => {
      'id': 'private-device-$index',
      'registrationId': 'private-registration-$index',
      'displayName': '私有平板 $index',
      'platform': 'ANDROID',
      'state': 'ACTIVE',
    };

class _Fixture {
  final List<Json> firstPage;
  final Future<http.Response> Function() nextPage;
  final requests = <http.Request>[];
  final changes = ValueNotifier<int>(0);
  bool completed = false;
  List<Json>? result;

  _Fixture(this.firstPage, this.nextPage);

  late final client = MockClient((request) async {
    requests.add(request);
    expect(request.method, 'GET');
    expect(request.url.path, '/api/v1/tenants/tenant-a/devices');
    expect(request.url.queryParameters['limit'], '50');
    if (request.url.queryParameters['cursor'] == 'next') return nextPage();
    expect(request.url.queryParameters.containsKey('cursor'), isFalse);
    return reply({'items': firstPage, 'nextCursor': 'next'});
  });
  late final api = Api(() async => client,
      baseUrl: 'https://fixture.invalid/api/v1');
}

Future<void> _waitUntil(WidgetTester tester, bool Function() ready) async {
  for (var turn = 0; turn < 40 && !ready(); turn++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: 'The observed picker state must arrive.');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Finder _button(String text) => find.ancestor(
    of: find.text(text),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

VoidCallback _capture(WidgetTester tester, String text) {
  final button = tester.widget<ButtonStyleButton>(_button(text));
  expect(button.onPressed, isNotNull);
  return button.onPressed!;
}

Finder _row(int index) => find.byKey(ValueKey('private-device-$index'));

Future<void> _mount(WidgetTester tester, _Fixture fixture) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(
      key: ObjectKey(fixture),
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    fixture.result = await presentOwnedDialog<List<Json>>(
                        context,
                        OwnedDialogRoute<List<Json>>(
                            context: context,
                            builder: (_) => DeviceGroupBatchPicker(
                                api: fixture.api,
                                root: '/tenants/tenant-a',
                                current: () => true,
                                accessChanges: fixture.changes)));
                    fixture.completed = true;
                  },
                  child: const Text('打开设备选择'))))));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.client.close();
    fixture.changes.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.tap(find.text('打开设备选择'));
  await _waitUntil(tester, () => _row(0).evaluate().isNotEmpty);
}

void main() {
  testWidgets(
      'denied paging redacts private choices and a retained confirm cannot return them under a cover',
      (tester) async {
    for (final rejection in const {
      403: 'ACCESS_DENIED',
      409: 'WORKSPACE_CHANGED',
      401: 'UNAUTHENTICATED',
    }.entries) {
      final response = Completer<http.Response>();
      final fixture = _Fixture([_device(0)], () => response.future);
      addTearDown(() {
        if (!response.isCompleted) response.complete(reply({}, 503));
      });
      await _mount(tester, fixture);
      await tester.tap(_row(0));
      await tester.enterText(find.byType(TextField), '私有平板');
      final confirm = _capture(tester, '核对并加入 1 台');
      _capture(tester, '加载更多设备')();
      await _waitUntil(tester, () => fixture.requests.length == 2);

      var coverClosed = false;
      final context = tester.element(find.byType(DeviceGroupBatchPicker));
      unawaited(showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
              title: const Text('独立通知'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭通知'))
              ])).then((_) => coverClosed = true));
      await _waitUntil(
          tester, () => find.text('独立通知').evaluate().isNotEmpty);
      response.complete(reply({'errorCode': rejection.value}, rejection.key));
      await _waitUntil(tester, () => find
          .text('工作空间或权限已变化', skipOffstage: false)
          .evaluate()
          .isNotEmpty);

      confirm();
      fixture.changes.value++;
      await tester.pump();
      expect(coverClosed, isFalse);
      expect(fixture.completed, isFalse);
      expect(find.text('独立通知'), findsOneWidget);
      expect(find.textContaining('私有平板', skipOffstage: false), findsNothing);
      expect(find.textContaining('private-device-', skipOffstage: false),
          findsNothing);
      expect(find.byType(TextField, skipOffstage: false), findsNothing);

      await tester.tap(_button('关闭通知'));
      await _waitUntil(tester, () => coverClosed);
      confirm();
      await tester.pump();
      expect(fixture.completed, isFalse,
          reason: 'Server denial must stay latched after the cover closes.');
      expect(fixture.requests, hasLength(2));
      _capture(tester, '关闭')();
      await _waitUntil(tester, () => fixture.completed);
      expect(fixture.result, isNull);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'network and recent-auth paging failures preserve choice while the 50-device limit remains adjustable',
      (tester) async {
    var pages = 0;
    final fixture = _Fixture(
        [for (var index = 0; index < 50; index++) _device(index)], () async {
      pages++;
      if (pages == 1) throw http.ClientException('offline');
      if (pages == 2) return reply({'errorCode': 'REAUTH_REQUIRED'}, 401);
      return reply({'items': [_device(50)], 'nextCursor': null});
    });
    await _mount(tester, fixture);
    expect(find.text('选择加入设备'), findsOneWidget);
    await tester.tap(_row(0));
    await tester.enterText(find.byType(TextField), '私有平板');
    _capture(tester, '加载更多设备')();
    for (var failedPage = 1; failedPage <= 2; failedPage++) {
      await _waitUntil(tester, () => pages == failedPage &&
          _button('重试').evaluate().isNotEmpty);
      expect(find.text('已选择 1 / 50 台 · 当前显示 50 台'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '私有平板');
      expect(tester.widget<CheckboxListTile>(_row(0)).value, isTrue);
      expect(fixture.completed, isFalse);
      _capture(tester, '重试')();
    }
    await _waitUntil(tester, () => pages == 3 &&
        find.text('已加载 51 台').evaluate().isNotEmpty);
    final scrolling = find.descendant(
        of: find.byType(ListView), matching: find.byType(Scrollable));
    for (var index = 1; index < 50; index++) {
      await tester.scrollUntilVisible(_row(index), 160, scrollable: scrolling);
      await tester.tap(_row(index));
      await tester.pump();
    }
    await tester.scrollUntilVisible(_row(50), 160, scrollable: scrolling);
    expect(tester.widget<CheckboxListTile>(_row(50)).onChanged, isNull);
    expect(find.textContaining('已达到 50 台上限'), findsOneWidget);
    await tester.scrollUntilVisible(_row(49), -160, scrollable: scrolling);
    await tester.tap(_row(49));
    await tester.pump();
    expect(find.textContaining('已达到 50 台上限'), findsNothing);
    await tester.scrollUntilVisible(_row(50), 160, scrollable: scrolling);
    await tester.tap(_row(50));
    await tester.pump();
    _capture(tester, '核对并加入 50 台')();
    await _waitUntil(tester, () => fixture.completed);
    expect(fixture.result, hasLength(50));
    expect(fixture.result!.map((row) => row['id']),
        allOf(contains('private-device-0'), contains('private-device-50'),
            isNot(contains('private-device-49'))));
    expect(fixture.requests, hasLength(4));
    expect(tester.takeException(), isNull);
  });
}
