import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/family_identity_page.dart';
import 'family_identity_configuration_test.dart';
import 'family_identity_repository_test.dart' show identityReply;
import 'family_identity_release_fixtures.dart' show releaseStatusFixture;
import 'family_identity_release_fixtures.dart' show releaseOperationFixture;
import 'family_identity_acceptance_test.dart'
    show identityAcceptanceStatusFixture;

Future<void> _flushIdentityPage(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'closing current acceptance confirmation completes its exit animation',
      (tester) async {
    final changes = ChangeNotifier();
    final requests = <http.Request>[];
    final api = Api(
        () async => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/acceptance-status')) {
                return identityReply(identityAcceptanceStatusFixture());
              }
              return identityReply(request.url.path.endsWith('/release-status')
                  ? (releaseStatusFixture(
                      confirmed:
                          releaseOperationFixture(state: 'APPLIED_CLOSED'))
                    ..['runtimeRevision'] = 2)
                  : identityStatusFixture());
            }),
        baseUrl: 'https://fixture.invalid');
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: IdentityProvidersPage(
                    api: api,
                    actor: 'operator',
                    canRead: true,
                    canManage: true,
                    canTest: true,
                    changes: changes,
                    isCurrent: () => true,
                    reauthenticate: () {})))));
    await _flushIdentityPage(tester);
    final setup = find.text('建立本次验收');
    await tester.ensureVisible(setup);
    await tester.tap(setup);
    await tester.pumpAndSettle();
    expect(find.text('建立本次验收'), findsNWidgets(2));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    changes.dispose();
  });
  testWidgets(
      'blocked release preparation cannot advance the page to real acceptance',
      (tester) async {
    final changes = ChangeNotifier();
    final api = Api(
        () async => MockClient((request) async {
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(releaseStatusFixture());
              }
              if (request.url.path.endsWith('/acceptance-status')) {
                return identityReply(identityAcceptanceStatusFixture(
                    nextAction: 'CHECK_CONFIGURATION')
                  ..addAll(
                      {'confirmedOperationId': null, 'runtimeRevision': 0}));
              }
              if (request.method == 'GET' &&
                  request.url.path.endsWith('/status')) {
                return identityReply(identityStatusFixture());
              }
              if (request.url.path.endsWith('/validations')) {
                return identityReply({
                  'versionId': identityVersionId,
                  'readinessStatus': 'READY',
                  'checks': [],
                  'runtimeStatus': 'APPLY_REQUIRED',
                  'salesAllowed': false
                });
              }
              if (request.url.path.endsWith('/release-preparations')) {
                return identityReply({
                  'id': jsonDecode(request.body)['id'],
                  'versionId': identityVersionId,
                  'status': 'BLOCKED',
                  'reasonCode': 'RELEASE_NOT_READY',
                  'runtimeStatus': 'APPLY_REQUIRED',
                  'salesAllowed': false
                });
              }
              return identityReply({'errorCode': 'IDENTITY_PROVIDER_NOT_FOUND'},
                  status: 404);
            }),
        baseUrl: 'https://fixture.invalid');
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: IdentityProvidersPage(
                    api: api,
                    actor: 'operator',
                    canRead: true,
                    canManage: true,
                    canTest: true,
                    changes: changes,
                    isCurrent: () => true,
                    reauthenticate: () {})))));
    Future<void> flush() async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
    }

    await flush();
    final validate = find.widgetWithText(FilledButton, '检查当前配置');
    await tester.ensureVisible(validate);
    await tester.tap(validate);
    await flush();
    final prepare = find.widgetWithText(FilledButton, '准备受控发布');
    await tester.ensureVisible(prepare);
    await tester.tap(prepare);
    await flush();
    expect(find.text('继续真实联调'), findsNothing);
    expect(find.widgetWithText(FilledButton, '准备受控发布'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    changes.dispose();
  });
  testWidgets(
      'simple status shows separate providers and never represents configured as real acceptance',
      (tester) async {
    final changes = ChangeNotifier(), requests = <http.Request>[];
    final api = Api(
        () async => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(releaseStatusFixture());
              }
              if (request.url.path.endsWith('/acceptance-status')) {
                return identityReply(identityAcceptanceStatusFixture(
                    nextAction: 'CHECK_CONFIGURATION')
                  ..addAll(
                      {'confirmedOperationId': null, 'runtimeRevision': 0}));
              }
              if (request.url.path != '/platform/identity-providers/status') {
                return identityReply(
                    {'errorCode': 'IDENTITY_PROVIDER_NOT_FOUND'},
                    status: 404);
              }
              return identityReply(identityStatusFixture());
            }),
        baseUrl: 'https://fixture.invalid');
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: IdentityProvidersPage(
                    api: api,
                    actor: 'operator',
                    canRead: true,
                    canManage: true,
                    canTest: true,
                    changes: changes,
                    isCurrent: () => true,
                    reauthenticate: () {})))));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
    expect(find.text('短信服务'), findsOneWidget);
    expect(find.text('微信登录'), findsOneWidget);
    expect(find.text('检查当前配置'), findsOneWidget);
    expect(find.text('真实联调验收 · 0/12'), findsOneWidget);
    expect(find.textContaining('短信正常'), findsNothing);
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    changes.dispose();
  });
  testWidgets(
      'narrow large-text page and fixed acceptance checklist do not overflow',
      (tester) async {
    final changes = ChangeNotifier();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = Api(
        () async => MockClient((request) async {
              if (request.url.path.endsWith('/acceptance-status')) {
                return identityReply(identityAcceptanceStatusFixture(
                    nextAction: 'CHECK_CONFIGURATION')
                  ..addAll(
                      {'confirmedOperationId': null, 'runtimeRevision': 0}));
              }
              return request.url.path.endsWith('/release-status')
                  ? identityReply(releaseStatusFixture())
                  : request.url.path == '/platform/identity-providers/status'
                      ? identityReply(identityStatusFixture())
                      : identityReply(
                          {'errorCode': 'IDENTITY_PROVIDER_NOT_FOUND'},
                          status: 404);
            }),
        baseUrl: 'https://fixture.invalid');
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(390, 844), textScaler: TextScaler.linear(2)),
            child: Scaffold(
                body: SingleChildScrollView(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: IdentityProvidersPage(
                            api: api,
                            actor: 'operator',
                            canRead: true,
                            canManage: false,
                            canTest: false,
                            changes: changes,
                            isCurrent: () => true,
                            reauthenticate: () {})))))));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
    final checklist = find.text('查看 12 项验收要求');
    await tester.ensureVisible(checklist);
    await tester.tap(checklist);
    await tester.pumpAndSettle();
    expect(find.text('真实短信发送与接收'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    changes.dispose();
  });
}
