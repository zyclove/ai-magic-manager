import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/ui/schedule_editor.dart';
import 'package:schedule_contracts/schedule_contracts.dart';

void main() {
  testWidgets('weekly composer adds only the missing selected day near capacity',
      (tester) async {
    final existing = <Json>[
      for (final day in ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY'])
        {'day': day, 'start': '18:00', 'end': '20:00'},
      ...List.generate(51,
          (_) => {'day': 'MONDAY', 'start': '22:00', 'end': '01:00'}),
    ];
    final batches = <List<Json>>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
                builder: (_, rebuild) => ScheduleWindowComposer(
                    weekly: true,
                    existingWeekly: existing,
                    remaining: maximumWeeklyWindows - existing.length,
                    onAdd: (rows) {
                      batches.add(rows);
                      rebuild(() => existing.addAll(rows));
                    })))));

    final add = find.ancestor(
        of: find.text('添加时段'),
        matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
    expect(tester.widget<ButtonStyleButton>(add).onPressed, isNotNull);
    await tester.tap(add);
    await tester.pump();

    expect(batches, [
      [
        {'day': 'FRIDAY', 'start': '18:00', 'end': '20:00'}
      ]
    ]);
    expect(existing, hasLength(maximumWeeklyWindows));
    expect(tester.widget<ButtonStyleButton>(add).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
