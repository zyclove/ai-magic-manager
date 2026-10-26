import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/class_action_dialog.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';

Future<void> open(WidgetTester tester, Future<Json> Function(Json) send,
    {void Function(Json?)? returned, String field = 'name',
    String fieldLabel = '班级名称', Map<String, String>? options}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    final result = await presentOwnedDialog<Json>(context,
                        OwnedDialogRoute<Json>(context: context,
                            builder: (_) => ClassActionDialog(
                                title: '新建班级',
                                description: '设置班级名称',
                                field: field,
                                fieldLabel: fieldLabel,
                                options: options,
                                submitLabel: '创建班级',
                                onSubmit: send)));
                    returned?.call(result);
                  },
                  child: const Text('打开'))))));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Finder get submitButton => find.byKey(const Key('class-action-submit'));
Finder get closeButton => find.byKey(const Key('class-action-close'));

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

  testWidgets('unknown result remains frozen after retry authentication refusal',
      (tester) async {
    final sent = <Json>[];
    await open(tester, (body) async {
      sent.add(body);
      expect(() => body['name'] = '不能改写原提交', throwsUnsupportedError);
      if (sent.length == 1) throw const ApiFailure(503, 'TEMPORARY_FAILURE');
      if (sent.length == 2) throw const ApiFailure(401, 'UNAUTHENTICATED');
      return body;
    });
    await tester.enterText(find.byKey(const Key('class-name')), '七年级一班');
    final heldSubmit = tester.widget<FilledButton>(submitButton).onPressed!;
    await tester.tap(submitButton);
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byKey(const Key('class-name'))).enabled, false);
    heldSubmit();
    await tester.pumpAndSettle();
    expect(sent, hasLength(2));
    expect(tester.widget<TextFormField>(find.byKey(const Key('class-name'))).enabled, false);
    expect(find.text('重试原提交'), findsOneWidget);
    expect(tester.widget<FailureView>(find.byType(FailureView)).error,
        isA<ApiFailure>().having((value) => value.status, 'status', 401));
    heldSubmit();
    await tester.pumpAndSettle();
    expect(sent, [
      {'name': '七年级一班'}, {'name': '七年级一班'}, {'name': '七年级一班'},
    ]);
    expect(identical(sent[0], sent[1]), isTrue);
    expect(identical(sent[0], sent[2]), isTrue);
  });

  testWidgets('terminal results keep the original draft and stop retained submit callbacks',
      (tester) async {
    const reference = '00000000-0000-4000-8000-000000000123';
    for (final failure in const [
      ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'),
      ApiFailure(409, 'IDEMPOTENCY_KEY_EXPIRED'),
      ApiFailure(410, 'IDEMPOTENCY_RESPONSE_ERASED'),
    ]) {
      Json? result;
      var calls = 0;
      final selectReference = failure.status != 412;
      await open(tester, (_) async { calls++; throw failure; },
          field: selectReference ? 'subjectId' : 'name',
          fieldLabel: selectReference ? '关联档案' : '班级名称',
          options: selectReference ? const {reference: '小明'} : null,
          returned: (value) => result = value);
      if (selectReference) {
        await tester.tap(find.byKey(const Key('class-choice')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('小明').last);
        await tester.pumpAndSettle();
      } else {
        await tester.enterText(find.byKey(const Key('class-name')), '七年级一班');
      }
      final oldSubmit = tester.widget<FilledButton>(submitButton).onPressed!;
      await tester.tap(submitButton);
      await tester.pumpAndSettle();
      expect(find.text('已停止再次提交'), findsOneWidget);
      expect(tester.widget<FailureView>(find.byType(FailureView)).error, same(failure));
      final draft = tester.widget<SelectableText>(
          find.byKey(const Key('class-action-recovery-draft'))).data!;
      expect(draft, contains(selectReference ? reference : '七年级一班'));
      expect(draft, contains(selectReference ? '关联档案' : '班级名称'));
      expect(submitButton, findsNothing);
      oldSubmit();
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      expect(result, {'refresh': true});
      oldSubmit();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('unknown close confirms in place and retained confirmations cannot close a cover',
      (tester) async {
    var calls = 0, closes = 0;
    Json? result;
    await open(tester, (_) async {
      calls++;
      throw const ApiFailure(503, 'TEMPORARY_FAILURE');
    }, returned: (value) { closes++; result = value; });
    await tester.enterText(find.byKey(const Key('class-name')), '七年级一班');
    await tester.tap(submitButton);
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.byType(ClassActionDialog)))!
        as OwnedDialogRoute<Json>;
    await tester.tap(closeButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('class-action-unknown-close-notice')), findsOneWidget);
    final oldConfirm = tester.widget<FilledButton>(find.widgetWithText(
        FilledButton, '关闭并核对记录')).onPressed!;
    tester.widget<TextButton>(find.widgetWithText(TextButton, '继续处理原提交')).onPressed!();
    oldConfirm();
    await tester.pumpAndSettle();
    expect(closes, 0);
    expect(route.available, isTrue);
    expect(find.byKey(const Key('class-action-unknown-close-notice')), findsNothing);
    await tester.tap(closeButton);
    await tester.pumpAndSettle();
    final confirm = tester.widget<FilledButton>(find.widgetWithText(
        FilledButton, '关闭并核对记录')).onPressed!;
    final context = tester.element(find.byType(ClassActionDialog));
    unawaited(showDialog<void>(context: context, builder: (dialog) => AlertDialog(
        title: const Text('独立覆盖通知'), actions: [TextButton(
            onPressed: () => Navigator.of(dialog).pop(), child: const Text('知道了'))])));
    await tester.pumpAndSettle();
    confirm();
    await tester.pumpAndSettle();
    expect(find.text('独立覆盖通知'), findsOneWidget);
    expect(route.available, isTrue);
    expect(closes, 0);
    await tester.tap(find.widgetWithText(TextButton, '知道了'));
    await tester.pumpAndSettle();
    confirm();
    await tester.pumpAndSettle();
    expect(result, {'refresh': true});
    expect(closes, 1);
    expect(calls, 1);
    oldConfirm();
    confirm();
    expect(closes, 1);
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });
}
