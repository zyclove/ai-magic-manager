import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/schedule_week_view.dart';

void main() {
  testWidgets('weekly view keeps duplicate rows independently removable on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = <String, dynamic>{
      'day': 'MONDAY', 'start': '22:30', 'end': '01:15',
    };
    final second = Map<String, dynamic>.from(first);
    final friday = <String, dynamic>{
      'day': 'FRIDAY', 'start': '19:00', 'end': '20:00',
    };
    final source = [friday, first, second];
    final draft = List<Map<String, dynamic>>.from(source);
    Map<String, dynamic>? removed;
    late StateSetter update;
    var editable = true;
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
                body: SingleChildScrollView(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: StatefulBuilder(builder: (context, setState) {
                          update = setState;
                          return ScheduleWeekView(
                              windows: draft,
                              onRemove: editable
                                  ? (window) => setState(() {
                                        removed = window;
                                        draft.remove(window);
                                      })
                                  : null);
                        })))))));
    expect(find.text('22:30 – 01:15（次日）'), findsNWidgets(2));
    expect(find.text('周一'), findsOneWidget);
    expect(find.text('周五'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final duplicate = find.byKey(const ValueKey('schedule-weekly-window-2'));
    await tester.tap(find.descendant(
        of: duplicate,
        matching: find.byTooltip('移除周一 22:30 – 01:15（次日）')));
    await tester.pump();
    expect(identical(removed, second), isTrue);
    expect(draft, hasLength(2));
    expect(identical(draft.last, first), isTrue);
    expect(source, hasLength(3));
    expect(identical(source.last, second), isTrue);
    update(() => editable = false);
    await tester.pump();
    for (final chip in tester.widgetList<InputChip>(find.byType(InputChip))) {
      expect(chip.onDeleted, isNull);
    }
    expect(tester.takeException(), isNull);
  });
}
