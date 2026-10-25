import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/access_request_dialog.dart';
import 'package:guardian/ui/design.dart';

const deviceId = '11111111-1111-1111-1111-111111111111';
Json policy({String version = 'version-1', int rules = 1}) => {
      'id': 'policy-1',
      'name': '课堂策略',
      'baseVersionId': version,
      'commonRules': [
        {'id': 'window', 'kind': 'TIME_WINDOW'}
      ],
      'applications': [
        {
          'id': 'app-1',
          'displayName': '课堂练习',
          'rules': List.generate(
              rules, (i) => {'id': 'lesson_$i', 'kind': 'APP_LAUNCH'}),
        }
      ],
    };
Future<PageResult> load(String path, String? cursor) async => path == 'devices'
    ? PageResult([
        {'id': deviceId, 'displayName': '教室平板', 'state': 'ACTIVE'},
        {
          'id': 'unconfirmed',
          'displayName': '待确认设备',
          'state': 'AWAITING_CONFIRMATION'
        }
      ], null)
    : PageResult([policy()], null);

Future<void> open(WidgetTester tester, Future<Json> Function(Json) submit,
    {Future<PageResult> Function(String, String?)? loader}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => showDialog<Json>(
                      context: context,
                      builder: (_) => AccessRequestDialog(
                          load: loader ?? load, submit: submit)),
                  child: const Text('打开申请'))))));
  await tester.tap(find.text('打开申请'));
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, Key key, String label) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> selectDevice(WidgetTester tester) =>
    choose(tester, const Key('request-device'), '教室平板 · 11111111…');
Future<void> selectApp(WidgetTester tester) =>
    choose(tester, const ValueKey('option-$deviceId'), '课堂练习 · 课堂策略');
Future<void> submit(WidgetTester tester, [String title = '提交申请']) async {
  final control = find.widgetWithText(FilledButton, title);
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pumpAndSettle();
}

DropdownButton<String> _deviceDropdown(WidgetTester tester, Finder field) =>
    tester.widget<DropdownButton<String>>(find.descendant(
        of: field,
        matching: find
            .byWidgetPredicate((widget) => widget is DropdownButton<String>)));

void main() {
  testWidgets('requires device application rules and bounded minutes',
      (tester) async {
    int writes = 0;
    await open(tester, (body) async {
      writes++;
      return body;
    });
    await submit(tester);
    expect(find.text('请选择设备'), findsOneWidget);
    expect(writes, 0);
    await selectDevice(tester);
    expect(find.text('待确认设备'), findsNothing);
    await selectApp(tester);
    await tester.enterText(find.byKey(const Key('request-minutes')), '61');
    await submit(tester);
    expect(find.text('请输入 1–60 的整数'), findsOneWidget);
    expect(writes, 0);
  });
  testWidgets('merges common rules and sends trimmed reason and seconds',
      (tester) async {
    Json? sent;
    await open(tester, (body) async {
      sent = body;
      return body;
    });
    await selectDevice(tester);
    await selectApp(tester);
    expect(find.text('申请放宽的规则（2/20）'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('request-minutes')), '5');
    await tester.enterText(find.byKey(const Key('request-reason')), '  课堂活动  ');
    await submit(tester);
    expect(sent, {
      'deviceId': deviceId,
      'policyId': 'policy-1',
      'baseVersionId': 'version-1',
      'applicationId': 'app-1',
      'ruleIds': ['lesson_0', 'window'],
      'requestedWindowSeconds': 300,
      'reason': '课堂活动'
    });
    expect(find.text('申请临时访问'), findsNothing);
  });
  testWidgets('empty option page preserves cursor and can load the next page',
      (tester) async {
    final cursors = <String?>[];
    await open(tester, (body) async => body, loader: (path, cursor) async {
      if (path == 'devices') return load(path, cursor);
      cursors.add(cursor);
      return cursor == null
          ? PageResult([], 'next-policy')
          : PageResult([policy()], null);
    });
    await selectDevice(tester);
    expect(find.text('本页没有可申请规则，可继续加载。'), findsOneWidget);
    await tester.ensureVisible(find.text('加载更多规则'));
    await tester.tap(find.text('加载更多规则'));
    await tester.pumpAndSettle();
    await selectApp(tester);
    expect(cursors, [null, 'next-policy']);
    expect(find.text('申请放宽的规则（2/20）'), findsOneWidget);
  });
  testWidgets(
      'expired device cursor restarts from the first page without losing the draft',
      (tester) async {
    final selectedDevice = (await load('devices', null)).items.first;
    final restarted = Completer<PageResult>();
    final cursors = <String?>[];
    Json? sent;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!restarted.isCompleted) restarted.complete(PageResult([], null));
      await tester.pumpAndSettle();
    });
    await open(tester, (body) async {
      sent = body;
      return body;
    }, loader: (path, cursor) async {
      if (path != 'devices') return load(path, cursor);
      cursors.add(cursor);
      return switch (cursors.length) {
        1 => PageResult([
            selectedDevice,
            {'id': 'old-unselected', 'displayName': '旧列表设备', 'state': 'ACTIVE'},
          ], 'expired-page'),
        2 => throw const ApiFailure(400, 'INVALID_CURSOR'),
        3 => restarted.future,
        _ => PageResult([], null),
      };
    });
    await selectDevice(tester);
    await selectApp(tester);
    await tester.enterText(find.byKey(const Key('request-minutes')), '7');
    await tester.enterText(find.byKey(const Key('request-reason')), '保留的申请理由');
    await tester.ensureVisible(find.text('加载更多设备'));
    await tester.tap(find.text('加载更多设备'));
    await tester.pumpAndSettle();
    expect(find.text('从首页重新加载设备'), findsOneWidget);
    expect(find.text('重试加载设备'), findsNothing);
    final deviceField = find.byKey(const Key('request-device'));
    expect(tester.state<FormFieldState<String>>(deviceField).value, deviceId);
    final restart = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '从首页重新加载设备'))
        .onPressed!;
    restart();
    restart();
    await tester.pump();
    expect(cursors, [null, 'expired-page', null]);
    expect(
        _deviceDropdown(tester, deviceField).items!.map((item) => item.value),
        contains('old-unselected'),
        reason:
            'Keep the existing choices until the replacement page succeeds.');
    restarted.complete(PageResult([
      {'id': 'new-first', 'displayName': '新首页设备', 'state': 'ACTIVE'},
    ], 'fresh-next'));
    await tester.pumpAndSettle();
    expect(
        _deviceDropdown(tester, deviceField).items!.map((item) => item.value),
        unorderedEquals(['new-first', deviceId]));
    expect(tester.state<FormFieldState<String>>(deviceField).value, deviceId);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('request-minutes')))
            .controller!
            .text,
        '7');
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('request-reason')))
            .controller!
            .text,
        '保留的申请理由');
    expect(find.text('申请放宽的规则（2/20）'), findsOneWidget);
    await tester.ensureVisible(find.text('加载更多设备'));
    await tester.tap(find.text('加载更多设备'));
    await tester.pumpAndSettle();
    expect(cursors, [null, 'expired-page', null, 'fresh-next']);
    await submit(tester);
    expect(sent?['deviceId'], deviceId);
    expect(sent?['requestedWindowSeconds'], 420);
    expect(sent?['reason'], '保留的申请理由');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'restarting devices clears an explicitly revoked selection and ignores its late rules error',
      (tester) async {
    const replacement = '33333333-3333-3333-3333-333333333333';
    const targetChanged = ApiFailure(409, 'ACCESS_TARGET_CHANGED');
    final selectedDevice = (await load('devices', null)).items.first;
    final oldRules = Completer<PageResult>();
    var deviceReads = 0, ruleReads = 0;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!oldRules.isCompleted) oldRules.complete(PageResult([], null));
      await tester.pumpAndSettle();
    });
    await open(tester, (body) async => body, loader: (path, cursor) async {
      if (path != 'devices') {
        return ++ruleReads == 2
            ? oldRules.future
            : PageResult([policy()], null);
      }
      return switch (++deviceReads) {
        1 => PageResult([selectedDevice], 'expired-page'),
        2 => throw const ApiFailure(400, 'INVALID_CURSOR'),
        _ => PageResult([
            {...selectedDevice, 'state': 'REVOKED'},
            {'id': replacement, 'displayName': '替代设备', 'state': 'ACTIVE'},
          ], null),
      };
    });
    await selectDevice(tester);
    await selectApp(tester);
    await tester.enterText(find.byKey(const Key('request-minutes')), '8');
    await tester.enterText(find.byKey(const Key('request-reason')), '不要丢失的理由');
    await tester.ensureVisible(find.text('加载更多设备'));
    await tester.tap(find.text('加载更多设备'));
    await tester.pumpAndSettle();
    final refreshRules = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '刷新可申请规则'))
        .onPressed!;
    refreshRules();
    await tester.pump();
    expect(ruleReads, 2);
    final restart = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '从首页重新加载设备'))
        .onPressed!;
    restart();
    await tester.pumpAndSettle();

    final deviceField = find.byKey(const Key('request-device'));
    expect(tester.state<FormFieldState<String>>(deviceField).value, isNull);
    final dropdown = _deviceDropdown(tester, deviceField);
    expect(dropdown.items!.map((item) => item.value), [replacement]);
    expect(dropdown.onChanged, isNotNull);
    expect(find.text('当前选择的设备已失效，已保留时长和理由。请重新选择设备。'), findsOneWidget);
    oldRules.completeError(const ApiFailure(503, 'TEMPORARY_FAILURE'));
    await tester.pumpAndSettle();
    expect(find.text(targetChanged.message), findsOneWidget,
        reason:
            'The old device rules request must not replace the recovery reason.');
    expect(find.byKey(const ValueKey('option-$deviceId')), findsNothing);
    expect(find.text('申请放宽的规则（2/20）'), findsNothing);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('request-minutes')))
            .controller!
            .text,
        '8');
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('request-reason')))
            .controller!
            .text,
        '不要丢失的理由');
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交申请'))
            .onPressed,
        isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary device load failure retries the same cursor',
      (tester) async {
    final selectedDevice = (await load('devices', null)).items.first;
    final cursors = <String?>[];
    await open(tester, (body) async => body, loader: (path, cursor) async {
      if (path != 'devices') return load(path, cursor);
      cursors.add(cursor);
      return switch (cursors.length) {
        1 => PageResult([selectedDevice], 'retry-page'),
        2 => throw const ApiFailure(503, 'TEMPORARY_FAILURE'),
        _ => PageResult([
            {'id': 'next-device', 'displayName': '后续设备', 'state': 'ACTIVE'},
          ], null),
      };
    });
    await tester.ensureVisible(find.text('加载更多设备'));
    await tester.tap(find.text('加载更多设备'));
    await tester.pumpAndSettle();
    expect(find.text('从首页重新加载设备'), findsNothing);
    await tester.ensureVisible(find.text('重试加载设备'));
    await tester.tap(find.text('重试加载设备'));
    await tester.pumpAndSettle();
    expect(cursors, [null, 'retry-page', 'retry-page']);
    final deviceField = find.byKey(const Key('request-device'));
    expect(
        _deviceDropdown(tester, deviceField).items!.map((item) => item.value),
        unorderedEquals([deviceId, 'next-device']));
    expect(find.text('加载更多设备'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown submission freezes values and retries the original body',
      (tester) async {
    final writes = <Json>[];
    await open(tester, (body) async {
      writes.add(body);
      if (writes.length == 1) throw const ApiFailure(503, 'TEMPORARY_FAILURE');
      return body;
    });
    await selectDevice(tester);
    await selectApp(tester);
    await submit(tester);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('request-minutes')))
            .enabled,
        false);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('request-reason')))
            .enabled,
        false);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                find.byKey(const Key('request-device')))
            .onChanged,
        isNull);
    await submit(tester, '重试原提交');
    expect(writes.length, 2);
    expect(writes[1], writes[0]);
  });
  testWidgets('stale baseline disables resubmit until refreshed and reselected',
      (tester) async {
    int writes = 0, reads = 0;
    await open(tester, (body) async {
      writes++;
      throw const ApiFailure(409, 'BASELINE_CHANGED');
    }, loader: (path, cursor) async {
      if (path == 'devices') return load(path, cursor);
      reads++;
      return PageResult([policy(version: 'version-$reads')], null);
    });
    await selectDevice(tester);
    await selectApp(tester);
    await submit(tester);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交申请'))
            .onPressed,
        isNull);
    await tester.ensureVisible(find.text('刷新可申请规则'));
    await tester.tap(find.text('刷新可申请规则'));
    await tester.pumpAndSettle();
    expect(find.text('申请放宽的规则（2/20）'), findsNothing);
    await selectApp(tester);
    expect(reads, 2);
    expect(writes, 1);
  });
  testWidgets('twenty-rule maximum keeps selected rules removable',
      (tester) async {
    await open(tester, (body) async => body,
        loader: (path, cursor) async => path == 'devices'
            ? load(path, cursor)
            : PageResult([policy(rules: 21)], null));
    await selectDevice(tester);
    await selectApp(tester);
    expect(find.text('申请放宽的规则（0/20）'), findsOneWidget);
    for (int i = 0; i < 20; i++) {
      final item = find.byType(CheckboxListTile).at(i);
      await tester.ensureVisible(item);
      await tester.tap(item);
      await tester.pump();
    }
    expect(find.text('申请放宽的规则（20/20）'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).at(20))
            .onChanged,
        isNull);
    expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
            .onChanged,
        isNotNull);
  });
  testWidgets('mobile submit failure reveals the reason and recovery action',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const failure = ApiFailure(409, 'BASELINE_CHANGED');
    await open(tester, (body) async => throw failure);
    await selectDevice(tester);
    await selectApp(tester);
    await submit(tester);
    expect(find.text(failure.message).hitTestable(), findsOneWidget);
    expect(find.text('刷新可申请规则').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
