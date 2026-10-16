import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';

void main() {
  testWidgets('queued edit callbacks submit only once before the next frame',
      (tester) async {
    final pending = Completer<Json?>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => formDialog(context,
              title: '编辑名称',
              fields: const [FieldSpec('name', '名称')],
              initial: const {'name': '班级平板'}, onSubmit: (values) {
            calls++;
            expect(values, {'name': '班级平板'});
            return pending.future;
          }),
          child: const Text('打开编辑'),
        );
      })),
    ));
    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();
    final callback = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
        .onPressed!;
    callback();
    callback();
    try {
      expect(calls, 1);
    } finally {
      pending.complete({'name': '班级平板'});
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
