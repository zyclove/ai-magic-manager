@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_publication.dart';
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
import 'publication_test_journal.dart' show MemoryPublicationJournal;

const _policy = 'policy-private-a';
const _name = '原账户私有策略';
const _domain = 'private-policy.example';
const _copyName = '原账户私有策略 · 新副本';
const _version = 'version-private-a';
final _v4Key = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

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
  bool laterBranch = false;

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
          request.method == 'POST' &&
          request.url.path.endsWith('/policy-draft-changes')) {
        final body = jsonDecode(request.body) as Json;
        expect(body['operation'], 'UPDATE');
        expect(body['policyId'], _policy);
        expect(body['revision'], revision);
        expect(
            body.keys,
            unorderedEquals(
                ['operation', 'policyId', 'revision', 'name', 'rules']));
        expect(request.headers['If-Match'], isNull);
        expect(
            request.headers['Idempotency-Key'],
            matches(RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
        currentName = body['name'] as String;
        revision++;
        return reply({...draft(), 'rules': body['rules']});
      }
      if (fromList &&
          request.method == 'POST' &&
          request.url.path.endsWith(
              '/policies/$_policy/versions/$_version/rollback-drafts')) {
        currentName = (jsonDecode(request.body) as Json)['name'] as String;
        sourceVersionId = _version;
        revision++;
        return reply(draft());
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/policies/$_policy/copies')) {
        final value = branchReceipt(request);
        if (fromList) copied = value;
        return reply(value);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/query') &&
          (request.url.path.contains('/copy-results/') ||
              request.url.path.contains('/rollback-draft-results/'))) {
        final original = [...copies, ...rollbacks].singleWhere((original) =>
            request.url.path
                .endsWith('/${original.headers['Idempotency-Key']}/query'));
        expect(request.body, original.body);
        expect(request.headers['If-Match'], original.headers['If-Match']);
        expect(request.headers['Idempotency-Key'], isNull);
        final committed = branchReceipt(original);
        final current = laterBranch
            ? {
                ...committed,
                'revision': (committed['revision'] as int) + 2,
                'name': '后续修改后的草稿',
                'sourceVersionId': 'later-rollback-version'
              }
            : committed;
        final copy = original.url.path.endsWith('/copies');
        if (copy) {
          copied = current;
        } else {
          currentName = current['name'] as String;
          revision = current['revision'] as int;
          sourceVersionId = current['sourceVersionId'] as String?;
        }
        return reply({
          'requestId': original.headers['Idempotency-Key'],
          'operation': copy ? 'TEMPLATE_COPY' : 'ROLLBACK_DRAFT',
          'committed': committed,
          'current': current
        });
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

  Json branchReceipt(http.Request original) {
    final copy = original.url.path.endsWith('/copies');
    return {
      ...draft(),
      'id': copy ? 'copy-private-a' : _policy,
      'kind': copy ? 'POLICY' : draft()['kind'],
      'name': (jsonDecode(original.body) as Json)['name'],
      'revision': copy ? 0 : 8,
      'sourceVersionId': copy ? null : _version
    };
  }

  List<http.Request> get copies => requests
      .where((request) =>
          request.method == 'POST' &&
          request.url.path.endsWith('/policies/$_policy/copies'))
      .toList();

  List<http.Request> get rollbacks => requests
      .where((request) =>
          request.method == 'POST' &&
          request.url.path.endsWith(
              '/policies/$_policy/versions/$_version/rollback-drafts'))
      .toList();

  List<http.Request> get branchQueries => requests
      .where((request) =>
          request.method == 'POST' &&
          request.url.path.endsWith('/query') &&
          (request.url.path.contains('/copy-results/') ||
              request.url.path.contains('/rollback-draft-results/')))
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

class _PendingPreviewJournal extends MemoryPublicationJournal {
  final response = Completer<PublicationPending?>();
  int reads = 0;

  @override
  Future<PublicationPending?> read(PublicationOwner owner, String policyId) {
    reads++;
    return response.future;
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

bool _ready(WidgetTester tester, String label) {
  final button = _button(label);
  return button.evaluate().length == 1 &&
      tester.widget<ButtonStyleButton>(button).onPressed != null;
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
      'preview resource loss during journal read stops child work while its parent route stays active',
      (tester) async {
    final fixture = _Fixture();
    final journal = _PendingPreviewJournal();
    final changes = ValueNotifier<int>(0);
    var allowed = true;
    await _mount(tester, fixture);
    addTearDown(() {
      if (!journal.response.isCompleted) journal.response.complete(null);
      changes.dispose();
    });
    final context = tester.element(find.text('策略详情宿主'));
    final parent = ModalRoute.of(context)!;
    final tenant = fixture.session.tenant;
    final invocation = _Invocation(fixture.actions.previewPolicy(
        context, fixture.draft(),
        journal: journal, accessChanges: changes, hasAccess: () => allowed));
    await _waitUntil(tester, () => journal.reads == 1);
    expect(invocation.completed, isFalse);
    expect(parent.isActive, isTrue);
    expect(parent.isCurrent, isTrue);
    expect(fixture.requests, isEmpty);

    allowed = false;
    changes.value++;
    journal.response.complete(null);
    await _waitUntil(tester, () => invocation.completed);
    expect(invocation.failure, isNull);
    _expectSameScopeValues(fixture);
    expect(fixture.session.tenant, same(tenant));
    expect(parent.isActive, isTrue);
    expect(parent.isCurrent, isTrue);
    expect(find.text('策略详情宿主'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    _expectNoPrivate(tester);
    expect(fixture.requests, isEmpty,
        reason:
            'A late journal read cannot open the target picker or start preview HTTP after resource loss.');
    expect(fixture.session.previews, isEmpty);
    expect(fixture.session.publications, isEmpty);
    expect(tester.takeException(), isNull);
  });

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
    expect(sent.method, 'POST');
    expect(sent.url.path, '/api/v1/tenants/tenant-a/policy-draft-changes');
    expect(sent.headers['If-Match'], isNull);
    expect(
        sent.headers['Idempotency-Key'],
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    final body = jsonDecode(sent.body) as Json;
    expect(
        body.keys,
        unorderedEquals(
            ['operation', 'policyId', 'revision', 'name', 'rules']));
    expect(body['operation'], 'UPDATE');
    expect(body['policyId'], _policy);
    expect(body['revision'], 7);
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
    expect(sent.headers['Idempotency-Key'], matches(_v4Key));
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
    expect(sent.headers['Idempotency-Key'], matches(_v4Key));
    expect(jsonDecode(sent.body), {'name': _name});
    expect(fixture.sourceVersionId, _version);
    expect(fixture.listReads, hasLength(2));
  });

  testWidgets(
      'policy branch original-result queries confirm copies and rollbacks without replaying writes',
      (tester) async {
    for (final template in [true, false]) {
      final fixture = _Fixture(template: template)..laterBranch = true;
      fixture.respond = (request) async {
        if (request.method != 'POST') return null;
        if (request.url.path.endsWith('/copies') ||
            request.url.path.endsWith('/rollback-drafts')) {
          return reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 408);
        }
        if (request.url.path.endsWith('/query')) {
          if (fixture.branchQueries.length == 1) {
            return reply(
                {'errorCode': 'POLICY_BRANCH_RESULT_UNAVAILABLE'}, 404);
          }
          if (fixture.branchQueries.length == 2) {
            return reply({'errorCode': 'REAUTH_REQUIRED'}, 401);
          }
        }
        return null;
      };
      final details = await _openFromList(tester, fixture);
      if (template) {
        _capture(tester, '从模板创建策略')();
        await _waitUntil(tester, () => _ready(tester, '保存'));
      } else {
        _capture(tester, '版本历史')();
        await _waitUntil(
            tester, () => find.text('版本 98731').evaluate().length == 1);
        await tester.tap(find.text('版本 98731'));
        await _waitUntil(tester, () => _ready(tester, '回滚为草稿'));
        _capture(tester, '回滚为草稿')();
        await _waitUntil(tester, () => _ready(tester, '确认'));
        expect(
            tester
                .widget<TextFormField>(find.byType(TextFormField))
                .controller!
                .text,
            _name);
      }
      final name = template ? _copyName : '恢复历史规则后的草稿';
      await tester.enterText(find.byType(TextFormField), name);
      final heldSubmit = _capture(tester, template ? '保存' : '确认');
      heldSubmit();
      await _waitUntil(
          tester,
          () =>
              fixture.copies.length + fixture.rollbacks.length == 1 &&
              _ready(tester, '查询原保存结果'));
      final original = [...fixture.copies, ...fixture.rollbacks].single;
      final key = original.headers['Idempotency-Key'];
      expect(key, matches(_v4Key));
      expect(original.headers['If-Match'], '"7"');
      expect(jsonDecode(original.body), {'name': name});
      fixture.currentName = '当前草稿的后续名称';
      for (var query = 1; query <= 2; query++) {
        (query == 1 ? _capture(tester, '查询原保存结果') : heldSubmit)();
        await _waitUntil(
            tester,
            () =>
                fixture.branchQueries.length == query &&
                _ready(tester, '查询原保存结果'));
        final field = tester.widget<TextFormField>(find.byType(TextFormField));
        expect(field.controller!.text, name);
        expect(field.enabled, isFalse);
        expect(fixture.copies.length + fixture.rollbacks.length, 1);
        expect(fixture.listReads, hasLength(1));
        expect(details.available, isTrue);
      }
      _capture(tester, '查询原保存结果')();
      await _waitUntil(
          tester,
          () =>
              fixture.branchQueries.length == 3 &&
              fixture.listReads.length == 2 &&
              !details.available);
      for (final query in fixture.branchQueries) {
        expect(
            query.url.path,
            template
                ? '/api/v1/tenants/tenant-a/policies/$_policy/copy-results/$key/query'
                : '/api/v1/tenants/tenant-a/policies/$_policy/versions/$_version/rollback-draft-results/$key/query');
        expect(query.body, original.body);
        expect(query.headers['If-Match'], original.headers['If-Match']);
        expect(query.headers['Idempotency-Key'], isNull);
      }
      expect(fixture.copies, hasLength(template ? 1 : 0));
      expect(fixture.rollbacks, hasLength(template ? 0 : 1));
      expect(fixture.listReads, hasLength(2));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('后续修改后的草稿'), findsOneWidget);
      expect(find.textContaining('原操作已核对，草稿已有后续修改'), findsOneWidget);
      expect(template ? fixture.copied!['revision'] : fixture.revision,
          template ? 2 : 10);
      expect(
          template
              ? fixture.copied!['sourceVersionId']
              : fixture.sourceVersionId,
          'later-rollback-version');
      expect(tester.takeException(), isNull);
    }
  }, tags: 'policy-draft-results');

  testWidgets(
      'policy-return unknown copy survives MFA and closes only for review',
      (tester) async {
    final fixture = _Fixture(template: true);
    fixture.respond = (request) async {
      if (request.method != 'POST') return null;
      if (request.url.path.endsWith('/policies/$_policy/copies')) {
        return reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503);
      }
      if (request.url.path.contains('/copy-results/')) {
        return fixture.branchQueries.length == 1
            ? reply({'errorCode': 'REAUTH_REQUIRED'}, 401)
            : reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 408);
      }
      return null;
    };
    final details = await _openFromList(tester, fixture);
    _capture(tester, '从模板创建策略')();
    await _waitUntil(tester, () => find.text('复制为策略').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextFormField), _copyName);
    _capture(tester, '保存')();
    await _waitUntil(
        tester, () => fixture.copies.length == 1 && _ready(tester, '查询原保存结果'));
    final original = fixture.copies.single;
    _capture(tester, '查询原保存结果')();
    await _waitUntil(tester,
        () => fixture.branchQueries.length == 1 && _ready(tester, '重新安全验证'));
    var field = tester.widget<TextFormField>(find.byType(TextFormField));
    expect(field.controller!.text, _copyName);
    expect(field.enabled, isFalse);
    expect(_button('查询原保存结果'), findsOneWidget);
    _capture(tester, '重新安全验证')();
    await _waitUntil(tester, () => fixture.session.securityChecks == 1);
    expect(fixture.branchQueries, hasLength(1),
        reason: 'MFA does not query or submit automatically.');
    expect(fixture.copies, hasLength(1));
    _capture(tester, '查询原保存结果')();
    await _waitUntil(tester,
        () => fixture.branchQueries.length == 2 && _ready(tester, '查询原保存结果'));
    field = tester.widget<TextFormField>(find.byType(TextFormField));
    expect(field.controller!.text, _copyName);
    expect(field.enabled, isFalse);
    for (final query in fixture.branchQueries) {
      expect(query.headers['Idempotency-Key'], isNull);
      expect(query.headers['If-Match'], original.headers['If-Match']);
      expect(query.body, original.body);
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
    expect(fixture.copies, hasLength(1));
    expect(fixture.branchQueries, hasLength(2));
    expect(find.text(_copyName), findsNothing);
    expect(find.textContaining('保存成功'), findsNothing);
    expect(fixture.listReads, hasLength(2));
  }, tags: 'policy-draft-results');

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
      'dispatched policy writes review once on close and actor loss blocks stale review under a cover',
      (tester) async {
    void expectOldDialogsRedacted() {
      final dialogs = find.byType(AlertDialog, skipOffstage: false);
      for (final secret in [_name, _domain, _policy, _version, '版本 98731']) {
        expect(
            find.descendant(
                of: dialogs,
                matching: find.textContaining(secret, skipOffstage: false),
                skipOffstage: false),
            findsNothing);
        for (final field in tester.widgetList<TextFormField>(
            find.byType(TextFormField, skipOffstage: false))) {
          expect(field.controller?.text ?? '', isNot(contains(secret)));
        }
      }
    }

    for (final operation in [
      'template-copy',
      'rollback',
      'edit',
      'template-copy-actor-aba'
    ]) {
      final copying = operation.startsWith('template-copy');
      final editing = operation == 'edit';
      final actorABA = operation == 'template-copy-actor-aba';
      final expectedListReads = actorABA ? 1 : 2;
      final fixture = _Fixture(template: copying);
      final response = Completer<http.Response>();
      Json? lateReceipt;
      var transportReturned = false, coverClosed = false;
      fixture.respond = (request) async {
        if (request.method != 'POST' ||
            !(editing
                ? request.url.path.endsWith('/policy-draft-changes')
                : request.url.path
                    .endsWith(copying ? '/copies' : '/rollback-drafts'))) {
          return null;
        }
        final body = jsonDecode(request.body) as Json;
        final committed = editing
            ? {
                ...fixture.draft(),
                'name': body['name'],
                'revision': (body['revision'] as int) + 1,
                'rules': body['rules'],
              }
            : fixture.branchReceipt(request);
        lateReceipt = committed;
        if (copying) {
          fixture.copied = committed;
        } else {
          fixture.currentName = committed['name'] as String;
          fixture.revision = committed['revision'] as int;
          fixture.sourceVersionId = committed['sourceVersionId'] as String?;
        }
        final result = await response.future;
        transportReturned = true;
        return result;
      };
      addTearDown(() {
        if (!response.isCompleted) {
          response.complete(reply(lateReceipt ?? fixture.draft()));
        }
      });
      final details = await _openFromList(tester, fixture);
      if (editing) {
        _capture(tester, '编辑草稿')();
        await _waitUntil(
            tester, () => find.byType(PolicyEditor).evaluate().isNotEmpty);
      } else if (copying) {
        _capture(tester, '从模板创建策略')();
        await _waitUntil(
            tester,
            () => find
                .byKey(const Key('policy-copy-form'))
                .evaluate()
                .isNotEmpty);
      } else {
        _capture(tester, '版本历史')();
        await _waitUntil(
            tester, () => find.text('版本 98731').evaluate().length == 1);
        await tester.tap(find.text('版本 98731'));
        await _waitUntil(tester, () => _ready(tester, '回滚为草稿'));
        _capture(tester, '回滚为草稿')();
        await _waitUntil(
            tester,
            () => find
                .byKey(const Key('policy-rollback-form'))
                .evaluate()
                .isNotEmpty);
      }
      final field = editing
          ? find.widgetWithText(TextFormField, '策略名称')
          : find.byType(TextFormField);
      final name = '派发后需核对的${operation}草稿';
      await tester.enterText(field, name);
      final submit = editing
          ? '保存草稿'
          : copying
              ? '保存'
              : '确认';
      await _waitUntil(tester, () => _ready(tester, submit));
      _capture(tester, submit)();
      await _waitUntil(
          tester, () => fixture.writes.length == 1 && lateReceipt != null);
      expect(response.isCompleted, isFalse,
          reason: 'The write has entered transport and still has no response.');
      final sent = fixture.writes.single;
      final body = jsonDecode(sent.body) as Json;
      expect(sent.headers['Idempotency-Key'], matches(_v4Key));
      if (editing) {
        expect(body, {
          'operation': 'UPDATE',
          'policyId': _policy,
          'revision': 7,
          'name': name,
          'rules': fixture.draft()['rules'],
        });
        expect(sent.headers['If-Match'], isNull);
      } else {
        expect(body, {'name': name});
        expect(sent.headers['If-Match'], '"7"');
      }
      unawaited(showDialog<void>(
              context: tester.element(field),
              builder: (context) => AlertDialog(
                      title: const Text('独立核对提示'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('关闭独立提示'))
                      ]))
          .then<void>((_) {
        coverClosed = true;
      }));
      await _waitUntil(
          tester, () => find.text('独立核对提示').evaluate().isNotEmpty);
      final cover = ModalRoute.of(tester.element(find.text('独立核对提示')))!;
      if (actorABA) {
        fixture.session.awayAndBack('actor');
      }
      details.finish();
      await _waitUntil(
          tester,
          () =>
              !details.available &&
              fixture.listReads.length == expectedListReads);
      _expectSameScopeValues(fixture);
      expect(response.isCompleted, isFalse);
      expect(fixture.writes, hasLength(1));
      if (actorABA) {
        expectOldDialogsRedacted();
        expect(find.textContaining(name, skipOffstage: false), findsNothing);
      } else {
        final list = find.byType(ResourcePage, skipOffstage: false);
        expect(
            find.descendant(
                of: list,
                matching: find.text(name, skipOffstage: false),
                skipOffstage: false),
            findsOneWidget);
        expect(
            find.descendant(
                of: list,
                matching:
                    find.text(copying ? 'v0' : 'v8', skipOffstage: false),
                skipOffstage: false),
            findsOneWidget);
      }
      expect(coverClosed, isFalse);
      expect(cover.isCurrent, isTrue);

      response.complete(reply(lateReceipt!));
      await _waitUntil(tester, () => transportReturned);
      await flush(tester);
      expect(fixture.writes, hasLength(1));
      expect(fixture.listReads, hasLength(expectedListReads),
          reason: 'The late response must not request another list review.');
      expect(coverClosed, isFalse);
      expect(cover.isCurrent, isTrue);
      expect(find.text('独立核对提示'), findsOneWidget);
      expect(find.textContaining('保存成功', skipOffstage: false), findsNothing);
      if (actorABA) {
        expectOldDialogsRedacted();
        expect(find.textContaining(name, skipOffstage: false), findsNothing);
      }
      expect(tester.takeException(), isNull);
    }
  }, tags: 'policy-dispatch-review');

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
      fixture.respond = (request) async => request.method == 'POST' &&
              request.url.path.endsWith('/policy-draft-changes')
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
      final original = fixture.writes.single;
      expect(original.method, 'POST');
      expect(
          original.url.path, '/api/v1/tenants/tenant-a/policy-draft-changes');
      expect(original.headers['If-Match'], isNull);
      expect(
          original.headers['Idempotency-Key'],
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      final body = jsonDecode(original.body) as Json;
      expect(body['operation'], 'UPDATE');
      expect(body['policyId'], _policy);
      expect(body['revision'], 7);
      expect(body['name'], stoppedName);
      expect(find.byType(TextFormField), findsNothing);
      expect(_button('保存草稿'), findsNothing);
      expect(_button('按原内容恢复'), findsNothing);
      expect(_button('查询原保存结果'), findsNothing);
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
    expect(sent.headers['Idempotency-Key'], matches(_v4Key));
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
        'copy 201 $description retains original name and key until original-result query',
        (tester) async {
      final fixture = _Fixture(template: true);
      fixture.respond = (request) async {
        if (request.method != 'POST' ||
            !request.url.path.endsWith('/policies/$_policy/copies')) {
          return null;
        }
        return http.Response(jsonEncode(invalid), 201,
            headers: {'content-type': 'application/json; charset=utf-8'});
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
      expect(original.headers['Idempotency-Key'], matches(_v4Key));
      expect(jsonDecode(original.body), {'name': _copyName});

      _capture(tester, '查询原保存结果')();
      await settle(tester);

      expect(fixture.copies, hasLength(1));
      expect(fixture.branchQueries, hasLength(1));
      final query = fixture.branchQueries.single;
      expect(query.headers['Idempotency-Key'], isNull);
      expect(query.headers['If-Match'], original.headers['If-Match']);
      expect(query.body, original.body);
      expect(invocation.completed, isTrue);
      expect(invocation.failure, isNull);
      expect(tester.takeException(), isNull);
    }, tags: 'policy-draft-results');
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
