import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/quota_plan_editor.dart';
import 'package:guardian/ui/design.dart';

Future<void> open(WidgetTester tester, Future<void> Function(Json) submit,
    {Json? plan, String? targetDescription}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => QuotaPlanEditor(
                            plan: plan,
                            targetDescription: targetDescription,
                            children: const {'child': '验收档案'},
                            applications: const {},
                            loadCalendar: (_) async => {
                              'timeZone': 'America/Los_Angeles',
                              'currentDate': '2026-10-08'
                            },
                            onSubmit: submit,
                          )),
                  child: const Text('打开'))))));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.ancestor(of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var turn = 0; turn < 24 && !ready(); turn++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: 'The quota plan flow must reach its bounded next state.');
}

void main() {
  testWidgets('editing identifies the child and application being changed',
      (tester) async {
    await open(tester, (_) async {},
        plan: {'name': '每周使用额度', 'subjectId': 'child'},
        targetDescription: '儿童：小明\n额度范围：数学练习');
    expect(find.text('儿童：小明\n额度范围：数学练习'), findsOneWidget);
    expect(find.textContaining('生效日：2026-10-09'), findsOneWidget);
  });
  testWidgets('server errors scroll into view above the fixed save action',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, (_) async {
      throw const ApiFailure(401, 'REAUTH_REQUIRED');
    });
    await tester.tap(find.text('保存计划'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(FailureView)).bottom,
        lessThan(tester.getRect(find.text('保存计划')).top));
  });
  testWidgets('corrected minute input clears its validation error immediately',
      (tester) async {
    await open(tester, (_) async {});
    final monday = find.widgetWithText(TextFormField, '周一（分钟）');
    await tester.ensureVisible(monday);
    await tester.enterText(monday, '1500');
    await tester.tap(find.text('保存计划'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 0–1440 分钟'), findsOneWidget);
    await tester.ensureVisible(monday);
    await tester.enterText(monday, '45');
    await tester.pumpAndSettle();
    expect(find.text('请输入 0–1440 分钟'), findsNothing);
  });
  testWidgets(
      'weekly plan uses server calendar and submits all seven days in seconds',
      (tester) async {
    Json? result;
    await open(tester, (value) async {
      result = value;
    });
    await tester.tap(find.text('保存计划'));
    await tester.pumpAndSettle();
    expect(result?['timeZone'], 'America/Los_Angeles');
    expect(result?['effectiveFrom'], '2026-10-08');
    expect(result?['weeklyLimits'], hasLength(7));
    expect((result?['weeklyLimits'] as Map)['MONDAY'], 3600);
    expect(result?['scope'], 'TOTAL');
  });

  testWidgets('sixty date overrides edit locally with exact seconds and weekday copies preserve the source duration',
      (tester) async {
    final dates = List<String>.generate(60, (index) => DateTime.utc(2026, 10, 9)
        .add(Duration(days: index)).toIso8601String().substring(0, 10));
    final originalOverrides = <String, int>{
      for (var index = 0; index < dates.length; index++) dates[index]: index == 0 ? 3661 : 3600,
    };
    final submitted = <Json>[];
    await open(tester, (value) async => submitted.add(value), plan: {
      'name': '精确日期额度', 'subjectId': 'child',
      'weeklyLimits': {for (final day in quotaWeek.keys) day: day == 'MONDAY' ? 3661 : 3600},
      'dateOverrides': originalOverrides,
    });
    final copy = _button('周一额度应用到工作日');
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pump();
    final first = find.byKey(Key('quota-plan-edit-override-${dates.first}'));
    final second = find.byKey(Key('quota-plan-edit-override-${dates[1]}'));
    final minutes = find.widgetWithText(TextFormField, '分钟');
    final seconds = find.widgetWithText(TextFormField, '秒');
    bool planReady() => find.byType(EditDialog).evaluate().isEmpty &&
        first.evaluate().length == 1 && tester.widget<IconButton>(first).onPressed != null;
    Future<void> edit(Finder entry) async {
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await _until(tester, () => minutes.evaluate().length == 1);
      expect(tester.widget<EditDialog>(find.byType(EditDialog)).canCommit, isFalse);
      expect(find.byType(DatePickerDialog), findsNothing);
    }
    Future<void> apply() async {
      await tester.ensureVisible(_button('应用到草稿'));
      await tester.tap(_button('应用到草稿'));
      await _until(tester, planReady);
    }

    await edit(first);
    expect(tester.widget<TextFormField>(minutes).controller!.text, '61');
    expect(tester.widget<TextFormField>(seconds).controller!.text, '1');
    await tester.enterText(minutes, '5');
    await tester.enterText(seconds, '9');
    await tester.tap(find.descendant(of: find.byType(EditDialog), matching: _button('取消')));
    await _until(tester, planReady);
    expect(submitted, isEmpty);
    await edit(first);
    expect(tester.widget<TextFormField>(minutes).controller!.text, '61');
    expect(tester.widget<TextFormField>(seconds).controller!.text, '1');
    await apply();
    expect(submitted, isEmpty);
    await edit(second);
    await tester.enterText(minutes, '1440');
    await tester.enterText(seconds, '1');
    await tester.ensureVisible(_button('应用到草稿'));
    await tester.tap(_button('应用到草稿'));
    await _until(tester, () => find.byType(FailureView).evaluate().length == 1);
    expect(tester.widget<TextFormField>(minutes).enabled, isTrue);
    expect(tester.widget<TextFormField>(seconds).enabled, isTrue);
    expect(submitted, isEmpty);
    await tester.enterText(minutes, '0');
    await tester.enterText(seconds, '0');
    await apply();
    expect(submitted, isEmpty, reason: 'Date edits apply only to the local draft.');
    await tester.ensureVisible(_button('保存计划'));
    await tester.tap(_button('保存计划'));
    await _until(tester, () => find.byType(QuotaPlanEditor).evaluate().isEmpty);
    expect(submitted, hasLength(1));
    final body = submitted.single;
    expect(body['dateOverrides'], {...originalOverrides, dates[1]: 0});
    expect((body['dateOverrides'] as Map).values.every((value) => value is int), isTrue);
    for (final day in ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY']) {
      expect((body['weeklyLimits'] as Map)[day], 3661);
    }
    for (final day in ['SATURDAY', 'SUNDAY']) {
      expect((body['weeklyLimits'] as Map)[day], 3600);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('uncertain plan writes freeze nested data and retain it through reauthentication',
      (tester) async {
    final submitted = <Json>[];
    await open(tester, (value) async {
      submitted.add(value);
      if (submitted.length == 1) throw const ApiFailure(408, 'REQUEST_TIMEOUT');
      if (submitted.length == 2) throw const ApiFailure(401, 'REAUTH_REQUIRED');
    }, plan: {
      'name': '原精确额度', 'subjectId': 'child',
      'weeklyLimits': {'MONDAY': 3661}, 'dateOverrides': {'2026-10-09': 3661},
    });
    await tester.tap(find.text('保存计划'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextFormField>(find.byType(TextFormField).first).enabled,
        isFalse);
    final frozen = jsonEncode(submitted.single);
    expect(() => submitted.single['name'] = 'changed', throwsUnsupportedError);
    expect(() => (submitted.single['weeklyLimits'] as Map)['MONDAY'] = 0, throwsUnsupportedError);
    expect(() => (submitted.single['dateOverrides'] as Map)['2026-10-09'] = 0, throwsUnsupportedError);
    await tester.tap(find.text('重试原提交'));
    await tester.pumpAndSettle();
    expect(submitted, hasLength(2));
    expect(tester.widget<TextFormField>(find.byType(TextFormField).first).enabled, isFalse);
    expect(find.text('重试原提交'), findsOneWidget);
    expect(find.text('保存计划'), findsNothing);
    await tester.tap(find.text('重试原提交'));
    await tester.pumpAndSettle();
    expect(submitted, hasLength(3));
    expect(submitted.every((body) => jsonEncode(body) == frozen), isTrue);
    expect((submitted.last['weeklyLimits'] as Map)['MONDAY'], 3661);
    expect((submitted.last['dateOverrides'] as Map)['2026-10-09'], 3661);
    expect(find.byType(QuotaPlanEditor), findsNothing);
  });

  testWidgets('terminal plan results stop old callbacks and unknown closing requires its current confirmation',
      (tester) async {
    for (final failure in [
      const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'),
      const ApiFailure(410, 'IDEMPOTENCY_RESULT_EXPIRED'),
    ]) {
      var attempts = 0;
      await open(tester, (_) async {
        attempts++;
        throw failure;
      });
      final originalSave = tester.widget<ButtonStyleButton>(_button('保存计划')).onPressed!;
      originalSave();
      await tester.pumpAndSettle();
      expect(attempts, 1);
      expect(tester.widget<ButtonStyleButton>(_button('已停止旧提交')).onPressed, isNull);
      expect(tester.widget<TextFormField>(find.byType(TextFormField).first).enabled, isFalse);
      expect(find.textContaining('输入以只读方式保留'), findsOneWidget);
      expect(find.text('重试原提交'), findsNothing);
      originalSave();
      await tester.pumpAndSettle();
      expect(attempts, 1, reason: 'A stopped plan must never resend through an old save callback.');
      await tester.tap(_button('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(QuotaPlanEditor), findsNothing);
    }

    var attempts = 0;
    await open(tester, (_) async {
      attempts++;
      throw const ApiFailure(503, 'SERVICE_UNAVAILABLE');
    });
    await tester.tap(_button('保存计划'));
    await tester.pumpAndSettle();
    final close = find.byKey(const Key('quota-plan-close-unknown'));
    final confirm = find.byKey(const Key('quota-plan-confirm-close-unknown'));
    await tester.tap(close);
    await tester.pumpAndSettle();
    final oldConfirm = tester.widget<ButtonStyleButton>(confirm).onPressed!;
    await tester.tap(find.byKey(const Key('quota-plan-keep-unknown')));
    await tester.pumpAndSettle();
    oldConfirm();
    await tester.pumpAndSettle();
    expect(find.byType(QuotaPlanEditor), findsOneWidget);
    expect(confirm, findsNothing);
    expect(attempts, 1);
    await tester.tap(close);
    await tester.pumpAndSettle();
    oldConfirm();
    await tester.pumpAndSettle();
    expect(find.byType(QuotaPlanEditor), findsOneWidget);
    expect(confirm, findsOneWidget);
    expect(attempts, 1, reason: 'Reopening confirmation must not revive a callback from the previous confirmation.');
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.byType(QuotaPlanEditor), findsNothing);
    expect(attempts, 1, reason: 'Closing an unknown plan only leaves the form; it does not retry or cancel its server write.');
    var deniedAttempts = 0;
    await open(tester, (_) async {
      deniedAttempts++;
      throw const ApiFailure(403, 'ACCESS_DENIED');
    });
    final deniedSave = tester.widget<ButtonStyleButton>(_button('保存计划')).onPressed!;
    deniedSave();
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNothing);
    deniedSave();
    await tester.pumpAndSettle();
    expect(deniedAttempts, 1, reason: 'An access denial must retire held saves as well as hide private inputs.');
    await tester.tap(_button('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(QuotaPlanEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
