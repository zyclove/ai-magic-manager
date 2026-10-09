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
  testWidgets('uncertain plan writes freeze fields and retry the same body',
      (tester) async {
    final submitted = <Json>[];
    await open(tester, (value) async {
      submitted.add(value);
      if (submitted.length == 1) throw const ApiFailure(0, 'NETWORK_ERROR');
    });
    await tester.tap(find.text('保存计划'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextFormField>(find.byType(TextFormField).first).enabled,
        isFalse);
    await tester.tap(find.text('重试原提交'));
    await tester.pumpAndSettle();
    expect(submitted, hasLength(2));
    expect(submitted.first, submitted.last);
  });
}
