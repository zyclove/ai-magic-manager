import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/class_action_dialog.dart';
import 'package:guardian/ui/design.dart';

Future<void> open(WidgetTester tester, Future<Json> Function(Json) send,
    {void Function(Json?)? returned}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    final result = await showDialog<Json>(
                        context: context,
                        builder: (_) => ClassActionDialog(
                            title: '新建班级',
                            description: '设置班级名称',
                            field: 'name',
                            fieldLabel: '班级名称',
                            submitLabel: '创建班级',
                            onSubmit: send));
                    returned?.call(result);
                  },
                  child: const Text('打开'))))));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('class name is required and trimmed before submission',
      (tester) async {
    Json? sent;
    await open(tester, (body) async {
      sent = body;
      return body;
    });
    await tester.tap(find.text('创建班级'));
    await tester.pumpAndSettle();
    expect(sent, isNull);
    expect(find.text('请输入班级名称'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('class-name')), '  七年级一班  ');
    await tester.tap(find.text('创建班级'));
    await tester.pumpAndSettle();
    expect(sent, {'name': '七年级一班'});
  });
  testWidgets('unknown result freezes payload and retries the original body',
      (tester) async {
    final sent = <Json>[];
    await open(tester, (body) async {
      sent.add(body);
      if (sent.length == 1) throw const ApiFailure(503, 'TEMPORARY_FAILURE');
      return body;
    });
    await tester.enterText(find.byKey(const Key('class-name')), '七年级一班');
    await tester.tap(find.text('创建班级'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('class-name')))
            .enabled,
        false);
    await tester.tap(find.text('重试原提交'));
    await tester.pumpAndSettle();
    expect(sent, [
      {'name': '七年级一班'},
      {'name': '七年级一班'}
    ]);
  });
  testWidgets(
      'version conflict disables stale resubmit and requests parent refresh',
      (tester) async {
    Json? result;
    await open(tester,
        (_) async => throw const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'),
        returned: (value) => result = value);
    await tester.enterText(find.byKey(const Key('class-name')), '七年级一班');
    await tester.tap(find.text('创建班级'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '创建班级'))
            .onPressed,
        isNull);
    await tester.tap(find.text('关闭并刷新'));
    await tester.pumpAndSettle();
    expect(result, {'refresh': true});
  });
}
