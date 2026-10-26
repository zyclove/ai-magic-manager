@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/pages/help_requests_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'device_management_entry_test.dart' show EntrySession, settleReads;

const _approvalId = '11111111-1111-4111-8111-111111111111';
const _applicationId = '66666666-6666-4666-8666-666666666666';
const _registrationId = '77777777-7777-4777-8777-777777777777';
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

class _ApprovalFixture {
  _ApprovalFixture(this.action,
      {this.requestedSeconds = 60, this.listRow});

  final String action;
  final int requestedSeconds;
  final Json? listRow;
  int deliveryReads = 0;
  final pending = Completer<http.Response>();
  final posts = <http.Request>[];
  late BuildContext host;
  bool detailsCompleted = false;
  late final session = EntrySession((request) async {
    final path = request.url.path;
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
    if (request.method == 'POST' &&
        path.endsWith('/$_approvalId/${action == '撤销批准' ? 'revoke' : 'decisions'}')) {
      posts.add(request);
      return pending.future;
    }
    throw StateError('Unexpected approval fixture request.');
  });

  Future<void> open(WidgetTester tester, {bool openAction = true}) async {
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
                  .approvalDetails(listRow ?? {'id': _approvalId})
                  .then((_) => detailsCompleted = true),
              child: const Text('打开申请'));
        }))));
    await tester.tap(find.text('打开申请'));
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

class _HelpFixture {
  _HelpFixture({this.initialPending = false});

  final bool initialPending;
  final pending = Completer<http.Response>();
  int reads = 0, acknowledgements = 0;
  late final session = EntrySession((request) async {
    if (request.method == 'GET' &&
        request.url.path.endsWith('/help-requests')) {
      reads++;
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
      expect(tester.takeException(), isNull);
    });

    testWidgets('$action success closes its approval details', (tester) async {
      final fixture = _ApprovalFixture(action);
      await fixture.open(tester);
      await fixture.submit(tester);
      fixture.succeed();
      await settleReads(tester);

      expect(fixture.detailsCompleted, isTrue);
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
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await settleReads(tester);
        expect(find.byType(EditDialog), findsNothing);
        expect(find.text('临时访问申请'), findsOneWidget);
      }
      expect(fixture.posts, hasLength(1));
      expect(fixture.detailsCompleted, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

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
