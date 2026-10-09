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
