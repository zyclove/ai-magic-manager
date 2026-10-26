@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/pages/editors.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:guardian/ui/resource_page.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'policy_preview_flow_test.dart' show PreviewSession, flush;
import 'policy_target_picker_test.dart' show reply, settle;

const _policy = 'policy-private-a';
const _name = '原账户私有策略';
const _domain = 'private-policy.example';
const _copyName = '原账户私有策略 · 新副本';
const _version = 'version-private-a';

class _ScopeSession extends PreviewSession {
  _ScopeSession() : super(groups: true);

  Api? requestApi;
  int securityChecks = 0;
  @override
  Api get api => requestApi ?? super.api;

  @override
  void login({bool stepUp = false}) {
    if (stepUp) securityChecks++;
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

// Authentication and workspace identity are explicit fixture values. The API,
// ConsoleActions, details, form and HTTP dispatch are production implementations.
class _Fixture {
  final session = _ScopeSession();
  final requests = <http.Request>[];
  final bool template;
  Future<http.Response?> Function(http.Request)? respond;
  late ConsoleActions actions;
  bool fromList = false;
  int revision = 7;
  String currentName = _name;
  String? sourceVersionId;
  Json? copied;

  _Fixture({this.template = false}) {
    session.intercept = (request) async {
      requests.add(request);
      final response = await respond?.call(request);
      if (response != null) return response;
      if (fromList &&
          request.method == 'GET' &&
          request.url.path.endsWith('/policies')) {
        return reply({
          'items': [draft(), if (copied != null) copied!],
          'nextCursor': null,
        });
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/policies/$_policy')) {
        return reply(draft());
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/policies/$_policy/versions')) {
        return reply({
          'items': [fromList ? _contractVersion(this) : version()],
          'nextCursor': null
        });
      }
      if (fromList &&
          request.method == 'PUT' &&
          request.url.path.endsWith('/policies/$_policy')) {
        currentName = (jsonDecode(request.body) as Json)['name'] as String;
        revision++;
        return reply(draft());
      }
      if (fromList &&
          request.method == 'POST' &&
          request.url.path.endsWith(
              '/policies/$_policy/versions/$_version/rollback-drafts')) {
        sourceVersionId = _version;
        revision++;
        return reply(draft());
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/policies/$_policy/copies')) {
        final value = <String, dynamic>{
          ...draft(),
          'id': 'copy-private-a',
          'kind': 'POLICY',
          'name': (jsonDecode(request.body) as Json)['name'],
          'revision': 0,
          'sourceVersionId': null
        };
        if (fromList) copied = value;
        return reply(value);
      }
      throw StateError(
          'Unexpected HTTP boundary: ${request.method} ${request.url}');
    };
  }

  Json draft() => {
        'id': _policy,
        'name': currentName,
        'kind': template ? 'TEMPLATE' : 'POLICY',
        'revision': revision,
        'sourceVersionId': sourceVersionId,
        'rules': <Json>[
          {
            'id': 'private-rule-a',
            'kind': 'DOMAIN_ACCESS',
            'effect': 'DENY',
            'applicationId': null,
            'scheduleId': null,
            'permission': null,
            'domain': _domain,
            'seconds': null,
            'required': true,
          },
        ],
      };

  Json version() => {
        'id': _version,
        'policyId': _policy,
        'draftRevision': 7,
        'previewHash': 'a' * 64,
        'sourceVersionId': null,
        'sequence': 98731,
        'createdAt': 1730000000000,
        'mode': 'CONFIGURE_ONLY',
        'snapshot': {
          'schemaVersion': 1,
          'name': _name,
          'sourceRules': draft()['rules'],
          'applications': <Json>[],
          'schedules': <Json>[],
          'protectedPackageExemptions': <String>[],
          'targets': <Json>[]
        },
      };

  List<http.Request> get copies => requests
      .where((request) =>
          request.method == 'POST' &&
          request.url.path.endsWith('/policies/$_policy/copies'))
      .toList();

  List<http.Request> get versionReads => requests
      .where((request) =>
          request.method == 'GET' &&
          request.url.path.endsWith('/policies/$_policy/versions'))
      .toList();

  List<http.Request> get listReads => requests
      .where((request) =>
          request.method == 'GET' && request.url.path.endsWith('/policies'))
      .toList();

  List<http.Request> get writes =>
      requests.where((request) => request.method != 'GET').toList();
}

class _Invocation {
  bool completed = false;
  Object? failure;
  _Invocation(Future<void> operation) {
    unawaited(operation.then<void>((_) {
      completed = true;
    }, onError: (Object error, StackTrace _) {
      failure = error;
      completed = true;
    }));
  }
}

Future<void> _mount(WidgetTester tester, _Fixture fixture,
    {bool policiesList = false}) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1;
  fixture.fromList = policiesList;
  late BuildContext host;
  await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
      value: fixture.session,
      child: MaterialApp(
          key: ObjectKey(fixture),
          theme: consoleTheme(),
          home: Scaffold(body: Builder(builder: (context) {
            host = context;
            return policiesList
                ? const SingleChildScrollView(
                    child: ConsolePages(section: 'policies'))
                : const Text('策略详情宿主');
          })))));
  fixture.actions = ConsoleActions(host, fixture.session);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    fixture.session.previewClient.close();
    fixture.session.client.close();
    fixture.session.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _waitUntil(WidgetTester tester, bool Function() ready) async {
  for (var turn = 0; turn < 40 && !ready(); turn++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: 'The observed policy flow must complete.');
  // A deliberately pending client keeps progress animations running. Complete
  // only bounded route transitions after observing the requested state.
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Finder _topButton(String text) =>
    find.descendant(of: find.byType(AlertDialog).last, matching: _button(text));

OwnedDialogRoute<dynamic> _topRoute(WidgetTester tester) =>
    ModalRoute.of(tester.element(find.byType(AlertDialog).last))!
        as OwnedDialogRoute<dynamic>;

Future<OwnedDialogRoute<dynamic>> _openFromList(
    WidgetTester tester, _Fixture fixture) async {
  await _mount(tester, fixture, policiesList: true);
  final row = find.descendant(
      of: find.byType(ResourcePage), matching: find.text(_name));
  await _waitUntil(tester, () => row.evaluate().length == 1);
  expect(fixture.listReads, hasLength(1));
  await tester.tap(row);
  await _waitUntil(
      tester, () => find.byType(AlertDialog).evaluate().length == 1);
  return _topRoute(tester);
}

Finder _button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

VoidCallback _capture(WidgetTester tester, String label) {
  final button = _button(label);
  expect(button, findsOneWidget);
  final callback = tester.widget<ButtonStyleButton>(button).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

Future<_Invocation> _open(WidgetTester tester, _Fixture fixture) async {
  final invocation =
      _Invocation(fixture.actions.policyDetails({'id': _policy}));
  await settle(tester);
  expect(find.text(_name), findsOneWidget);
  return invocation;
}

void _expectSameScopeValues(_Fixture fixture) {
  expect(fixture.session.profile?['subject'], 'admin');
  expect(fixture.session.role, 'OWNER');
  expect(fixture.session.scopeGeneration, 0,
      reason:
          'The away-and-back notifications must latch loss without a new epoch.');
}

void _expectNoPrivate(WidgetTester tester) {
  for (final secret in [_name, _domain, _policy, _version, '版本 98731']) {
    expect(find.textContaining(secret, skipOffstage: false), findsNothing,
        reason: 'Old details and child routes must redact private values.');
    for (final field in tester
        .widgetList<TextField>(find.byType(TextField, skipOffstage: false))) {
      expect(field.controller?.text ?? '', isNot(contains(secret)));
    }
  }
  for (final label in ['编辑草稿', '从模板创建策略', '版本历史', '保存']) {
    for (final button in tester.widgetList<ButtonStyleButton>(_button(label))) {
      expect(button.onPressed, isNull,
          reason: 'Old actions must be absent or disabled after scope loss.');
    }
  }
}

const _scheduleId = 'schedule-private-a';
const _scheduleName = '原账户私有时间计划';

Json _schedule() => {
      'id': _scheduleId,
      'name': _scheduleName,
      'definition': {
        'timeZone': 'Asia/Shanghai',
        'weekly': [
          {'day': 'MONDAY', 'start': '18:00', 'end': '20:00'}
        ],
        'exceptions': <Json>[],
      },
    };

Json _scheduleDecision({String date = '2091-08-09', bool allowed = true}) => {
      'allowed': allowed,
      'currentUntil': allowed ? '2091-08-09T11:00:00Z' : null,
      'nextAllowedAt': allowed ? null : '2091-08-10T06:00:00Z',
      'timeZone': 'Pacific/Auckland',
      'localDate': date,
    };

void _expectNoSchedulePrivate(WidgetTester tester) {
  for (final secret in [_scheduleName, '2091-08-09', 'Pacific/Auckland']) {
    expect(find.textContaining(secret, skipOffstage: false), findsNothing,
        reason: 'Both the plan and inline evaluation belong to the old scope.');
  }
}

void main() {
  testWidgets(
      'policy-return history closes back to details without list refresh',
      (tester) async {
    final fixture = _Fixture();
    final details = await _openFromList(tester, fixture);
    _capture(tester, '版本历史')();
    await _waitUntil(
        tester, () => find.text('版本 98731').evaluate().length == 1);
    final history = _topRoute(tester);
    await tester.tap(_topButton('关闭'));
    await _waitUntil(tester, () => !history.available);
    expect(details.available, isTrue);
    expect(details.isCurrent, isTrue);
    expect(_button('编辑草稿'), findsOneWidget);
    expect(fixture.listReads, hasLength(1));
    expect(fixture.versionReads, hasLength(1));
    expect(fixture.writes, isEmpty);
  });

  testWidgets(
      'policy-return cancelling edit or template copy keeps old details',
      (tester) async {
    for (final template in [false, true]) {
      final fixture = _Fixture(template: template);
      final details = await _openFromList(tester, fixture);
      _capture(tester, template ? '从模板创建策略' : '编辑草稿')();
      await _waitUntil(
          tester,
          () => template
              ? find.text('复制为策略').evaluate().isNotEmpty
              : find.byType(PolicyEditor).evaluate().isNotEmpty);
      final editor = _topRoute(tester);
      await tester.tap(_topButton('取消'));
      await _waitUntil(tester, () => !editor.available);
      expect(details.available, isTrue);
      expect(details.isCurrent, isTrue);
      expect(_button('编辑草稿'), findsOneWidget);
      expect(fixture.listReads, hasLength(1));
      expect(fixture.writes, isEmpty);
    }
  });

  testWidgets('policy-return edit saves once and refreshes the revised list',
      (tester) async {
    final fixture = _Fixture();
    final details = await _openFromList(tester, fixture);
    _capture(tester, '编辑草稿')();
    await _waitUntil(
        tester, () => find.byType(PolicyEditor).evaluate().isNotEmpty);
    await tester.enterText(
        find.widgetWithText(TextFormField, '策略名称'), '调整后的私有策略');
    _capture(tester, '保存草稿')();
    await _waitUntil(
        tester,
        () =>
            fixture.listReads.length == 2 &&
            find.text('调整后的私有策略').evaluate().length == 1);
    expect(details.available, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('v8'), findsOneWidget);
    expect(fixture.writes, hasLength(1));
    final sent = fixture.writes.single;
    expect(sent.method, 'PUT');
    expect(sent.url.path, '/api/v1/tenants/tenant-a/policies/$_policy');
    expect(sent.headers['If-Match'], '"7"');
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    final body = jsonDecode(sent.body) as Json;
    expect(body.keys, unorderedEquals(['name', 'rules']));
    expect(body['name'], '调整后的私有策略');
    expect(body['rules'], isNotEmpty);
    expect(fixture.listReads, hasLength(2));
  });

  testWidgets(
      'policy-return template copy saves a new policy and refreshes once',
      (tester) async {
    final fixture = _Fixture(template: true);
    final details = await _openFromList(tester, fixture);
    _capture(tester, '从模板创建策略')();
    await _waitUntil(tester, () => find.text('复制为策略').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextFormField), _copyName);
    _capture(tester, '保存')();
    await _waitUntil(
        tester,
        () =>
            fixture.listReads.length == 2 &&
            find.text(_copyName).evaluate().length == 1);
    expect(details.available, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    expect(fixture.copies, hasLength(1));
    final sent = fixture.copies.single;
    expect(sent.headers['If-Match'], '"7"');
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(sent.headers['Idempotency-Key'], isNot(_policy));
    expect(jsonDecode(sent.body), {'name': _copyName});
    expect(fixture.copied!['id'], isNot(_policy));
    expect(fixture.copied!['kind'], 'POLICY');
    expect(fixture.copied!['revision'], 0);
    expect(find.text(_name), findsOneWidget);
    expect(find.text('v0'), findsOneWidget);
    expect(fixture.listReads, hasLength(2));
    expect(fixture.writes, hasLength(1));
  });

  testWidgets(
      'policy-return rollback cancellation keeps version and confirm refreshes',
      (tester) async {
    final fixture = _Fixture();
    final details = await _openFromList(tester, fixture);
    _capture(tester, '版本历史')();
    await _waitUntil(tester, () => find.text('版本 98731').evaluate().isNotEmpty);
    final history = _topRoute(tester);
    await tester.tap(find.text('版本 98731'));
    await _waitUntil(tester, () => find.text('历史版本').evaluate().isNotEmpty);
    final version = _topRoute(tester);
    _capture(tester, '回滚为草稿')();
    await _waitUntil(tester, () => _topButton('确认').evaluate().isNotEmpty);
    await tester.tap(_topButton('取消'));
    // Route.current precedes completion of the child action's async cleanup.
    await _waitUntil(tester, () {
      final rollback = _topButton('回滚为草稿');
      return version.isCurrent &&
          rollback.evaluate().length == 1 &&
          tester.widget<ButtonStyleButton>(rollback).onPressed != null;
    });
    expect(version.available, isTrue);
    expect(history.available, isTrue);
    expect(details.available, isTrue);
    expect(fixture.writes, isEmpty);
    expect(fixture.listReads, hasLength(1));

    _capture(tester, '回滚为草稿')();
    await _waitUntil(tester, () => _topButton('确认').evaluate().isNotEmpty);
    await tester.tap(_topButton('确认'));
    await _waitUntil(
        tester,
        () =>
            fixture.listReads.length == 2 &&
            find.text('v8').evaluate().length == 1);
    expect(version.available, isFalse);
    expect(history.available, isFalse);
    expect(details.available, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    expect(fixture.writes, hasLength(1));
    final sent = fixture.writes.single;
    expect(sent.method, 'POST');
    expect(
        sent.url.path,
        '/api/v1/tenants/tenant-a/policies/$_policy/'
        'versions/$_version/rollback-drafts');
    expect(sent.headers['If-Match'], '"7"');
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(jsonDecode(sent.body), {'name': _name});
    expect(fixture.sourceVersionId, _version);
    expect(fixture.listReads, hasLength(2));
  });

  testWidgets(
      'policy-return unknown copy survives MFA and closes only for review',
      (tester) async {
    final fixture = _Fixture(template: true);
    var attempts = 0;
    fixture.respond = (request) async {
      if (request.method != 'POST' ||
          !request.url.path.endsWith('/policies/$_policy/copies')) return null;
      attempts++;
      return attempts == 2
          ? reply({'errorCode': 'REAUTH_REQUIRED'}, 401)
          : reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503);
    };
    final details = await _openFromList(tester, fixture);
    _capture(tester, '从模板创建策略')();
    await _waitUntil(tester, () => find.text('复制为策略').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextFormField), _copyName);
    _capture(tester, '保存')();
    await _waitUntil(
        tester, () => attempts == 1 && _button('重试原提交').evaluate().isNotEmpty);
    final original = fixture.copies.single;
    _capture(tester, '重试原提交')();
    await _waitUntil(
        tester, () => attempts == 2 && _button('重新安全验证').evaluate().isNotEmpty);
    var field = tester.widget<TextFormField>(find.byType(TextFormField));
    expect(field.controller!.text, _copyName);
    expect(field.enabled, isFalse);
    expect(_button('重试原提交'), findsOneWidget);
    _capture(tester, '重新安全验证')();
    await _waitUntil(tester, () => fixture.session.securityChecks == 1);
    expect(attempts, 2, reason: 'MFA does not submit a pending write.');
    _capture(tester, '重试原提交')();
    await _waitUntil(
        tester, () => attempts == 3 && _button('重试原提交').evaluate().isNotEmpty);
    field = tester.widget<TextFormField>(find.byType(TextFormField));
    expect(field.controller!.text, _copyName);
    expect(field.enabled, isFalse);
    for (final retried in fixture.copies.skip(1)) {
      expect(retried.headers['Idempotency-Key'],
          original.headers['Idempotency-Key']);
      expect(retried.headers['If-Match'], original.headers['If-Match']);
      expect(retried.body, original.body);
    }
    expect(fixture.listReads, hasLength(1));
    expect(details.available, isTrue);
    await tester.tap(find.descendant(
        of: find.byKey(const Key('policy-copy-form')),
        matching: _button('暂时关闭')));
    await _waitUntil(
        tester,
        () => find
            .byKey(const Key('edit-dialog-confirm-close'))
            .evaluate()
            .isNotEmpty);
    await tester.tap(find.byKey(const Key('edit-dialog-confirm-close')));
    await _waitUntil(
        tester, () => fixture.listReads.length == 2 && !details.available);
    expect(find.byType(AlertDialog), findsNothing);
    expect(fixture.copied, isNull);
    expect(fixture.revision, 7);
    expect(fixture.copies, hasLength(3));
    expect(find.text(_copyName), findsNothing);
    expect(find.textContaining('保存成功'), findsNothing);
    expect(fixture.listReads, hasLength(2));
  });

  testWidgets(
      'policy-return closed or ABA parent blocks late client under a cover',
      (tester) async {
    for (final loss in ['closed', 'actor']) {
      final fixture = _Fixture(template: true);
      final client = Completer<http.Client>();
      var blocked = false,
          waiting = false,
          delivered = false,
          coverClosed = false;
      fixture.session.requestApi = Api(() {
        if (!blocked) return Future.value(fixture.session.previewClient);
        waiting = true;
        return client.future.then((value) {
          delivered = true;
          return value;
        });
      }, baseUrl: 'https://fixture.invalid/api/v1');
      addTearDown(() {
        if (!client.isCompleted) client.complete(fixture.session.previewClient);
      });
      final details = await _openFromList(tester, fixture);
      _capture(tester, '从模板创建策略')();
      await _waitUntil(tester, () => find.text('复制为策略').evaluate().isNotEmpty);
      await tester.enterText(find.byType(TextFormField), _copyName);
      blocked = true;
      _capture(tester, '保存')();
      await _waitUntil(tester, () => waiting);
      unawaited(showDialog<void>(
              context: tester.element(find.byType(TextFormField)),
              builder: (_) => const AlertDialog(title: Text('独立提示')))
          .then<void>((_) {
        coverClosed = true;
      }));
      await _waitUntil(tester, () => find.text('独立提示').evaluate().isNotEmpty);
      final cover = ModalRoute.of(tester.element(find.text('独立提示')))!;
      if (loss == 'closed') {
        details.finish();
      } else {
        fixture.session.awayAndBack('actor');
      }
      client.complete(fixture.session.previewClient);
      await _waitUntil(
          tester,
          () =>
              delivered &&
              find.text('复制为策略', skipOffstage: false).evaluate().isEmpty);
      expect(fixture.writes, isEmpty);
      expect(fixture.listReads, hasLength(1));
      expect(coverClosed, isFalse);
      expect(cover.isCurrent, isTrue);
      expect(find.text('独立提示'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'policy-return stopped edit preserves input and closes for refresh',
      (tester) async {
    const stoppedName = '并发后应保留的私有草稿';
    for (final rejection in const {
      412: 'RESOURCE_VERSION_CONFLICT',
      409: 'IDEMPOTENCY_KEY_EXPIRED',
      410: 'IDEMPOTENCY_RESPONSE_ERASED',
    }.entries) {
      final fixture = _Fixture();
      fixture.respond = (request) async => request.method == 'PUT' &&
              request.url.path.endsWith('/policies/$_policy')
          ? reply({'errorCode': rejection.value}, rejection.key)
          : null;
      final details = await _openFromList(tester, fixture);
      _capture(tester, '编辑草稿')();
      await _waitUntil(
          tester, () => find.byType(PolicyEditor).evaluate().isNotEmpty);
      await tester.enterText(
          find.widgetWithText(TextFormField, '策略名称'), stoppedName);
      final oldSave = _capture(tester, '保存草稿');
      oldSave();
      await _waitUntil(
          tester,
          () => find
              .byKey(const Key('editor-close-stopped'))
              .evaluate()
              .isNotEmpty);
      expect(fixture.writes, hasLength(1));
      expect(fixture.writes.single.method, 'PUT');
      expect((jsonDecode(fixture.writes.single.body) as Json)['name'],
          stoppedName);
      expect(find.byType(TextFormField), findsNothing);
      expect(_button('保存草稿'), findsNothing);
      expect(_button('按原内容恢复'), findsNothing);
      expect(_button('重试原提交'), findsNothing);
      await tester.ensureVisible(find.text('保留的草稿'));
      await tester.tap(find.text('保留的草稿'));
      await _waitUntil(
          tester, () => find.textContaining(stoppedName).evaluate().isNotEmpty);
      oldSave();
      await settle(tester);
      expect(fixture.writes, hasLength(1),
          reason:
              'A stopped revision or expired request cannot be resubmitted.');
      expect(fixture.listReads, hasLength(1));
      expect(details.available, isTrue);
      final close = find.byKey(const Key('editor-close-stopped'));
      expect(find.descendant(of: close, matching: find.text('关闭并刷新')),
          findsOneWidget);
      await tester.tap(close);
      await _waitUntil(
          tester, () => fixture.listReads.length == 2 && !details.available);
      expect(find.byType(AlertDialog), findsNothing);
      expect(fixture.revision, 7);
      expect(fixture.listReads, hasLength(2));
      expect(find.textContaining('保存成功'), findsNothing);
    }
  });

  for (final dimension in ['actor', 'role']) {
    testWidgets('late policy GET after $dimension ABA cannot disclose details',
        (tester) async {
      final fixture = _Fixture();
      final response = Completer<http.Response>();
      fixture.respond = (request) async =>
          request.url.path.endsWith('/policies/$_policy')
              ? response.future
              : null;
      await _mount(tester, fixture);
      addTearDown(() {
        if (!response.isCompleted) {
          response.complete(reply(fixture.draft()));
        }
      });
      final invocation =
          _Invocation(fixture.actions.policyDetails({'id': _policy}));
      await settle(tester);
      expect(fixture.requests, hasLength(1));

      fixture.session.awayAndBack(dimension);
      response.complete(reply(fixture.draft()));
      await settle(tester);

      _expectSameScopeValues(fixture);
      _expectNoPrivate(tester);
      expect(
          invocation.failure,
          anyOf(
              isNull,
              isA<ApiFailure>().having(
                  (failure) => failure.code, 'code', 'WORKSPACE_CHANGED')));
      expect(fixture.requests, hasLength(1));
      expect(fixture.copies, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'open details role ABA redacts data and revokes a retained action',
      (tester) async {
    final fixture = _Fixture();
    await _mount(tester, fixture);
    await _open(tester, fixture);
    final history = _capture(tester, '版本历史');
    final beforeLoss = fixture.requests.length;

    fixture.session.awayAndBack('role');
    await settle(tester);
    history();
    await settle(tester);

    _expectSameScopeValues(fixture);
    expect(fixture.requests, hasLength(beforeLoss),
        reason: 'The retained details action must not enter HTTP transport.');
    _expectNoPrivate(tester);
    expect(tester.takeException(), isNull);
  });

  for (final dimension in ['actor', 'role']) {
    testWidgets(
        'open template copy form $dimension ABA redacts and blocks POST',
        (tester) async {
      final fixture = _Fixture(template: true);
      await _mount(tester, fixture);
      await _open(tester, fixture);
      _capture(tester, '从模板创建策略')();
      await settle(tester);
      expect(find.text('复制为策略'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), _copyName);
      final save = _capture(tester, '保存');

      fixture.session.awayAndBack(dimension);
      await settle(tester);
      save();
      await settle(tester);

      _expectSameScopeValues(fixture);
      expect(fixture.copies, isEmpty,
          reason:
              'An already open child form must not submit after scope loss.');
      _expectNoPrivate(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'late version page after actor ABA cannot paginate or disclose history',
      (tester) async {
    final fixture = _Fixture();
    final response = Completer<http.Response>();
    await _mount(tester, fixture);
    addTearDown(() {
      if (!response.isCompleted) {
        response.complete(reply({
          'items': [fixture.version()],
          'nextCursor': 'late-next'
        }));
      }
    });
    await _open(tester, fixture);
    fixture.respond = (request) async =>
        request.url.path.endsWith('/versions') &&
                !request.url.queryParameters.containsKey('cursor')
            ? response.future
            : null;
    _capture(tester, '版本历史')();
    await settle(tester);
    expect(fixture.versionReads, hasLength(1));

    fixture.session.awayAndBack('actor');
    response.complete(reply({
      'items': [fixture.version()],
      'nextCursor': 'late-next'
    }));
    await settle(tester);

    _expectSameScopeValues(fixture);
    expect(fixture.versionReads, hasLength(1),
        reason:
            'A late page must not dispatch its cursor under the restored actor.');
    _expectNoPrivate(tester);
    expect(fixture.copies, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'active template copy sends explicit name with original revision once',
      (tester) async {
    final fixture = _Fixture(template: true);
    await _mount(tester, fixture);
    final invocation = await _open(tester, fixture);
    _capture(tester, '从模板创建策略')();
    await settle(tester);
    await tester.enterText(find.byType(TextFormField), _copyName);
    _capture(tester, '保存')();
    await settle(tester);

    expect(fixture.copies, hasLength(1));
    final sent = fixture.copies.single;
    expect(sent.url.path, '/api/v1/tenants/tenant-a/policies/$_policy/copies');
    expect(sent.headers['If-Match'], '"7"');
    expect(sent.headers['Idempotency-Key'], isNotEmpty);
    expect(jsonDecode(sent.body), {'name': _copyName});
    expect(invocation.completed, isTrue);
    expect(invocation.failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returned draft id mismatch cannot disclose or enable copy',
      (tester) async {
    final fixture = _Fixture(template: true);
    fixture.respond = (request) async => request.method == 'GET' &&
            request.url.path.endsWith('/policies/$_policy')
        ? reply({...fixture.draft(), 'id': 'unrelated-private-policy'})
        : null;
    await _mount(tester, fixture);
    final invocation =
        _Invocation(fixture.actions.policyDetails({'id': _policy}));
    await settle(tester);

    _expectNoPrivate(tester);
    expect(find.textContaining('unrelated-private-policy', skipOffstage: false),
        findsNothing);
    _expectNoEnabledPolicyActions(tester);
    expect(fixture.requests, hasLength(1));
    expect(fixture.copies, isEmpty);
    expect(invocation.failure,
        isA<ApiFailure>().having((failure) => failure.status, 'status', 502));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'invalid draft kind and revision cannot disclose or enable actions',
      (tester) async {
    final fixture = _Fixture();
    fixture.respond = (request) async => request.method == 'GET' &&
            request.url.path.endsWith('/policies/$_policy')
        ? reply({
            ...fixture.draft(),
            'kind': 'UNRECOGNIZED_POLICY_KIND',
            'revision': '7',
          })
        : null;
    await _mount(tester, fixture);
    final invocation =
        _Invocation(fixture.actions.policyDetails({'id': _policy}));
    await settle(tester);

    _expectNoPrivate(tester);
    _expectNoEnabledPolicyActions(tester);
    expect(fixture.requests, hasLength(1));
    expect(
        fixture.requests.every((request) => request.method == 'GET'), isTrue);
    expect(invocation.failure,
        isA<ApiFailure>().having((failure) => failure.status, 'status', 502));
    expect(tester.takeException(), isNull);
  });

  testWidgets('history policy id mismatch cannot disclose or enable rollback',
      (tester) async {
    final fixture = _Fixture();
    fixture.respond = (request) async =>
        request.method == 'GET' && request.url.path.endsWith('/versions')
            ? reply({
                'items': [
                  {..._contractVersion(fixture), 'policyId': 'unrelated-policy'}
                ],
                'nextCursor': null,
              })
            : null;
    await _mount(tester, fixture);
    await _open(tester, fixture);
    _capture(tester, '版本历史')();
    await settle(tester);

    expect(find.text('版本 98731', skipOffstage: false), findsNothing);
    expect(find.textContaining(_version, skipOffstage: false), findsNothing);
    _expectNoEnabledPolicyActions(tester, labels: ['回滚为草稿']);
    expect(fixture.versionReads, hasLength(1));
    expect(
        fixture.requests.every((request) => request.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'history without sequence cannot display version null or rollback',
      (tester) async {
    final fixture = _Fixture();
    final invalid = _contractVersion(fixture)..remove('sequence');
    fixture.respond = (request) async =>
        request.method == 'GET' && request.url.path.endsWith('/versions')
            ? reply({
                'items': [invalid],
                'nextCursor': null
              })
            : null;
    await _mount(tester, fixture);
    await _open(tester, fixture);
    _capture(tester, '版本历史')();
    await settle(tester);

    expect(find.text('版本 null', skipOffstage: false), findsNothing);
    expect(find.textContaining(_version, skipOffstage: false), findsNothing);
    _expectNoEnabledPolicyActions(tester, labels: ['回滚为草稿']);
    expect(fixture.versionReads, hasLength(1));
    expect(
        fixture.requests.every((request) => request.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final invalid in <Object?>[<String, dynamic>{}, null]) {
    final description = invalid == null ? 'null' : 'empty object';
    testWidgets(
        'copy 201 $description retains original name and key until explicit retry',
        (tester) async {
      final fixture = _Fixture(template: true);
      var attempts = 0;
      fixture.respond = (request) async {
        if (request.method != 'POST' ||
            !request.url.path.endsWith('/policies/$_policy/copies')) {
          return null;
        }
        attempts++;
        if (attempts == 1) {
          return http.Response(jsonEncode(invalid), 201,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        return reply({
          ...fixture.draft(),
          'id': 'copy-private-a',
          'name': _copyName,
          'kind': 'POLICY',
          'revision': 0,
          'sourceVersionId': null,
        });
      };
      await _mount(tester, fixture);
      final invocation = await _open(tester, fixture);
      _capture(tester, '从模板创建策略')();
      await settle(tester);
      await tester.enterText(find.byType(TextFormField), _copyName);
      _capture(tester, '保存')();
      await settle(tester);

      expect(find.text('复制为策略'), findsOneWidget,
          reason: 'An invalid success projection cannot complete the copy.');
      expect(invocation.completed, isFalse);
      final field = tester.widget<TextFormField>(find.byType(TextFormField));
      expect(field.controller?.text, _copyName);
      expect(field.enabled, isFalse,
          reason: 'The original pending name must remain immutable.');
      expect(fixture.copies, hasLength(1),
          reason: 'Recovery must never submit automatically.');
      final original = fixture.copies.single;
      expect(original.headers['Idempotency-Key'], isNotEmpty);
      expect(jsonDecode(original.body), {'name': _copyName});

      _capture(tester, '重试原提交')();
      await settle(tester);

      expect(fixture.copies, hasLength(2));
      final retried = fixture.copies.last;
      expect(retried.headers['Idempotency-Key'],
          original.headers['Idempotency-Key']);
      expect(retried.headers['If-Match'], original.headers['If-Match']);
      expect(retried.body, original.body);
      expect(invocation.completed, isTrue);
      expect(invocation.failure, isNull);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('schedule checks replace inline results without closing the plan',
      (tester) async {
    final fixture = _Fixture();
    final second = Completer<http.Response>();
    var checks = 0;
    fixture.respond = (request) async {
      expect(request.method, 'GET');
      expect(request.url.path.endsWith('/schedules/$_scheduleId/evaluation'),
          isTrue);
      expect(request.url.queryParameters['at'], isNotEmpty);
      return ++checks == 1 ? reply(_scheduleDecision()) : second.future;
    };
    await _mount(tester, fixture);
    addTearDown(() {
      if (!second.isCompleted) second.complete(reply(_scheduleDecision()));
    });
    final invocation =
        _Invocation(fixture.actions.scheduleDetails(_schedule()));
    await settle(tester);
    _capture(tester, '检查此刻是否允许')();
    await settle(tester);
    expect(find.text(_scheduleName), findsOneWidget);
    expect(find.text('时段计算结果'), findsOneWidget);
    expect(find.text('结果：当前在允许时段内'), findsOneWidget);
    expect(find.text('当地日期：2091-08-09'), findsOneWidget);
    expect(find.textContaining('检查时间：'), findsOneWidget);
    expect(invocation.completed, isFalse);
    _capture(tester, '检查此刻是否允许')();
    await flush(tester);
    expect(fixture.requests, hasLength(2));
    expect(find.text('当地日期：2091-08-09'), findsNothing,
        reason:
            'An in-flight recheck must not present the old decision as current.');
    second
        .complete(reply(_scheduleDecision(date: '2091-08-10', allowed: false)));
    await settle(tester);
    expect(find.text('时段计算结果'), findsOneWidget);
    expect(find.text('结果：当前不在允许时段内'), findsOneWidget);
    expect(find.text('当地日期：2091-08-10'), findsOneWidget);
    expect(find.text('当地日期：2091-08-09'), findsNothing);
    expect(find.text(_scheduleName), findsOneWidget);
    expect(invocation.completed, isFalse);
    _capture(tester, '关闭')();
    await settle(tester);
    expect(invocation.completed, isTrue);
    expect(invocation.failure, isNull);
    expect(fixture.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('schedule actor and role ABA redact both plan and inline result',
      (tester) async {
    for (final dimension in ['actor', 'role']) {
      final fixture = _Fixture();
      fixture.respond = (_) async => reply(_scheduleDecision());
      await _mount(tester, fixture);
      final invocation =
          _Invocation(fixture.actions.scheduleDetails(_schedule()));
      await settle(tester);
      final check = _capture(tester, '检查此刻是否允许');
      check();
      await settle(tester);
      expect(find.text('当地日期：2091-08-09'), findsOneWidget);
      fixture.session.awayAndBack(dimension);
      check();
      await settle(tester);
      _expectSameScopeValues(fixture);
      _expectNoSchedulePrivate(tester);
      expect(find.text('工作空间或权限已变化'), findsOneWidget);
      expect(fixture.requests, hasLength(1),
          reason: '$dimension ABA must permanently revoke a captured check.');
      _capture(tester, '关闭')();
      await settle(tester);
      expect(invocation.completed, isTrue);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'schedule scope loss while awaiting a client prevents the old GET',
      (tester) async {
    final fixture = _Fixture();
    final client = Completer<http.Client>();
    fixture.session.requestApi =
        Api(() => client.future, baseUrl: 'https://fixture.invalid/api/v1');
    fixture.respond = (_) async => reply(_scheduleDecision());
    await _mount(tester, fixture);
    addTearDown(() {
      if (!client.isCompleted) client.complete(fixture.session.previewClient);
    });
    final invocation =
        _Invocation(fixture.actions.scheduleDetails(_schedule()));
    await settle(tester);
    _capture(tester, '检查此刻是否允许')();
    await flush(tester);
    expect(fixture.requests, isEmpty);
    fixture.session.awayAndBack('actor');
    client.complete(fixture.session.previewClient);
    await settle(tester);
    expect(fixture.requests, isEmpty,
        reason:
            'The authenticated client must not receive the old evaluation GET.');
    _expectNoSchedulePrivate(tester);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    _capture(tester, '关闭')();
    await settle(tester);
    expect(invocation.completed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'late schedule evaluation cannot disclose data or close a covering notice',
      (tester) async {
    final fixture = _Fixture();
    final response = Completer<http.Response>();
    fixture.respond = (_) async => response.future;
    await _mount(tester, fixture);
    addTearDown(() {
      if (!response.isCompleted) response.complete(reply(_scheduleDecision()));
    });
    final invocation =
        _Invocation(fixture.actions.scheduleDetails(_schedule()));
    await settle(tester);
    _capture(tester, '检查此刻是否允许')();
    await flush(tester);
    expect(fixture.requests, hasLength(1));
    var noticeClosed = false;
    unawaited(showDialog<void>(
        context: tester.element(find.text(_scheduleName)),
        builder: (context) => AlertDialog(title: const Text('独立通知'), actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭通知'))
            ])).then((_) => noticeClosed = true));
    await flush(tester);
    fixture.session.awayAndBack('actor');
    response.complete(reply(_scheduleDecision()));
    await settle(tester);
    expect(noticeClosed, isFalse);
    expect(find.text('独立通知'), findsOneWidget);
    expect(find.text('时段计算结果', skipOffstage: false), findsNothing);
    _expectNoSchedulePrivate(tester);
    expect(fixture.requests, hasLength(1));
    expect(invocation.completed, isFalse);
    _capture(tester, '关闭通知')();
    await settle(tester);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    _capture(tester, '关闭')();
    await settle(tester);
    expect(invocation.completed, isTrue);
    expect(invocation.failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'schedule failures distinguish revoked access from reauthentication',
      (tester) async {
    for (final rejection in const {
      403: 'ACCESS_DENIED',
      409: 'WORKSPACE_CHANGED',
      401: 'REAUTH_REQUIRED',
    }.entries) {
      final fixture = _Fixture();
      var attempts = 0;
      fixture.respond = (_) async => ++attempts == 1
          ? reply({'errorCode': rejection.value}, rejection.key)
          : reply(_scheduleDecision());
      await _mount(tester, fixture);
      final invocation =
          _Invocation(fixture.actions.scheduleDetails(_schedule()));
      await settle(tester);
      final check = _capture(tester, '检查此刻是否允许');
      check();
      await settle(tester);
      if (rejection.value == 'REAUTH_REQUIRED') {
        expect(find.text('工作空间或权限已变化'), findsNothing);
        expect(find.text(_scheduleName), findsOneWidget);
        _capture(tester, '检查此刻是否允许')();
        await settle(tester);
        expect(fixture.requests, hasLength(2));
        expect(find.text('时段计算结果'), findsOneWidget);
      } else {
        expect(find.text('工作空间或权限已变化'), findsOneWidget);
        _expectNoSchedulePrivate(tester);
        check();
        await flush(tester);
        expect(fixture.requests, hasLength(1));
      }
      _capture(tester, '关闭')();
      await settle(tester);
      expect(invocation.completed, isTrue);
      expect(invocation.failure, isNull);
      expect(tester.takeException(), isNull);
    }
  });
}

void _expectNoEnabledPolicyActions(WidgetTester tester,
    {List<String> labels = const [
      '编辑草稿',
      '从模板创建策略',
      '预览与发布',
      '版本历史',
      '回滚为草稿',
    ]}) {
  for (final label in labels) {
    for (final button in tester.widgetList<ButtonStyleButton>(_button(label))) {
      expect(button.onPressed, isNull,
          reason: 'Invalid server projections cannot authorize $label.');
    }
  }
}

Json _contractVersion(_Fixture fixture) => {
      ...fixture.version(),
      'policyId': _policy,
      'draftRevision': 7,
      'previewHash': 'a' * 64,
      'sourceVersionId': null,
      'snapshot': {
        'schemaVersion': 1,
        'name': _name,
        'sourceRules': fixture.draft()['rules'],
        'applications': <Json>[],
        'schedules': <Json>[],
        'protectedPackageExemptions': <String>[],
        'targets': <Json>[],
      },
    };
