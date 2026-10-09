import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/design.dart';

void main() {
  testWidgets(
      'required fields block submission and server errors preserve input',
      (tester) async {
    var submissions = 0;
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => formDialog(context,
                            title: '添加儿童档案',
                            fields: const [FieldSpec('nickname', '昵称')],
                            onSubmit: (data) async {
                          submissions++;
                          throw Exception('unavailable');
                        }),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入昵称'), findsOneWidget);
    expect(submissions, 0);
    await tester.enterText(find.byType(TextFormField), '小明');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(submissions, 1);
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('加载未完成，请重试。'), findsOneWidget);
  });
}
