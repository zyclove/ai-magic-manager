import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';

Future<void> _openRecoveryForm(WidgetTester tester,
    {required Completer<Json?> closed,
    required ValueNotifier<bool> access,
    required Future<Json?> Function(Json) onSubmit,
    List<FieldSpec> fields = const [FieldSpec('name', '名称')],
    Json initial = const {'name': '原始名称'}}) async {
  await tester.pumpWidget(MaterialApp(
    theme: consoleTheme(),
    home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () async {
          closed.complete(await formDialog(context,
              title: '编辑名称',
              fields: fields,
              initial: initial,
              accessChanges: access,
              hasAccess: () => access.value,
              onSubmit: onSubmit));
        },
        child: const Text('打开恢复表单')))),
  ));
  await tester.tap(find.text('打开恢复表单'));
  await tester.pumpAndSettle();
}

VoidCallback _editCallback(WidgetTester tester, String label) {
  final callback = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, label)).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

Future<void> _disposeRecoveryForm(WidgetTester tester,
    ValueNotifier<bool> access, List<Completer<Json?>> pending) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (final result in pending) {
    if (!result.isCompleted) result.complete(null);
  }
  await tester.pumpAndSettle();
  access.dispose();
}

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

  testWidgets('412 preserves the submitted draft and blocks held save callbacks',
      (tester) async {
    final request = Completer<Json?>();
    final closed = Completer<Json?>();
    final access = ValueNotifier(true);
    final bodies = <Json>[];
    try {
      await _openRecoveryForm(tester, closed: closed, access: access,
          onSubmit: (body) {
            bodies.add(body);
            return request.future;
          });
      await tester.enterText(find.byType(TextFormField), '保留的冲突草稿');
      final heldSave = _editCallback(tester, '保存');
      heldSave();
      heldSave();
      expect(bodies, [{'name': '保留的冲突草稿'}]);
      request.completeError(const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'));
      await tester.pumpAndSettle();

      expect(closed.isCompleted, isFalse);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
      expect(find.text('保留的草稿'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => widget is SelectableText &&
          widget.data == '名称：保留的冲突草稿'), findsOneWidget);
      expect(find.text('记录已更新，已停止再次提交。可选中并复制下方草稿；关闭后请刷新原页面，再重新打开表单核对最新内容。'),
          findsOneWidget);
      heldSave();
      expect(bodies, hasLength(1));
      _editCallback(tester, '关闭表单')();
      heldSave();
      expect(bodies, hasLength(1),
          reason: 'Closing recovery must not replay a stale submission.');
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isTrue);
      expect(await closed.future, isNull);
      expect(find.byType(EditDialog), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, [request]);
    }
  });

  for (final failure in <String, Object>{
    '': const ApiFailure(0, 'NETWORK_ERROR'),
    ' after a parsing failure': const FormatException('invalid response'),
    ' after a pending-operation refusal':
        const ApiFailure(409, 'PENDING_OPERATION_UNCHANGED'),
  }.entries) {
    testWidgets('unknown result${failure.key} retries the same payload '
        'before a 412 stops replay', (tester) async {
      final first = Completer<Json?>();
      final second = Completer<Json?>();
      final closed = Completer<Json?>();
      final access = ValueNotifier(true);
      final bodies = <Json>[];
      try {
        await _openRecoveryForm(tester, closed: closed, access: access,
            onSubmit: (body) {
              bodies.add(body);
              return bodies.length == 1 ? first.future : second.future;
            });
        await tester.enterText(find.byType(TextFormField), '尚未确认的草稿');
        _editCallback(tester, '保存')();
        first.completeError(failure.value);
        await tester.pumpAndSettle();
        expect(find.text('上次提交结果尚未确认。重试将发送相同内容；离开后请先刷新列表核对结果，避免重复创建。'),
            findsOneWidget);
        expect(tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
            isFalse);
        final heldRetry = _editCallback(tester, '重试原提交');
        heldRetry();
        expect(bodies, hasLength(2));
        expect(identical(bodies.first, bodies.last), isTrue);
        expect(bodies.last, {'name': '尚未确认的草稿'});
        second.completeError(const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(FilledButton, '重试原提交'), findsNothing);
        expect(find.text('上次提交结果尚未确认。重试将发送相同内容；离开后请先刷新列表核对结果，避免重复创建。'),
            findsNothing);
        expect(find.byWidgetPredicate((widget) => widget is SelectableText &&
            widget.data == '名称：尚未确认的草稿'), findsOneWidget);
        heldRetry();
        expect(bodies, hasLength(2));
        _editCallback(tester, '关闭表单')();
        await tester.pumpAndSettle();
        expect(closed.isCompleted, isTrue);
        expect(await closed.future, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await _disposeRecoveryForm(tester, access, [first, second]);
      }
    });
  }

  testWidgets('reauth on an unknown retry keeps the original payload until success',
      (tester) async {
    const reauthFailure = ApiFailure(401, 'REAUTH_REQUIRED');
    final requests = List.generate(3, (_) => Completer<Json?>());
    final closed = Completer<Json?>();
    final access = ValueNotifier(true);
    final bodies = <Json>[];
    try {
      await _openRecoveryForm(tester, closed: closed, access: access,
          onSubmit: (body) {
            bodies.add(body);
            return requests[bodies.length - 1].future;
          });
      await tester.enterText(find.byType(TextFormField), '等待安全验证的原草稿');
      _editCallback(tester, '保存')();
      requests[0].completeError(const ApiFailure(0, 'NETWORK_ERROR'));
      await tester.pumpAndSettle();

      final heldRetry = _editCallback(tester, '重试原提交');
      heldRetry();
      heldRetry();
      expect(bodies, hasLength(2));
      expect(identical(bodies.first, bodies.last), isTrue);
      requests[1].completeError(reauthFailure);
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isFalse);
      expect(find.text(reauthFailure.message), findsOneWidget);
      expect(tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
          isFalse);
      expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
      expect(find.widgetWithText(FilledButton, '重试原提交'), findsOneWidget);

      heldRetry();
      heldRetry();
      expect(bodies, hasLength(3));
      expect(identical(bodies.first, bodies.last), isTrue);
      expect(bodies.last, {'name': '等待安全验证的原草稿'});
      requests[2].complete({'name': '等待安全验证的原草稿'});
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isTrue);
      expect(await closed.future, {'name': '等待安全验证的原草稿'});
      expect(find.byType(EditDialog), findsNothing);
      heldRetry();
      expect(bodies, hasLength(3));
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, requests);
    }
  });

  for (final code in ['IDEMPOTENCY_RESULT_EXPIRED', 'IDEMPOTENCY_RESPONSE_ERASED']) {
    testWidgets('$code keeps a read-only draft and stops stale save callbacks',
        (tester) async {
      final request = Completer<Json?>();
      final closed = Completer<Json?>();
      final access = ValueNotifier(true);
      final bodies = <Json>[];
      final failure = ApiFailure(410, code);
      try {
        await _openRecoveryForm(tester, closed: closed, access: access,
            onSubmit: (body) {
              bodies.add(body);
              return request.future;
            });
        await tester.enterText(find.byType(TextFormField), '不可恢复结果的草稿');
        final heldSave = _editCallback(tester, '保存');
        heldSave();
        request.completeError(failure);
        await tester.pumpAndSettle();

        expect(closed.isCompleted, isFalse);
        expect(find.text(failure.message), findsOneWidget);
        expect(find.text('原操作结果已无法恢复，已停止再次提交。请关闭后核对当前记录；不要把结果不可恢复当作操作未执行。'),
            findsOneWidget);
        expect(find.text('保留的草稿'), findsOneWidget);
        expect(find.byWidgetPredicate((widget) => widget is SelectableText &&
            widget.data == '名称：不可恢复结果的草稿'), findsOneWidget);
        expect(find.byType(TextFormField), findsNothing);
        expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
        expect(find.widgetWithText(FilledButton, '重试原提交'), findsNothing);
        expect(find.byType(FilledButton), findsOneWidget);
        heldSave();
        expect(bodies, [{'name': '不可恢复结果的草稿'}]);
        _editCallback(tester, '关闭表单')();
        heldSave();
        await tester.pumpAndSettle();
        expect(bodies, hasLength(1));
        expect(closed.isCompleted, isTrue);
        expect(await closed.future, isNull);
        expect(find.byType(EditDialog), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await _disposeRecoveryForm(tester, access, [request]);
      }
    });
  }

  testWidgets('unknown result confirms closing inside the original form',
      (tester) async {
    final request = Completer<Json?>();
    final closed = Completer<Json?>();
    final access = ValueNotifier(true);
    var calls = 0;
    try {
      await _openRecoveryForm(tester, closed: closed, access: access,
          onSubmit: (_) {
            calls++;
            return request.future;
          });
      _editCallback(tester, '保存')();
      request.completeError(const ApiFailure(0, 'NETWORK_ERROR'));
      await tester.pumpAndSettle();
      final route = ModalRoute.of(tester.element(find.byType(EditDialog)));
      expect(route, isNotNull);
      expect(find.byKey(const Key('edit-dialog-unknown-close-notice')),
          findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isFalse);
      expect(find.byKey(const Key('edit-dialog-unknown-close-notice')),
          findsOneWidget);
      expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
      expect(ModalRoute.of(tester.element(find.byType(EditDialog))), same(route));
      expect(find.widgetWithText(TextButton, '继续核对'), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-dialog-keep-original')));
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isFalse);
      expect(find.byKey(const Key('edit-dialog-unknown-close-notice')),
          findsNothing);
      expect(find.widgetWithText(FilledButton, '重试原提交'), findsOneWidget);
      expect(tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
          isFalse);

      await tester.tap(find.widgetWithText(TextButton, '暂时关闭'));
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isFalse);
      expect(find.byKey(const Key('edit-dialog-unknown-close-notice')),
          findsOneWidget);
      expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
      expect(ModalRoute.of(tester.element(find.byType(EditDialog))), same(route));
      expect(find.widgetWithText(FilledButton, '确认关闭'), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-dialog-confirm-close')));
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isTrue);
      expect(await closed.future, isNull);
      expect(find.byType(EditDialog), findsNothing);
      expect(calls, 1, reason: 'Close confirmation must not resubmit the request.');
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, [request]);
    }
  });

  testWidgets('access loss hides a 412 draft and gives original workspace guidance',
      (tester) async {
    final request = Completer<Json?>();
    final closed = Completer<Json?>();
    final access = ValueNotifier(true);
    var calls = 0;
    try {
      await _openRecoveryForm(tester, closed: closed, access: access,
          onSubmit: (_) {
            calls++;
            return request.future;
          });
      await tester.enterText(find.byType(TextFormField), '失权后隐藏的草稿');
      final heldSave = _editCallback(tester, '保存');
      heldSave();
      request.completeError(const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'));
      await tester.pumpAndSettle();
      final heldClose = _editCallback(tester, '关闭表单');
      expect(find.byWidgetPredicate((widget) => widget is SelectableText &&
          widget.data == '名称：失权后隐藏的草稿'), findsOneWidget);
      access.value = false;
      heldSave();
      heldClose();
      expect(calls, 1);
      expect(closed.isCompleted, isFalse);
      await tester.pumpAndSettle();
      expect(find.text('工作空间或权限已变化'), findsOneWidget);
      expect(find.text('已隐藏原表单内容。请关闭后在当前工作空间重新打开；已提交的操作请回到原工作空间刷新列表核对结果。'),
          findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isTrue);
      expect(await closed.future, isNull);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, [request]);
    }
  });

  testWidgets('access loss during submission hides a late 412 and prevents resubmit',
      (tester) async {
    final request = Completer<Json?>();
    final closed = Completer<Json?>();
    final access = ValueNotifier(true);
    var calls = 0;
    try {
      await _openRecoveryForm(tester, closed: closed, access: access,
          onSubmit: (_) {
            calls++;
            return request.future;
          });
      await tester.enterText(find.byType(TextFormField), '不得重新展示的草稿');
      final heldSave = _editCallback(tester, '保存');
      heldSave();
      access.value = false;
      heldSave();
      expect(calls, 1);
      request.completeError(const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'));
      await tester.pumpAndSettle();
      heldSave();
      expect(calls, 1);
      expect(find.text('工作空间或权限已变化'), findsOneWidget);
      expect(find.text('已隐藏原表单内容。请关闭后在当前工作空间重新打开；已提交的操作请回到原工作空间刷新列表核对结果。'),
          findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isTrue);
      expect(await closed.future, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, [request]);
    }
  });

  testWidgets('412 draft preserves trimmed text numeric labels and empty fields',
      (tester) async {
    final request = Completer<Json?>();
    final closed = Completer<Json?>();
    final access = ValueNotifier(true);
    final bodies = <Json>[];
    try {
      await _openRecoveryForm(tester,
          closed: closed,
          access: access,
          fields: const [
            FieldSpec('name', '名称'),
            FieldSpec('minutes', '分钟', numeric: true),
            FieldSpec('mode', '模式', options: {'daily': '每天', 'weekly': '每周'}),
            FieldSpec('note', '备注', required: false),
          ],
          initial: const {
            'name': '  带空格的草稿  ',
            'minutes': 25,
            'mode': 'daily',
            'note': '   ',
          },
          onSubmit: (body) {
            bodies.add(body);
            return request.future;
          });
      final heldSave = _editCallback(tester, '保存');
      heldSave();
      expect(bodies, [
        {'name': '带空格的草稿', 'minutes': 25, 'mode': 'daily', 'note': ''}
      ]);
      request.completeError(const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'));
      await tester.pumpAndSettle();
      const draft = '名称：带空格的草稿\n'
          '分钟：25\n'
          '模式：每天\n'
          '备注：（空）';
      expect(find.byWidgetPredicate((widget) => widget is SelectableText &&
          widget.data == draft), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      heldSave();
      expect(bodies, hasLength(1));
      _editCallback(tester, '关闭表单')();
      heldSave();
      expect(bodies, hasLength(1));
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isTrue);
      expect(await closed.future, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, [request]);
    }
  });
}
