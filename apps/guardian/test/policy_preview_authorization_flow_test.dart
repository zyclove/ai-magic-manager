@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart' hide Flow;
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/policy_publication.dart';
import 'package:guardian/ui/policy_publication_dialog.dart';
import 'package:guardian/ui/policy_preview_results.dart';
import 'package:guardian/ui/policy_target_picker.dart';
import 'package:http/http.dart' as http;

import 'policy_preview_flow_test.dart'
    show PreviewSession, Flow, startFlow, selectGroup, reveal, scrollToTop;
import 'policy_target_picker_test.dart' show reply, settle;

// Exercise the real picker, preview and save flows. The fixture deliberately
// keeps the local session unchanged after a denial from the HTTP boundary.
class _AuthorizationSession extends PreviewSession {
  _AuthorizationSession() : super(groups: true);

  final loginSteps = <bool>[];
  VoidCallback? beforeLogin;

  @override
  void login({bool stepUp = false}) {
    beforeLogin?.call();
    loginSteps.add(stepUp);
  }

  void awayAndBack(String dimension) {
    if (dimension == 'actor') {
      profile = {'subject': 'replacement-admin'};
      notifyListeners();
      profile = {'subject': 'admin'};
    } else {
      role = 'AUDITOR';
      notifyListeners();
      role = 'OWNER';
    }
    notifyListeners();
  }
}

class _AuthorizationFixture {
  final session = _AuthorizationSession();
  final requests = <http.Request>[];
  Future<http.Response?> Function(http.Request)? respond;

  _AuthorizationFixture() {
    session.intercept = (request) async {
      requests.add(request);
      return respond?.call(request);
    };
  }

  List<http.Request> get writes => requests
      .where((request) => request.url.path.endsWith('/publications'))
      .toList();
}

Future<Flow> _start(WidgetTester tester, _AuthorizationFixture fixture) async {
  final flow = await startFlow(tester, fixture.session);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
  });
  return flow;
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await settle(tester);
}

Future<Flow> _openPreview(
    WidgetTester tester, _AuthorizationFixture fixture) async {
  final flow = await _start(tester, fixture);
  await selectGroup(tester);
  await _tap(tester, find.text('预览这些设备'));
  expect(find.byType(PolicyPreviewResults), findsOneWidget);
  await _tap(tester, find.widgetWithText(ExpansionTile, '班级平板 group-1'));
  expect(find.text('域名访问'), findsOneWidget);
  expect(find.text('学习应用'), findsWidgets);
  return flow;
}

Future<void> _save(WidgetTester tester) async {
  await _tap(tester, find.widgetWithText(FilledButton, '仅保存配置'));
  await _tap(tester, find.widgetWithText(FilledButton, '发布配置'));
  // Confirmation stays in this owned route. Flush the HTTP and journal turns
  // before asserting the save response.
  await settle(tester);
}

Future<(Flow, VoidCallback)> _capturePickerReauthentication(
    WidgetTester tester, _AuthorizationFixture fixture) async {
  fixture.respond = (request) async => request.url.path.endsWith('/previews')
      ? reply({'errorCode': 'REAUTH_REQUIRED'}, 401)
      : null;
  final flow = await _start(tester, fixture);
  await selectGroup(tester);
  await _tap(tester, find.text('预览这些设备'));
  await scrollToTop(tester);
  final reauth = _button('重新安全验证');
  expect(reauth, findsOneWidget);
  final callback = tester.widget<ButtonStyleButton>(reauth).onPressed;
  expect(callback, isNotNull);
  expect(fixture.session.loginSteps, isEmpty);
  expect(fixture.writes, isEmpty);
  return (flow, callback!);
}

Finder _button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

void _expectInactiveAction(WidgetTester tester, String label) {
  final buttons = _button(label);
  for (final button in tester.widgetList<ButtonStyleButton>(buttons)) {
    expect(button.onPressed, isNull,
        reason: 'A denied preview must not keep the $label action enabled.');
  }
}

void _expectNoPrivatePicker(WidgetTester tester) {
  for (final name in [
    '学习平板 A',
    '客厅电视',
    '一年级 · 2 台',
    '班级平板 group-1',
    '班级平板 group-2',
  ]) {
    expect(find.text(name), findsNothing,
        reason: 'A hard denial must hide private target names.');
  }
  _expectInactiveAction(tester, '预览这些设备');
  _expectInactiveAction(tester, '重试预览');
  _expectInactiveAction(tester, '加载更多设备');
  _expectInactiveAction(tester, '更多组');
}

void _expectNoPrivatePreview(WidgetTester tester) {
  expect(find.byType(PolicyPreviewResults), findsNothing);
  expect(find.text('班级平板 group-1'), findsNothing);
  expect(find.text('班级平板 group-2'), findsNothing);
  expect(find.text('学习应用'), findsNothing);
  expect(find.text('域名访问'), findsNothing);
  _expectInactiveAction(tester, '仅保存配置');
}

void _expectSameSession(_AuthorizationFixture fixture) {
  expect(fixture.session.authenticated, isTrue);
  expect(fixture.session.profile?['subject'], 'admin');
  expect(fixture.session.role, 'OWNER');
  expect(fixture.session.scopeGeneration, 0);
}

bool _groupList(http.Request request) =>
    request.method == 'GET' && request.url.path.endsWith('/device-groups');

void main() {
  const denials = [
    (status: 403, code: 'ACCESS_DENIED'),
    (status: 401, code: 'UNAUTHENTICATED'),
  ];
  const stages = [
    'device-page',
    'group-list',
    'group-page',
    'group-detail',
    'group-summary',
    'group-members',
    'preview',
  ];

  for (final denial in denials) {
    for (final stage in stages) {
      testWidgets(
          '$stage hard ${denial.status} hides targets and stops further requests',
          (tester) async {
        final fixture = _AuthorizationFixture();
        var groupLists = 0;
        fixture.respond = (request) async {
          // startFlow first opens and closes its helper picker. Deny the list
          // in the actual ConsoleActions journey, not that setup route.
          if (stage == 'group-list' && _groupList(request)) {
            groupLists++;
            if (groupLists == 2) {
              return reply({'errorCode': denial.code}, denial.status);
            }
          }
          if (stage == 'group-page' && _groupList(request)) {
            if (!request.url.queryParameters.containsKey('cursor')) {
              return reply({
                'items': [fixture.session.group],
                'nextCursor': 'group-next',
              });
            }
            return reply({'errorCode': denial.code}, denial.status);
          }
          final rejected = switch (stage) {
            'device-page' => request.url.path.endsWith('/devices') &&
                request.url.queryParameters.containsKey('cursor'),
            'group-detail' =>
              request.url.path.endsWith('/device-groups/group-a'),
            'group-summary' =>
              request.url.path.endsWith('/device-groups/group-a/summary'),
            'group-members' =>
              request.url.path.endsWith('/device-groups/group-a/devices'),
            'preview' => request.url.path.endsWith('/previews'),
            _ => false,
          };
          return rejected
              ? reply({'errorCode': denial.code}, denial.status)
              : null;
        };
        await _start(tester, fixture);
        VoidCallback? retained;
        switch (stage) {
          case 'device-page':
            final moreDevices = _button('加载更多设备');
            await reveal(tester, moreDevices);
            expect(moreDevices, findsOneWidget);
            retained = tester.widget<ButtonStyleButton>(moreDevices).onPressed!;
            await _tap(tester, moreDevices);
          case 'group-page':
            final moreGroups = _button('更多组');
            await reveal(tester, moreGroups);
            expect(moreGroups, findsOneWidget);
            retained = tester.widget<ButtonStyleButton>(moreGroups).onPressed!;
            await _tap(tester, moreGroups);
          case 'group-detail':
          case 'group-summary':
          case 'group-members':
            final change = tester
                .widget<DropdownButtonFormField<String>>(
                    find.byType(DropdownButtonFormField<String>))
                .onChanged!;
            retained = () => change('group-a');
            await selectGroup(tester);
          case 'preview':
            await selectGroup(tester);
            final preview = find.widgetWithText(FilledButton, '预览这些设备');
            retained = tester.widget<FilledButton>(preview).onPressed!;
            await _tap(tester, preview);
          case 'group-list':
            break;
        }

        _expectSameSession(fixture);
        _expectNoPrivatePicker(tester);
        final afterDenial = fixture.requests.length;
        retained?.call();
        await settle(tester);
        _expectNoPrivatePicker(tester);
        expect(fixture.requests, hasLength(afterDenial),
            reason: 'A retained callback must not enter the HTTP transport.');
        expect(fixture.writes, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
        'save hard ${denial.status} hides the loaded preview without replay',
        (tester) async {
      final fixture = _AuthorizationFixture();
      fixture.respond = (request) async =>
          request.url.path.endsWith('/publications')
              ? reply({'errorCode': denial.code}, denial.status)
              : null;
      await _openPreview(tester, fixture);
      await _save(tester);

      _expectSameSession(fixture);
      _expectNoPrivatePreview(tester);
      expect(fixture.writes, hasLength(1));
      final afterDenial = fixture.requests.length;
      await settle(tester);
      expect(fixture.requests, hasLength(afterDenial));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'save group recheck hard ${denial.status} hides evidence before publication',
        (tester) async {
      final fixture = _AuthorizationFixture();
      var denied = false;
      fixture.respond = (request) async =>
          denied && request.url.path.endsWith('/device-groups/group-a')
              ? reply({'errorCode': denial.code}, denial.status)
              : null;
      await _openPreview(tester, fixture);
      denied = true;
      await _save(tester);

      _expectSameSession(fixture);
      _expectNoPrivatePreview(tester);
      expect(fixture.writes, isEmpty);
      final afterDenial = fixture.requests.length;
      await settle(tester);
      expect(fixture.requests, hasLength(afterDenial));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'stale picker reauthentication after actor and role ABA cannot log in',
      (tester) async {
    final fixture = _AuthorizationFixture();
    final (flow, retained) =
        await _capturePickerReauthentication(tester, fixture);
    final before = fixture.requests.length;

    // Both transitions return to identical visible values before the frame.
    // The retained callback still belongs to the original lost authority.
    fixture.session.awayAndBack('actor');
    fixture.session.awayAndBack('role');
    await settle(tester);
    _expectSameSession(fixture);
    expect(find.byType(PolicyTargetPicker, skipOffstage: false), findsNothing);
    expect(flow.completed, isTrue);
    await flow.done;
    retained();
    await settle(tester);

    expect(fixture.session.loginSteps, isEmpty);
    expect(fixture.requests, hasLength(before));
    expect(fixture.writes, isEmpty);
    expect(flow.failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale picker reauthentication after cancellation cannot log in',
      (tester) async {
    final fixture = _AuthorizationFixture();
    final (flow, retained) =
        await _capturePickerReauthentication(tester, fixture);
    final before = fixture.requests.length;
    await _tap(tester, _button('取消'));
    expect(find.byType(PolicyTargetPicker, skipOffstage: false), findsNothing);
    expect(flow.completed, isTrue);
    await flow.done;
    retained();
    await settle(tester);

    expect(fixture.session.loginSteps, isEmpty);
    expect(fixture.requests, hasLength(before));
    expect(fixture.writes, isEmpty);
    expect(flow.failure, isNull);
    expect(find.text('选择设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'stale picker reauthentication under an independent notice cannot log in',
      (tester) async {
    final fixture = _AuthorizationFixture();
    final (flow, retained) =
        await _capturePickerReauthentication(tester, fixture);
    final notice = showDialog<void>(
        context: flow.context,
        builder: (context) => AlertDialog(
              title: const Text('独立通知'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭通知'))
              ],
            ));
    await settle(tester);
    final before = fixture.requests.length;
    expect(find.text('独立通知'), findsOneWidget);
    expect(
        find.byType(PolicyTargetPicker, skipOffstage: false), findsOneWidget);
    retained();
    await settle(tester);

    expect(fixture.session.loginSteps, isEmpty);
    expect(fixture.requests, hasLength(before));
    expect(fixture.writes, isEmpty);
    expect(flow.completed, isFalse);
    expect(find.text('独立通知'), findsOneWidget);
    await _tap(tester, find.text('关闭通知'));
    await notice;
    expect(find.byType(PolicyTargetPicker), findsOneWidget);
    await _tap(tester, _button('取消'));
    expect(flow.completed, isTrue);
    await flow.done;
    expect(flow.failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'preview recent authentication preserves explicit selection for the user',
      (tester) async {
    final fixture = _AuthorizationFixture();
    fixture.respond = (request) async => request.url.path.endsWith('/previews')
        ? reply({'errorCode': 'REAUTH_REQUIRED'}, 401)
        : null;
    await _start(tester, fixture);
    await selectGroup(tester);
    await _tap(tester, find.text('预览这些设备'));

    _expectSameSession(fixture);
    expect(find.text('班级平板 group-1'), findsOneWidget);
    expect(find.text('班级平板 group-2'), findsOneWidget);
    await scrollToTop(tester);
    final reauth = _button('重新安全验证');
    expect(reauth, findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(reauth).onPressed, isNotNull);
    final retry = find.widgetWithText(FilledButton, '重试预览');
    expect(retry, findsOneWidget);
    expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
    final beforeReauthentication = fixture.requests.length;
    await _tap(tester, reauth);
    expect(fixture.session.loginSteps, [true]);
    expect(fixture.requests, hasLength(beforeReauthentication));
    expect(
        fixture.requests
            .where((request) => request.url.path.endsWith('/previews')),
        hasLength(1));
    expect(fixture.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'save recent authentication preserves the original operation and defers login until route completion',
      (tester) async {
    final fixture = _AuthorizationFixture();
    fixture.respond =
        (request) async => request.url.path.endsWith('/publications')
            ? http.Response(
                jsonEncode({
                  'type': 'about:blank',
                  'title': 'Unauthorized',
                  'status': 401,
                  'instance': request.url.path,
                  'errorCode': 'REAUTH_REQUIRED',
                  'messageKey': 'error.reauth_required',
                  'correlationId': 'synthetic-correlation',
                }),
                401,
                headers: {'content-type': 'application/problem+json'})
            : null;
    final flow = await _openPreview(tester, fixture);
    final dialog = tester
        .widget<PolicyPublicationDialog>(find.byType(PolicyPublicationDialog));
    final originalIntent = dialog.controller.intent;
    final route =
        ModalRoute.of(tester.element(find.byType(PolicyPublicationDialog)))!;
    final parentRoute = ModalRoute.of(flow.context)!;
    var routeCompleted = false;
    unawaited(route.completed.then<void>((_) {
      routeCompleted = true;
    }));
    final loginObservations =
        <({bool routeCompleted, bool routeIsActive, bool parentIsCurrent})>[];
    fixture.session.beforeLogin = () {
      loginObservations.add((
        routeCompleted: routeCompleted,
        routeIsActive: route.isActive,
        parentIsCurrent: parentRoute.isCurrent,
      ));
    };
    await _save(tester);

    _expectSameSession(fixture);
    expect(find.byType(PolicyPublicationDialog), findsOneWidget);
    expect(
        find.byType(PolicyPreviewResults, skipOffstage: false), findsNothing);
    for (final name in [
      '班级平板 group-1',
      '班级平板 group-2',
      '学习应用',
      '域名访问',
    ]) {
      expect(find.text(name, skipOffstage: false), findsNothing,
          reason: 'The recovery state disposes the private preview.');
    }
    final pending = await fixture.session.publicationJournal
        .read(originalIntent.owner, originalIntent.policyId);
    expect(pending, isNotNull);
    expect(pending!.intent, originalIntent);
    expect(pending.phase, PublicationPhase.reauthenticationRequired);
    expect(pending.attempt, 1);
    expect(fixture.writes, hasLength(1));
    expect(jsonDecode(fixture.writes.single.body), originalIntent.body);
    expect(fixture.writes.single.headers['if-match'],
        '"${originalIntent.revision}"');
    expect(fixture.writes.single.headers['idempotency-key'],
        originalIntent.idempotencyKey);
    final reauth = _button('完成安全验证');
    expect(reauth, findsOneWidget);
    final authenticate = tester.widget<ButtonStyleButton>(reauth).onPressed;
    expect(authenticate, isNotNull);
    expect(fixture.session.loginSteps, isEmpty);
    final afterDenial = fixture.requests.length;
    await settle(tester);
    expect(fixture.requests, hasLength(afterDenial));
    expect(fixture.writes, hasLength(1));
    authenticate!();
    expect(routeCompleted, isFalse);
    expect(fixture.session.loginSteps, isEmpty);
    expect(fixture.requests, hasLength(afterDenial));
    await settle(tester);
    expect(routeCompleted, isTrue);
    await tester.runAsync(() => flow.done.timeout(const Duration(seconds: 2)));
    expect(flow.failure, isNull);
    expect(loginObservations, hasLength(1));
    expect(loginObservations.single.routeCompleted, isTrue,
        reason: 'Login must wait for this owned route.completed.');
    expect(loginObservations.single.routeIsActive, isFalse);
    expect(loginObservations.single.parentIsCurrent, isTrue);
    expect(fixture.session.loginSteps, [true]);
    expect(flow.completed, isTrue);
    await flow.done;
    expect(flow.failure, isNull);
    expect(fixture.requests, hasLength(afterDenial));
    expect(fixture.writes, hasLength(1));
    expect(
        await fixture.session.publicationJournal
            .read(originalIntent.owner, originalIntent.policyId),
        pending);
    authenticate();
    await settle(tester);
    expect(fixture.session.loginSteps, [true]);
    expect(fixture.requests, hasLength(afterDenial));
    expect(fixture.writes, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
