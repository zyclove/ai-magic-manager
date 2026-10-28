@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/console_routes.dart';
import 'package:guardian/core/labels.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/pages/help_requests_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:guardian/ui/resource_page.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'device_management_entry_test.dart' show EntrySession, settleReads;

const _approvalId = '11111111-1111-4111-8111-111111111111';
const _applicationId = '66666666-6666-4666-8666-666666666666';
const _registrationId = '77777777-7777-4777-8777-777777777777';
const _documentId = '88888888-8888-4888-8888-888888888888';
const _olderDocumentId = '99999999-9999-4999-8999-999999999999';
const _helpId = '22222222-2222-4222-8222-222222222222';

http.Response _reply(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

Json _approval(String state, {int requestedSeconds = 60}) => {
      'id': _approvalId,
      'state': state,
      'requestedWindowSeconds': requestedSeconds,
      'reason': '查看学习资料',
      'requestExpiresAt': 2000000000000,
      'deviceId': '33333333-3333-4333-8333-333333333333',
      'subjectId': '44444444-4444-4444-8444-444444444444',
      'applicationId': _applicationId,
      'registrationId': _registrationId,
      'absoluteNotAfter': null,
      'executionState': 'NOT_ENFORCED',
      'version': 3,
    };

Json _help({bool acknowledged = false}) => {
      'id': _helpId,
      'subjectId': '33333333-3333-4333-8333-333333333333',
      'subjectNickname': '示例儿童',
      'deviceId': '44444444-4444-4444-8444-444444444444',
      'clientRequestId': '55555555-5555-4555-8555-555555555555',
      'reasonCode': 'NEED_HELP',
      'state': acknowledged ? 'ACKNOWLEDGED' : 'OPEN',
      'createdAt': 1000,
      'acknowledgedAt': acknowledged ? 2000 : null,
      'version': acknowledged ? 1 : 0,
    };

// Deliver browser HTTP events without waiting for a deliberately pending
// request's progress indicator to stop animating.
Future<void> _flushPending(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _waitUntil(WidgetTester tester, bool Function() done) async {
  for (var frame = 0; frame < 40 && !done(); frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue, reason: 'The browser journey did not finish in time.');
}

Finder _helpButton(String text) => find.ancestor(
    of: find.text(text),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

Future<void> _openHelpConfirmation(WidgetTester tester) async {
  final open = _helpButton('确认已看到');
  await tester.ensureVisible(open);
  await tester.tap(open);
  await _flushPending(tester);
  expect(find.text('确认已看到求助'), findsOneWidget);
}

class _ApprovalFixture {
  _ApprovalFixture(this.action,
      {this.requestedSeconds = 60, this.listRow,
      this.documentAppend, this.attemptRead});

  final String action;
  final int requestedSeconds;
  final Json? listRow;
  final Future<http.Response>? documentAppend, attemptRead;
  int listReads = 0, deliveryReads = 0;
  final documentReads = <http.Request>[];
  final attemptReads = <http.Request>[];
  final pending = Completer<http.Response>();
  final posts = <http.Request>[];
  late BuildContext host;
  bool detailsCompleted = false;
  bool? needsReview;
  late final session = EntrySession((request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/access-requests')) {
      listReads++;
      return _reply({
        'items': [listRow ?? _approval(
            action == '撤销批准' ? 'APPROVED_PENDING_DELIVERY' : 'PENDING',
            requestedSeconds: requestedSeconds)],
        'nextCursor': null,
      });
    }
    if (request.method == 'GET' && path.endsWith('/$_approvalId')) {
      return _reply(_approval(
          action == '撤销批准' ? 'APPROVED_PENDING_DELIVERY' : 'PENDING',
          requestedSeconds: requestedSeconds));
    }
    if (request.method == 'GET' && path.endsWith('/$_approvalId/delivery')) {
      deliveryReads++;
      return _reply({
        'approvalVersion': 3,
        'action': 'CONFIGURE_ONLY',
        'deliveryState': 'NOT_ISSUED',
        'deliveryAttempt': null,
        'receivedAt': null,
      });
    }
    if (request.method == 'GET' && path.endsWith('/documents')) {
      documentReads.add(request);
      final first = !request.url.queryParameters.containsKey('cursor');
      if (!first) {
        expect(request.url.queryParameters['cursor'], _documentId);
        if (documentAppend != null) return documentAppend!;
      }
      return _reply({
        'items': [{
          'documentId': first ? _documentId : _olderDocumentId,
          'approvalVersion': first ? 3 : 2,
          'action': 'CONFIGURE_ONLY',
          'deliveryState': 'NOT_ISSUED',
          'deliveryAttempt': null,
          'current': first,
          'documentIssuedAt': 1700000000000,
          'receivedAt': null,
        }],
        'nextCursor': first ? _documentId : null,
      });
    }
    if (request.method == 'GET' && path.endsWith('/attempts')) {
      attemptReads.add(request);
      if (attemptRead != null) return attemptRead!;
      return _reply({
        'items': [{
          'deliveryAttempt': 1,
          'deliveryState': 'NOT_FETCHED',
          'reasonCode': null,
          'current': true,
          'createdAt': 1700000000000,
          'receivedAt': null,
        }],
        'nextCursor': null,
      });
    }
    if (request.method == 'POST' &&
        path.endsWith('/$_approvalId/${action == '撤销批准' ? 'revoke' : 'decisions'}')) {
      posts.add(request);
      return pending.future;
    }
    throw StateError('Unexpected approval fixture request.');
  });

  Future<void> open(WidgetTester tester,
      {bool openAction = true, bool throughConsole = false}) async {
    addTearDown(() async {
      if (!pending.isCompleted) pending.complete(_reply({'id': _approvalId}));
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReads(tester);
      session.transport.close();
      session.dispose();
    });
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(body: Builder(builder: (context) {
          host = context;
          return throughConsole
              ? ChangeNotifierProvider<Session>.value(
                  value: session,
                  child: const SingleChildScrollView(
                      child: ConsolePages(section: 'approvals',
                          listView: ConsoleListView.all)))
              : TextButton(
              onPressed: () => ConsoleActions(context, session)
                  .approvalDetailsChanged(listRow ?? {'id': _approvalId})
                  .then((changed) {
                    needsReview = changed;
                    detailsCompleted = true;
                  }),
              child: const Text('打开申请'));
        }))));
    if (throughConsole) {
      await _waitUntil(tester, () => _helpButton('查看详情').evaluate().isNotEmpty);
      expect(listReads, 1);
      final open = _helpButton('查看详情');
      await tester.ensureVisible(open);
      await tester.tap(open);
    } else {
      await tester.tap(find.text('打开申请'));
    }
    await settleReads(tester);
    expect(find.text('临时访问申请'), findsOneWidget);
    expect(deliveryReads, action == '撤销批准' ? 1 : 0);
    if (openAction) {
      await tester.tap(find.widgetWithText(OutlinedButton, action));
      await settleReads(tester);
    }
  }

  Future<void> submit(WidgetTester tester) async {
    if (action == '拒绝') {
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('当前不合适').last);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.widgetWithText(
        FilledButton, action == '撤销批准' ? '确认' : '保存'));
    await _flushPending(tester);
    expect(posts, hasLength(1));
    expect(posts.single.headers['if-match'], '"3"');
    expect(posts.single.headers['idempotency-key'], isNotEmpty);
  }

  void succeed() => pending.complete(_reply({
        'id': _approvalId,
        'version': 4,
        'state': action == '批准'
            ? 'APPROVED_PENDING_DELIVERY'
            : action == '拒绝'
                ? 'DENIED'
                : 'REVOKED',
      }));
}

Future<void> _checkApprovalHistoryRetirement(
    WidgetTester tester, _ApprovalFixture original) async {
  for (final reason in ['parent close', 'actor ABA']) {
    final fixture = reason == 'parent close'
        ? original : _ApprovalFixture('撤销批准');
    if (reason == 'actor ABA') {
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReads(tester);
      await fixture.open(tester, openAction: false);
    }
    final details = ModalRoute.of(
        tester.element(find.text('临时访问申请')))! as OwnedDialogRoute<void>;
    await tester.tap(_helpButton('交付历史'));
    await settleReads(tester);
    final history = find.byKey(const Key('approval-delivery-history'));
    final resource = find.descendant(
        of: history, matching: find.byType(ResourcePage));
    final state = tester.state<ResourcePageState>(resource);
    final more = find.descendant(of: history, matching: _helpButton('加载更多'));
    await tester.ensureVisible(more);
    await tester.tap(more);
    await settleReads(tester);
    expect(fixture.documentReads, hasLength(2));
    final search = find.descendant(
        of: history, matching: find.byType(TextField));
    await tester.enterText(search, _documentId);
    await tester.pump();

    Future<void> openAttempt() async {
      final view = find.descendant(
          of: history, matching: _helpButton('查看详情'));
      await tester.ensureVisible(view);
      await tester.tap(view);
      await settleReads(tester);
    }

    await openAttempt();
    final attempts = find.byKey(const Key('approval-attempt-history'));
    final close = find.descendant(of: attempts, matching: _helpButton('关闭'));
    await tester.ensureVisible(close);
    await tester.tap(close);
    await settleReads(tester);
    expect(fixture.documentReads, hasLength(2),
        reason: 'A read-only attempt history must retain document pages.');
    expect(tester.state<ResourcePageState>(resource), same(state));
    expect(tester.widget<TextField>(search).controller!.text, _documentId);
    expect(find.text('已加载 2 条 · 匹配 1 条'), findsOneWidget);
    await openAttempt();
    final cover = DialogRoute<void>(
        context: fixture.host,
        builder: (_) => const AlertDialog(title: Text('独立通知')));
    unawaited(Navigator.of(fixture.host, rootNavigator: true).push<void>(cover));
    await _flushPending(tester);
    if (reason == 'parent close') {
      details.finish();
    } else {
      final actor = fixture.session.profile;
      fixture.session.profile = {'subject': 'other-adult'};
      fixture.session.changed();
      fixture.session.profile = actor;
      fixture.session.changed();
    }
    await _flushPending(tester);
    expect(cover.isCurrent, isTrue);
    expect(find.text('独立通知'), findsOneWidget);
    expect(find.byKey(const Key('approval-delivery-history'),
        skipOffstage: false), findsNothing);
    expect(find.byKey(const Key('approval-attempt-history'),
        skipOffstage: false), findsNothing);
    expect(find.text(_approvalId, skipOffstage: false), findsNothing);
    expect(fixture.documentReads, hasLength(2));
    expect(fixture.attemptReads, hasLength(2));
    expect(fixture.posts, isEmpty);
    details.finish();
    await _flushPending(tester);
    expect(fixture.needsReview, isFalse);
    Navigator.of(fixture.host, rootNavigator: true).removeRoute(cover);
    await settleReads(tester);
    expect(tester.takeException(), isNull);
  }
}

class _HelpFixture {
  _HelpFixture({this.initialPending = false, this.listRead});

  final bool initialPending;
  final FutureOr<http.Response> Function(http.Request, int)? listRead;
  final pending = Completer<http.Response>();
  int reads = 0, acknowledgements = 0;
  late final session = EntrySession((request) async {
    if (request.method == 'GET' &&
        request.url.path.endsWith('/help-requests')) {
      reads++;
      final read = listRead;
      if (read != null) return await read(request, reads);
      if (initialPending) return pending.future;
      return _reply({'items': [_help()], 'nextCursor': null});
    }
    if (request.method == 'POST' &&
        request.url.path.endsWith('/$_helpId/acknowledge')) {
      acknowledgements++;
      expect(request.headers['if-match'], '"0"');
      return pending.future;
    }
    throw StateError('Unexpected help fixture request.');
  });

  Future<void> mount(WidgetTester tester, {bool throughConsole = false}) async {
    addTearDown(() async {
      if (!pending.isCompleted) {
        pending.complete(initialPending
            ? _reply({'items': [_help()], 'nextCursor': null})
            : _reply(_help(acknowledged: true)));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReads(tester);
      session.transport.close();
      session.dispose();
    });
    final page = throughConsole
        ? ChangeNotifierProvider<Session>.value(
            value: session,
            child: const ConsolePages(section: 'help-requests'))
        : HelpRequestsPage(session: session);
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(child: page))));
    await _flushPending(tester);
    expect(reads, 1);
  }
}

void main() {
  for (final retireScope in [false, true]) {
    testWidgets('access creation preserves an independent cover on '
        '${retireScope ? 'actor retirement' : 'success'}', (tester) async {
      const deviceId = '33333333-3333-4333-8333-333333333333';
      const policyId = '55555555-5555-4555-8555-555555555555';
      const versionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const ruleId = 'draw-rule';
      final pending = Completer<http.Response>();
      final reads = <http.Request>[];
      final posts = <http.Request>[];
      final session = EntrySession((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path.endsWith('/devices')) {
          reads.add(request);
          return _reply({
            'items': [{
              'id': deviceId,
              'displayName': '学习平板',
              'state': 'ACTIVE',
            }],
            'nextCursor': null,
          });
        }
        if (request.method == 'GET' &&
            path.endsWith('/access-requests/options')) {
          reads.add(request);
          expect(request.url.queryParameters['deviceId'], deviceId);
          return _reply({
            'items': [{
              'id': policyId,
              'name': '学习策略',
              'baseVersionId': versionId,
              'commonRules': [],
              'applications': [{
                'id': _applicationId,
                'displayName': '绘画应用',
                'rules': [{'id': ruleId, 'kind': 'APP_LAUNCH'}],
              }],
            }],
            'nextCursor': null,
          });
        }
        if (request.method == 'POST' && path.endsWith('/access-requests')) {
          posts.add(request);
          return pending.future;
        }
        throw StateError('Unexpected access creation request.');
      })..role = 'CHILD';
      late BuildContext host;
      bool? needsReview;
      addTearDown(() async {
        if (!pending.isCompleted) pending.complete(_reply({'id': _approvalId}));
        await tester.pumpWidget(const SizedBox.shrink());
        await settleReads(tester);
        session.transport.close();
        session.dispose();
      });
      await tester.pumpWidget(MaterialApp(
          theme: consoleTheme(),
          home: Scaffold(body: Builder(builder: (context) {
            host = context;
            return TextButton(
                onPressed: () => ConsoleActions(context, session)
                    .createAccessRequestChanged()
                    .then((changed) => needsReview = changed),
                child: const Text('打开申请'));
          }))));
      await tester.tap(find.text('打开申请'));
      await settleReads(tester);
      Future<void> choose(Key key, String text) async {
        final field = find.byKey(key);
        await tester.ensureVisible(field);
        await tester.tap(field);
        await settleReads(tester);
        await tester.tap(find.text(text).last);
        await settleReads(tester);
      }
      await choose(const Key('request-device'), '学习平板 · 33333333…');
      await choose(const ValueKey('option-$deviceId'), '绘画应用 · 学习策略');
      await tester.enterText(find.byKey(const Key('request-minutes')), '2');
      final submit = _helpButton('提交申请');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await _flushPending(tester);
      expect(reads, hasLength(2));
      expect(posts, hasLength(1));
      expect(posts.single.headers['idempotency-key'], isNotEmpty);
      expect(jsonDecode(posts.single.body), {
        'deviceId': deviceId,
        'policyId': policyId,
        'baseVersionId': versionId,
        'applicationId': _applicationId,
        'ruleIds': [ruleId],
        'requestedWindowSeconds': 120,
        'reason': null,
      });
      expect(needsReview, isNull);
      final cover = DialogRoute<void>(context: host,
          builder: (_) => const AlertDialog(title: Text('独立通知')));
      unawaited(Navigator.of(host, rootNavigator: true).push<void>(cover));
      await _flushPending(tester);
      if (retireScope) {
        final actor = session.profile;
        session.profile = {'subject': 'other-child'};
        session.changed();
        session.profile = actor;
        session.changed();
        await _flushPending(tester);
      }
      pending.complete(_reply({'id': _approvalId}));
      await settleReads(tester);
      expect(cover.isCurrent, isTrue);
      expect(find.text('独立通知'), findsOneWidget);
      expect(find.text('申请临时访问', skipOffstage: false), findsNothing);
      expect(needsReview, !retireScope);
      expect(posts, hasLength(1));
      expect(reads, hasLength(2));
      Navigator.of(host, rootNavigator: true).removeRoute(cover);
      await settleReads(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('approval keeps named context and validates exact total before POST',
      (tester) async {
    final fixture = _ApprovalFixture('批准', requestedSeconds: 90, listRow: {
      ..._approval('PENDING'),
      'subjectName': '示例儿童',
      'deviceName': '学习平板',
      'applicationName': '绘画应用',
      'applicationPackageName': 'com.example.draw',
    });
    await fixture.open(tester, openAction: false);
    for (final value in ['示例儿童', '学习平板', '绘画应用',
      'com.example.draw', _applicationId,
      '33333333-3333-4333-8333-333333333333',
      '44444444-4444-4444-8444-444444444444']) {
      expect(find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == value),
          findsOneWidget);
    }
    expect(find.byWidgetPredicate((widget) => widget is SelectableText &&
        widget.data == '1 分钟 30 秒'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '批准'));
    await settleReads(tester);
    final minutes = find.byWidgetPredicate((widget) => widget is TextField &&
        widget.decoration?.labelText == '分钟');
    final seconds = find.byWidgetPredicate((widget) => widget is TextField &&
        widget.decoration?.labelText == '秒');
    expect(tester.widget<TextField>(minutes).controller!.text, '1');
    expect(tester.widget<TextField>(seconds).controller!.text, '30');
    await tester.enterText(seconds, '31');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await settleReads(tester);
    expect(fixture.posts, isEmpty);
    expect(find.text('批准时长不能超过申请时长。'), findsOneWidget);
    expect(tester.widget<TextField>(minutes).enabled, isTrue);
    await tester.enterText(minutes, '0');
    await tester.enterText(seconds, '45');
    await fixture.submit(tester);
    expect(jsonDecode(fixture.posts.single.body),
        {'decision': 'APPROVE', 'grantedWindowSeconds': 45});
    expect(fixture.deliveryReads, 0);
    fixture.succeed();
    await settleReads(tester);
    expect(fixture.detailsCompleted, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('document read denial retires covered histories and reviews approvals once',
      (tester) async {
    final append = Completer<http.Response>();
    final fixture = _ApprovalFixture('撤销批准', documentAppend: append.future);
    addTearDown(() {
      if (!append.isCompleted) {
        append.complete(_reply({'items': [], 'nextCursor': null}));
      }
    });
    await fixture.open(tester, openAction: false, throughConsole: true);
    final generation = fixture.session.scopeGeneration;
    await tester.tap(_helpButton('交付历史'));
    final history = find.byKey(const Key('approval-delivery-history'));
    await _waitUntil(tester, () => fixture.documentReads.length == 1 &&
        find.descendant(of: history, matching: _helpButton('查看详情'))
            .evaluate().isNotEmpty);
    final more = find.descendant(of: history, matching: _helpButton('加载更多'));
    final oldMore = tester.widget<OutlinedButton>(more).onPressed!;
    await tester.ensureVisible(more);
    await tester.tap(more);
    await _waitUntil(tester, () => fixture.documentReads.length == 2);
    final open = find.descendant(of: history, matching: _helpButton('查看详情'));
    await tester.ensureVisible(open);
    await tester.tap(open);
    await _waitUntil(tester, () => fixture.attemptReads.length == 1 &&
        find.text('第 1 次').evaluate().isNotEmpty);
    final attempts = find.byKey(const Key('approval-attempt-history'));
    final oldClose = tester.widget<TextButton>(find.descendant(
        of: attempts, matching: _helpButton('关闭'))).onPressed!;
    final cover = DialogRoute<void>(
        context: fixture.host,
        builder: (_) => const AlertDialog(title: Text('独立通知')));
    final navigator = Navigator.of(fixture.host, rootNavigator: true);
    unawaited(navigator.push<void>(cover));
    await _waitUntil(tester,
        () => cover.animation?.status == AnimationStatus.completed);
    append.complete(_reply({'errorCode': 'SCOPE_DENIED'}, 403));
    await _waitUntil(tester, () => fixture.listReads == 2 &&
        find.byKey(const Key('approval-delivery-history'),
            skipOffstage: false).evaluate().isEmpty &&
        find.byKey(const Key('approval-attempt-history'),
            skipOffstage: false).evaluate().isEmpty &&
        find.text('临时访问申请', skipOffstage: false).evaluate().isEmpty);
    oldMore();
    oldClose();
    await _flushPending(tester);
    expect(fixture.listReads, 2);
    expect(fixture.documentReads, hasLength(2));
    expect(fixture.attemptReads, hasLength(1));
    expect(fixture.posts, isEmpty);
    expect(fixture.session.scopeGeneration, generation);
    expect(cover.isCurrent, isTrue);
    expect(find.text('独立通知'), findsOneWidget);
    navigator.removeRoute(cover);
    await _flushPending(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('attempt read denial reviews documents once and retains request details',
      (tester) async {
    final pendingAttempt = Completer<http.Response>();
    final fixture = _ApprovalFixture('撤销批准', attemptRead: pendingAttempt.future);
    addTearDown(() {
      if (!pendingAttempt.isCompleted) {
        pendingAttempt.complete(_reply({'items': [], 'nextCursor': null}));
      }
    });
    await fixture.open(tester, openAction: false, throughConsole: true);
    final generation = fixture.session.scopeGeneration;
    await tester.tap(_helpButton('交付历史'));
    final history = find.byKey(const Key('approval-delivery-history'));
    await _waitUntil(tester, () => fixture.documentReads.length == 1 &&
        find.descendant(of: history, matching: _helpButton('查看详情'))
            .evaluate().isNotEmpty);
    final open = find.descendant(of: history, matching: _helpButton('查看详情'));
    await tester.ensureVisible(open);
    await tester.tap(open);
    await _waitUntil(tester, () => fixture.attemptReads.length == 1);
    final cover = DialogRoute<void>(
        context: fixture.host,
        builder: (_) => const AlertDialog(title: Text('独立通知')));
    final navigator = Navigator.of(fixture.host, rootNavigator: true);
    unawaited(navigator.push<void>(cover));
    await _waitUntil(tester,
        () => cover.animation?.status == AnimationStatus.completed);
    pendingAttempt.complete(_reply({'errorCode': 'SCOPE_DENIED'}, 403));
    await _waitUntil(tester, () => fixture.documentReads.length == 2 &&
        find.byKey(const Key('approval-attempt-history'),
            skipOffstage: false).evaluate().isEmpty);
    await _flushPending(tester);
    expect(find.byKey(const Key('approval-delivery-history'),
        skipOffstage: false), findsOneWidget);
    expect(find.text('临时访问申请', skipOffstage: false), findsOneWidget);
    expect(fixture.listReads, 1);
    expect(fixture.documentReads, hasLength(2));
    expect(fixture.attemptReads, hasLength(1));
    expect(fixture.session.scopeGeneration, generation);
    expect(cover.isCurrent, isTrue);
    expect(find.text('独立通知'), findsOneWidget);
    navigator.removeRoute(cover);
    await _flushPending(tester);
    await tester.tap(find.descendant(of: history, matching: _helpButton('关闭')));
    await _waitUntil(tester, () => history.evaluate().isEmpty);
    final revoke = find.widgetWithText(OutlinedButton, '撤销批准');
    expect(tester.widget<OutlinedButton>(revoke).onPressed, isNotNull);
    await tester.tap(revoke);
    await _waitUntil(tester, () => find.text('撤销此访问窗口并记录审计。')
        .evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await _flushPending(tester);
    expect(find.text('临时访问申请'), findsOneWidget);
    expect(fixture.posts, isEmpty);
    expect(fixture.listReads, 1);
    expect(fixture.documentReads, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  for (final action in ['批准', '拒绝', '撤销批准']) {
    testWidgets('$action cancellation preserves the original approval details',
        (tester) async {
      final fixture = _ApprovalFixture(action);
      await fixture.open(tester);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settleReads(tester);

      expect(fixture.posts, isEmpty);
      expect(fixture.detailsCompleted, isFalse);
      expect(find.text('临时访问申请'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, action), findsOneWidget);
      if (action == '撤销批准') {
        await _checkApprovalHistoryRetirement(tester, fixture);
      } else {
        await tester.tap(_helpButton('关闭'));
        await settleReads(tester);
        expect(fixture.needsReview, isFalse);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('$action success closes its approval details', (tester) async {
      final fixture = _ApprovalFixture(action);
      await fixture.open(tester);
      await fixture.submit(tester);
      fixture.succeed();
      await settleReads(tester);

      expect(fixture.detailsCompleted, isTrue);
      expect(fixture.needsReview, isTrue);
      expect(find.text('临时访问申请'), findsNothing);
      expect(find.byType(EditDialog), findsNothing);
      expect(fixture.posts, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('$action success cannot dismiss an unrelated covering dialog',
        (tester) async {
      final fixture = _ApprovalFixture(action);
      await fixture.open(tester);
      await fixture.submit(tester);
      final cover = DialogRoute<void>(
          context: fixture.host,
          builder: (_) => const AlertDialog(title: Text('独立通知')));
      unawaited(Navigator.of(fixture.host, rootNavigator: true).push<void>(cover));
      await _flushPending(tester);
      fixture.succeed();
      await settleReads(tester);

      expect(cover.isCurrent, isTrue);
      expect(find.text('独立通知'), findsOneWidget);
      expect(fixture.detailsCompleted, isTrue);
      expect(find.text('临时访问申请', skipOffstage: false), findsNothing);
      expect(find.byType(EditDialog, skipOffstage: false), findsNothing);
      expect(fixture.posts, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('$action failed submission keeps the original details open',
        (tester) async {
      final fixture = _ApprovalFixture(action);
      await fixture.open(tester);
      await fixture.submit(tester);
      fixture.pending.complete(_reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503));
      await settleReads(tester);

      expect(fixture.detailsCompleted, isFalse);
      expect(find.text('临时访问申请', skipOffstage: false), findsOneWidget);
      expect(find.byType(FailureView), findsOneWidget);
      if (action != '撤销批准') {
        await tester.tap(find.widgetWithText(TextButton, '暂时关闭'));
        await settleReads(tester);
        await tester.tap(find.byKey(const Key('edit-dialog-confirm-close')));
        await settleReads(tester);
        expect(find.byType(EditDialog), findsNothing);
        expect(find.text('临时访问申请'), findsOneWidget);
      }
      expect(fixture.posts, hasLength(1));
      expect(fixture.detailsCompleted, isFalse);
      await tester.tap(_helpButton('关闭'));
      await settleReads(tester);
      expect(fixture.needsReview, isTrue,
          reason: 'A dispatched write still needs review after an unknown result.');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('help append denial hides private rows and its covered confirmation',
      (tester) async {
    final append = Completer<http.Response>();
    const next = '88888888-8888-4888-8888-888888888888';
    final fixture = _HelpFixture(listRead: (request, read) {
      if (read == 1) return _reply({'items': [_help()], 'nextCursor': next});
      expect(request.url.queryParameters['cursor'], next);
      return append.future;
    });
    await fixture.mount(tester);
    addTearDown(() {
      if (!append.isCompleted) append.complete(_reply({'items': [], 'nextCursor': null}));
    });
    final before = fixture.session.scopeGeneration;
    final heldFilter = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '全部')).onSelected!;
    final more = _helpButton('加载更多');
    await tester.ensureVisible(more);
    await tester.tap(more);
    await _flushPending(tester);
    expect(fixture.reads, 2);
    await _openHelpConfirmation(tester);
    final heldConfirm = tester.widget<ButtonStyleButton>(_helpButton('已看到'))
        .onPressed!;
    final pageContext = tester.element(find.byType(HelpRequestsPage));
    final notice = OwnedDialogRoute<void>(context: pageContext,
        builder: (_) => const AlertDialog(title: Text('独立通知')));
    addTearDown(() {
      if (notice.available) notice.finish();
    });
    unawaited(presentOwnedDialog(pageContext, notice));
    await _flushPending(tester);
    append.complete(_reply({'errorCode': 'SCOPE_DENIED'}, 403));
    await settleReads(tester);
    expect(fixture.session.scopeGeneration, before);
    expect(find.textContaining('示例儿童', skipOffstage: false), findsNothing);
    expect(find.textContaining(_help()['deviceId'] as String,
        skipOffstage: false), findsNothing);
    expect(find.text('确认已看到求助', skipOffstage: false), findsNothing);
    heldConfirm();
    heldFilter(true);
    await _flushPending(tester);
    expect(fixture.reads, 2);
    expect(fixture.acknowledgements, 0);
    expect(notice.available, isTrue);
    expect(notice.isCurrent, isTrue);
    expect(find.text('独立通知'), findsOneWidget);
    notice.finish();
    await settleReads(tester);
    expect(find.text('已隐藏旧求助记录，请重新打开当前工作空间。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('help unavailable acknowledgement invalidates an in-flight list read',
      (tester) async {
    final lateRead = Completer<http.Response>();
    final fixture = _HelpFixture(listRead: (_, read) {
      if (read == 1) return _reply({'items': [_help()], 'nextCursor': null});
      return lateRead.future;
    });
    await fixture.mount(tester);
    addTearDown(() {
      if (!lateRead.isCompleted) lateRead.complete(_reply({'items': [], 'nextCursor': null}));
    });
    final heldRefresh = tester.widget<ButtonStyleButton>(_helpButton('刷新'))
        .onPressed!;
    await _openHelpConfirmation(tester);
    await tester.tap(_helpButton('已看到'));
    await _flushPending(tester);
    expect(fixture.acknowledgements, 1);
    heldRefresh();
    await _flushPending(tester);
    expect(fixture.reads, 2);
    fixture.pending.complete(_reply({'errorCode': 'HELP_REQUEST_UNAVAILABLE'}, 404));
    await settleReads(tester);
    expect(find.textContaining('示例儿童', skipOffstage: false), findsNothing);
    lateRead.complete(_reply({'items': [_help()], 'nextCursor': null}));
    await settleReads(tester);
    heldRefresh();
    await _flushPending(tester);
    expect(fixture.reads, 2);
    expect(fixture.acknowledgements, 1);
    expect(find.text('已隐藏旧求助记录，请重新打开当前工作空间。'), findsOneWidget);
    expect(find.textContaining('示例儿童', skipOffstage: false), findsNothing);
    expect(find.text('确认已看到', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('help confirmation identifies its target and refreshes unknown results without POST',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _HelpFixture();
    await fixture.mount(tester);
    await _openHelpConfirmation(tester);
    final confirmation = find.byType(AlertDialog);
    for (final detail in ['示例儿童', _help()['subjectId'] as String,
        _help()['deviceId'] as String, '需要监护人帮助',
        dateLabel(_help()['createdAt']), '不代表已联系孩子']) {
      expect(find.descendant(of: confirmation,
          matching: find.textContaining(detail)), findsOneWidget);
    }
    final confirm = _helpButton('已看到');
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await _flushPending(tester);
    expect(fixture.acknowledgements, 1);
    fixture.pending.complete(_reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503));
    await settleReads(tester);
    final reconcile = _helpButton('刷新核对');
    expect(reconcile, findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(reconcile).onPressed, isNotNull);
    await tester.ensureVisible(reconcile);
    await tester.tap(reconcile);
    await settleReads(tester);
    expect(fixture.reads, 2);
    expect(fixture.acknowledgements, 1,
        reason: 'Reconciliation is a GET, not another acknowledgement.');
    expect(_helpButton('刷新核对'), findsNothing);
    expect(tester.widget<ButtonStyleButton>(_helpButton('确认已看到')).onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final succeeds in [true, false]) {
    testWidgets('help initial ${succeeds ? 'success' : 'error'} after disposal '
        'does not update the removed page', (tester) async {
      final fixture = _HelpFixture(initialPending: true);
      await fixture.mount(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.pending.complete(succeeds
          ? _reply({'items': [_help()], 'nextCursor': null})
          : _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503));
      await settleReads(tester);

      expect(fixture.reads, 1);
      expect(fixture.acknowledgements, 0);
      expect(find.byType(HelpRequestsPage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('help acknowledgement ${succeeds ? 'success' : 'error'} after '
        'disposal cannot start a follow-up read', (tester) async {
      final fixture = _HelpFixture();
      await fixture.mount(tester);
      await tester.ensureVisible(find.text('确认已看到'));
      await tester.tap(find.text('确认已看到'));
      await settleReads(tester);
      await tester.tap(find.widgetWithText(FilledButton, '已看到'));
      await _flushPending(tester);
      expect(fixture.acknowledgements, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      fixture.pending.complete(succeeds
          ? _reply(_help(acknowledged: true))
          : _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503));
      await settleReads(tester);

      expect(fixture.reads, 1, reason: 'A removed page cannot reload the list.');
      expect(fixture.acknowledgements, 1);
      expect(find.byType(HelpRequestsPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('help actor ABA cannot revive a late read or old filter callback',
      (tester) async {
    final fixture = _HelpFixture(initialPending: true);
    await fixture.mount(tester);
    final selectAll = tester
        .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部'))
        .onSelected!;

    fixture.session.profile = {'subject': 'adult-b'};
    fixture.session.changed();
    fixture.session.profile = {'subject': 'adult-a'};
    fixture.session.changed();
    fixture.pending.complete(_reply({'items': [_help()], 'nextCursor': null}));
    await settleReads(tester);

    expect(find.text('已隐藏旧求助记录，请重新打开当前工作空间。'), findsOneWidget);
    expect(find.text('需要监护人帮助'), findsNothing);
    expect(() => selectAll(true), returnsNormally);
    await settleReads(tester);
    expect(fixture.reads, 1);
    expect(fixture.acknowledgements, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('help console entry creates a new page for the current generation',
      (tester) async {
    final fixture = _HelpFixture();
    await fixture.mount(tester, throughConsole: true);
    final previous = tester.state(find.byType(HelpRequestsPage));
    expect(find.text('需要监护人帮助'), findsOneWidget);

    fixture.session.changed();
    await settleReads(tester);

    expect(tester.state(find.byType(HelpRequestsPage)), isNot(same(previous)));
    expect(fixture.reads, 2);
    expect(find.text('需要监护人帮助'), findsOneWidget);
    expect(find.text('已隐藏旧求助记录，请重新打开当前工作空间。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a captured help filter callback is inert after page disposal',
      (tester) async {
    final fixture = _HelpFixture();
    await fixture.mount(tester);
    final selectAll = tester
        .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部'))
        .onSelected!;
    await tester.pumpWidget(const SizedBox.shrink());

    expect(() => selectAll(true), returnsNormally);
    await settleReads(tester);
    expect(fixture.reads, 1);
    expect(fixture.acknowledgements, 0);
    expect(find.byType(HelpRequestsPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
