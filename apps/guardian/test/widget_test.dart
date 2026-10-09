import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/core/api.dart';

void main() {
  testWidgets('detail facts have explicit readable accessibility labels',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () =>
                        actionDetails(context, '申请详情', {'状态': '已撤销'}),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('状态：已撤销'), findsOneWidget);
    semantics.dispose();
  });
  testWidgets('live access loss removes details and mutation actions',
      (tester) async {
    final allowed = ValueNotifier(true);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => actionDetails(
                        context, '申请详情', {'理由': '私有申请理由'},
                        actions: [DetailAction('批准申请', (_) async {})],
                        accessChanges: allowed,
                        hasAccess: () => allowed.value),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('私有申请理由'), findsOneWidget);
    allowed.value = false;
    await tester.pumpAndSettle();
    expect(find.text('私有申请理由'), findsNothing);
    expect(find.text('批准申请'), findsNothing);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    allowed.dispose();
  });
  testWidgets('unknown submission freezes original values for explicit retry',
      (tester) async {
    final submissions = <Json>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => formDialog(context,
                            title: '创建',
                            fields: const [FieldSpec('name', '名称')],
                            onSubmit: (value) async {
                          submissions.add(Map.of(value));
                          if (submissions.length == 1) {
                            throw const ApiFailure(0, 'NETWORK_ERROR');
                          }
                          return {'id': 'same-result'};
                        }),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '原内容');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
        isFalse);
    expect(find.text('重试原提交'), findsOneWidget);
    await tester.tap(find.text('重试原提交'));
    await tester.pumpAndSettle();
    expect(submissions, [
      {'name': '原内容'},
      {'name': '原内容'}
    ]);
    expect(find.byType(AlertDialog), findsNothing);
  });
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
