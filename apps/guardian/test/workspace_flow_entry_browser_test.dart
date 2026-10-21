@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/audit_exports_page.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/ui/audit_exports_view.dart';
import 'package:guardian/ui/audit_view.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/shell.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'device_management_entry_test.dart' show EntrySession, settleReads;
import 'managed_enrollment_page_test.dart' as enrollment;
import 'workspace_recovery_browser_test.dart' as workspace;

const _a = '71111111-1111-4111-8111-111111111111';
const _b = '72222222-2222-4222-8222-222222222222';
const _c = '73333333-3333-4333-8333-333333333333';

http.Response _reply(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

http.Response _emptyPage() => _reply({'items': [], 'nextCursor': null});

Matcher get _scopeLost => isA<ApiFailure>()
    .having((error) => error.code, 'code', 'WORKSPACE_CHANGED');

Future<void> _console(
    WidgetTester tester, Session session, String section) async {
  await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
      value: session,
      child: MaterialApp(
          theme: consoleTheme(),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: ConsolePages(section: section))))));
  await settleReads(tester);
}

Widget _exports(Session session) => MaterialApp(
    theme: consoleTheme(),
    home: Scaffold(
        body: SingleChildScrollView(
            child: AuditExportsPage(
                key: const ValueKey('held-export-page'), session: session))));

// Keep real Session initialization, selectTenant and SelectionGeneration.
// Only identity/HTTP facts and the starting workspace are synthetic.
class _SelectionSession extends workspace.FixtureSession {
  _SelectionSession(super.handle);

  void seedWorkspaces() {
    tenants = [
      {'id': _a, 'name': '空间A', 'kind': 'FAMILY'},
      {'id': _b, 'name': '空间B', 'kind': 'FAMILY'},
      {'id': _c, 'name': '空间C', 'kind': 'FAMILY'},
    ];
    tenant = tenants.first;
    role = 'OWNER';
    notifyListeners();
  }
}

http.Response _shellRead(http.Request request) {
  if (request.url.path.endsWith('/unread-count') ||
      request.url.path.endsWith('/open-count')) {
    return _reply({'count': 0, 'capped': false});
  }
  if (request.url.path.endsWith('/applications')) return _emptyPage();
  throw StateError('Unexpected shell read: ${request.url.path}');
}

Future<GoRouter> _shell(
    WidgetTester tester, _SelectionSession session) async {
  await session.authenticate();
  session.seedWorkspaces();
  final router = GoRouter(
      initialLocation: '/applications',
      overridePlatformDefaultLocation: true,
      routes: [
        GoRoute(
            path: '/',
            builder: (_, __) =>
                const Scaffold(body: Text('当前空间首页'))),
        GoRoute(
            path: '/:section',
            builder: (_, state) =>
                ConsoleShell(section: state.pathParameters['section']!)),
      ]);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await session.release();
  });
  await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
      value: session,
      child: MaterialApp.router(
          theme: consoleTheme(), routerConfig: router)));
  await workspace.flushReads(tester);
  return router;
}

void _select(WidgetTester tester, String id) {
  // Invoke the real picker callback so same-value selection reaches the guard,
  // independently of whether DropdownButton itself filters identical values.
  tester
      .widget<DropdownButton<String>>(
          find.byType(DropdownButton<String>).first)
      .onChanged!(id);
}

void main() {
  testWidgets('audit entry recreates a readable page for a new scope generation',
      (tester) async {
    var reads = 0;
    final session = EntrySession((request) async {
      expect(request.url.path.endsWith('/audit-events/search'), isTrue);
      reads++;
      return _emptyPage();
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      session.transport.close();
      session.dispose();
    });
    await _console(tester, session, 'audit');
    expect(find.byType(AuditView), findsOneWidget);
    expect(reads, 1);

    // Actor, tenant and role stay unchanged: only the real page's key must change.
    session.changed();
    await settleReads(tester);
    expect(find.byType(AuditView), findsOneWidget);
    expect(reads, 2, reason: 'The fresh journey must make its own first read.');
    expect(find.text('已隐藏旧记录，请重新打开当前工作空间的审计日志。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('managed entry reloads and enables refresh after generation change',
      (tester) async {
    final session = enrollment.EnrollmentSession();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      session.transport.close();
      session.dispose();
    });
    await _console(tester, session, 'managed-android');
    expect(session.requests.where((r) => r.url.path.endsWith('/readiness')),
        hasLength(1));
    session.invalidate();
    await settleReads(tester);
    expect(session.requests.where((r) => r.url.path.endsWith('/readiness')),
        hasLength(2));
    final refresh = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '刷新状态'));
    expect(refresh.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final loss in ['actor ABA', 'generation', 'dispose']) {
    testWidgets('export old repository rejects late data after $loss',
        (tester) async {
      final late = Completer<http.Response>();
      var reads = 0;
      final session = EntrySession((request) async {
        expect(request.url.path.endsWith('/audit-exports'), isTrue);
        return ++reads == 1 ? _emptyPage() : late.future;
      });
      addTearDown(() async {
        if (!late.isCompleted) late.complete(_emptyPage());
        await tester.pumpWidget(const SizedBox.shrink());
        session.transport.close();
        session.dispose();
      });
      await tester.pumpWidget(_exports(session));
      await settleReads(tester);
      final original = tester
          .widget<AuditExportsView>(find.byType(AuditExportsView))
          .repository;
      final response = original.load();
      final rejected = expectLater(response, throwsA(_scopeLost));
      await settleReads(tester);
      expect(reads, 2);

      if (loss == 'dispose') {
        await tester.pumpWidget(const SizedBox.shrink());
      } else if (loss == 'actor ABA') {
        final actor = session.profile!['subject'];
        session.profile = {...session.profile!, 'subject': 'adult-b'};
        session.changed();
        session.profile = {...session.profile!, 'subject': actor};
        session.changed();
      } else {
        session.changed();
      }
      late.complete(_emptyPage());
      await settleReads(tester);
      await rejected;
      expect(original.current(), isFalse);
      await expectLater(original.load(), throwsA(_scopeLost));
      expect(reads, 2, reason: 'An old repository must never dispatch again.');
      expect(find.byType(AuditExportsView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('workspace picker ignores its already selected tenant',
      (tester) async {
    final session = _SelectionSession((request) async => _shellRead(request));
    final router = await _shell(tester, session);
    final generation = session.scopeGeneration;
    _select(tester, _a);
    await workspace.flushReads(tester);
    expect(session.scopeGeneration, generation);
    expect(session.requests.where((r) => r.path.endsWith('/membership')), isEmpty);
    expect(router.routeInformationProvider.value.uri.path, '/applications');
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('superseded workspace return cannot navigate or toast '
      'after newest selection fails', (tester) async {
      final b = Completer<http.Response>(), c = Completer<http.Response>();
      final session = _SelectionSession((request) async {
        if (request.url.path == '/api/v1/tenants/$_b/membership') return b.future;
        if (request.url.path == '/api/v1/tenants/$_c/membership') return c.future;
        return _shellRead(request);
      });
      final router = await _shell(tester, session);
      addTearDown(() {
        if (!b.isCompleted) b.complete(_reply({'role': 'OWNER'}));
        if (!c.isCompleted) c.complete(_reply({'role': 'OWNER'}));
      });
      _select(tester, _b);
      await workspace.flushReads(tester);
      _select(tester, _c);
      await workspace.flushReads(tester);
      expect(session.requests.where((r) => r.path.endsWith('/membership'))
          .map((r) => r.path), [
        '/api/v1/tenants/$_b/membership',
        '/api/v1/tenants/$_c/membership',
      ]);
      c.complete(_reply({'errorCode': 'CURRENT_SELECTION_FAILED'}, 503));
      await workspace.flushReads(tester);
      expect(session.tenant!['id'], _a);
      expect(router.routeInformationProvider.value.uri.path, '/applications');
      expect(find.byType(SnackBar), findsOneWidget,
          reason: 'The newest selection failure must remain visible.');
      ScaffoldMessenger.of(tester.element(find.byType(ConsoleShell)))
          .clearSnackBars();
      await tester.pump(const Duration(milliseconds: 500));

      b.complete(_reply({'role': 'OWNER'}));
      await workspace.flushReads(tester);
      expect(session.tenant!['id'], _a);
      expect(router.routeInformationProvider.value.uri.path, '/applications');
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('当前空间首页'), findsNothing);
      expect(tester.takeException(), isNull);
  });

  testWidgets('newest successful workspace selection returns home',
      (tester) async {
    final pending = Completer<http.Response>();
    final session = _SelectionSession((request) async {
      if (request.url.path == '/api/v1/tenants/$_b/membership') {
        return pending.future;
      }
      return _shellRead(request);
    });
    final router = await _shell(tester, session);
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(_reply({'role': 'OWNER'}));
    });
    _select(tester, _b);
    await workspace.flushReads(tester);
    expect(router.routeInformationProvider.value.uri.path, '/applications');
    pending.complete(_reply({'role': 'OWNER'}));
    await workspace.flushReads(tester);
    expect(session.tenant!['id'], _b);
    expect(router.routeInformationProvider.value.uri.path, '/');
    expect(find.text('当前空间首页'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
