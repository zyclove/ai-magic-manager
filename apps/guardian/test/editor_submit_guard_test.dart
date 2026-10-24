@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/editors.dart';
import 'package:guardian/ui/class_action_dialog.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:guardian/ui/member_editor.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'fixtures/diagnostic.dart' as fixture;

// These fixtures exercise local editor submission boundaries. They do not log
// in, mutate a backend, or supply evidence of device or provider execution.
class _EditorSession extends Session {
  final Api editorApi;
  _EditorSession(this.editorApi) {
    profile = {'subject': 'admin'};
    tenant = {'id': _tenantId, 'kind': 'ORGANIZATION'};
    role = 'OWNER';
  }

  @override
  Api get api => editorApi;

  @override
  bool get authenticated => profile != null;
}

const _tenantId = fixture.tenant;
const _root = '/tenants/$_tenantId';

class _BlockedApi {
  final clientReady = Completer<http.Client>();
  final responseReady = Completer<http.Response>();
  final requests = <http.Request>[];
  late final transport = MockClient((request) {
    requests.add(request);
    return responseReady.future;
  });
  late final api =
      Api(() => clientReady.future, baseUrl: 'https://fixture.invalid/api/v1');

  void releaseClient() {
    if (!clientReady.isCompleted) clientReady.complete(transport);
  }

  void releaseResponse() {
    if (!responseReady.isCompleted) {
      responseReady.complete(http.Response('{}', 200,
          headers: {'content-type': 'application/json; charset=utf-8'}));
    }
  }
}


class _ScheduleRecoveryFixture {
  final requests = <http.Request>[];
  final responses = <Completer<http.Response>>[];
  late final transport = MockClient((request) {
    requests.add(request);
    final response = Completer<http.Response>();
    responses.add(response);
    return response.future;
  });
  late final api = Api(() async => transport,
      baseUrl: 'https://fixture.invalid/api/v1');
  late final session = _EditorSession(api);

  void reply(int index, int status, Json body) => responses[index].complete(
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json; charset=utf-8'}));

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final response in responses) {
      if (!response.isCompleted) {
        response.complete(http.Response('{}', 200,
            headers: {'content-type': 'application/json; charset=utf-8'}));
      }
    }
    await _flush(tester);
    transport.close();
    session.dispose();
  }
}

Finder _scheduleButton(String text) => find.ancestor(
    of: find.text(text),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

VoidCallback _scheduleCallback(WidgetTester tester, Finder finder) =>
    tester.widget<ButtonStyleButton>(finder).onPressed!;

Future<void> _openSchedule(WidgetTester tester, _ScheduleRecoveryFixture fixture,
    {bool withException = false}) async {
  await _open(tester, ScheduleEditor(session: fixture.session, root: _root,
      timeZone: 'Asia/Shanghai'));
  await tester.enterText(find.widgetWithText(TextFormField, '计划名称'),
      '  放学后的自由时间  ');
  await tester.ensureVisible(_scheduleButton('加入计划'));
  await tester.tap(_scheduleButton('加入计划'));
  await tester.pumpAndSettle();
  if (withException) {
    await tester.ensureVisible(_scheduleButton('添加关闭日期'));
    await tester.tap(_scheduleButton('添加关闭日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Future<void> _open(WidgetTester tester, Widget dialog) async {
  tester.view.physicalSize = const Size(1100, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(MaterialApp(
    theme: consoleTheme(),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => presentOwnedDialog<void>(
              context,
              OwnedDialogRoute<void>(
                context: context,
                builder: (_) => dialog,
              )),
          child: const Text('打开编辑器'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开编辑器'));
  await tester.pumpAndSettle();
}

VoidCallback _capturedSubmit(WidgetTester tester, String label) {
  final button = find.widgetWithText(FilledButton, label);
  expect(button, findsOneWidget);
  final submit = tester.widget<FilledButton>(button).onPressed;
  expect(submit, isNotNull);
  return submit!;
}

Future<void> Function() _apiCleanup(
    WidgetTester tester, _BlockedApi blocked, _EditorSession session) {
  Future<void>? pendingCleanup;
  Future<void> performCleanup() async {
    // Unmount before completing a potentially duplicated operation, so a RED
    // result cannot also pop the test's host route during cleanup.
    await tester.pumpWidget(const SizedBox.shrink());
    blocked.releaseClient();
    blocked.releaseResponse();
    await _flush(tester);
    blocked.transport.close();
    session.dispose();
  }

  Future<void> cleanup() => pendingCleanup ??= performCleanup();
  return cleanup;
}

Future<void> Function() _submissionCleanup(
    WidgetTester tester, Completer<Json> result) {
  Future<void>? pendingCleanup;
  Future<void> performCleanup() async {
    await tester.pumpWidget(const SizedBox.shrink());
    if (!result.isCompleted) result.complete(<String, dynamic>{});
    await _flush(tester);
  }

  Future<void> cleanup() => pendingCleanup ??= performCleanup();
  return cleanup;
}

void main() {
  testWidgets('ScheduleEditor saves once when a captured callback is repeated',
      (tester) async {
    final blocked = _BlockedApi();
    final session = _EditorSession(blocked.api);
    final cleanup = _apiCleanup(tester, blocked, session);
    try {
      await _open(
          tester,
          ScheduleEditor(
            session: session,
            root: _root,
            timeZone: 'Asia/Shanghai',
          ));
      await tester.enterText(
          find.widgetWithText(TextFormField, '计划名称'), '放学后的自由时间');
      await tester.ensureVisible(find.text('加入计划'));
      await tester.tap(find.text('加入计划'));
      await tester.pumpAndSettle();

      final submit = _capturedSubmit(tester, '保存计划');
      submit();
      submit();
      expect(blocked.requests, isEmpty,
          reason:
              'Client acquisition is still pending for the first submission.');
      blocked.releaseClient();
      await _flush(tester);

      expect(blocked.requests, hasLength(1),
          reason: 'The editor must lock before its first asynchronous wait.');
      final request = blocked.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1$_root/schedules');
      expect(jsonDecode(request.body), {
        'name': '放学后的自由时间',
        'definition': {
          'timeZone': 'Asia/Shanghai',
          'weekly': [
            for (final day in [
              'MONDAY',
              'TUESDAY',
              'WEDNESDAY',
              'THURSDAY',
              'FRIDAY',
            ])
              {'day': day, 'start': '18:00', 'end': '20:00'},
          ],
          'exceptions': <Json>[],
        },
      });
      expect(tester.takeException(), isNull);
    } finally {
      await cleanup();
    }
  });

  testWidgets('PolicyEditor saves once when a captured callback is repeated',
      (tester) async {
    final blocked = _BlockedApi();
    final session = _EditorSession(blocked.api);
    final cleanup = _apiCleanup(tester, blocked, session);
    try {
      await _open(
          tester,
          PolicyEditor(
            session: session,
            root: _root,
            applications: const [],
            schedules: const [],
          ));
      await tester.enterText(
          find.widgetWithText(TextFormField, '策略名称'), '学习日使用规则');
      await tester.pump();

      final submit = _capturedSubmit(tester, '保存草稿');
      submit();
      submit();
      expect(blocked.requests, isEmpty,
          reason:
              'Client acquisition is still pending for the first submission.');
      blocked.releaseClient();
      await _flush(tester);

      expect(blocked.requests, hasLength(1),
          reason: 'The editor must lock before its first asynchronous wait.');
      final request = blocked.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1$_root/policies');
      expect(jsonDecode(request.body), {
        'name': '学习日使用规则',
        'kind': 'POLICY',
        'rules': <Json>[],
      });
      expect(tester.takeException(), isNull);
    } finally {
      await cleanup();
    }
  });

  testWidgets('MemberEditor submits once when a captured callback is repeated',
      (tester) async {
    final result = Completer<Json>();
    final bodies = <Json>[];
    final cleanup = _submissionCleanup(tester, result);
    try {
      await _open(
          tester,
          MemberEditor(
            kind: 'ORGANIZATION',
            operatorRole: 'OWNER',
            subjects: const {'subject-a': '小明'},
            classes: const {'class-a': '七年级一班'},
            onSubmit: (body) {
              bodies.add(Map<String, dynamic>.from(body));
              return result.future;
            },
          ));
      await tester.enterText(
          find.byKey(const Key('member-email')), 'auditor@example.test');
      await tester.pump();

      final submit = _capturedSubmit(tester, '创建邀请');
      submit();
      submit();

      expect(result.isCompleted, isFalse);
      expect(bodies, hasLength(1),
          reason:
              'The editor must lock while the first invitation is pending.');
      expect(bodies.single, {
        'recipientEmail': 'auditor@example.test',
        'role': 'AUDITOR',
      });
      expect(tester.takeException(), isNull);
    } finally {
      await cleanup();
    }
  });

  testWidgets(
      'ClassActionDialog submits once when a captured callback is repeated',
      (tester) async {
    final result = Completer<Json>();
    final bodies = <Json>[];
    final cleanup = _submissionCleanup(tester, result);
    try {
      await _open(
          tester,
          ClassActionDialog(
            title: '新建班级',
            description: '设置班级名称',
            field: 'name',
            fieldLabel: '班级名称',
            submitLabel: '创建班级',
            onSubmit: (body) {
              bodies.add(Map<String, dynamic>.from(body));
              return result.future;
            },
          ));
      await tester.enterText(find.byKey(const Key('class-name')), '七年级一班');
      await tester.pump();

      final submit = _capturedSubmit(tester, '创建班级');
      submit();
      submit();

      expect(result.isCompleted, isFalse);
      expect(bodies, hasLength(1),
          reason:
              'The dialog must lock while the first class action is pending.');
      expect(bodies.single, {'name': '七年级一班'});
      expect(tester.takeException(), isNull);
    } finally {
      await cleanup();
    }
  });

  for (final failure in ['network', 'server', 'unexpected']) {
    testWidgets('ScheduleEditor $failure outcome preserves the original retry',
        (tester) async {
      final f = _ScheduleRecoveryFixture();
      try {
        await _openSchedule(tester, f, withException: true);
        final save = _capturedSubmit(tester, '保存计划');
        final add = _scheduleCallback(tester, _scheduleButton('加入计划'));
        final time = _scheduleCallback(tester, _scheduleButton('18:00'));
        final date = _scheduleCallback(tester, _scheduleButton('添加关闭日期'));
        final day = tester.widget<FilterChip>(find.byType(FilterChip).first)
            .onSelected!;
        final remove = tester.widget<IconButton>(find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == '移除此时段')
            .first).onPressed!;
        final removeException = tester.widget<IconButton>(find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == '移除例外')
            .first).onPressed!;
        save();
        save();
        await _flush(tester);
        expect(f.requests, hasLength(1));
        final originalBody = f.requests.single.body;
        final requestKey = f.requests.single.headers['Idempotency-Key'];
        expect(requestKey, isNotEmpty);
        expect(jsonDecode(originalBody)['name'], '放学后的自由时间');
        expect(jsonDecode(originalBody)['definition']['weekly'], hasLength(5));
        expect(jsonDecode(originalBody)['definition']['exceptions'], hasLength(1));
        if (failure == 'server') {
          f.reply(0, 503, {'errorCode': 'SERVICE_UNAVAILABLE'});
        } else {
          f.responses.single.completeError(failure == 'network'
              ? http.ClientException('fixture connection lost')
              : StateError('fixture unexpected transport error'));
        }
        await _flush(tester);
        await tester.pumpAndSettle();
        for (final field in tester.widgetList<TextFormField>(
            find.byType(TextFormField))) {
          expect(field.enabled, isFalse);
        }
        expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
        expect(find.text('重试原提交'), findsOneWidget);
        day(false);
        remove();
        removeException();
        add();
        time();
        date();
        save();
        await tester.pump();
        expect(find.byType(TimePickerDialog), findsNothing);
        expect(find.byType(DatePickerDialog), findsNothing);
        expect(find.byTooltip('移除此时段'), findsNWidgets(5));
        expect(find.byTooltip('移除例外'), findsOneWidget);
        expect(tester.widget<FilterChip>(find.byType(FilterChip).first).selected,
            isTrue);
        expect(f.requests, hasLength(1));
        final retry = _capturedSubmit(tester, '重试原提交');
        retry();
        retry();
        await _flush(tester);
        expect(f.requests, hasLength(2));
        expect(f.requests.last.body, originalBody);
        expect(f.requests.last.headers['Idempotency-Key'], requestKey);
        f.reply(1, 200, {});
        await _flush(tester);
        await tester.pumpAndSettle();
        expect(find.byType(ScheduleEditor), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await f.cleanup(tester);
      }
    });
  }

  testWidgets('ScheduleEditor known rejection permits a corrected submission',
      (tester) async {
    final f = _ScheduleRecoveryFixture();
    try {
      await _openSchedule(tester, f);
      _capturedSubmit(tester, '保存计划')();
      await _flush(tester);
      f.reply(0, 400, {'errorCode': 'INVALID_TIME_WINDOW'});
      await _flush(tester);
      await tester.pumpAndSettle();
      for (final field in tester.widgetList<TextFormField>(
          find.byType(TextFormField))) {
        expect(field.enabled, isTrue);
      }
      expect(find.text('重试原提交'), findsNothing);
      await tester.enterText(find.widgetWithText(TextFormField, '计划名称'),
          '修正后的计划');
      _capturedSubmit(tester, '保存计划')();
      await _flush(tester);
      expect(f.requests, hasLength(2));
      expect(jsonDecode(f.requests.last.body)['name'], '修正后的计划');
      expect(f.requests.last.body, isNot(f.requests.first.body));
      expect(f.requests.last.headers['Idempotency-Key'],
          f.requests.first.headers['Idempotency-Key']);
      f.reply(1, 200, {});
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEditor), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.cleanup(tester);
    }
  });

  testWidgets('ScheduleEditor pending-operation rejection retains unknown content',
      (tester) async {
    final f = _ScheduleRecoveryFixture();
    try {
      await _openSchedule(tester, f);
      _capturedSubmit(tester, '保存计划')();
      await _flush(tester);
      f.reply(0, 503, {'errorCode': 'SERVICE_UNAVAILABLE'});
      await _flush(tester);
      _capturedSubmit(tester, '重试原提交')();
      await _flush(tester);
      f.reply(1, 409, {'errorCode': 'PENDING_OPERATION_UNCHANGED'});
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(find.text('重试原提交'), findsOneWidget);
      expect(tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, '计划名称')).enabled, isFalse);
      _capturedSubmit(tester, '重试原提交')();
      await _flush(tester);
      expect(f.requests, hasLength(3));
      expect(f.requests.map((r) => r.body).toSet(), hasLength(1));
      expect(f.requests.map((r) => r.headers['Idempotency-Key']).toSet(),
          hasLength(1));
      f.reply(2, 200, {});
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEditor), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.cleanup(tester);
    }
  });

  testWidgets('ScheduleEditor unknown back navigation requires explicit close',
      (tester) async {
    final f = _ScheduleRecoveryFixture();
    try {
      await _openSchedule(tester, f);
      final staleSave = _capturedSubmit(tester, '保存计划');
      staleSave();
      await _flush(tester);
      f.reply(0, 503, {'errorCode': 'SERVICE_UNAVAILABLE'});
      await _flush(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      await navigator.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('暂时关闭未确认的提交？'), findsOneWidget);
      await tester.tap(find.byKey(const Key('schedule-editor-keep-unknown')));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEditor), findsOneWidget);
      expect(find.text('重试原提交'), findsOneWidget);
      await tester.tap(find.byKey(const Key('schedule-editor-close-unknown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
          const Key('schedule-editor-confirm-close-unknown')));
      staleSave();
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEditor), findsNothing);
      expect(f.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    } finally {
      await f.cleanup(tester);
    }
  });

  testWidgets('ScheduleEditor late success preserves an unrelated covering dialog',
      (tester) async {
    final f = _ScheduleRecoveryFixture();
    try {
      await _openSchedule(tester, f);
      _capturedSubmit(tester, '保存计划')();
      await _flush(tester);
      var noticeClosed = false;
      unawaited(showDialog<void>(
          context: tester.element(find.byType(ScheduleEditor)),
          builder: (context) => AlertDialog(
              title: const Text('独立通知'),
              actions: [TextButton(onPressed: () => Navigator.pop(context),
                  child: const Text('关闭通知'))]))
          .then((_) => noticeClosed = true));
      await tester.pumpAndSettle();
      f.reply(0, 200, {});
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(find.text('独立通知'), findsOneWidget);
      expect(noticeClosed, isFalse);
      expect(find.byType(ScheduleEditor, skipOffstage: false), findsNothing);
      await tester.tap(find.text('关闭通知'));
      await tester.pumpAndSettle();
      expect(noticeClosed, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await f.cleanup(tester);
    }
  });

  for (final picker in ['time', 'date']) {
    testWidgets('ScheduleEditor late $picker result cannot edit a closed owner',
        (tester) async {
      final f = _ScheduleRecoveryFixture();
      try {
        await _openSchedule(tester, f);
        final save = _capturedSubmit(tester, '保存计划');
        final owner = ModalRoute.of(tester.element(find.byType(ScheduleEditor)))
            as OwnedDialogRoute<void>;
        final button = _scheduleButton(
            picker == 'time' ? '18:00' : '添加关闭日期');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        save();
        await _flush(tester);
        expect(f.requests, isEmpty);
        owner.finish();
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(find.byType(ScheduleEditor), findsNothing);
        expect(f.requests, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await f.cleanup(tester);
      }
    });
  }

}
