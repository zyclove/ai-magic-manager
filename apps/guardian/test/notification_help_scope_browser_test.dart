@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/notifications.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/notifications_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/help_shortcut.dart';
import 'package:guardian/ui/notification_shortcut.dart';
import 'package:guardian/ui/notifications_view.dart';
import 'package:guardian/ui/shell.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'device_management_entry_test.dart' show EntrySession;
import 'workspace_recovery_browser_test.dart' as workspace;

const _a = '71111111-1111-4111-8111-111111111111';
const _b = '72222222-2222-4222-8222-222222222222';
const _noticeId = '73333333-3333-4333-8333-333333333333';
const _requestId = '74444444-4444-4444-8444-444444444444';
const _at = 1791504000000;

http.Response _reply(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

Json _notice({bool read = false}) => {
      'id': _noticeId,
      'requestId': _requestId,
      'subjectId': _requestId,
      'deviceId': _requestId,
      'requestVersion': 1,
      'state': 'APPROVED_PENDING_DELIVERY',
      'occurredAt': _at,
      'readAt': read ? _at : null,
    };

http.Response _page({bool read = false}) =>
    _reply({'items': [_notice(read: read)], 'nextCursor': null});
http.Response _count([int count = 1]) =>
    _reply({'count': count, 'capped': false});
http.Response _receipt() => _reply({'id': _noticeId, 'readAt': _at});

Matcher get _scopeLost => isA<ApiFailure>()
    .having((failure) => failure.code, 'code', 'WORKSPACE_CHANGED');
Matcher get _membershipFailed => isA<ApiFailure>()
    .having((failure) => failure.code, 'code', 'SELECTION_FAILED');

// Authentication initialization, SelectionGeneration, selectTenant, canOpen
// and scopeGeneration all remain production Session behavior. Only the HTTP
// transport, identity facts and initial workspace list are synthetic.
class _SelectionSession extends workspace.FixtureSession {
  _SelectionSession(super.handle);

  final listeners = <VoidCallback>{};
  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
    super.removeListener(listener);
  }

  void seedWorkspaces() {
    tenants = [
      {'id': _a, 'name': '空间A', 'kind': 'FAMILY'},
      {'id': _b, 'name': '空间B', 'kind': 'FAMILY'},
    ];
    tenant = tenants.first;
    role = 'OWNER';
    notifyListeners();
  }
}

Future<_SelectionSession> _session(WidgetTester tester,
    Future<http.Response> Function(http.Request) handle) async {
  final session = _SelectionSession(handle);
  await session.authenticate();
  session.seedWorkspaces();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await workspace.flushReads(tester);
    await session.release();
  });
  return session;
}

http.Response _normal(http.Request request, {bool read = false}) {
  final path = request.url.path;
  if (path.endsWith('/membership')) return _reply({'role': 'OWNER'});
  if (request.method == 'PUT' && path.endsWith('/$_noticeId/read')) {
    return _receipt();
  }
  if (path.endsWith('/notifications/unread-count')) return _count(read ? 0 : 1);
  if (path.endsWith('/help-requests/open-count')) return _count(3);
  if (path.endsWith('/notifications')) return _page(read: read);
  if (path.endsWith('/applications') || path.endsWith('/help-requests')) {
    return _reply({'items': [], 'nextCursor': null});
  }
  throw StateError('Unexpected fixture request: ${request.method} $path');
}

Widget _hosts(Session session,
        {Object identity = 'held',
        Future<void> Function(String)? onOpen,
        VoidCallback? onHelp}) =>
    MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: Column(children: [
          HelpShortcut(
              key: ValueKey(('help', identity)),
              session: session,
              onOpen: onHelp ?? () {}),
          NotificationsPage(
              key: ValueKey(('page', identity)),
              session: session,
              onOpen: onOpen ?? (_) async {}),
        ]))));

IconButton _helpButton(WidgetTester tester) => tester.widget<IconButton>(
    find.descendant(of: find.byType(HelpShortcut), matching: find.byType(IconButton)));
NotificationsView _view(WidgetTester tester) =>
    tester.widget<NotificationsView>(find.byType(NotificationsView));
VoidCallback _button(WidgetTester tester, String label) => tester
    .widget<OutlinedButton>(find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton)))
    .onPressed!;
ValueChanged<bool> _filter(WidgetTester tester) => tester
    .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '未读'))
    .onSelected!;

// Publicly named State methods are retained explicitly because the State type
// is private. This exercises the refresh guard even after observer removal.
Future<void> Function() _helpRefresh(WidgetTester tester) {
  final dynamic state = tester.state(find.byType(HelpShortcut));
  return state.refresh as Future<void> Function();
}

void main() {
  testWidgets('real selection invalidates late inbox GET and Help count before '
      'membership resolves, and failure cannot restore them', (tester) async {
    final membership = Completer<http.Response>();
    final inbox = Completer<http.Response>();
    final help = Completer<http.Response>();
    final session = await _session(tester, (request) async {
      final path = request.url.path;
      if (path == '/api/v1/tenants/$_b/membership') return membership.future;
      if (path.endsWith('/notifications')) return inbox.future;
      if (path.endsWith('/help-requests/open-count')) return help.future;
      return _normal(request);
    });
    addTearDown(() {
      if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
      if (!inbox.isCompleted) inbox.complete(_page());
      if (!help.isCompleted) help.complete(_count(7));
    });
    var opened = 0, helpOpened = 0;
    await tester.pumpWidget(_hosts(session,
        onOpen: (_) async { opened++; }, onHelp: () { helpOpened++; }));
    await workspace.flushReads(tester);
    final old = _view(tester).repository;
    final heldOpen = _view(tester).onOpen;
    final heldHelp = _helpButton(tester).onPressed!;
    final refreshHelp = _helpRefresh(tester);
    final generation = session.scopeGeneration;
    final root = session.root;

    final selecting = session.selectTenant(session.tenants.last);
    final rejected = expectLater(selecting, throwsA(_membershipFailed));
    // These facts must hold before the first pump or HTTP membership result.
    expect(session.scopeGeneration, generation + 1);
    expect(session.root, root);
    expect(session.tenant!['id'], _a);
    expect(session.role, 'OWNER');
    expect(old.current(), isFalse);
    await heldOpen(_requestId);
    heldHelp();
    await refreshHelp();
    await workspace.flushReads(tester);
    expect(find.byType(NotificationsView), findsNothing);
    expect(_helpButton(tester).onPressed, isNull);
    expect(find.text('已隐藏旧通知，请重新打开当前工作空间的通知中心。'), findsOneWidget);

    inbox.complete(_page());
    help.complete(_count(7));
    await workspace.flushReads(tester);
    membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
    await workspace.flushReads(tester);
    await rejected;
    expect(session.root, root);
    expect(session.role, 'OWNER');
    expect(old.current(), isFalse);
    final dispatched = session.requests.length;
    await expectLater(old.load(), throwsA(_scopeLost));
    await expectLater(old.markRead([_noticeId]), throwsA(_scopeLost));
    await heldOpen(_requestId);
    heldHelp();
    await refreshHelp();
    await tester.pump(const Duration(minutes: 1));
    await workspace.flushReads(tester);
    expect(session.requests, hasLength(dispatched));
    expect(opened, 0);
    expect(helpOpened, 0);
    expect(find.text('访问申请已批准'), findsNothing);
    expect(find.byTooltip('有 7 条儿童求助待查看'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final loss in ['real selection then failure', 'dispose']) {
    testWidgets('late markRead and retained actions stay inert after $loss',
        (tester) async {
      final membership = Completer<http.Response>();
      final receipt = Completer<http.Response>();
      var writes = 0, opened = 0, helpOpened = 0;
      final session = await _session(tester, (request) async {
        if (request.url.path == '/api/v1/tenants/$_b/membership') {
          return membership.future;
        }
        if (request.method == 'PUT') {
          writes++;
          return receipt.future;
        }
        return _normal(request);
      });
      addTearDown(() {
        if (!receipt.isCompleted) receipt.complete(_receipt());
        if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
      });
      await tester.pumpWidget(_hosts(session,
          onOpen: (_) async { opened++; }, onHelp: () { helpOpened++; }));
      await workspace.flushReads(tester);
      final old = _view(tester).repository;
      final refresh = _button(tester, '刷新通知');
      final filter = _filter(tester);
      final open = _button(tester, '查看当前申请');
      final directOpen = _view(tester).onOpen;
      final help = _helpButton(tester).onPressed!;
      final refreshHelp = _helpRefresh(tester);
      open();
      await workspace.flushReads(tester);
      expect(writes, 1);

      Future<void>? rejected;
      if (loss == 'dispose') {
        await tester.pumpWidget(const SizedBox.shrink());
        expect(session.listeners, isEmpty,
            reason: 'Both host scopes must remove their Session listeners.');
      } else {
        final generation = session.scopeGeneration;
        final selecting = session.selectTenant(session.tenants.last);
        rejected = expectLater(selecting, throwsA(_membershipFailed));
        expect(session.scopeGeneration, generation + 1);
        expect(session.tenant!['id'], _a);
        expect(session.role, 'OWNER');
      }
      expect(old.current(), isFalse);
      receipt.complete(_receipt());
      await workspace.flushReads(tester);
      if (rejected != null) {
        membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
        await workspace.flushReads(tester);
        await rejected;
      }
      final dispatched = session.requests.length;
      refresh();
      filter(true);
      open();
      await directOpen(_requestId);
      help();
      await refreshHelp();
      await tester.pump(const Duration(minutes: 1));
      await workspace.flushReads(tester);
      expect(session.requests, hasLength(dispatched));
      expect(writes, 1);
      expect(opened, 0);
      expect(helpOpened, 0);
      expect(find.textContaining('已将 1 条通知标为已读'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a fresh repository can read while the old read is pending; '
      'retained View callbacks and old completion keep their owner', (tester) async {
    final oldReceipt = Completer<http.Response>();
    final freshReceipt = Completer<http.Response>();
    var read = false;
    final session = await _session(tester, (request) async {
      if (request.method == 'PUT') {
        if (request.url.path.startsWith('/api/v1/tenants/$_a/')) {
          return oldReceipt.future;
        }
        read = true;
        return freshReceipt.future;
      }
      return _normal(request,
          read: read && request.url.path.startsWith('/api/v1/tenants/$_b/'));
    });
    addTearDown(() {
      if (!oldReceipt.isCompleted) oldReceipt.complete(_receipt());
      if (!freshReceipt.isCompleted) freshReceipt.complete(_receipt());
    });
    final old = const ConsoleShell(section: 'applications')
        .notificationRepository(session);
    final opened = <String>[];
    Widget viewHost(NotificationRepository repository) => MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(body: SingleChildScrollView(child: NotificationsView(
            key: const ValueKey('same-view-state'),
            repository: repository,
            onOpen: (id) async { opened.add(id); }))));
    await tester.pumpWidget(viewHost(old));
    await workspace.flushReads(tester);
    final refresh = _button(tester, '刷新通知');
    final filter = _filter(tester);
    final open = _button(tester, '查看当前申请');
    open();
    await workspace.flushReads(tester);
    expect(session.requests.where((r) => r.method == 'PUT'), hasLength(1));
    final selecting = session.selectTenant(session.tenants.last);
    await workspace.flushReads(tester);
    await selecting;
    final fresh = const ConsoleShell(section: 'applications')
        .notificationRepository(session);
    await tester.pumpWidget(viewHost(fresh));
    await workspace.flushReads(tester);
    final dispatched = session.requests.length;
    refresh();
    filter(true);
    open();
    await workspace.flushReads(tester);
    expect(session.requests, hasLength(dispatched));
    expect(opened, isEmpty);
    expect(tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '未读')).selected, isFalse);
    final freshOpen = _button(tester, '查看当前申请');
    final freshRefresh = _button(tester, '刷新通知');
    freshOpen();
    await workspace.flushReads(tester);
    expect(session.requests.where((r) => r.method == 'PUT').map((r) => r.path), [
      '/api/v1/tenants/$_a/notifications/$_noticeId/read',
      '/api/v1/tenants/$_b/notifications/$_noticeId/read',
    ], reason: 'The new journey must not wait for the old read future.');
    oldReceipt.complete(_receipt());
    await workspace.flushReads(tester);
    expect(opened, isEmpty);
    // A retained refresh can finish while B's read remains pending. With busy
    // false again, only B's operation ownership prevents the held open action
    // from dispatching a duplicate after A's finally block has run.
    freshRefresh();
    await workspace.flushReads(tester);
    freshOpen();
    await workspace.flushReads(tester);
    expect(session.requests.where((r) => r.method == 'PUT'), hasLength(2));
    freshReceipt.complete(_receipt());
    await workspace.flushReads(tester);
    expect(opened, isEmpty,
        reason: 'The retained refresh superseded that read generation.');
    _button(tester, '查看当前申请')();
    await workspace.flushReads(tester);
    expect(opened, [_requestId]);
    expect(find.text('0 条未读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixed host keys fail closed when Session instance changes; '
      'fresh host keys attach and dispose listeners correctly', (tester) async {
    final first = await _session(tester, (request) async => _normal(request));
    final second = await _session(tester, (request) async => _normal(request));
    var opened = 0;
    await tester.pumpWidget(_hosts(first, onHelp: () { opened++; }));
    await workspace.flushReads(tester);
    final old = _view(tester).repository;
    final open = _view(tester).onOpen;
    final help = _helpButton(tester).onPressed!;
    final refreshHelp = _helpRefresh(tester);
    expect(first.listeners, hasLength(2));
    await tester.pumpWidget(_hosts(second, onHelp: () { opened++; }));
    await workspace.flushReads(tester);
    expect(old.current(), isFalse);
    expect(find.byType(NotificationsView), findsNothing);
    expect(_helpButton(tester).onPressed, isNull);
    expect(second.requests, isEmpty,
        reason: 'A retained host must not silently bind its old journey to a new Session.');
    final dispatched = first.requests.length;
    await open(_requestId);
    help();
    await refreshHelp();
    expect(first.requests, hasLength(dispatched));
    expect(opened, 0);
    await tester.pumpWidget(_hosts(second, identity: 'fresh'));
    await workspace.flushReads(tester);
    expect(first.listeners, isEmpty);
    expect(second.listeners, hasLength(2));
    expect(find.byType(NotificationsView), findsOneWidget);
    expect(_helpButton(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(second.listeners, isEmpty);
    await refreshHelp();
    expect(tester.takeException(), isNull);
  });

  testWidgets('fresh shell entries navigate, read and open current approval '
      'after real successful workspace selection', (tester) async {
    final membership = Completer<http.Response>();
    var read = false;
    final session = await _session(tester, (request) async {
      final path = request.url.path;
      if (path == '/api/v1/tenants/$_b/membership') return membership.future;
      if (path.endsWith('/access-requests/$_requestId')) {
        return _reply({
          'id': _requestId, 'state': 'APPROVED_PENDING_DELIVERY',
          'requestedWindowSeconds': 60, 'reason': '合成申请',
          'requestExpiresAt': 2000000000000, 'deviceId': _requestId,
          'subjectId': _requestId, 'absoluteNotAfter': null,
          'executionState': 'NOT_ENFORCED', 'version': 1,
        });
      }
      if (path.endsWith('/access-requests/$_requestId/delivery')) {
        return _reply({
          'approvalVersion': 1, 'action': 'CONFIGURE_ONLY',
          'deliveryState': 'NOT_ISSUED', 'deliveryAttempt': null,
          'receivedAt': null,
        });
      }
      if (request.method == 'PUT') read = true;
      return _normal(request, read: read);
    });
    final router = GoRouter(
        initialLocation: '/applications',
        overridePlatformDefaultLocation: true,
        routes: [
          GoRoute(path: '/:section', builder: (_, state) =>
              ConsoleShell(section: state.pathParameters['section']!)),
        ]);
    addTearDown(() async {
      if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    });
    await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
        value: session, child: MaterialApp.router(
            theme: consoleTheme(), routerConfig: router)));
    await workspace.flushReads(tester);
    final shortcut = tester.widget<NotificationShortcut>(find.byType(NotificationShortcut));
    final oldRepo = shortcut.repository;
    final oldNotificationOpen = shortcut.onOpen;
    final oldHelpOpen = _helpButton(tester).onPressed!;
    final selecting = session.selectTenant(session.tenants.last);
    expect(oldRepo.current(), isFalse);
    oldNotificationOpen();
    oldHelpOpen();
    await workspace.flushReads(tester);
    expect(router.routeInformationProvider.value.uri.path, '/applications');
    membership.complete(_reply({'role': 'OWNER'}));
    await workspace.flushReads(tester);
    await selecting;
    expect(session.tenant!['id'], _b);
    oldNotificationOpen();
    oldHelpOpen();
    await workspace.flushReads(tester);
    expect(router.routeInformationProvider.value.uri.path, '/applications');
    tester.widget<NotificationShortcut>(find.byType(NotificationShortcut)).onOpen();
    await workspace.flushReads(tester);
    expect(router.routeInformationProvider.value.uri.path, '/notifications');
    expect(_view(tester).repository.root, '/tenants/$_b');
    _button(tester, '查看当前申请')();
    await workspace.flushReads(tester);
    expect(find.text('临时访问申请'), findsOneWidget);
    expect(session.requests.where((r) => r.method == 'PUT').map((r) => r.path),
        ['/api/v1/tenants/$_b/notifications/$_noticeId/read']);
    expect(session.requests.where((r) => r.path.endsWith('/access-requests/$_requestId'))
        .map((r) => r.path), ['/api/v1/tenants/$_b/access-requests/$_requestId']);
    // Close the actual detail route so View.read can complete its fresh reload.
    await tester.tap(find.text('关闭').last);
    await workspace.flushReads(tester);
    expect(find.text('0 条未读'), findsOneWidget);
    _helpButton(tester).onPressed!();
    await workspace.flushReads(tester);
    expect(router.routeInformationProvider.value.uri.path, '/help-requests');
    expect(tester.takeException(), isNull);
  });

  // Optional synthetic boundary: real authentication/selection never mutate an
  // actor while preserving generation. This proves the existing scope's sticky
  // listener behavior for an observed A -> B -> A between Flutter frames only.
  testWidgets('SYNTHETIC optional actor ABA never revives held host scopes',
      (tester) async {
    final session = _SyntheticActorSession((request) async => _normal(request));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      session.transport.close();
      session.dispose();
    });
    var opened = 0;
    await tester.pumpWidget(_hosts(session,
        onOpen: (_) async { opened++; }, onHelp: () { opened++; }));
    await workspace.flushReads(tester);
    final old = _view(tester).repository;
    final open = _view(tester).onOpen;
    final help = _helpButton(tester).onPressed!;
    final generation = session.scopeGeneration;
    session.actor('adult-b');
    session.actor('adult-a');
    expect(session.scopeGeneration, generation);
    expect(old.current(), isFalse);
    await open(_requestId);
    help();
    await workspace.flushReads(tester);
    expect(find.byType(NotificationsView), findsNothing);
    expect(_helpButton(tester).onPressed, isNull);
    expect(opened, 0);
    expect(tester.takeException(), isNull);
  });
}

class _SyntheticActorSession extends EntrySession {
  _SyntheticActorSession(super.handler);
  void actor(String value) {
    profile = {...profile!, 'subject': value};
    notifyListeners();
  }
}
