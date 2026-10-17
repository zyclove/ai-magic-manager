@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
// Exercise the production browser Session without a real identity provider.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/managed_execution_dialog_entry.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/managed_execution_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oauth2/oauth2.dart' as oauth;

import 'managed_execution_fixtures.dart';

const _actor = 'execution-host-owner';
const _deviceName = '原工作空间学习平板';
const _credentialKey = 'ai-manager.session';
const _workspaceKey = 'ai-manager.workspace';

/// Only transport lookup is replaced. Authentication ownership, initialization,
/// tenant selection and scopeGeneration remain the production implementation.
class _Session extends Session {
  final String membershipRole;
  late final MockClient bootstrap;
  late final Api _testApi;
  late Future<http.Client> Function() transport;

  _Session({this.membershipRole = 'OWNER'}) {
    bootstrap = MockClient((request) async {
      if (request.url.path == '/api/v1/me') {
        return _json({
          'subject': _actor,
          'name': '合成机构管理员',
          'canCreateTenant': false,
        });
      }
      if (request.url.path == '/api/v1/tenants') {
        return _json({
          'items': [
            {
              'id': executionTenant,
              'name': '原工作空间',
              'kind': 'ORGANIZATION',
            }
          ],
          'nextCursor': null,
        });
      }
      if (request.url.path == '/api/v1/tenants/$executionTenant/membership') {
        return _json({'role': membershipRole});
      }
      throw StateError('Unexpected execution host bootstrap request.');
    });
    transport = () async => bootstrap;
    _testApi =
        Api(authenticatedClient, baseUrl: 'https://execution.invalid/api/v1');
  }

  @override
  Api get api => _testApi;

  @override
  Future<http.Client> authenticatedClient() => transport();

  void changeActor(String actor) {
    profile = {...profile!, 'subject': actor};
    notifyListeners();
  }

  void changeRole(String nextRole) {
    role = nextRole;
    notifyListeners();
  }

  Future<void> sameTenantSelection() async {
    final original = transport;
    transport = () async => bootstrap;
    try {
      await selectTenant({...tenant!});
    } finally {
      transport = original;
    }
  }

  Future<void> release() async {
    // initialize closes the real Session's unused browser authentication client.
    html.window.sessionStorage.remove(_credentialKey);
    transport = () async => bootstrap;
    await initialize();
    bootstrap.close();
    dispose();
  }
}

http.Response _json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _Attempt {
  Object? error;
  bool completed = false;
}

_Attempt _open(BuildContext context, _Session session,
    {bool Function()? current,
    Listenable? targetChanges,
    bool readOnly = false}) {
  final attempt = _Attempt();
  try {
    unawaited(openManagedExecutions(context, session,
            deviceId: executionDevice,
            registrationId: executionRegistration,
            deviceName: _deviceName,
            current: current ?? () => true,
            targetChanges: targetChanges,
            readOnly: readOnly)
        .then<void>((_) {
      attempt.completed = true;
    }, onError: (Object error, StackTrace _) {
      attempt.error = error;
      attempt.completed = true;
    }));
  } catch (error) {
    attempt.error = error;
    attempt.completed = true;
  }
  return attempt;
}

Future<void> _flush(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    // Browser response streams also use the native event loop. Keep this
    // bounded so a deliberately pending response does not stall the test.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}

Future<BuildContext> _mount(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(body: Builder(builder: (value) {
        context = value;
        return const Text('执行记录宿主测试入口');
      }))));
  return context;
}

Future<_Session> _session(WidgetTester tester, ExecutionFixture data,
    {String role = 'OWNER'}) async {
  html.window.sessionStorage[_credentialKey] = oauth.Credentials(
          'synthetic-execution-host-access',
          expiration: DateTime.now().add(const Duration(hours: 1)))
      .toJson();
  html.window.localStorage[_workspaceKey] = executionTenant;
  final session = _Session(membershipRole: role);
  await session.initialize();
  expect(session.authenticated, isTrue);
  expect(session.error, isNull);
  expect(session.profile?['subject'], _actor);
  expect(session.tenant?['id'], executionTenant);
  expect(session.role, role);
  session.transport = () async => data.client;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await session.release();
    data.client.close();
  });
  return session;
}

Future<void> _press(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _flush(tester);
}

Future<void> _openDetail(WidgetTester tester) async {
  await _press(tester, 'execution-open-$executionId');
  expect(find.byKey(const Key('execution-event-1')), findsOneWidget);
  expect(find.byKey(const Key('execution-cancel')), findsOneWidget);
}

void _expectHidden() {
  expect(find.textContaining(_deviceName), findsNothing);
  expect(find.byKey(const Key('execution-open-$executionId')), findsNothing);
  expect(find.byKey(const Key('execution-event-1')), findsNothing);
  expect(find.byKey(const Key('execution-cancel')), findsNothing);
  expect(find.byKey(const Key('execution-confirm-cancel')), findsNothing);
  expect(find.byKey(const Key('execution-scope-unavailable')), findsOneWidget);
}

void main() {
  setUp(() {
    final sessionValues = <String, String?>{
      for (final key in [
        _credentialKey,
        'ai-manager.report-resume',
        'ai-manager.contract-resume',
      ])
        key: html.window.sessionStorage[key],
    };
    final workspace = html.window.localStorage[_workspaceKey];
    addTearDown(() {
      for (final entry in sessionValues.entries) {
        if (entry.value == null) {
          html.window.sessionStorage.remove(entry.key);
        } else {
          html.window.sessionStorage[entry.key] = entry.value!;
        }
      }
      if (workspace == null) {
        html.window.localStorage.remove(_workspaceKey);
      } else {
        html.window.localStorage[_workspaceKey] = workspace;
      }
    });
  });

  for (final access in [
    (role: 'OWNER', readOnly: false, cancellable: true),
    (role: 'AUDITOR', readOnly: false, cancellable: false),
    (role: 'OWNER', readOnly: true, cancellable: false),
  ]) {
    testWidgets(
        '${access.role} readOnly=${access.readOnly} opens records with the permitted actions',
        (tester) async {
      final data = ExecutionFixture();
      final session = await _session(tester, data, role: access.role);
      final context = await _mount(tester);
      final attempt = _open(context, session, readOnly: access.readOnly);
      await _flush(tester);

      expect(attempt.error, isNull);
      expect(find.byType(ManagedExecutionDialog), findsOneWidget);
      expect(find.textContaining(_deviceName), findsWidgets);
      expect(
          find.byKey(const Key('execution-open-$executionId')), findsOneWidget);
      expect(data.requests, hasLength(1));
      expect(data.requests.single.method, 'GET');
      expect(data.requests.single.url.path,
          '/api/v1/tenants/$executionTenant/managed-android/executions');
      expect(data.requests.single.url.queryParameters['deviceId'],
          executionDevice);
      expect(data.requests.single.url.queryParameters['limit'], '50');

      await _press(tester, 'execution-open-$executionId');

      expect(find.byKey(const Key('execution-event-1')), findsOneWidget);
      expect(find.byKey(const Key('execution-cancel')),
          access.cancellable ? findsOneWidget : findsNothing);
      expect(find.byKey(const Key('execution-confirm-cancel')), findsNothing);
      expect(
          data.requests.where((request) => request.method == 'POST'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final role in ['GUARDIAN', 'CHILD']) {
    testWidgets('$role is denied before a dialog or execution request exists',
        (tester) async {
      final data = ExecutionFixture();
      final session = await _session(tester, data, role: role);
      final context = await _mount(tester);
      final attempt = _open(context, session);
      await _flush(tester);

      expect(
          attempt.error,
          isA<ApiFailure>()
              .having((error) => error.status, 'status', 403)
              .having((error) => error.code, 'code', 'ACCESS_DENIED'));
      expect(attempt.completed, isTrue);
      expect(find.byType(Dialog), findsNothing);
      expect(data.requests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final change in ['actor', 'role']) {
    testWidgets(
        '$change away and back before a frame permanently hides old data',
        (tester) async {
      final data = ExecutionFixture();
      final session = await _session(tester, data);
      final context = await _mount(tester);
      final attempt = _open(context, session);
      await _flush(tester);
      await _openDetail(tester);
      final refresh = tester
          .widget<TextButton>(find.byKey(const Key('execution-refresh-detail')))
          .onPressed!;
      final before = data.requests.length;
      final generation = session.scopeGeneration;

      if (change == 'actor') {
        session.changeActor('replacement-execution-actor');
        session.changeActor(_actor);
      } else {
        session.changeRole('ORG_ADMIN');
        session.changeRole('OWNER');
      }
      expect(session.scopeGeneration, generation,
          reason:
              'This case isolates identity and role from selection generation.');
      await _flush(tester);

      _expectHidden();
      refresh();
      await _flush(tester);
      _expectHidden();
      expect(data.requests, hasLength(before));
      expect(attempt.error, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('same tenant selection invalidates the existing execution window',
      (tester) async {
    final data = ExecutionFixture();
    final session = await _session(tester, data);
    final context = await _mount(tester);
    final attempt = _open(context, session);
    await _flush(tester);
    await _openDetail(tester);
    final refresh = tester
        .widget<TextButton>(find.byKey(const Key('execution-refresh-detail')))
        .onPressed!;
    final before = data.requests.length;
    final generation = session.scopeGeneration;

    await session.sameTenantSelection();
    expect(session.scopeGeneration, greaterThan(generation));
    expect(session.profile?['subject'], _actor);
    expect(session.tenant?['id'], executionTenant);
    expect(session.role, 'OWNER');
    await _flush(tester);

    _expectHidden();
    refresh();
    await _flush(tester);
    _expectHidden();
    expect(data.requests, hasLength(before));
    expect(attempt.error, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'parent target changes revoke the window synchronously and permanently',
      (tester) async {
    final data = ExecutionFixture();
    final session = await _session(tester, data);
    final context = await _mount(tester);
    final targetChanges = ValueNotifier<int>(0);
    addTearDown(targetChanges.dispose);
    var parentCurrent = true;
    final attempt = _open(context, session,
        current: () => parentCurrent, targetChanges: targetChanges);
    await _flush(tester);
    await _openDetail(tester);
    final refresh = tester
        .widget<TextButton>(find.byKey(const Key('execution-refresh-detail')))
        .onPressed!;
    final before = data.requests.length;

    parentCurrent = false;
    targetChanges.value++;
    parentCurrent = true;
    targetChanges.value++;
    await _flush(tester);

    _expectHidden();
    refresh();
    await _flush(tester);
    _expectHidden();
    expect(data.requests, hasLength(before));
    expect(attempt.error, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('parent invalidation before the first builder cannot be revived',
      (tester) async {
    final data = ExecutionFixture();
    final session = await _session(tester, data);
    final context = await _mount(tester);
    final targetChanges = ValueNotifier<int>(0);
    addTearDown(targetChanges.dispose);
    var parentCurrent = true;
    final attempt = _open(context, session,
        current: () => parentCurrent, targetChanges: targetChanges);

    // No pump or await may occur between opening and both notifications.
    // The host must observe the loss before its dialog starts listening.
    parentCurrent = false;
    targetChanges.value++;
    parentCurrent = true;
    targetChanges.value++;
    await _flush(tester);

    expect(data.requests, isEmpty,
        reason: 'The first builder must not read for a revoked parent target.');
    _expectHidden();
    final controller = tester
        .widget<ManagedExecutionDialog>(find.byType(ManagedExecutionDialog))
        .controller;
    expect(controller.hasAccess, isFalse);
    expect(controller.items, isEmpty);
    expect(controller.selected, isNull);
    expect(controller.events, isEmpty);
    await controller.load();
    expect(data.requests, isEmpty);
    expect(attempt.error, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'closing the host rejects a late list response without restoring data',
      (tester) async {
    final data = ExecutionFixture();
    final response = Completer<http.Response>();
    data.handler = (_) => response.future;
    addTearDown(() {
      if (!response.isCompleted) {
        response.complete(data.response({'items': [], 'nextCursor': null}));
      }
    });
    final session = await _session(tester, data);
    final context = await _mount(tester);
    final attempt = _open(context, session);
    await _flush(tester);
    expect(find.byType(ManagedExecutionDialog), findsOneWidget);
    expect(data.requests, hasLength(1));
    expect(find.byKey(const Key('execution-open-$executionId')), findsNothing);
    final original = tester
        .widget<ManagedExecutionDialog>(find.byType(ManagedExecutionDialog))
        .controller;

    await _press(tester, 'execution-close');
    expect(attempt.completed, isTrue);
    expect(find.byType(ManagedExecutionDialog), findsNothing);
    expect(original.hasAccess, isFalse);
    response.complete(data.response({
      'items': [data.record()],
      'nextCursor': null,
    }));
    await _flush(tester);

    expect(find.byType(ManagedExecutionDialog), findsNothing);
    expect(find.textContaining(_deviceName), findsNothing);
    expect(find.byKey(const Key('execution-open-$executionId')), findsNothing);
    expect(original.items, isEmpty);
    await original.load();
    expect(data.requests, hasLength(1));
    expect(attempt.error, isNull);
    expect(tester.takeException(), isNull);
  });
}
