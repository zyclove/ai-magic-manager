import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:guardian/ui/time_zone_field.dart';

Future<void> _openPreparationForm(WidgetTester tester,
    {required Completer<Json?> closed,
    required ValueNotifier<bool> access,
    required Future<Json?> Function(Json) onSubmit}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    closed.complete(await presentOwnedDialog<Json>(
                        context,
                        OwnedDialogRoute<Json>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => EditDialog(
                                title: '准备规则',
                                fields: const [FieldSpec('name', '名称')],
                                initial: const {'name': '原始输入'},
                                submit: '准备草稿',
                                canCommit: false,
                                accessChanges: access,
                                hasAccess: () => access.value,
                                onSubmit: onSubmit))));
                  },
                  child: const Text('打开准备表单'))))));
  await tester.tap(find.text('打开准备表单'));
  await tester.pumpAndSettle();
}

Future<void> _openRecoveryForm(WidgetTester tester,
    {required Completer<Json?> closed,
    required ValueNotifier<bool> access,
    required Future<Json?> Function(Json) onSubmit,
    Future<Json> Function(Json)? onRecoverUnknown,
    String recoverLabel = '查询原结果',
    List<FieldSpec> fields = const [FieldSpec('name', '名称')],
    Json initial = const {'name': '原始名称'}}) async {
  await tester.pumpWidget(MaterialApp(
    theme: consoleTheme(),
    home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                onPressed: () async {
                  closed.complete(await formDialog(context,
                      title: '编辑名称',
                      fields: fields,
                      initial: initial,
                      accessChanges: access,
                      hasAccess: () => access.value,
                      onRecoverUnknown: onRecoverUnknown,
                      recoverLabel: recoverLabel,
                      onSubmit: onSubmit));
                },
                child: const Text('打开恢复表单')))),
  ));
  await tester.tap(find.text('打开恢复表单'));
  await tester.pumpAndSettle();
}

VoidCallback _editCallback(WidgetTester tester, String label) {
  final callback = tester
      .widget<FilledButton>(find.widgetWithText(FilledButton, label))
      .onPressed;
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
  testWidgets('time-zone choices cannot alter a submitted unknown form before rebuild',
      (tester) async {
    final access = ValueNotifier(true);
    final closed = Completer<Json?>();
    final request = Completer<Json?>();
    final bodies = <Json>[];
    try {
      await _openRecoveryForm(tester, closed: closed, access: access,
          fields: const [FieldSpec.timeZone('timeZone', '时区')],
          initial: const {'timeZone': 'Asia/Shanghai'}, onSubmit: (body) {
        bodies.add(body);
        return bodies.length == 1 ? request.future : Future<Json?>.value(body);
      });
      await tester.enterText(find.byType(TextFormField), '东京');
      await tester.pumpAndSettle();
      final tokyo = find.byKey(const ValueKey('time-zone-option-Asia/Tokyo'));
      final heldTokyo = tester.widget<ListTile>(tokyo).onTap!;
      await tester.tap(tokyo);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'UTC');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('time-zone-option-UTC')));
      await tester.pumpAndSettle();
      _editCallback(tester, '保存')();
      // The child still has its old enabled widget until the next frame.
      heldTokyo();
      expect(bodies, [{'timeZone': 'UTC'}]);
      expect(tester.widget<TextFormField>(find.byType(TextFormField))
          .controller!.text, 'UTC');
      await tester.pump();
      expect(tester.widget<TimeZoneField>(find.byType(TimeZoneField)).enabled, isFalse);
      request.completeError(const ApiFailure(503, 'SERVICE_UNAVAILABLE'));
      await tester.pumpAndSettle();
      heldTokyo();
      expect(tester.widget<TextFormField>(find.byType(TextFormField))
          .controller!.text, 'UTC');
      _editCallback(tester, '重试原提交')();
      await tester.pumpAndSettle();
      expect(bodies, [{'timeZone': 'UTC'}, {'timeZone': 'UTC'}]);
      expect(await closed.future, {'timeZone': 'UTC'});
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, [request]);
    }
  });

  testWidgets('bounded numeric fields reject invalid input before submitting',
      (tester) async {
    final access = ValueNotifier(true);
    final closed = Completer<Json?>();
    final bodies = <Json>[];
    try {
      await _openRecoveryForm(tester, closed: closed, access: access,
          fields: const [FieldSpec('count', '数量', numeric: true,
              minValue: 1, maxValue: 10)],
          initial: const {'count': 1}, onSubmit: (body) async {
        bodies.add(body);
        return body;
      });
      for (final sample in [(0, '不能小于 1'), (11, '不能大于 10')]) {
        await tester.enterText(find.byType(TextFormField), '${sample.$1}');
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await tester.pumpAndSettle();
        expect(find.text(sample.$2), findsOneWidget);
        expect(bodies, isEmpty);
        expect(closed.isCompleted, isFalse);
      }
      await tester.enterText(find.byType(TextFormField), '5');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(bodies, [{'count': 5}]);
      expect(closed.isCompleted, isTrue);
      expect(await closed.future, {'count': 5});
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, []);
    }
  });

  testWidgets('custom field errors stay inline until the values are repaired',
      (tester) async {
    for (final sample in [
      (FieldSpec('name', '名称', validator: (value) =>
          (value ?? '').contains(' ') ? '名称不能包含空格' : null),
          '两 段', '修正名称', '名称不能包含空格'),
      (FieldSpec('mode', '模式', options: const {'old': '旧模式', 'new': '新模式'},
          validator: (value) => value == 'old' ? '请选择新模式' : null),
          'old', 'new', '请选择新模式'),
      (FieldSpec.timeZone('timeZone', '时区', validator: (value) =>
          value == 'Mars/Olympus' ? '请核对时区编号' : null),
          'Mars/Olympus', 'Asia/Shanghai', '请核对时区编号'),
    ]) {
      final access = ValueNotifier(true);
      final closed = Completer<Json?>();
      final bodies = <Json>[];
      try {
        await _openRecoveryForm(tester, closed: closed, access: access,
            fields: [sample.$1], initial: {sample.$1.key: sample.$2},
            onSubmit: (body) async {
          bodies.add(body);
          return body;
        });
        _editCallback(tester, '保存')();
        await tester.pumpAndSettle();
        expect(find.text(sample.$4), findsOneWidget);
        expect(find.byType(FailureView), findsNothing);
        expect(bodies, isEmpty);
        expect(closed.isCompleted, isFalse);
        if (sample.$1.options != null) {
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('新模式').last);
          await tester.pumpAndSettle();
        } else {
          await tester.enterText(find.byType(TextFormField), sample.$3);
        }
        _editCallback(tester, '保存')();
        await tester.pumpAndSettle();
        expect(bodies, [{sample.$1.key: sample.$3}]);
        expect(closed.isCompleted, isTrue);
        expect(await closed.future, {sample.$1.key: sample.$3});
        expect(tester.takeException(), isNull);
      } finally {
        await _disposeRecoveryForm(tester, access, []);
      }
    }
  });

  testWidgets(
      '408 recovery queries the frozen original through 404 and reauth to success',
      (tester) async {
    final request = Completer<Json?>();
    final closed = Completer<Json?>();
    final access = ValueNotifier(true);
    final submissions = <Json>[];
    final queries = <Json>[];
    var rejectLiveValue = false;
    var validations = 0;
    const recoverLabel = '核对原申请';
    const confirmed = {'id': 'original-application', 'name': '原申请'};
    const failures = [
      ApiFailure(404, 'APPLICATION_REGISTRATION_RESULT_NOT_FOUND'),
      ApiFailure(401, 'REAUTH_REQUIRED'),
    ];
    try {
      await _openRecoveryForm(tester, closed: closed, access: access,
          fields: [FieldSpec('name', '名称', validator: (_) {
            validations++;
            return rejectLiveValue ? '当前输入已不可提交' : null;
          })],
          initial: const {'name': '  原申请  '},
          recoverLabel: recoverLabel, onSubmit: (body) {
        submissions.add(body);
        return request.future;
      }, onRecoverUnknown: (body) async {
        queries.add(body);
        if (queries.length <= failures.length) {
          throw failures[queries.length - 1];
        }
        return confirmed;
      });
      final heldSave = _editCallback(tester, '保存');
      heldSave();
      heldSave();
      expect(submissions, [{'name': '原申请'}]);
      expect(() => submissions.single['name'] = '改写提交',
          throwsUnsupportedError);
      request.completeError(const ApiFailure(408, 'REQUEST_TIMEOUT'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, recoverLabel), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重试原提交'), findsNothing);
      expect(tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
          isFalse);
      final validatedOriginal = validations;
      rejectLiveValue = true;
      final heldRecovery = _editCallback(tester, recoverLabel);
      for (var index = 0; index < failures.length; index++) {
        heldRecovery();
        heldRecovery();
        expect(queries, hasLength(index + 1));
        await tester.pumpAndSettle();
        expect(find.text(failures[index].message), findsOneWidget);
        expect(find.widgetWithText(FilledButton, recoverLabel), findsOneWidget);
        expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
        expect(tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
            isFalse);
        expect(closed.isCompleted, isFalse);
        expect(submissions, hasLength(1));
        expect(identical(queries.last, submissions.single), isTrue);
        expect(queries.last, {'name': '原申请'});
        expect(validations, validatedOriginal);
      }
      expect(() => queries.last['name'] = '改写核对', throwsUnsupportedError);
      heldRecovery();
      heldRecovery();
      await tester.pumpAndSettle();
      expect(queries, hasLength(3));
      expect(identical(queries.last, submissions.single), isTrue);
      expect(validations, validatedOriginal);
      expect(closed.isCompleted, isTrue);
      expect(await closed.future, confirmed);
      expect(find.byType(EditDialog), findsNothing);
      heldSave();
      heldRecovery();
      expect(submissions, hasLength(1));
      expect(queries, hasLength(3));
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, [request]);
    }
  });

  testWidgets(
      'read-only preparation failures keep editable input and retry new values',
      (tester) async {
    for (final failure in <Object>[
      const ApiFailure(0, 'NETWORK_ERROR'),
      const FormatException('invalid normalization response'),
      const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'),
      const ApiFailure(410, 'IDEMPOTENCY_RESULT_EXPIRED'),
    ]) {
      final closed = Completer<Json?>();
      final access = ValueNotifier(true);
      final bodies = <Json>[];
      try {
        await _openPreparationForm(tester, closed: closed, access: access,
            onSubmit: (body) async {
          bodies.add(body);
          if (bodies.length == 1) throw failure;
          return body;
        });
        _editCallback(tester, '准备草稿')();
        await tester.pumpAndSettle();
        expect(find.byType(FailureView), findsOneWidget);
        if (failure is ApiFailure) {
          expect(find.text(failure.message), findsOneWidget);
        }
        expect(tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
            isTrue);
        expect(find.text('重试原提交'), findsNothing);
        expect(find.text('保留的草稿'), findsNothing);
        expect(find.text('原始输入'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), '修改后重新准备');
        _editCallback(tester, '准备草稿')();
        await tester.pumpAndSettle();
        expect(bodies, [
          {'name': '原始输入'},
          {'name': '修改后重新准备'}
        ]);
        expect(identical(bodies.first, bodies.last), isFalse);
        expect(closed.isCompleted, isTrue);
        expect(await closed.future, {'name': '修改后重新准备'});
        expect(tester.takeException(), isNull);
      } finally {
        await _disposeRecoveryForm(tester, access, []);
      }
    }
  });

  testWidgets(
      'read-only preparation can cancel after failure without unknown-write confirmation',
      (tester) async {
    final closed = Completer<Json?>();
    final access = ValueNotifier(true);
    try {
      await _openPreparationForm(tester,
          closed: closed,
          access: access,
          onSubmit: (_) async => throw const ApiFailure(0, 'NETWORK_ERROR'));
      _editCallback(tester, '准备草稿')();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit-dialog-unknown-close-notice')),
          findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isTrue);
      expect(await closed.future, isNull);
      expect(find.byType(EditDialog), findsNothing);
      expect(find.text('确认关闭'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, []);
    }
  });

  testWidgets(
      'read-only preparation rejects duplicate callbacks and late results after scope ABA',
      (tester) async {
    final pending = Completer<Json?>();
    final closed = Completer<Json?>();
    final access = ValueNotifier(true);
    var calls = 0;
    try {
      await _openPreparationForm(tester, closed: closed, access: access,
          onSubmit: (_) {
        calls++;
        return pending.future;
      });
      final heldSubmit = _editCallback(tester, '准备草稿');
      heldSubmit();
      heldSubmit();
      expect(calls, 1);
      access.value = false;
      access.value = true;
      pending.complete({'name': '失效的私有准备结果'});
      await tester.pumpAndSettle();
      heldSubmit();
      expect(calls, 1);
      expect(closed.isCompleted, isFalse);
      expect(find.text('工作空间或权限已变化'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('失效的私有准备结果'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isTrue);
      expect(await closed.future, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, [pending]);
    }
  });

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

  testWidgets(
      '412 preserves the submitted draft and blocks held save callbacks',
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
      expect(bodies, [
        {'name': '保留的冲突草稿'}
      ]);
      request.completeError(const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'));
      await tester.pumpAndSettle();

      expect(closed.isCompleted, isFalse);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
      expect(find.text('保留的草稿'), findsOneWidget);
      expect(
          find.byWidgetPredicate((widget) =>
              widget is SelectableText && widget.data == '名称：保留的冲突草稿'),
          findsOneWidget);
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
    testWidgets(
        'unknown result${failure.key} retries the same payload '
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
        second
            .completeError(const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(FilledButton, '重试原提交'), findsNothing);
        expect(find.text('上次提交结果尚未确认。重试将发送相同内容；离开后请先刷新列表核对结果，避免重复创建。'),
            findsNothing);
        expect(
            find.byWidgetPredicate((widget) =>
                widget is SelectableText && widget.data == '名称：尚未确认的草稿'),
            findsOneWidget);
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

  testWidgets(
      'reauth on an unknown retry keeps the original payload until success',
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

  for (final code in [
    'IDEMPOTENCY_KEY_EXPIRED',
    'IDEMPOTENCY_RESULT_EXPIRED',
    'IDEMPOTENCY_RESPONSE_ERASED'
  ]) {
    testWidgets('$code keeps a read-only draft and stops stale save callbacks',
        (tester) async {
      final request = Completer<Json?>();
      final closed = Completer<Json?>();
      final access = ValueNotifier(true);
      final bodies = <Json>[];
      final failure =
          ApiFailure(code == 'IDEMPOTENCY_KEY_EXPIRED' ? 409 : 410, code);
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
        expect(
            find.byWidgetPredicate((widget) =>
                widget is SelectableText && widget.data == '名称：不可恢复结果的草稿'),
            findsOneWidget);
        expect(find.byType(TextFormField), findsNothing);
        expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
        expect(find.widgetWithText(FilledButton, '重试原提交'), findsNothing);
        expect(find.byType(FilledButton), findsOneWidget);
        heldSave();
        expect(bodies, [
          {'name': '不可恢复结果的草稿'}
        ]);
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
      expect(
          ModalRoute.of(tester.element(find.byType(EditDialog))), same(route));
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
      expect(
          ModalRoute.of(tester.element(find.byType(EditDialog))), same(route));
      expect(find.widgetWithText(FilledButton, '确认关闭'), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-dialog-confirm-close')));
      await tester.pumpAndSettle();
      expect(closed.isCompleted, isTrue);
      expect(await closed.future, isNull);
      expect(find.byType(EditDialog), findsNothing);
      expect(calls, 1,
          reason: 'Close confirmation must not resubmit the request.');
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeRecoveryForm(tester, access, [request]);
    }
  });

  testWidgets(
      'access loss hides a 412 draft and gives original workspace guidance',
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
      expect(
          find.byWidgetPredicate((widget) =>
              widget is SelectableText && widget.data == '名称：失权后隐藏的草稿'),
          findsOneWidget);
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

  testWidgets(
      'access loss during submission hides a late 412 and prevents resubmit',
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

  testWidgets(
      '412 draft preserves trimmed text numeric labels and empty fields',
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
          }, onSubmit: (body) {
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
      expect(
          find.byWidgetPredicate(
              (widget) => widget is SelectableText && widget.data == draft),
          findsOneWidget);
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
