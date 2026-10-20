@TestOn('browser')
library;

import 'dart:convert';
// Storage belongs only to the isolated browser-test origin.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/ui/console_navigation.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/family_finance_page.dart';
import 'package:guardian/ui/shell.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oauth2/oauth2.dart' as oauth;
import 'package:provider/provider.dart';

const _familyId = '71111111-1111-4111-8111-111111111111';
const _refundPath = '/api/v1/platform/family-subscription/refund-requests';
const _billPath = '/api/v1/platform/family-subscription/reconciliation/tasks';

http.Response _reply(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

/// Uses the real Session initialization and access policy. Identity and HTTP
/// facts are synthetic; no identity-provider, merchant or live API is called.
class _EntrySession extends Session {
  final bool review, finance, familyOwner;
  final requests = <http.Request>[];
  final savedCredential = html.window.sessionStorage['ai-manager.session'];
  final savedWorkspace = html.window.localStorage['ai-manager.workspace'];
  late final MockClient transport;
  late final Api fixtureApi;

  _EntrySession(
      {this.review = false, this.finance = false, this.familyOwner = false}) {
    transport = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (request.method != 'GET') {
        throw StateError('Opening this entry must never perform a mutation.');
      }
      if (path == '/api/v1/me') {
        return _reply({
          'subject': 'synthetic-entry-$review-$finance-$familyOwner',
          'name': '合成测试账号',
          'canCreateTenant': false,
          'canReviewFamilyRefunds': review,
          'canManageFamilyFinance': finance
        });
      }
      if (path == '/api/v1/tenants') {
        return _reply({
          'items': [
            if (familyOwner) {'id': _familyId, 'name': '合成家庭', 'kind': 'FAMILY'}
          ],
          'nextCursor': null
        });
      }
      if (path == '/api/v1/tenants/$_familyId/membership') {
        return _reply({'role': 'OWNER'});
      }
      if (path == _refundPath && review || path == _billPath && finance) {
        return _reply({'items': [], 'nextCursor': null});
      }
      if (familyOwner &&
          (path == '/api/v1/tenants/$_familyId/notifications/unread-count' ||
              path == '/api/v1/tenants/$_familyId/help-requests/open-count')) {
        return _reply({'count': 0, 'capped': false});
      }
      throw StateError('Unexpected entry request: $path');
    });
    fixtureApi =
        Api(authenticatedClient, baseUrl: 'https://fixture.invalid/api/v1');
  }

  @override
  Api get api => fixtureApi;
  @override
  Future<http.Client> authenticatedClient() async => transport;

  Future<void> authenticate() async {
    html.window.sessionStorage['ai-manager.session'] = oauth.Credentials(
            'SYNTHETIC_ENTRY_TOKEN',
            expiration: DateTime.now().add(const Duration(hours: 1)))
        .toJson();
    await initialize();
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

// Real HTTP stream futures must be drained outside the fake widget clock.
Future<void> _flushReads(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<GoRouter> _mount(WidgetTester tester, _EntrySession session,
    {String path = '/family-finance'}) async {
  GoRouter? router;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router?.dispose();
    await session.release();
  });
  await session.authenticate();
  expect(session.authenticated, isTrue);
  final configuration = GoRouter(
      initialLocation: path,
      overridePlatformDefaultLocation: true,
      routes: [
        GoRoute(
            path: '/:section',
            builder: (_, state) =>
                ConsoleShell(section: state.pathParameters['section']!))
      ]);
  router = configuration;
  await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
      value: session,
      child: MaterialApp.router(
          theme: consoleTheme(), routerConfig: configuration)));
  await _flushReads(tester);
  return configuration;
}

void main() {
  testWidgets(
      'review operator without a tenant enters through the real console welcome',
      (tester) async {
    final session = _EntrySession(review: true);
    final router = await _mount(tester, session, path: '/overview');
    expect(session.tenant, isNull);
    expect(session.canOpen('family-finance'), isTrue);
    expect(find.byType(FamilyFinancePage), findsNothing);
    final entry = find.text('家庭售后与对账');
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await _flushReads(tester);
    expect(router.routeInformationProvider.value.uri.path, '/family-finance');
    expect(find.byType(ConsoleShell), findsOneWidget);
    expect(find.byType(FamilyFinancePage), findsOneWidget);
    expect(find.text('家庭订阅售后'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '退款售后'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '日账单'), findsNothing);
    expect(
        session.requests.where((r) => r.url.path == _refundPath), hasLength(1));
    expect(session.requests.where((r) => r.url.path == _billPath), isEmpty);
    expect(session.requests.every((r) => r.method == 'GET'), isTrue);
    // ConsoleShell supplies the actual outer SingleChildScrollView, which
    // previously caused the finance page's viewport to have unbounded height.
    expect(tester.takeException(), isNull);
  });

  testWidgets('finance-only operator reads bills without any tenant membership',
      (tester) async {
    final session = _EntrySession(finance: true);
    await _mount(tester, session);
    expect(session.tenant, isNull);
    expect(find.byType(FamilyFinancePage), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '日账单'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '退款售后'), findsNothing);
    expect(
        session.requests.where((r) => r.url.path == _billPath), hasLength(1));
    expect(session.requests.where((r) => r.url.path == _refundPath), isEmpty);
    expect(session.requests.every((r) => r.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('family owner cannot open or request platform after-sales data',
      (tester) async {
    final session = _EntrySession(familyOwner: true);
    await _mount(tester, session);
    expect(session.tenant?['id'], _familyId);
    expect(session.role, 'OWNER');
    expect(session.canOpen('family-finance'), isFalse);
    expect(find.byType(FamilyFinancePage), findsNothing);
    expect(find.text('没有家庭售后权限'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(ConsoleNavigation), matching: find.text('家庭售后与对账')),
        findsNothing);
    expect(
        session.requests.where((r) =>
            r.url.path.startsWith('/api/v1/platform/family-subscription/')),
        isEmpty);
    expect(session.requests.every((r) => r.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
  });
}
