@TestOn('browser')
library;

import 'dart:convert';
// Synthetic session storage belongs only to the isolated browser-test origin.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/family_identity_page.dart';
import 'package:guardian/ui/shell.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oauth2/oauth2.dart' as oauth;
import 'package:provider/provider.dart';
import 'family_identity_configuration_test.dart' show identityStatusFixture;
import 'family_identity_release_fixtures.dart' show releaseStatusFixture;
import 'family_identity_acceptance_test.dart'
    show identityAcceptanceStatusFixture;

class _ProviderSession extends Session {
  final bool read, owner, mfa;
  final requests = <http.Request>[];
  final savedCredential = html.window.sessionStorage['ai-manager.session'];
  final savedWorkspace = html.window.localStorage['ai-manager.workspace'];
  late final MockClient transport;
  late final Api fixtureApi;
  int stepUps = 0;
  _ProviderSession({this.read = true, this.owner = false, this.mfa = false}) {
    transport = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      Object value;
      int status = 200;
      if (request.method != 'GET') {
        throw StateError('Opening the fixture must not mutate.');
      }
      if (path == '/api/v1/me') {
        value = {
          'subject': 'synthetic-provider-$read-$owner-$mfa',
          'name': '合成运营账号',
          'canReadIdentityProviders': read,
          'canManageIdentityProviders': false,
          'canTestIdentityProviders': false,
          'canCreateTenant': false
        };
      } else if (path == '/api/v1/tenants') {
        value = {
          'items': owner
              ? [
                  {
                    'id': '33333333-3333-4333-8333-333333333333',
                    'name': '合成家庭',
                    'kind': 'FAMILY'
                  }
                ]
              : [],
          'nextCursor': null
        };
      } else if (path.endsWith('/membership')) {
        value = {'role': 'OWNER'};
      } else if (path.endsWith('/unread-count') ||
          path.endsWith('/open-count')) {
        value = {'count': 0, 'capped': false};
      } else if (path == '/api/v1/platform/identity-providers/status') {
        value = mfa
            ? {'errorCode': 'REAUTH_REQUIRED'}
            : identityStatusFixture(manage: false, test: false);
        status = mfa ? 401 : 200;
      } else if (path == '/api/v1/platform/identity-providers/release-status') {
        value = releaseStatusFixture();
      } else if (path ==
          '/api/v1/platform/identity-providers/acceptance-status') {
        value =
            identityAcceptanceStatusFixture(nextAction: 'CHECK_CONFIGURATION')
              ..addAll({'confirmedOperationId': null, 'runtimeRevision': 0});
      } else {
        throw StateError('Unexpected synthetic request.');
      }
      return http.Response(jsonEncode(value), status,
          headers: {'content-type': 'application/json'});
    });
    fixtureApi =
        Api(authenticatedClient, baseUrl: 'https://fixture.invalid/api/v1');
  }
  @override
  Api get api => fixtureApi;
  @override
  Future<http.Client> authenticatedClient() async => transport;
  @override
  void login({bool stepUp = false}) {
    if (stepUp) stepUps++;
  }

  Future<void> authenticate() async {
    html.window.sessionStorage['ai-manager.session'] = oauth.Credentials(
            'SYNTHETIC_PROVIDER_TOKEN',
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

Future<void> _flush(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<GoRouter> _mount(WidgetTester tester, _ProviderSession session,
    {String path = '/identity-providers'}) async {
  await session.authenticate();
  final router = GoRouter(
      initialLocation: path,
      overridePlatformDefaultLocation: true,
      routes: [
        GoRoute(
            path: '/:section',
            builder: (_, state) =>
                ConsoleShell(section: state.pathParameters['section']!))
      ]);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await session.release();
  });
  await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
      value: session,
      child: MaterialApp.router(theme: consoleTheme(), routerConfig: router)));
  await _flush(tester);
  return router;
}

void main() {
  testWidgets(
      'platform reader without a tenant reaches the real welcome and page entry',
      (tester) async {
    final session = _ProviderSession();
    final router = await _mount(tester, session, path: '/overview');
    expect(session.tenant, isNull);
    final entry = find.text('短信与微信');
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await _flush(tester);
    expect(
        router.routeInformationProvider.value.uri.path, '/identity-providers');
    expect(find.byType(IdentityProvidersPage), findsOneWidget);
    expect(find.text('真实联调验收 · 0/12'), findsOneWidget);
    expect(find.text('2 · 手机完成'), findsOneWidget);
    expect(find.text('收费开放检查'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(
        session.requests.where((request) =>
            request.url.path == '/api/v1/platform/identity-providers/status'),
        hasLength(1));
    expect(
        session.requests.every((request) => request.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'family ownership does not grant platform configuration or dispatch reads',
      (tester) async {
    final session = _ProviderSession(read: false, owner: true);
    await _mount(tester, session);
    expect(session.role, 'OWNER');
    expect(session.canOpen('identity-providers'), isFalse);
    expect(find.text('没有短信与微信配置权限'), findsOneWidget);
    expect(
        session.requests.where((request) =>
            request.url.path.contains('/platform/identity-providers')),
        isEmpty);
  });
  testWidgets(
      'MFA required shows one safe authentication action without replay',
      (tester) async {
    final session = _ProviderSession(mfa: true);
    await _mount(tester, session);
    final verify = find.widgetWithText(FilledButton, '重新安全验证');
    expect(verify, findsOneWidget);
    await tester.tap(verify);
    await _flush(tester);
    expect(session.stepUps, 1);
    expect(
        session.requests.every((request) => request.method == 'GET'), isTrue);
  });
}
