import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/schedule_exception_editor.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';

final _date = DateTime(2026, 12, 25);

class _Host {
  final access = ValueNotifier(true);
  final closed = Completer<Json?>();
  late BuildContext context;
  OwnedDialogRoute<void>? parent;
}

Future<_Host> _open(WidgetTester tester,
    {Json? initial, bool parent = false}) async {
  final host = _Host();
  Widget launch(BuildContext context) => TextButton(
      onPressed: () async {
        host.closed.complete(await editScheduleException(context,
            date: _date,
            initial: initial,
            accessChanges: host.access,
            hasAccess: () => host.access.value));
      },
      child: const Text('编辑例外'));
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(body: Builder(builder: (context) {
        host.context = context;
        return parent
            ? TextButton(
                onPressed: () {
                  host.parent = OwnedDialogRoute<void>(
                      context: context,
                      builder: (inner) => AlertDialog(content: launch(inner)));
                  unawaited(presentOwnedDialog(context, host.parent!));
                },
                child: const Text('打开父窗口'))
            : launch(context);
      }))));
  if (parent) {
    await tester.tap(find.text('打开父窗口'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('编辑例外'));
  await tester.pumpAndSettle();
  return host;
}

Future<void> _dispose(WidgetTester tester, ValueNotifier<bool> access) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  access.dispose();
}

FilledButton _apply(WidgetTester tester) => tester
    .widget<FilledButton>(find.byKey(const Key('schedule-exception-apply')));

Future<void> _time(
    WidgetTester tester, String key, String hour, String minute) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  expect(find.byType(TimePickerDialog), findsOneWidget);
  final fields = find.descendant(
      of: find.byType(TimePickerDialog), matching: find.byType(TextFormField));
  await tester.enterText(fields.at(0), hour);
  await tester.enterText(fields.at(1), minute);
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
}

Future<void> _mode(WidgetTester tester, bool closed) async {
  final field = find.byKey(Key(closed
      ? 'schedule-exception-mode-closed'
      : 'schedule-exception-mode-custom'));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final field = find.byKey(Key(key));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('new custom exception edits exact overnight times locally',
      (tester) async {
    final host = await _open(tester);
    try {
      expect(find.textContaining('2026-12-25'), findsOneWidget);
      expect(_apply(tester).onPressed, isNull);
      await _tapKey(tester, 'schedule-exception-add');
      await _time(tester, 'schedule-exception-start-0', '22', '30');
      await _time(tester, 'schedule-exception-end-0', '01', '15');
      expect(find.text('跨午夜，结束于次日'), findsOneWidget);
      _apply(tester).onPressed!();
      await tester.pumpAndSettle();
      expect(await host.closed.future, {
        'date': '2026-12-25',
        'windows': [
          {'start': '22:30', 'end': '01:15'},
        ],
      });
    } finally {
      await _dispose(tester, host.access);
    }
  });

  testWidgets(
      'duplicate original windows survive editing cancellation and apply',
      (tester) async {
    final initial = <String, dynamic>{
      'date': '2026-12-25',
      'windows': [
        {'start': '09:00', 'end': '11:00'},
        {'start': '09:00', 'end': '11:00'},
      ],
    };
    final before = jsonEncode(initial);
    final canceled = await _open(tester, initial: initial);
    try {
      await _time(tester, 'schedule-exception-start-0', '08', '15');
      await tester.tap(find.byKey(const Key('schedule-exception-cancel')));
      await tester.pumpAndSettle();
      expect(await canceled.closed.future, isNull);
      expect(jsonEncode(initial), before);
    } finally {
      await _dispose(tester, canceled.access);
    }
    final applied = await _open(tester, initial: initial);
    try {
      _apply(tester).onPressed!();
      await tester.pumpAndSettle();
      final result = (await applied.closed.future)!;
      expect(result, initial);
      ((result['windows'] as List).first as Json)['start'] = '07:00';
      expect(jsonEncode(initial), before,
          reason: 'Returned windows must not borrow the original records.');
    } finally {
      await _dispose(tester, applied.access);
    }
  });

  testWidgets('closed mode retains local custom windows but returns none',
      (tester) async {
    final host = await _open(tester, initial: {
      'date': '2026-12-25',
      'windows': <Json>[],
    });
    try {
      expect(_apply(tester).onPressed, isNotNull);
      await _mode(tester, false);
      expect(_apply(tester).onPressed, isNull);
      await _tapKey(tester, 'schedule-exception-add');
      await _mode(tester, true);
      await _mode(tester, false);
      expect(
          find.byKey(const Key('schedule-exception-start-0')), findsOneWidget);
      await _mode(tester, true);
      _apply(tester).onPressed!();
      await tester.pumpAndSettle();
      expect(await host.closed.future,
          {'date': '2026-12-25', 'windows': <Json>[]});
    } finally {
      await _dispose(tester, host.access);
    }
  });

  testWidgets('eight window limit and equal endpoints cannot be applied',
      (tester) async {
    final host = await _open(tester, initial: {
      'date': '2026-12-25',
      'windows': List.generate(8, (_) => {'start': '18:00', 'end': '20:00'}),
    });
    try {
      final add = tester.widget<OutlinedButton>(
          find.byKey(const Key('schedule-exception-add')));
      expect(add.onPressed, isNull);
      await _tapKey(tester, 'schedule-exception-remove-0');
      await _tapKey(tester, 'schedule-exception-add');
      await _time(tester, 'schedule-exception-end-0', '18', '00');
      expect(_apply(tester).onPressed, isNull);
      expect(find.textContaining('不能相同'), findsOneWidget);
      await _time(tester, 'schedule-exception-end-0', '19', '00');
      _apply(tester).onPressed!();
      await tester.pumpAndSettle();
      expect(((await host.closed.future)!['windows'] as List).length, 8);
    } finally {
      await _dispose(tester, host.access);
    }
  });

  testWidgets(
      'date picker and exception callbacks stay revoked after scope ABA',
      (tester) async {
    final access = ValueNotifier(true);
    final picked = Completer<DateTime?>();
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      picked.complete(await pickScheduleExceptionDate(context,
                          accessChanges: access,
                          hasAccess: () => access.value));
                    },
                    child: const Text('选择日期'))))));
    try {
      await tester.tap(find.text('选择日期'));
      await tester.pumpAndSettle();
      final calendar =
          tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker));
      expect(calendar.firstDate, DateTime(1900));
      expect(calendar.lastDate, DateTime(2200, 12, 31));
      final confirm = tester
          .widget<FilledButton>(
              find.byKey(const Key('schedule-exception-date-apply')))
          .onPressed!;
      access.value = false;
      access.value = true;
      calendar.onDateChanged(_date);
      confirm();
      await tester.pumpAndSettle();
      expect(await picked.future, isNull);
    } finally {
      await _dispose(tester, access);
    }
    final host = await _open(tester, initial: {
      'date': '2026-12-25',
      'windows': [
        {'start': '09:00', 'end': '11:00'},
      ],
    });
    try {
      final apply = _apply(tester).onPressed!;
      host.access.value = false;
      host.access.value = true;
      apply();
      await tester.pumpAndSettle();
      expect(await host.closed.future, isNull);
      expect(find.text('09:00'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, host.access);
    }
  });

  testWidgets('covered parent removal ends only owned form and time picker',
      (tester) async {
    final host = await _open(tester, parent: true, initial: {
      'date': '2026-12-25',
      'windows': [
        {'start': '09:00', 'end': '11:00'},
      ],
    });
    try {
      final apply = _apply(tester).onPressed!;
      final start = tester
          .widget<OutlinedButton>(
              find.byKey(const Key('schedule-exception-start-0')))
          .onPressed!;
      start();
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
      unawaited(showDialog<void>(
          context: host.context,
          builder: (_) => const AlertDialog(title: Text('独立通知'))));
      await tester.pumpAndSettle();
      Navigator.of(host.context).removeRoute(host.parent!);
      await tester.pumpAndSettle();
      apply();
      start();
      await tester.pumpAndSettle();
      expect(await host.closed.future, isNull);
      expect(find.text('独立通知'), findsOneWidget);
      expect(find.byType(TimePickerDialog, skipOffstage: false), findsNothing);
      expect(
          find.byKey(const Key('schedule-exception-apply'),
              skipOffstage: false),
          findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, host.access);
    }
  });
}
