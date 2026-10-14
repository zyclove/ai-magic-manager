@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
// Session is the production browser session, exercised without a real IdP.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:device_operations/device_operations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:guardian/pages/device_diagnostic_dialog.dart';
import 'package:guardian/pages/device_exit_dialog.dart';
import 'package:guardian/pages/diagnostic_packages_dialog.dart';
import 'package:guardian/pages/observation_page.dart';
import 'package:guardian/pages/support_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/diagnostic_packages_view.dart';
import 'package:guardian/ui/diagnostic_preview_view.dart';
import 'package:guardian/ui/observation_view.dart';
import 'package:guardian/ui/support_center_view.dart';
import 'package:guardian/ui/support_grant_view.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oauth2/oauth2.dart' as oauth;
// Reuse the existing device_operations journal fixture without a new dependency.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'api_scope_test.dart'
    show RecordingTransport, expiredCredentials, refreshedToken;
import 'fixtures/diagnostic.dart' as diagnostic;
import 'fixtures/support.dart' as support;

enum _Flow { diagnostic, packages, receivedPackages, grant, observation, exit }

const _actor = support.owner;
const _otherActor = 'different-authenticated-actor';
const _otherTenant = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _credentialKey = 'ai-manager.session';
const _workspaceKey = 'ai-manager.workspace';

Json _device() => {
      'id': diagnostic.device,
      'registrationId': diagnostic.registration,
      'displayName': '原工作空间学习平板',
      'state': 'ACTIVE',
      'platform': 'ANDROID',
      'managementMode': 'BYOD',
      'version': 3,
    };

/// Replace only transport lookup. Authentication ownership, initialize,
/// selectTenant and scopeGeneration are the real Session implementation.
class _Session extends Session {
  late final Api _testApi;
  late final MockClient bootstrap;
  late Future<http.Client> Function() transport;

  _Session() {
    bootstrap = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v1/me') {
        return _json({
          'subject': _actor,
          'name': '模拟管理员',
          'canCreateTenant': false,
        });
      }
      if (path == '/api/v1/tenants') {
        return _json({
          'items': [
            {'id': diagnostic.tenant, 'name': '原工作空间', 'kind': 'FAMILY'}
          ],
          'nextCursor': null,
        });
      }
      if (path.endsWith('/membership')) return _json({'role': 'OWNER'});
      throw StateError('Unexpected session fixture request.');
    });
    transport = () async => bootstrap;
    _testApi =
        Api(authenticatedClient, baseUrl: 'https://business.example/api/v1');
  }

  @override
  Api get api => _testApi;

  @override
  Future<http.Client> authenticatedClient() => transport();

  void change({String? actor, String? tenantId, String? nextRole}) {
    if (actor != null) profile = {...profile!, 'subject': actor};
    if (tenantId != null) tenant = {...tenant!, 'id': tenantId};
    if (nextRole != null) role = nextRole;
    notifyListeners();
  }

  void receiving(bool eligible) {
    profile = {...profile!, 'canCreateTenant': eligible};
    notifyListeners();
  }

  Future<void> sameScopeSelection() async {
    final original = transport;
    transport = () async => bootstrap;
    try {
      await selectTenant({...tenant!});
    } finally {
      transport = original;
    }
  }

  Future<void> release() async {
    // Closing the real Session authentication lifetime also closes its unused
    // browser transport. It never sends an actual request in this fixture.
    html.window.sessionStorage.remove(_credentialKey);
    transport = () async => bootstrap;
    await initialize();
    bootstrap.close();
    dispose();
  }
}

http.Response _json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _BusinessClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    await request.finalize().toBytes();
    final path = request.url.path;
    Object value;
    if (path.endsWith('/diagnostic-preview')) {
      value = diagnostic.fixture();
    } else if (path.endsWith('/observation-settings')) {
      value = {
        'deviceId': diagnostic.device,
        'registrationId': diagnostic.registration,
        'version': 1,
        'inventoryEnabled': false,
        'usageEnabled': false,
        'updatedAt': diagnostic.now,
      };
    } else if (path.endsWith('/resolve')) {
      value = support.pairingFixture();
    } else if (path.endsWith('/diagnostic-packages') ||
        path.endsWith('/deprovision/operations') ||
        path.endsWith('/support-grants')) {
      value = {'items': [], 'nextCursor': null};
    } else {
      throw StateError('Unexpected subflow fixture request.');
    }
    final bytes = utf8.encode(jsonEncode(value));
    return http.StreamedResponse(Stream.value(bytes), 200,
        contentLength: bytes.length,
        headers: {
          'content-type': 'application/json',
          'cache-control': 'no-store',
        },
        request: request);
  }
}

class _Attempt {
  Object? error;
}

_Attempt _open(_Flow flow, BuildContext context, _Session session) {
  final attempt = _Attempt();
  try {
    final future = switch (flow) {
      _Flow.diagnostic => openDeviceDiagnostic(context, session, _device()),
      _Flow.packages =>
        openDiagnosticPackages(context, session, device: _device()),
      _Flow.receivedPackages =>
        openDiagnosticPackages(context, session, received: true),
      _Flow.grant => openSupportGrant(context, session, _device()),
      _Flow.observation => openDeviceObservation(context, session, _device()),
      _Flow.exit => openDeviceExit(context, session, _device()),
    };
    unawaited(future.then<void>((_) {}, onError: (Object error, StackTrace _) {
      attempt.error = error;
    }));
  } catch (error) {
    attempt.error = error;
  }
  return attempt;
}

Future<void> _flush(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    // Browser stream delivery also uses the native event loop. Advance one
    // bounded turn without completing deliberately pending OAuth responses.
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
        return const Text('子流程测试入口');
      }))));
  return context;
}

Future<_Session> _session(WidgetTester tester, http.Client business) async {
  html.window.sessionStorage[_credentialKey] = oauth.Credentials(
          'synthetic-test-access',
          expiration: DateTime.now().add(const Duration(hours: 1)))
      .toJson();
  html.window.localStorage[_workspaceKey] = diagnostic.tenant;
  final session = _Session();
  await session.initialize();
  expect(session.authenticated, isTrue);
  expect(session.tenant?['id'], diagnostic.tenant);
  expect(session.role, 'OWNER');
  session.transport = () async => business;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await session.release();
    business.close();
  });
  return session;
}

void _prepare(_Flow flow, _Session session) {
  if (flow == _Flow.receivedPackages) session.receiving(true);
}

Future<void> _driveRead(WidgetTester tester, _Flow flow) async {
  final label = switch (flow) {
    _Flow.diagnostic => '读取诊断',
    _Flow.packages || _Flow.receivedPackages => '刷新任务列表',
    _Flow.grant => '核对接收人',
    _Flow.observation || _Flow.exit => null,
  };
  if (label == null) return; // These real dialogs read during initialization.
  if (flow == _Flow.grant) {
    final field = find.byWidgetPredicate((widget) =>
        widget is TextField &&
        widget.key == const ValueKey('support-pairing-code'));
    if (field.evaluate().isEmpty) return;
    await tester.enterText(field, support.code);
  }
  final button = find.text(label);
  if (button.evaluate().isEmpty) return;
  await tester.ensureVisible(button);
  await tester.tap(button);
  await _flush(tester);
}

void _expectEnabledButton(WidgetTester tester, String label) {
  final button = find.ancestor(
      of: find.text(label),
      matching:
          find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
  expect(button, findsOneWidget);
  expect(tester.widget<ButtonStyleButton>(button).onPressed, isNotNull);
}

void _expectReady(WidgetTester tester, _Flow flow) {
  expect(find.byType(LinearProgressIndicator), findsNothing);
  expect(find.byType(CircularProgressIndicator), findsNothing);
  switch (flow) {
    case _Flow.diagnostic:
      // A report is rendered only after successful parsing; a loading or error
      // view cannot contain these original device version facts.
      expect(find.text('1.2.3'), findsOneWidget);
      _expectEnabledButton(tester, '刷新诊断');
      break;
    case _Flow.packages:
    case _Flow.receivedPackages:
      expect(find.text('暂无诊断包任务。'), findsOneWidget,
          reason:
              'The empty list is shown only after a successful first read.');
      _expectEnabledButton(tester, '刷新任务列表');
      break;
    case _Flow.grant:
      expect(find.text('技术支持接收人'), findsOneWidget);
      expect(find.text('recipient@example.test'), findsOneWidget);
      expect(
          tester
              .widget<TextField>(find.byWidgetPredicate((widget) =>
                  widget is TextField &&
                  widget.key == const ValueKey('support-pairing-code')))
              .enabled,
          isTrue);
      _expectEnabledButton(tester, '核对接收人');
      break;
    case _Flow.observation:
      final view = tester.widget<ObservationView>(find.byType(ObservationView));
      expect(view.snapshot, isNotNull);
      expect(view.snapshot!.settings.version, 1);
      expect(view.busy, isFalse);
      expect(view.error, isNull);
      expect(find.text('应用清单 · 关闭'), findsOneWidget);
      expect(find.text('使用摘要 · 关闭'), findsOneWidget);
      _expectEnabledButton(tester, '刷新状态');
      break;
    case _Flow.exit:
      final panel =
          tester.widget<DeviceExitPanel>(find.byType(DeviceExitPanel));
      expect(panel.controller.initialized, isTrue);
      expect(panel.controller.busy, isFalse);
      expect(panel.controller.error, isNull);
      expect(panel.controller.operation, isNull);
      expect(panel.controller.canPrepare, isTrue);
      _expectEnabledButton(tester, '查看退出后果');
      break;
  }
}

void _expectHidden(WidgetTester tester, _Flow flow) {
  switch (flow) {
    case _Flow.diagnostic:
      final diagnosticView = find.byType(DiagnosticPreviewView);
      final buttons = find.descendant(
          of: diagnosticView, matching: find.byType(FilledButton));
      for (final button in tester.widgetList<FilledButton>(buttons)) {
        expect(button.onPressed, isNull,
            reason: 'An invalidated diagnostic cannot be loaded again.');
      }
      expect(find.text('1.2.3'), findsNothing,
          reason: 'Old diagnostic facts must be hidden.');
      break;
    case _Flow.packages:
    case _Flow.receivedPackages:
      final packagesView = find.byType(DiagnosticPackagesView);
      expect(
          find.descendant(
              of: packagesView, matching: find.byType(CheckboxListTile)),
          findsNothing);
      expect(
          find.descendant(
              of: packagesView, matching: find.byType(OutlinedButton)),
          findsNothing);
      break;
    case _Flow.grant:
      expect(
          find.descendant(
              of: find.byType(SupportGrantView),
              matching: find.byType(TextField)),
          findsNothing);
      expect(find.text('技术支持接收人'), findsNothing);
      break;
    case _Flow.observation:
      expect(find.byType(ObservationView), findsNothing,
          reason: 'Old observation settings must no longer be actionable.');
      break;
    case _Flow.exit:
      expect(find.byType(DeviceExitPanel), findsNothing,
          reason: 'An exit operation cannot adopt the replacement scope.');
      break;
  }
}

void main() {
  setUp(() {
    final previousPreferences = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final sessionValues = <String, String?>{
      for (final key in [
        _credentialKey,
        'ai-manager.report-resume',
        'ai-manager.contract-resume'
      ])
        key: html.window.sessionStorage[key],
    };
    final workspace = html.window.localStorage[_workspaceKey];
    addTearDown(() {
      SharedPreferencesAsyncPlatform.instance = previousPreferences;
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

  for (final flow in _Flow.values) {
    testWidgets(
        '${flow.name} rejects unauthorized entry before creating a dialog',
        (tester) async {
      final raw = _BusinessClient();
      final session = await _session(tester, raw);
      session.change(nextRole: 'TEACHER');
      session.receiving(false);
      final context = await _mount(tester);
      final attempt = _open(flow, context, session);
      await _flush(tester);
      expect(attempt.error,
          isA<ApiFailure>().having((error) => error.status, 'status', 403));
      expect(find.byType(Dialog), findsNothing);
      expect(raw.requests, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${flow.name} captures actor before the dialog builder runs',
        (tester) async {
      final raw = _BusinessClient();
      final session = await _session(tester, raw);
      _prepare(flow, session);
      final context = await _mount(tester);
      _open(flow, context, session);
      session.change(actor: _otherActor);
      await _flush(tester);
      _expectHidden(tester, flow);
      expect(raw.requests, isEmpty,
          reason:
              'The builder must not recapture a new actor for an old device.');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '${flow.name} same-scope reselection invalidates the old journey',
        (tester) async {
      final raw = _BusinessClient();
      final session = await _session(tester, raw);
      _prepare(flow, session);
      final context = await _mount(tester);
      final attempt = _open(flow, context, session);
      await _flush(tester);
      await _driveRead(tester, flow);
      expect(attempt.error, isNull);
      _expectReady(tester, flow);
      expect(raw.requests, hasLength(1),
          reason:
              'Exercise the real first read before invalidating its scope.');
      final before = session.scopeGeneration;
      await session.sameScopeSelection();
      expect(session.scopeGeneration, greaterThan(before));
      expect(session.profile?['subject'], _actor);
      expect(session.tenant?['id'], diagnostic.tenant);
      expect(session.role, 'OWNER');
      await _flush(tester);
      _expectHidden(tester, flow);
      await _driveRead(tester, flow);
      expect(raw.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('${flow.name} OAuth refresh cannot dispatch the old scope',
        (tester) async {
      final raw = RecordingTransport();
      final authenticated = oauth.Client(expiredCredentials(),
          identifier: 'guardian',
          basicAuth: false,
          httpClient: ScopeGuardedClient(raw));
      final session = await _session(tester, authenticated);
      _prepare(flow, session);
      final context = await _mount(tester);
      _open(flow, context, session);
      await _flush(tester);
      await _driveRead(tester, flow);
      expect(raw.tokenStarted.isCompleted, isTrue,
          reason:
              'The real OAuth refresh must be waiting before scope change.');
      await session.sameScopeSelection();
      raw.tokenReply.complete(refreshedToken());
      await _flush(tester);
      expect(raw.businessRequests, isEmpty,
          reason: 'No old business request may enter the physical transport.');
      _expectHidden(tester, flow);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'observation hides settings when role changes to another adult role',
      (tester) async {
    final raw = _BusinessClient();
    final session = await _session(tester, raw);
    final context = await _mount(tester);
    _open(_Flow.observation, context, session);
    await _flush(tester);
    expect(raw.requests, hasLength(1));
    expect(
        tester.widget<ObservationView>(find.byType(ObservationView)).snapshot,
        isNotNull);
    session.change(nextRole: 'GUARDIAN');
    await _flush(tester);
    _expectHidden(tester, _Flow.observation);
    expect(raw.requests, hasLength(1));
  });

  testWidgets(
      'observation tenant ABA before a frame cannot revive old settings',
      (tester) async {
    final raw = _BusinessClient();
    final session = await _session(tester, raw);
    final context = await _mount(tester);
    _open(_Flow.observation, context, session);
    await _flush(tester);
    expect(raw.requests, hasLength(1));
    session.change(tenantId: _otherTenant);
    session.change(tenantId: diagnostic.tenant);
    await _flush(tester);
    _expectHidden(tester, _Flow.observation);
    expect(raw.requests, hasLength(1));
  });

  testWidgets(
      'support workspace keeps the original repository invalid after reselection',
      (tester) async {
    final raw = _BusinessClient();
    final session = await _session(tester, raw);
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(body: SupportWorkspacePage(session))));
    final original =
        tester.widget<SupportCenterView>(find.byType(SupportCenterView));
    await session.sameScopeSelection();
    await _flush(tester);
    await expectLater(
        original.repository.grants(received: false),
        throwsA(isA<ApiFailure>()
            .having((error) => error.code, 'code', 'WORKSPACE_CHANGED')));
    expect(raw.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
