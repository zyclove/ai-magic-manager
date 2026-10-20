import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/family_identity_controller.dart';
import 'package:guardian/core/family_identity_repository.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/family_identity_acceptance_panel.dart';
import 'family_identity_configuration_test.dart';
import 'family_identity_repository_test.dart' show identityReply;
import 'family_identity_release_fixtures.dart';

Json identityAcceptanceStatusFixture({String nextAction = 'REGISTER_RUN'}) => {
      'environmentId': 'family-cn-pilot',
      'versionId': identityVersionId,
      'confirmedOperationId': releaseId,
      'runtimeRevision': 2,
      'status': 'PENDING',
      'nextAction': nextAction,
      'passedCount': 0,
      'requiredCount': 12,
      'latestRun': null,
      'readinessChecks': <Object>[],
      'checks': (identityAcceptanceFixture()['checks'] as List)
          .map((check) => {...check as Json, 'status': 'PENDING'})
          .toList(),
      'salesGate': {
        'allowed': false,
        'status': 'CLOSED',
        'checks': [
          {
            'id': 'REAL_IDENTITY_ACCEPTANCE',
            'label': '账号真实联调',
            'stage': '收费开放',
            'status': 'BLOCKED',
            'reasonCode': 'REAL_EXECUTION_NOT_OBSERVED',
            'action': '先完成真实短信、微信与安卓真机验收。'
          }
        ]
      }
    };

Json boundIdentityAcceptanceFixture() => identityAcceptanceFixture()
  ..addAll({
    'releaseOperationId': releaseId,
    'runtimeRevision': 2,
    'expiresAt': 1792286400000,
  });

Json _confirmedRelease() => releaseStatusFixture()
  ..addAll({
    'runtimeRevision': 2,
    'runtimeStatus': 'APPLIED_CLOSED',
    'confirmedOperation': releaseOperationFixture(state: 'APPLIED_CLOSED'),
  });

FamilyIdentityController _controller(Api api,
        {bool Function()? current,
        IdentityProviderOperationStorage? storage}) =>
    FamilyIdentityController(
        repository:
            FamilyIdentityRepository(api: api, current: current ?? () => true),
        actor: 'synthetic-acceptance-operator',
        current: current ?? () => true,
        canManage: () => true,
        canTest: () => true,
        clearSensitiveInput: () {},
        storage: storage);

void main() {
  test('acceptance status has twelve pending checks and a closed sales gate',
      () {
    final status = IdentityProviderAcceptanceStatus.parse(
        identityAcceptanceStatusFixture());
    expect(status.passedCount, 0);
    expect(status.requiredCount, 12);
    expect(status.checks, hasLength(12));
    expect(status.salesChecks.single.label, '账号真实联调');
    expect(status.nextAction, 'REGISTER_RUN');
  });
  test('server status cannot report fake passes or open sales', () {
    for (final change in [
      <String, dynamic>{'passedCount': 1},
      <String, dynamic>{'requiredCount': 11},
      <String, dynamic>{'status': 'PASSED'},
      <String, dynamic>{'nextAction': 'ENABLE_SALES'},
      <String, dynamic>{
        'salesGate': {'allowed': true, 'status': 'OPEN', 'checks': []}
      },
    ]) {
      expect(
          () => IdentityProviderAcceptanceStatus.parse(
              identityAcceptanceStatusFixture()..addAll(change)),
          throwsA(isA<ApiFailure>()));
    }
    final passed = identityAcceptanceStatusFixture();
    ((passed['checks'] as List).first as Json)['status'] = 'READY';
    expect(() => IdentityProviderAcceptanceStatus.parse(passed),
        throwsA(isA<ApiFailure>()));
  });
  test('bound run requires a complete operation revision expiry tuple', () {
    final run =
        IdentityProviderAcceptanceRun.parse(boundIdentityAcceptanceFixture());
    expect(run.releaseOperationId, releaseId);
    expect(run.runtimeRevision, 2);
    expect(run.expiresAt, 1792286400000);
    for (final key in ['releaseOperationId', 'runtimeRevision', 'expiresAt']) {
      final broken = boundIdentityAcceptanceFixture()..remove(key);
      expect(() => IdentityProviderAcceptanceRun.parse(broken),
          throwsA(isA<ApiFailure>()));
    }
  });
  test('read-only status and history never send provider requests', () async {
    final requests = <http.Request>[];
    final api = Api(
        () async => MockClient((request) async {
              requests.add(request);
              return identityReply(
                  request.url.path.endsWith('/acceptance-status')
                      ? identityAcceptanceStatusFixture()
                      : {
                          'items': [boundIdentityAcceptanceFixture()]
                        });
            }),
        baseUrl: 'https://fixture.invalid');
    final repository = FamilyIdentityRepository(api: api, current: () => true);
    await repository.acceptanceStatus();
    expect(await repository.acceptanceRuns(), hasLength(1));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
  });
  test('current run is bound automatically to confirmed artifacts', () async {
    Json? posted;
    final api = Api(
        () async => MockClient((request) async {
              if (request.method == 'POST') {
                posted = jsonDecode(request.body) as Json;
                return identityReply(
                    boundIdentityAcceptanceFixture()..['id'] = posted!['id']);
              }
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(_confirmedRelease());
              }
              if (request.url.path.endsWith('/acceptance-status')) {
                return identityReply(identityAcceptanceStatusFixture());
              }
              return identityReply(identityStatusFixture());
            }),
        baseUrl: 'https://fixture.invalid');
    final controller = _controller(api);
    await controller.load();
    expect(controller.canStartCurrentAcceptance, isTrue);
    await controller.startCurrentAcceptance();
    expect(posted!['releaseOperationId'], releaseId);
    expect(posted!['expectedRuntimeRevision'], 2);
    expect(posted!['providerJarSha256'], 'a' * 64);
    expect(posted!['parentApkSha256'], 'b' * 64);
    expect(controller.pending, isNull);
    controller.dispose();
  });
  test('stale or unavailable current status disables registration', () async {
    var fail = false;
    var mismatch = false;
    final api = Api(
        () async => MockClient((request) async {
              if (request.url.path.endsWith('/acceptance-status')) {
                if (fail) {
                  throw http.ClientException('private-provider-details');
                }
                return identityReply(identityAcceptanceStatusFixture()
                  ..['runtimeRevision'] = mismatch ? 99 : 2);
              }
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(_confirmedRelease());
              }
              return identityReply(identityStatusFixture());
            }),
        baseUrl: 'https://fixture.invalid');
    final controller = _controller(api);
    await controller.load();
    expect(controller.canStartCurrentAcceptance, isTrue);
    mismatch = true;
    await controller.load();
    expect(controller.canStartCurrentAcceptance, isFalse);
    fail = true;
    await controller.load();
    expect(controller.acceptanceStatus, isNull);
    expect(controller.canStartCurrentAcceptance, isFalse);
    expect(controller.errorMessage, isNot(contains('private-')));
    controller.dispose();
  });
  test('unknown run creation recovers original id without repeating POST',
      () async {
    String? id;
    var posts = 0;
    final api = Api(
        () async => MockClient((request) async {
              if (request.method == 'POST') {
                posts++;
                id = (jsonDecode(request.body) as Json)['id'] as String;
                throw http.ClientException('synthetic lost response');
              }
              if (request.url.path.contains('/acceptance-runs/')) {
                return identityReply(
                    boundIdentityAcceptanceFixture()..['id'] = id);
              }
              if (request.url.path.endsWith('/acceptance-status')) {
                return identityReply(identityAcceptanceStatusFixture());
              }
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(_confirmedRelease());
              }
              return identityReply(identityStatusFixture());
            }),
        baseUrl: 'https://fixture.invalid');
    final controller = _controller(api);
    await controller.load();
    await controller.startCurrentAcceptance();
    expect(controller.pending?.id, id);
    await controller.recover();
    expect(controller.pending, isNull);
    expect(posts, 1);
    controller.dispose();
  });
  testWidgets(
      'simple panel guides phone steps and never offers a pass or sales toggle',
      (tester) async {
    final api = Api(
        () async => MockClient((request) async {
              if (request.url.path.endsWith('/acceptance-status')) {
                return identityReply(identityAcceptanceStatusFixture(
                    nextAction: 'PREPARE_PILOT'));
              }
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(_confirmedRelease());
              }
              return identityReply(identityStatusFixture());
            }),
        baseUrl: 'https://fixture.invalid');
    final controller = _controller(api);
    await controller.load();
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child:
                    IdentityProviderAcceptancePanel(controller: controller)))));
    expect(find.text('真实联调验收 · 0/12'), findsOneWidget);
    expect(find.textContaining('独立受限成人试点'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('开放收费'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets(
      'account change closes current acceptance confirmation before any write',
      (tester) async {
    var current = true;
    final requests = <http.Request>[];
    final api = Api(
        () async => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/acceptance-status')) {
                return identityReply(identityAcceptanceStatusFixture());
              }
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(_confirmedRelease());
              }
              return identityReply(identityStatusFixture());
            }),
        baseUrl: 'https://fixture.invalid');
    final controller = _controller(api, current: () => current);
    await controller.load();
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child:
                    IdentityProviderAcceptancePanel(controller: controller)))));
    final action = find.text('建立本次验收');
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('确认建立'), findsOneWidget);
    current = false;
    controller.invalidate();
    await tester.pumpAndSettle();
    expect(find.text('确认建立'), findsNothing);
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
