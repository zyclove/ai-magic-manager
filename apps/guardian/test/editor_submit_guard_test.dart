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
}
