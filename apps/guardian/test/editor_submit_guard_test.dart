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

  int _generation = 0;
  @override
  int get scopeGeneration => _generation;

  void changeScope(String dimension, {bool restore = false}) {
    switch (dimension) {
      case 'generation':
        _generation = restore ? 0 : 1;
        break;
      case 'actor':
        profile = {...profile!, 'subject': restore ? 'admin' : 'other-admin'};
        break;
      case 'tenant':
        tenant = {...tenant!, 'id': restore ? _tenantId : 'other-tenant'};
        break;
      case 'role':
        role = restore ? 'OWNER' : 'GUARDIAN';
        break;
      default:
        throw ArgumentError.value(dimension);
    }
    notifyListeners();
  }
}

const _tenantId = fixture.tenant;
const _root = '/tenants/$_tenantId';
const _scheduleId = '88888888-8888-4888-8888-888888888888';

Json _savedSchedule(http.Request request) => {
      'id': _scheduleId,
      ...jsonDecode(request.body) as Json,
    };

void _expectScheduleQuery(http.Request request, http.Request original) {
  expect(request.method, 'POST');
  expect(request.url.path,
      '/api/v1$_root/schedules/creation-results/'
      '${original.headers['Idempotency-Key']}/query');
  expect(request.body, original.body);
  expect(request.headers['Idempotency-Key'], isNull);
}

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

Future<void> _fillScopeSchedule(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextFormField, '计划名称'),
      '范围变化前的私有计划');
  await tester.ensureVisible(_scheduleButton('加入计划'));
  await tester.tap(_scheduleButton('加入计划'));
  await tester.pumpAndSettle();
}

Future<void> _coverScopeNotice(
    WidgetTester tester, VoidCallback onClosed) async {
  unawaited(showDialog<void>(
      context: tester.element(find.byType(ScheduleEditor)),
      builder: (context) => AlertDialog(
          title: const Text('范围外通知'),
          actions: [TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('关闭范围外通知'))]))
      .then((_) => onClosed()));
  await tester.pumpAndSettle();
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
      expect(request.headers['Idempotency-Key'], matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false)));
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
      expect(request.url.path, '/api/v1$_root/policy-draft-changes');
      expect(jsonDecode(request.body), {
        'operation': 'CREATE',
        'name': '学习日使用规则',
        'kind': 'POLICY',
        'rules': <Json>[],
      });
      expect(request.headers['Idempotency-Key'], matches(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(request.headers['If-Match'], isNull);
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

  for (final failure in ['network', 'server', 'timeout', 'unexpected', 'receipt']) {
    testWidgets('ScheduleEditor $failure outcome only queries the original save',
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
        } else if (failure == 'timeout') {
          f.reply(0, 408, {'errorCode': 'REQUEST_TIMEOUT'});
        } else if (failure == 'receipt') {
          f.reply(0, 200, {});
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
        expect(find.text('查询保存结果'), findsOneWidget);
        expect(find.byKey(const Key('schedule-editor-query-original')),
            findsOneWidget);
        expect(find.text('重试原提交'), findsNothing);
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
        final query = _capturedSubmit(tester, '查询保存结果');
        query();
        query();
        await _flush(tester);
        expect(f.requests, hasLength(2));
        _expectScheduleQuery(f.requests.last, f.requests.first);
        expect(f.requests.where((request) =>
            request.url.path == '/api/v1$_root/schedules'), hasLength(1));
        f.reply(1, 200, _savedSchedule(f.requests.first));
        await _flush(tester);
        await tester.pumpAndSettle();
        expect(find.byType(ScheduleEditor), findsNothing);
        query();
        save();
        await _flush(tester);
        expect(f.requests, hasLength(2));
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
      expect(find.text('查询保存结果'), findsNothing);
      await tester.enterText(find.widgetWithText(TextFormField, '计划名称'),
          '修正后的计划');
      _capturedSubmit(tester, '保存计划')();
      await _flush(tester);
      expect(f.requests, hasLength(2));
      expect(jsonDecode(f.requests.last.body)['name'], '修正后的计划');
      expect(f.requests.last.body, isNot(f.requests.first.body));
      expect(f.requests.last.headers['Idempotency-Key'],
          f.requests.first.headers['Idempotency-Key']);
      f.reply(1, 200, _savedSchedule(f.requests.last));
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEditor), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.cleanup(tester);
    }
  });

  for (final outcome in ['confirmed', 'conflict', 'expired']) {
    testWidgets('ScheduleEditor preserves locked lookup content until $outcome',
        (tester) async {
      final f = _ScheduleRecoveryFixture();
      try {
        await _openSchedule(tester, f, withException: true);
        final staleSave = _capturedSubmit(tester, '保存计划');
        staleSave();
        await _flush(tester);
        final original = f.requests.single;
        f.reply(0, 503, {'errorCode': 'SERVICE_UNAVAILABLE'});
        await _flush(tester);
        final query = _capturedSubmit(tester, '查询保存结果');
        final receipt = _savedSchedule(original);
        final refusals = <(int, Json)>[
          (404, {'errorCode': 'SCHEDULE_CREATION_RESULT_NOT_FOUND'}),
          (401, {'errorCode': 'REAUTH_REQUIRED'}),
          (409, {'errorCode': 'PENDING_OPERATION_UNCHANGED'}),
          (200, {}),
          (200, {...receipt, 'id': 'invalid-schedule-id'}),
          (200, {...receipt, 'name': '其他计划'}),
          (200, {...receipt, 'definition': {
            ...receipt['definition'] as Json,
            'weekly': <Json>[],
          }}),
        ];
        for (var index = 0; index < refusals.length; index++) {
          query();
          query();
          await _flush(tester);
          expect(f.requests, hasLength(index + 2));
          _expectScheduleQuery(f.requests.last, original);
          f.reply(index + 1, refusals[index].$1, refusals[index].$2);
          await _flush(tester);
          await tester.pumpAndSettle();
          expect(find.byType(ScheduleEditor), findsOneWidget);
          expect(find.text('当前操作已失效'), findsNothing);
          expect(find.text('查询保存结果'), findsOneWidget);
          expect(find.widgetWithText(FilledButton, '保存计划'), findsNothing);
          for (final field in tester.widgetList<TextFormField>(
              find.byType(TextFormField))) {
            expect(field.enabled, isFalse);
          }
          expect(f.requests.where((request) =>
              request.url.path == '/api/v1$_root/schedules'), hasLength(1));
        }
        query();
        query();
        await _flush(tester);
        expect(f.requests, hasLength(refusals.length + 2));
        _expectScheduleQuery(f.requests.last, original);
        final finalIndex = f.requests.length - 1;
        if (outcome == 'confirmed') {
          f.reply(finalIndex, 200, receipt);
        } else {
          f.reply(finalIndex, outcome == 'conflict' ? 412 : 410, {
            'errorCode': outcome == 'conflict'
                ? 'RESOURCE_VERSION_CONFLICT' : 'IDEMPOTENCY_RESULT_EXPIRED'
          });
        }
        await _flush(tester);
        await tester.pumpAndSettle();
        if (outcome == 'confirmed') {
          expect(find.byType(ScheduleEditor), findsNothing);
        } else {
          expect(find.text('原提交需要重新核对'), findsOneWidget);
          expect(find.text('保留的草稿'), findsOneWidget);
          expect(find.byType(TextFormField), findsNothing);
          expect(find.text('查询保存结果'), findsNothing);
          await tester.tap(find.text('保留的草稿'));
          await tester.pumpAndSettle();
          expect(find.byWidgetPredicate((widget) => widget is SelectableText &&
              widget.data?.contains('放学后的自由时间') == true &&
              widget.data?.contains('Asia/Shanghai') == true), findsOneWidget);
          query();
          staleSave();
          await _flush(tester);
          expect(f.requests, hasLength(refusals.length + 2));
          await tester.tap(find.byKey(const Key('editor-close-stopped')));
          await tester.pumpAndSettle();
          expect(find.byType(ScheduleEditor), findsNothing);
        }
        query();
        staleSave();
        await _flush(tester);
        expect(f.requests, hasLength(refusals.length + 2));
        expect(tester.takeException(), isNull);
      } finally {
        await f.cleanup(tester);
      }
    });
  }

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
      expect(find.text('查询保存结果'), findsOneWidget);
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
      f.reply(0, 200, _savedSchedule(f.requests.single));
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

  // Scope changes must invalidate captured callbacks and in-flight views.
  testWidgets('ScheduleEditor scope loss while awaiting client prevents dispatch',
      (tester) async {
    final blocked = _BlockedApi();
    final session = _EditorSession(blocked.api);
    final cleanup = _apiCleanup(tester, blocked, session);
    try {
      await _open(tester, ScheduleEditor(session: session, root: _root,
          timeZone: 'Asia/Shanghai'));
      await _fillScopeSchedule(tester);
      _capturedSubmit(tester, '保存计划')();
      await _flush(tester);
      expect(blocked.requests, isEmpty);
      session.changeScope('tenant');
      blocked.releaseClient();
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(blocked.requests, isEmpty,
          reason: 'A client released after scope loss must not receive the old POST.');
      expect(find.text('当前操作已失效'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEditor), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await cleanup();
    }
  });

  for (final dimension in ['generation', 'actor', 'tenant', 'role']) {
    testWidgets('ScheduleEditor same-frame $dimension away and back stays revoked',
        (tester) async {
      final f = _ScheduleRecoveryFixture();
      try {
        await _openSchedule(tester, f);
        final save = _capturedSubmit(tester, '保存计划');
        final add = _scheduleCallback(tester, _scheduleButton('加入计划'));
        final time = _scheduleCallback(tester, _scheduleButton('18:00'));
        final date = _scheduleCallback(tester, _scheduleButton('添加关闭日期'));
        final day = tester.widget<FilterChip>(find.byType(FilterChip).first)
            .onSelected!;
        f.session.changeScope(dimension);
        f.session.changeScope(dimension, restore: true);
        save();
        add();
        time();
        date();
        day(false);
        await _flush(tester);
        await tester.pumpAndSettle();
        expect(f.requests, isEmpty,
            reason: 'Restoring final scope values cannot revive captured callbacks.');
        expect(find.text('当前操作已失效'), findsOneWidget);
        expect(find.byType(TextFormField), findsNothing);
        expect(find.byType(TimePickerDialog), findsNothing);
        expect(find.byType(DatePickerDialog), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await f.cleanup(tester);
      }
    });
  }

  testWidgets('ScheduleEditor scope loss removes only its covered unknown confirmation',
      (tester) async {
    final f = _ScheduleRecoveryFixture();
    try {
      await _openSchedule(tester, f);
      final save = _capturedSubmit(tester, '保存计划');
      save();
      await _flush(tester);
      f.reply(0, 503, {'errorCode': 'SERVICE_UNAVAILABLE'});
      await _flush(tester);
      final query = _capturedSubmit(tester, '查询保存结果');
      await tester.tap(find.byKey(const Key('schedule-editor-close-unknown')));
      await tester.pumpAndSettle();
      final confirm = tester.widget<TextButton>(find.byKey(
          const Key('schedule-editor-confirm-close-unknown'))).onPressed!;
      var noticeClosed = false;
      await _coverScopeNotice(tester, () => noticeClosed = true);
      f.session.changeScope('actor');
      query();
      save();
      confirm();
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(find.text('范围外通知'), findsOneWidget);
      expect(noticeClosed, isFalse);
      expect(find.byKey(const Key('schedule-editor-confirm-close-unknown'),
          skipOffstage: false), findsNothing);
      expect(f.requests, hasLength(1));
      await tester.tap(find.text('关闭范围外通知'));
      await tester.pumpAndSettle();
      expect(find.text('当前操作已失效'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEditor), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.cleanup(tester);
    }
  });

  for (final status in [200, 503]) {
    testWidgets('ScheduleEditor late $status after scope loss preserves covering notice',
        (tester) async {
      final f = _ScheduleRecoveryFixture();
      try {
        await _openSchedule(tester, f);
        _capturedSubmit(tester, '保存计划')();
        await _flush(tester);
        expect(f.requests, hasLength(1));
        var noticeClosed = false;
        await _coverScopeNotice(tester, () => noticeClosed = true);
        f.session.changeScope('tenant');
        await tester.pump();
        f.reply(0, status, status == 200 ? _savedSchedule(f.requests.single)
            : {'errorCode': 'SERVICE_UNAVAILABLE'});
        await _flush(tester);
        await tester.pumpAndSettle();
        expect(noticeClosed, isFalse);
        expect(find.text('范围外通知'), findsOneWidget);
        expect(find.byType(ScheduleEditor, skipOffstage: false), findsOneWidget);
        await tester.tap(find.text('关闭范围外通知'));
        await tester.pumpAndSettle();
        expect(find.text('当前操作已失效'), findsOneWidget);
        expect(find.byType(TextFormField), findsNothing);
        expect(find.text('查询保存结果'), findsNothing);
        expect(f.requests, hasLength(1));
        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(ScheduleEditor), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await f.cleanup(tester);
      }
    });
  }

  for (final rejection in const {
    401: 'UNAUTHENTICATED',
    403: 'ACCESS_DENIED',
    409: 'WORKSPACE_CHANGED',
  }.entries) {
    for (final querying in [false, true]) {
      testWidgets('ScheduleEditor ${rejection.value} revokes '
          '${querying ? 'lookup' : 'submission'} content',
          (tester) async {
        final f = _ScheduleRecoveryFixture();
        try {
          await _openSchedule(tester, f);
          final save = _capturedSubmit(tester, '保存计划');
          save();
          await _flush(tester);
          var staleAction = save;
          if (querying) {
            f.reply(0, 503, {'errorCode': 'SERVICE_UNAVAILABLE'});
            await _flush(tester);
            staleAction = _capturedSubmit(tester, '查询保存结果');
            staleAction();
            await _flush(tester);
            _expectScheduleQuery(f.requests.last, f.requests.first);
          }
          f.reply(querying ? 1 : 0, rejection.key, {'errorCode': rejection.value});
          await _flush(tester);
          await tester.pumpAndSettle();
          expect(find.text('当前操作已失效'), findsOneWidget);
          expect(find.byType(TextFormField), findsNothing);
          save();
          staleAction();
          await _flush(tester);
          expect(f.requests, hasLength(querying ? 2 : 1));
          await tester.tap(find.widgetWithText(TextButton, '关闭'));
          await tester.pumpAndSettle();
          expect(find.byType(ScheduleEditor), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await f.cleanup(tester);
        }
      });
    }
  }

  testWidgets('ScheduleEditor reauthentication requirement is not scope revocation',
      (tester) async {
    final f = _ScheduleRecoveryFixture();
    try {
      await _openSchedule(tester, f);
      _capturedSubmit(tester, '保存计划')();
      await _flush(tester);
      f.reply(0, 401, {'errorCode': 'REAUTH_REQUIRED'});
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(find.text('当前操作已失效'), findsNothing);
      expect(tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, '计划名称')).enabled, isTrue);
      _capturedSubmit(tester, '保存计划')();
      await _flush(tester);
      expect(f.requests, hasLength(2));
      f.reply(1, 200, _savedSchedule(f.requests.last));
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEditor), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.cleanup(tester);
    }
  });

  for (final replacement in ['session', 'root']) {
    testWidgets('ScheduleEditor $replacement replacement cannot revive old state',
        (tester) async {
      final original = _ScheduleRecoveryFixture();
      final next = _ScheduleRecoveryFixture();
      late StateSetter rebuild;
      var session = original.session;
      var root = _root;
      try {
        await _open(tester, StatefulBuilder(builder: (context, setState) {
          rebuild = setState;
          return ScheduleEditor(key: const Key('scope-replaced-schedule'),
              session: session, root: root, timeZone: 'Asia/Shanghai');
        }));
        await _fillScopeSchedule(tester);
        final save = _capturedSubmit(tester, '保存计划');
        rebuild(() {
          if (replacement == 'session') {
            session = next.session;
          } else {
            root = '/tenants/other-tenant';
          }
        });
        await tester.pumpAndSettle();
        rebuild(() {
          session = original.session;
          root = _root;
        });
        await tester.pumpAndSettle();
        save();
        await _flush(tester);
        expect(find.text('当前操作已失效'), findsOneWidget);
        expect(find.byType(TextFormField), findsNothing);
        expect(original.requests, isEmpty);
        expect(next.requests, isEmpty);
        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(ScheduleEditor), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await original.cleanup(tester);
        await next.cleanup(tester);
      }
    });
  }

}
