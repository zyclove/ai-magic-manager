import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/usage_reports.dart';
import 'package:guardian/ui/usage_report_device_picker.dart';
import 'usage_reports_test.dart' show registration, subject;

void main() {
  final targets = List.generate(
      201,
      (i) => UsageReportTarget(
          '${i.toString().padLeft(8, '0')}-1111-1111-1111-111111111111',
          registration,
          subject,
          '设备 $i'));
  testWidgets(
      'large selection is explicit and capped without silently truncating',
      (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: UsageReportDevicePicker(
                targets: targets, selected: const {}, limit: 200))));
    await t.pumpAndSettle();
    expect(
        t
            .widget<TextButton>(find.widgetWithText(TextButton, '选择筛选结果'))
            .onPressed,
        isNull);
    await t.enterText(find.byType(TextField), '设备 1');
    await t.pumpAndSettle();
    await t.tap(find.text('选择筛选结果'));
    await t.pumpAndSettle();
    expect(find.text('已选 111 / 200 台'), findsOneWidget);
    await t.tap(find.text('清空选择'));
    await t.pumpAndSettle();
    expect(find.text('已选 0 / 200 台'), findsOneWidget);
  });
  testWidgets('exactly 200 devices can be explicitly selected', (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: UsageReportDevicePicker(
                targets: targets.take(200).toList(),
                selected: const {},
                limit: 200))));
    await t.pumpAndSettle();
    await t.tap(find.text('选择筛选结果'));
    await t.pumpAndSettle();
    expect(find.text('已选 200 / 200 台'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
