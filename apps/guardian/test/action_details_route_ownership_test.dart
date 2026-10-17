import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';

class _Harness {
  late BuildContext context;
  bool detailsCompleted = false;
  bool coverCompleted = false;
  int calls = 0;
}

Future<_Harness> _open(WidgetTester tester,
    {Future<void> Function()? operation,
    bool closeOnSuccess = true,
    ValueNotifier<bool>? access}) async {
  final h = _Harness();
  await tester.pumpWidget(MaterialApp(
    theme: consoleTheme(),
    home: Scaffold(body: Builder(builder: (context) {
      h.context = context;
      return const Text('业务页面');
    })),
  ));
  unawaited(actionDetails(h.context, '所属操作窗口', const {'私有字段': '原私有内容'},
      accessChanges: access,
      hasAccess: access == null ? null : () => access.value,
      actions: [
        DetailAction('执行操作', (_) async {
          h.calls++;
          await operation?.call();
        }, closeOnSuccess: closeOnSuccess)
      ]).then((_) => h.detailsCompleted = true));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    access?.dispose();
  });
  return h;
}

VoidCallback _action(WidgetTester tester) => tester
    .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '执行操作'))
    .onPressed!;

Future<void> _cover(WidgetTester tester, _Harness h) async {
  unawaited(showDialog<void>(
      context: h.context,
      builder: (context) => AlertDialog(
            title: const Text('独立通知'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭通知'))
            ],
          )).then((_) => h.coverCompleted = true));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('successful action preserves an unrelated covering notification',
      (tester) async {
    final result = Completer<void>();
    final h = await _open(tester, operation: () => result.future);
    _action(tester)();
    await tester.pump();
    await _cover(tester, h);
    result.complete();
    await tester.pumpAndSettle();
    expect(find.text('独立通知'), findsOneWidget);
    expect(h.coverCompleted, isFalse);
    expect(h.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing a covered successful window completes its caller',
      (tester) async {
    final result = Completer<void>();
    final h = await _open(tester, operation: () => result.future);
    _action(tester)();
    await tester.pump();
    await _cover(tester, h);
    result.complete();
    await tester.pumpAndSettle();
    expect(h.detailsCompleted, isTrue);
    expect(find.text('所属操作窗口'), findsNothing);
    expect(find.text('独立通知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued action cannot run after access loss before a frame',
      (tester) async {
    final access = ValueNotifier(true);
    final h = await _open(tester, access: access);
    final queued = _action(tester);
    access.value = false;
    queued();
    await tester.pumpAndSettle();
    expect(h.calls, 0);
    expect(find.text('原私有内容'), findsNothing);
    expect(find.text('执行操作'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('access loss and restoration cannot revive a private window',
      (tester) async {
    final access = ValueNotifier(true);
    final h = await _open(tester, access: access);
    final queued = _action(tester);
    access.value = false;
    access.value = true;
    await tester.pumpAndSettle();
    expect(find.text('原私有内容'), findsNothing);
    expect(find.text('执行操作'), findsNothing);
    queued();
    await tester.pumpAndSettle();
    expect(h.calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nonclosing success keeps its own window and any cover',
      (tester) async {
    final result = Completer<void>();
    final h = await _open(tester,
        operation: () => result.future, closeOnSuccess: false);
    _action(tester)();
    await tester.pump();
    await _cover(tester, h);
    result.complete();
    await tester.pumpAndSettle();
    expect(h.detailsCompleted, isFalse);
    expect(h.coverCompleted, isFalse);
    expect(find.text('独立通知'), findsOneWidget);
    await tester.tap(find.text('关闭通知'));
    await tester.pumpAndSettle();
    expect(find.text('所属操作窗口'), findsOneWidget);
    expect(find.text('执行操作'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary success completes after its route finishes',
      (tester) async {
    final h = await _open(tester);
    await tester.tap(find.text('执行操作'));
    await tester.pumpAndSettle();
    expect(h.calls, 1);
    expect(h.detailsCompleted, isTrue);
    expect(find.text('所属操作窗口'), findsNothing);
    expect(find.text('业务页面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('covered form success preserves notice and returns its result',
      (tester) async {
    final h = await _open(tester, closeOnSuccess: false);
    final response = Completer<Json?>();
    var completed = false;
    Json? saved;
    unawaited(formDialog(h.context,
        title: '所属表单',
        fields: const [FieldSpec('name', '名称')],
        initial: const {'name': '提交快照'},
        submit: '保存表单',
        onSubmit: (_) => response.future).then((value) {
      completed = true;
      saved = value;
    }));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存表单'));
    await tester.pump();
    await _cover(tester, h);
    response.complete({'id': 'saved-form', 'name': '提交快照'});
    await tester.pumpAndSettle();
    expect(find.text('独立通知'), findsOneWidget);
    expect(h.coverCompleted, isFalse);
    expect(completed, isTrue);
    expect(saved, {'id': 'saved-form', 'name': '提交快照'});
    expect(find.text('所属表单'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued form save cannot run after the form has closed',
      (tester) async {
    final h = await _open(tester, closeOnSuccess: false);
    var writes = 0;
    unawaited(formDialog(h.context,
        title: '所属表单',
        fields: const [FieldSpec('name', '名称')],
        initial: const {'name': '提交快照'},
        submit: '保存表单', onSubmit: (_) async {
      writes++;
      return {'id': 'saved-form'};
    }));
    await tester.pumpAndSettle();
    final queued = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '保存表单'))
        .onPressed!;
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await _cover(tester, h);
    queued();
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('独立通知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stale form cancel callback cannot close another route',
      (tester) async {
    final h = await _open(tester, closeOnSuccess: false);
    unawaited(formDialog(h.context,
        title: '所属表单',
        fields: const [FieldSpec('name', '名称')],
        initial: const {'name': '提交快照'},
        onSubmit: (value) async => value));
    await tester.pumpAndSettle();
    final queued = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
        .onPressed!;
    queued();
    await tester.pumpAndSettle();
    await _cover(tester, h);
    expect(queued, returnsNormally);
    await tester.pumpAndSettle();
    expect(find.text('独立通知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale confirmation callback cannot close another route',
      (tester) async {
    final h = await _open(tester, closeOnSuccess: false);
    var accepted = false;
    unawaited(confirmAction(h.context, '所属确认', '确认当前操作？', confirm: '确认操作')
        .then((value) => accepted = value));
    await tester.pumpAndSettle();
    final queued = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '确认操作'))
        .onPressed!;
    queued();
    await tester.pumpAndSettle();
    await _cover(tester, h);
    expect(queued, returnsNormally);
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
    expect(find.text('独立通知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale details close callback cannot close another route',
      (tester) async {
    final h = await _open(tester, closeOnSuccess: false);
    unawaited(showDetails(h.context, '所属只读详情', const {'字段': '内容'}));
    await tester.pumpAndSettle();
    final dialog = find.ancestor(
        of: find.text('所属只读详情'), matching: find.byType(AlertDialog));
    final button = find.descendant(
        of: dialog, matching: find.widgetWithText(TextButton, '关闭'));
    final queued = tester.widget<TextButton>(button).onPressed!;
    queued();
    await tester.pumpAndSettle();
    await _cover(tester, h);
    expect(queued, returnsNormally);
    await tester.pumpAndSettle();
    expect(find.text('独立通知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale dropdown callback is harmless after its form closes',
      (tester) async {
    final h = await _open(tester, closeOnSuccess: false);
    unawaited(formDialog(h.context,
        title: '选择表单',
        fields: const [
          FieldSpec('mode', '模式', options: {'A': '模式 A', 'B': '模式 B'})
        ],
        initial: const {'mode': 'A'},
        onSubmit: (value) async => value));
    await tester.pumpAndSettle();
    final queued = tester
        .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>))
        .onChanged!;
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await _cover(tester, h);
    expect(() => queued('B'), returnsNormally);
    await tester.pumpAndSettle();
    expect(find.text('独立通知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued dropdown cannot change an uncertain submission snapshot',
      (tester) async {
    final h = await _open(tester, closeOnSuccess: false);
    unawaited(formDialog(h.context,
        title: '选择表单',
        fields: const [
          FieldSpec('mode', '模式', options: {'A': '模式 A', 'B': '模式 B'})
        ],
        initial: const {'mode': 'A'},
        submit: '保存选择',
        onSubmit: (_) async => throw const ApiFailure(0, 'NETWORK_ERROR')));
    await tester.pumpAndSettle();
    final field = find.byType(DropdownButtonFormField<String>);
    final queued =
        tester.widget<DropdownButtonFormField<String>>(field).onChanged!;
    await tester.tap(find.text('保存选择'));
    await tester.pumpAndSettle();
    expect(find.text('重试原提交'), findsOneWidget);
    queued('B');
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButtonFormField<String>>(field).initialValue,
        'A');
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale form reauthentication cannot authenticate after close',
      (tester) async {
    final h = await _open(tester, closeOnSuccess: false);
    var authentications = 0;
    unawaited(formDialog(h.context,
        title: '需重新验证的表单',
        fields: const [FieldSpec('name', '名称')],
        initial: const {'name': '提交快照'},
        submit: '保存待验证表单',
        reauth: () => authentications++,
        onSubmit: (_) async => throw const ApiFailure(401, 'REAUTH_REQUIRED')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存待验证表单'));
    await tester.pumpAndSettle();
    final reauth = find.ancestor(
        of: find.text('重新安全验证'),
        matching: find.byWidgetPredicate((widget) => widget is TextButton));
    expect(reauth, findsOneWidget);
    final queued = tester.widget<TextButton>(reauth).onPressed!;
    expect(authentications, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await _cover(tester, h);

    queued();
    await tester.pumpAndSettle();

    expect(authentications, 0,
        reason: 'A closed form cannot begin authentication for a later route.');
    expect(find.text('独立通知'), findsOneWidget);
    expect(h.coverCompleted, isFalse);
    expect(tester.takeException(), isNull);
  });
}
