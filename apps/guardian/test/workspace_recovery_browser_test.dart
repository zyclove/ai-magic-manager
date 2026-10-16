@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
// Browser storage below belongs only to this isolated test origin.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/core/workspace_read_recovery.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/workspace_welcome.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oauth2/oauth2.dart' as oauth;

const newTenant = '11111111-1111-4111-8111-111111111111';
const oldTenant = '22222222-2222-4222-8222-222222222222';
Json workspace(String id) => {'id': id, 'name': '测试工作空间', 'kind': 'FAMILY'};
http.Response reply(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
http.Response tenantList([List<String> ids = const [newTenant]]) =>
    reply({'items': ids.map(workspace).toList(), 'nextCursor': null});

/// Real Session initialization, selection and authentication ownership; only
/// HTTP transport and signed-in identity are explicit synthetic fixtures.
class FixtureSession extends Session {
  final Future<http.Response> Function(http.Request) handle;
  final requests = <({String method, String path})>[];
  late final MockClient transport;
  late final Api fixtureApi;
  bool bootstrapping = false;
  String actor = 'fixture-actor';
  int authentication = 0;
  final savedCredential = html.window.sessionStorage['ai-manager.session'];
  final savedWorkspace = html.window.localStorage['ai-manager.workspace'];

  FixtureSession(this.handle) {
    transport = MockClient((request) async {
      if (request.url.path == '/api/v1/me') {
        return reply(
            {'subject': actor, 'name': '合成管理员', 'canCreateTenant': true});
      }
      if (bootstrapping && request.url.path == '/api/v1/tenants') {
        return tenantList(const []);
      }
      requests.add((method: request.method, path: request.url.path));
      return handle(request);
    });
    fixtureApi =
        Api(authenticatedClient, baseUrl: 'https://fixture.invalid/api/v1');
  }
  @override
  Api get api => fixtureApi;
  @override
  Future<http.Client> authenticatedClient() async => transport;

  Future<void> authenticate([String nextActor = 'fixture-actor']) async {
    actor = nextActor;
    bootstrapping = true;
    html.window.sessionStorage['ai-manager.session'] = oauth.Credentials(
            'SYNTHETIC_TEST_TOKEN_${authentication++}',
            expiration: DateTime.now().add(const Duration(hours: 1)))
        .toJson();
    try {
      await initialize();
    } finally {
      bootstrapping = false;
    }
  }

  Future<void> release() async {
    html.window.sessionStorage.remove('ai-manager.session');
    await initialize();
    transport.close();
    dispose();
    if (savedCredential == null) {
      html.window.sessionStorage.remove('ai-manager.session');
    } else {
      html.window.sessionStorage['ai-manager.session'] = savedCredential!;
    }
    if (savedWorkspace == null) {
      html.window.localStorage.remove('ai-manager.workspace');
    } else {
      html.window.localStorage['ai-manager.workspace'] = savedWorkspace!;
    }
  }
}

// Drain real HTTP stream futures and finite route transitions. The welcome
// page intentionally stays busy while a form or recovery dialog awaits input,
// so waiting for every animation to stop would never finish in those states.
Future<void> flushReads(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> mount(WidgetTester tester, FixtureSession session,
    {bool centralDialog = false}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: AnimatedBuilder(
              animation: session,
              builder: (context, _) {
                final profile = session.profile;
                final actions = ConsoleActions(context, session);
                return SingleChildScrollView(
                    padding: const EdgeInsets.all(18),
                    child: WorkspaceWelcome(
                        key: ValueKey(profile),
                        authenticationIdentity: profile,
                        isCurrent: () =>
                            session.authenticated &&
                            identical(session.profile, profile),
                        onCreate: () => actions.createTenant(
                            onReadFailure: centralDialog
                                ? null
                                : (failure) async {
                                    throw failure;
                                  }),
                        onJoin: () => actions.acceptInvitation(
                            onReadFailure: centralDialog
                                ? null
                                : (failure) async {
                                    throw failure;
                                  }),
                        onRefresh: session.loadTenants));
              }))));
}

Future<void> openWrite(WidgetTester tester, {bool invitation = false}) async {
  final label = invitation ? '使用邀请加入' : '创建工作空间';
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await flushReads(tester);
  final form = find.byType(EditDialog);
  expect(form, findsOneWidget);
  final input =
      find.descendant(of: form, matching: find.byType(TextFormField)).first;
  expect(input.hitTestable(), findsOneWidget);
  await tester.enterText(
      input, invitation ? 'SYNTHETIC_INVITATION_ONLY' : '测试家庭');
}

Future<void> submit(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '保存').last);
  await flushReads(tester);
  expect(find.byType(EditDialog), findsNothing);
}

Future<void> retry(WidgetTester tester) async {
  await tester.ensureVisible(find.text('重试读取'));
  await tester.tap(find.text('重试读取'));
  await flushReads(tester);
}

Future<FixtureSession> fixture(WidgetTester tester,
    Future<http.Response> Function(http.Request) handle) async {
  final session = FixtureSession(handle);
  await session.authenticate();
  expect(session.authenticated, isTrue);
  expect(session.tenant, isNull);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await session.release();
  });
  return session;
}

void main() {
  testWidgets(
      'creation list failure retries only GET and selects the created workspace once',
      (tester) async {
    var listReads = 0;
    final session = await fixture(tester, (request) async {
      if (request.method == 'POST') return reply(workspace(newTenant), 201);
      if (request.url.path == '/api/v1/tenants') {
        return ++listReads == 1
            ? reply({'code': 'READ_UNAVAILABLE'}, 503)
            : tenantList(const [oldTenant, newTenant]);
      }
      if (request.url.path.endsWith('/membership')) {
        return reply({'role': 'OWNER'});
      }
      throw StateError('Unexpected fixture request.');
    });
    html.window.localStorage['ai-manager.workspace'] = oldTenant;
    await mount(tester, session);
    await openWrite(tester);
    await submit(tester);
    expect(find.text('工作空间已创建，工作空间资料暂未加载。'), findsOneWidget);
    await retry(tester);
    expect(session.requests.where((r) => r.method == 'POST').length, 1);
    expect(listReads, 2);
    expect(
        session.requests
            .where((r) => r.path.endsWith('/membership'))
            .map((r) => r.path),
        ['/api/v1/tenants/$newTenant/membership']);
    expect(session.tenant?['id'], newTenant);
  });
  testWidgets(
      'membership read failure preserves completed creation through its own scope epoch change',
      (tester) async {
    var memberships = 0;
    final session = await fixture(tester, (request) async {
      if (request.method == 'POST') return reply(workspace(newTenant), 201);
      if (request.url.path == '/api/v1/tenants') return tenantList();
      return ++memberships == 1
          ? reply({'code': 'READ_UNAVAILABLE'}, 503)
          : reply({'role': 'OWNER'});
    });
    await mount(tester, session);
    await openWrite(tester);
    await submit(tester);
    expect(find.text('工作空间已创建，工作空间资料暂未加载。'), findsOneWidget);
    await retry(tester);
    expect(memberships, 2);
    expect(session.requests.where((r) => r.method == 'POST').length, 1);
    expect(session.tenant?['id'], newTenant);
  });
  testWidgets(
      'accepted invitation is never POSTed again when repeated reads fail',
      (tester) async {
    var reads = 0;
    final session = await fixture(tester, (request) async {
      if (request.method == 'POST') return reply({'tenantId': newTenant});
      if (request.url.path == '/api/v1/tenants') {
        return ++reads < 3
            ? reply({'code': 'READ_UNAVAILABLE'}, 503)
            : tenantList();
      }
      return reply({'role': 'OWNER'});
    });
    await mount(tester, session);
    await openWrite(tester, invitation: true);
    await submit(tester);
    await retry(tester);
    expect(find.text('已加入工作空间，工作空间资料暂未加载。'), findsOneWidget);
    await retry(tester);
    expect(session.requests.where((r) => r.method == 'POST').map((r) => r.path),
        ['/api/v1/invitations/accept']);
    expect(reads, 3);
  });
  testWidgets('cancelled creation and invitation make no business request',
      (tester) async {
    final session = await fixture(
        tester, (_) async => throw StateError('No request expected.'));
    await mount(tester, session);
    for (final invitation in [false, true]) {
      await openWrite(tester, invitation: invitation);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    }
    expect(session.requests, isEmpty);
    expect(find.byType(WorkspaceReadRecoveryPanel), findsNothing);
  });
  testWidgets(
      'default action caller consumes read failure in a recovery dialog',
      (tester) async {
    final session = await fixture(
        tester,
        (request) async => request.method == 'POST'
            ? reply(workspace(newTenant), 201)
            : reply({'code': 'READ_UNAVAILABLE'}, 503));
    await mount(tester, session, centralDialog: true);
    await openWrite(tester);
    await submit(tester);
    expect(find.text('读取工作空间资料'), findsOneWidget);
    expect(find.text('工作空间已创建，工作空间资料暂未加载。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await session.authenticate('next-fixture-actor');
    await tester.pumpAndSettle();
    expect(find.text('工作空间已创建，工作空间资料暂未加载。'), findsNothing);
    expect(find.text('账号会话已变化，请关闭此窗口。'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('读取工作空间资料'), findsNothing);
  });
  testWidgets(
      'account change during old POST dispatches no follow-up GET for the new account',
      (tester) async {
    final pending = Completer<http.Response>();
    final session = await fixture(tester, (_) => pending.future);
    await mount(tester, session);
    await openWrite(tester);
    await tester.tap(find.widgetWithText(FilledButton, '保存').last);
    for (var frame = 0; frame < 3; frame++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
    }
    expect(session.requests.length, 1);
    await session.authenticate('next-fixture-actor');
    pending.complete(reply(workspace(newTenant), 201));
    await flushReads(tester);
    expect(session.requests.length, 1);
    expect(session.profile?['subject'], 'next-fixture-actor');
    expect(find.byType(WorkspaceReadRecoveryPanel), findsNothing);
    expect(find.text('工作空间已创建，工作空间资料暂未加载。'), findsNothing);
  });
  testWidgets(
      'new credentials for the same actor invalidate old retry callbacks',
      (tester) async {
    final session = await fixture(
        tester,
        (request) async => request.method == 'POST'
            ? reply(workspace(newTenant), 201)
            : reply({'code': 'READ_UNAVAILABLE'}, 503));
    await mount(tester, session);
    await openWrite(tester);
    await submit(tester);
    final retained = tester
        .widget<WorkspaceReadRecoveryPanel>(
            find.byType(WorkspaceReadRecoveryPanel))
        .onRetry;
    final before = session.requests.length;
    await session.authenticate();
    await tester.pumpAndSettle();
    retained();
    await flushReads(tester);
    expect(session.requests.length, before);
    expect(find.byType(WorkspaceReadRecoveryPanel), findsNothing);
  });
  testWidgets(
      'created workspace missing from a stale list stays in GET-only recovery',
      (tester) async {
    var reads = 0;
    final session = await fixture(tester, (request) async {
      if (request.method == 'POST') return reply(workspace(newTenant), 201);
      if (request.url.path == '/api/v1/tenants') {
        return tenantList(
            ++reads == 1 ? const [oldTenant] : const [oldTenant, newTenant]);
      }
      return reply({'role': 'OWNER'});
    });
    await mount(tester, session);
    await openWrite(tester);
    await submit(tester);
    expect(find.text('工作空间已创建，工作空间资料暂未加载。'), findsOneWidget);
    expect(
        session.requests.where((r) => r.path.endsWith('/membership')), isEmpty);
    await retry(tester);
    expect(session.requests.where((r) => r.method == 'POST').length, 1);
    expect(
        session.requests
            .where((r) => r.path.endsWith('/membership'))
            .map((r) => r.path),
        ['/api/v1/tenants/$newTenant/membership']);
  });
  testWidgets(
      'default list reload retains the existing stored selection behavior',
      (tester) async {
    final session = await fixture(
        tester,
        (request) async => request.url.path == '/api/v1/tenants'
            ? tenantList(const [newTenant, oldTenant])
            : reply({'role': 'OWNER'}));
    html.window.localStorage['ai-manager.workspace'] = oldTenant;
    await session.loadTenants();
    expect(session.tenant?['id'], oldTenant);
    expect(session.requests.map((r) => r.path),
        ['/api/v1/tenants', '/api/v1/tenants/$oldTenant/membership']);
  });
  testWidgets(
      'closed recovery dialog cannot pop a subsequently opened route after late GET',
      (tester) async {
    var reads = 0;
    final pending = Completer<http.Response>();
    final session = await fixture(tester, (request) async {
      if (request.method == 'POST') return reply(workspace(newTenant), 201);
      if (request.url.path == '/api/v1/tenants') {
        return ++reads == 1
            ? reply({'code': 'READ_UNAVAILABLE'}, 503)
            : pending.future;
      }
      return reply({'role': 'OWNER'});
    });
    await mount(tester, session, centralDialog: true);
    await openWrite(tester);
    await submit(tester);
    await tester.tap(find.text('重试读取'));
    await tester.pump();
    await tester.tap(find.text('关闭'));
    await tester.pump();
    unawaited(showDialog<void>(
        context: tester.element(find.byType(WorkspaceWelcome)),
        builder: (_) => const AlertDialog(title: Text('新打开的窗口'))));
    await tester.pump();
    pending.complete(tenantList());
    await flushReads(tester);
    expect(find.text('新打开的窗口'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final openAnother in [false, true]) {
    testWidgets('recovery close owns its route: openAnother=$openAnother',
        (tester) async {
      final access = ValueNotifier(0);
      addTearDown(access.dispose);
      final navigation = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
          navigatorKey: navigation,
          theme: consoleTheme(),
          home: const Scaffold(body: Text('恢复测试首页'))));
      unawaited(navigation.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => Scaffold(
              body: Builder(
                  builder: (context) => Column(children: [
                        const Text('工作空间页面'),
                        TextButton(
                            onPressed: () => showWorkspaceReadRecoveryDialog(
                                context,
                                WorkspaceReadRecovery(
                                    completedMessage: '写入已完成',
                                    error: const ApiFailure(
                                        503, 'READ_UNAVAILABLE'),
                                    reload: () async {},
                                    isCurrent: () => true),
                                accessChanges: access,
                                onSignOut: () {},
                                onReauthenticate: () {}),
                            child: const Text('显示恢复窗口'))
                      ]))))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示恢复窗口'));
      await tester.pumpAndSettle();
      final close = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
          .onPressed!;
      final pageContext = tester.element(find.text('工作空间页面'));
      if (openAnother) {
        navigation.currentState!.pop();
        unawaited(showDialog<void>(
            context: pageContext,
            builder: (_) => const AlertDialog(title: Text('后续窗口'))));
      } else {
        close();
      }
      close();
      await tester.pumpAndSettle();
      expect(find.text(openAnother ? '后续窗口' : '工作空间页面'), findsOneWidget);
      expect(find.text('恢复测试首页'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(close, returnsNormally);
      expect(find.text(openAnother ? '后续窗口' : '工作空间页面'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
