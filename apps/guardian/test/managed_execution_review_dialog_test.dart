import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/managed_execution_review.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:http/http.dart' as http;

import 'managed_execution_fixtures.dart';
import 'managed_execution_review_widget_fixtures.dart';

void main() {
  testWidgets('detail presents status reason next step timeline and collapsed identifiers', (tester) async {
    final f = ReviewWidgetFixture();
    await mountReview(tester, f);
    await openReview(tester);
    expect(tester.getTopLeft(find.text('需要复核').first).dy, lessThan(tester.getTopLeft(find.text('当前原因')).dy));
    expect(tester.getTopLeft(find.text('当前原因')).dy, lessThan(tester.getTopLeft(find.text('下一步')).dy));
    expect(tester.getTopLeft(find.text('下一步')).dy, lessThan(tester.getTopLeft(find.text('事件时间线')).dy));
    expect(find.byKey(const Key('execution-recheck')), findsOneWidget);
    expect(find.byKey(const Key('execution-cancel')), findsOneWidget);
    expect(find.text('执行编号：$executionId').hitTestable(), findsNothing);
    expect(f.posts, isEmpty);
    expect(f.data.requests.any((r) => r.url.path.endsWith('/review-eligibility')), isTrue);
  });

  testWidgets('recheck has one confirmation then original conditional POST and waits for device', (tester) async {
    final f = ReviewWidgetFixture();
    await mountReview(tester, f);
    await openReview(tester);
    await pressReview(tester, 'execution-recheck');
    expect(find.text('重新核实设备状态？'), findsOneWidget);
    expect(f.posts, isEmpty);
    expect(f.journal.reserves, 0);
    await pressReview(tester, 'execution-confirm-recheck');
    expect(f.posts, hasLength(1));
    expect(f.posts.single.url.path, endsWith('/$executionId/recheck-device'));
    expect(f.posts.single.headers['if-match'], '"1"');
    expect(f.posts.single.body, isEmpty);
    expect(f.posts.single.headers.keys.map((k) => k.toLowerCase()), isNot(contains('idempotency-key')));
    expect(f.operation!.selected!.state, 'WAITING_DEVICE');
    expect(find.text('已申请重新核实，等待设备反馈。'), findsOneWidget);
    expect(find.text('设备已应用'), findsNothing);
    expect(f.journal.receipts, 1);
    expect(f.journal.record, isNull);
  });

  testWidgets('queued recheck and confirmation double clicks send only once', (tester) async {
    final f = ReviewWidgetFixture();
    await mountReview(tester, f);
    await openReview(tester);
    final begin = tester.widget<FilledButton>(find.byKey(const Key('execution-recheck'))).onPressed!;
    begin(); begin();
    await flushReview(tester);
    expect(find.text('重新核实设备状态？'), findsOneWidget);
    final accept = tester.widget<FilledButton>(find.byKey(const Key('execution-confirm-recheck'))).onPressed!;
    accept(); accept();
    await flushReview(tester);
    expect(f.posts, hasLength(1));
    expect(f.journal.reserves, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retained old detail action cannot act after leaving and reopening the task', (tester) async {
    final f = ReviewWidgetFixture();
    await mountReview(tester, f);
    await openReview(tester);
    final staleRecheck = tester.widget<FilledButton>(find.byKey(const Key('execution-recheck'))).onPressed!;
    final staleCancel = tester.widget<TextButton>(find.byKey(const Key('execution-cancel'))).onPressed!;
    await pressReview(tester, 'execution-back');
    await openReview(tester);
    final before = f.data.requests.length;
    staleRecheck(); staleCancel();
    await flushReview(tester);
    expect(f.data.requests, hasLength(before));
    expect(find.byKey(const Key('execution-confirm-recheck')), findsNothing);
    expect(find.byKey(const Key('execution-confirm-cancel')), findsNothing);
    expect(f.journal.reserves, 0);
    expect(f.posts, isEmpty);
  });

  testWidgets('decline is a read-only decision and creates no pending record', (tester) async {
    final f = ReviewWidgetFixture();
    await mountReview(tester, f);
    await openReview(tester);
    await pressReview(tester, 'execution-recheck');
    await pressReview(tester, 'execution-dismiss-recheck');
    expect(f.journal.record, isNull);
    expect(f.journal.reserves, 0);
    expect(f.posts, isEmpty);
    expect(find.byKey(const Key('execution-recheck')), findsOneWidget);
  });

  testWidgets('eligibility refusal is explained with an explicit refresh and no recheck entry', (tester) async {
    final f = ReviewWidgetFixture()..eligibilityReason = 'EXECUTION_RECHECK_WINDOW_CLOSED';
    await mountReview(tester, f);
    await openReview(tester);
    expect(find.text('本任务核实时间已结束，请人工核对'), findsOneWidget);
    expect(find.byKey(const Key('execution-recheck')), findsNothing);
    f.eligibilityReason = 'ELIGIBLE';
    await pressReview(tester, 'execution-refresh-detail');
    expect(find.byKey(const Key('execution-recheck')), findsOneWidget);
    expect(f.posts, isEmpty);
  });

  testWidgets('stored UNKNOWN restores locally and does not auto query or eligibility refresh', (tester) async {
    final f = ReviewWidgetFixture();
    f.journal.record = f.pending();
    await mountReview(tester, f);
    expect(f.data.requests, hasLength(1));
    expect(f.data.requests.single.url.path, endsWith('/executions'));
    f.data.requests.clear(); // The real transport records every request.
    await openReview(tester);
    expect(f.data.requests, isEmpty,
        reason: 'UNKNOWN restore must precede every detail, eligibility and event request.');
    expect(f.journal.reads, 1);
    expect(find.byKey(const Key('execution-check-result')), findsOneWidget);
    expect(find.byKey(const Key('execution-recheck')), findsNothing);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    final count = f.data.requests.length;
    await tester.pump(const Duration(minutes: 5));
    await flushReview(tester);
    expect(f.data.requests, hasLength(count));
    expect(f.posts, isEmpty);
    await pressReview(tester, 'execution-check-result');
    expect(f.data.requests, hasLength(1));
    expect(f.data.requests.single.method, 'GET');
    expect(f.data.requests.single.url.path, endsWith('/$executionId'));
    expect(f.operation!.resultUnknown, isTrue);
  });

  testWidgets('unknown explicit old query remains unknown and never resends mutation', (tester) async {
    final f = ReviewWidgetFixture()..interruptPost = true;
    await mountReview(tester, f);
    await openReview(tester);
    await pressReview(tester, 'execution-recheck');
    await pressReview(tester, 'execution-confirm-recheck');
    expect(f.journal.record!.phase, ExecutionOperationPhase.unknown);
    final count = f.data.requests.length;
    await pressReview(tester, 'execution-check-result');
    expect(f.data.requests.skip(count).map((r) => r.method), ['GET']);
    expect(f.posts, hasLength(1));
    expect(f.operation!.resultUnknown, isTrue);
    expect(find.byKey(const Key('execution-recheck')), findsNothing);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
  });

  testWidgets('restored definite refusal is local only until explicit state refresh', (tester) async {
    final f = ReviewWidgetFixture();
    f.journal.record = ExecutionOperationPending(intent: f.pending().intent,
      phase: ExecutionOperationPhase.rejectedNotApplied, refusalCode: 'EXECUTION_RECHECK_LEASE_ACTIVE');
    await mountReview(tester, f);
    expect(f.data.requests, hasLength(1));
    f.data.requests.clear();
    await openReview(tester);
    expect(f.data.requests, isEmpty);
    expect(f.operation!.rejectedNotApplied, isTrue);
    expect(find.byKey(const Key('execution-recheck')), findsNothing);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    await pressReview(tester, 'execution-refresh-detail');
    expect(f.data.requests.map((r) => r.method), ['GET', 'GET']);
    expect(f.data.requests.last.url.path, endsWith('/review-eligibility'));
    expect(find.byKey(const Key('execution-recheck')), findsOneWidget);
    expect(f.posts, isEmpty);
  });

  testWidgets('newer GET reports progress without attributing it to this request', (tester) async {
    final f = ReviewWidgetFixture();
    f.journal.record = f.pending();
    await mountReview(tester, f);
    await openReview(tester);
    f.task = f.data.record(state: 'WAITING_DEVICE', reason: 'DEVICE_PENDING', revision: 2, updatedAt: 200);
    await pressReview(tester, 'execution-check-result');
    expect(f.operation!.resultUnknown, isFalse);
    expect(f.operation!.notice, '任务已有新进展，请查看当前状态。');
    expect(find.text('任务已有新进展，请查看当前状态。'), findsOneWidget);
    expect(find.textContaining('已申请重新核实'), findsNothing);
    expect(f.journal.progress, 1);
    expect(f.posts, isEmpty);
  });

  testWidgets('closing during physical POST preserves unknown and ignores late success', (tester) async {
    final f = ReviewWidgetFixture()..postRelease = Completer<http.Response>();
    await mountReview(tester, f, ownedRoute: true);
    await openReview(tester);
    await pressReview(tester, 'execution-recheck');
    await pressReview(tester, 'execution-confirm-recheck');
    expect(f.posts, hasLength(1));
    expect(f.journal.record!.phase, ExecutionOperationPhase.unknown);
    await pressReview(tester, 'execution-close');
    expect(f.closeCalls, 1);
    expect(find.byKey(const Key('execution-dialog')), findsNothing);
    f.postRelease!.complete(f.data.response(f.data.record(state: 'WAITING_DEVICE',
        reason: 'MANUAL_DEVICE_RECHECK_REQUESTED', revision: 2, updatedAt: 200)));
    await flushReview(tester);
    expect(find.byKey(const Key('execution-dialog')), findsNothing);
    expect(f.journal.record, isNotNull);
    expect(f.journal.receipts, 0);
    expect(f.journal.zeroSend, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scope ABA while reservation waits detaches and only exact zero-send cleanup runs', (tester) async {
    final f = ReviewWidgetFixture();
    f.journal.reserveEntered = Completer<void>();
    f.journal.reserveRelease = Completer<void>();
    await mountReview(tester, f);
    await openReview(tester);
    await pressReview(tester, 'execution-recheck');
    await pressReview(tester, 'execution-confirm-recheck');
    expect(f.journal.reserveEntered!.isCompleted, isTrue);
    f.data.current = false; f.changes.value++;
    f.data.current = true; f.changes.value++;
    f.journal.reserveRelease!.complete();
    await flushReview(tester);
    expect(f.posts, isEmpty);
    expect(f.journal.zeroSend, 1);
    expect(f.journal.record, isNull);
    expect(find.text('学习平板'), findsNothing);
    expect(find.byKey(const Key('execution-scope-unavailable')), findsOneWidget);
  });

  testWidgets('covered confirmation revocation removes only its own route', (tester) async {
    final f = ReviewWidgetFixture();
    await mountReview(tester, f, ownedRoute: true);
    await openReview(tester);
    await pressReview(tester, 'execution-recheck');
    final staleAccept = tester.widget<FilledButton>(find.byKey(const Key('execution-confirm-recheck'))).onPressed!;
    final context = tester.element(find.byKey(const Key('execution-confirm-recheck')));
    final overlay = OwnedDialogRoute<void>(context: context, builder: (_) => const AlertDialog(title: Text('其他窗口')));
    unawaited(Navigator.of(context, rootNavigator: true).push(overlay));
    await flushReview(tester);
    f.data.current = false; f.changes.value++;
    await flushReview(tester);
    staleAccept();
    await flushReview(tester);
    expect(find.text('其他窗口'), findsOneWidget);
    expect(f.posts, isEmpty);
    expect(f.journal.reserves, 0);
    overlay.finish();
    await flushReview(tester);
    expect(find.byKey(const Key('execution-scope-unavailable')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final loss in ['scope', '401', '403']) {
    testWidgets('$loss hides confirmation private body before reverse animation completes', (tester) async {
      final f = ReviewWidgetFixture();
      await mountReview(tester, f, ownedRoute: true);
      await openReview(tester);
      await pressReview(tester, 'execution-refresh-timeline');
      expect(find.byKey(const Key('execution-event-1')), findsOneWidget);
      await pressReview(tester, 'execution-recheck');
      final staleAccept = tester.widget<FilledButton>(find.byKey(const Key('execution-confirm-recheck'))).onPressed!;
      expect(find.text('学习平板'), findsWidgets);
      if (loss == 'scope') {
        f.data.current = false;
        f.changes.value++;
      } else {
        f.data.handler = (request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/$executionId')) {
            return f.data.response({'errorCode': loss == '401' ? 'REAUTH_REQUIRED' : 'ACCESS_DENIED'},
                status: int.parse(loss));
          }
          return f.serve(request);
        };
        // A real read response can revoke the already open confirmation.
        unawaited(f.list.refreshDetail());
      }
      // Flush transport and frame work without advancing the animation clock.
      // The owned confirmation is still reversing, so final removal cannot
      // make these privacy assertions pass on its behalf.
      for (var frame = 0; frame < 12; frame++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(find.byKey(const Key('execution-confirmation-revoked')), findsOneWidget);
      expect(find.text('学习平板'), findsNothing);
      expect(find.byKey(const Key('execution-event-1')), findsNothing);
      expect(find.byKey(const Key('execution-confirm-recheck')), findsNothing);
      staleAccept();
      await tester.pump();
      expect(f.posts, isEmpty);
      expect(f.journal.reserves, 0);
      expect(tester.takeException(), isNull);
      await flushReview(tester);
      expect(find.byKey(const Key('execution-confirmation-revoked')), findsNothing);
      await pressReview(tester, 'execution-close');
    });
  }

  for (final status in [401, 403]) {
    testWidgets('$status denial hides private details before another action', (tester) async {
      final f = ReviewWidgetFixture()..denialStatus = status
        ..denialCode = status == 401 ? 'REAUTH_REQUIRED' : 'ACCESS_DENIED';
      await mountReview(tester, f);
      final staleOpen = tester.widget<OutlinedButton>(find.byKey(const Key('execution-open-$executionId'))).onPressed!;
      await openReview(tester);
      final staleBack = tester.widget<TextButton>(find.byKey(const Key('execution-back'))).onPressed!;
      await pressReview(tester, 'execution-refresh-timeline');
      expect(find.byKey(const Key('execution-event-1')), findsOneWidget);
      await pressReview(tester, 'execution-recheck');
      await pressReview(tester, 'execution-confirm-recheck');
      expect(find.text('学习平板'), findsNothing);
      expect(find.byKey(const Key('execution-event-1')), findsNothing);
      expect(find.byKey(const Key('execution-recheck')), findsNothing);
      expect(find.byKey(const Key('execution-cancel')), findsNothing);
      expect(f.reauthCalls, 0);
      expect(f.posts, hasLength(1));
      final reads = f.data.requests.length;
      staleBack(); staleOpen();
      await flushReview(tester);
      expect(f.data.requests, hasLength(reads));
      expect(find.text('学习平板'), findsNothing);
      if (status == 401) {
        expect(find.byKey(const Key('execution-reauth')), findsOneWidget);
        await pressReview(tester, 'execution-reauth');
        expect(f.reauthCalls, 1);
        expect(f.posts, hasLength(1));
      } else {
        expect(find.byKey(const Key('execution-reauth')), findsNothing);
      }
    });
  }

  testWidgets('read-only and historical registration expose no mutation entry', (tester) async {
    final readOnly = ReviewWidgetFixture(writable: false);
    await mountReview(tester, readOnly);
    await openReview(tester);
    expect(find.byKey(const Key('execution-recheck')), findsNothing);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    expect(readOnly.operation, isNull);
    expect(readOnly.journal.reads, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    final historical = ReviewWidgetFixture();
    historical.task = {...historical.task, 'registrationId': executionOther};
    await mountReview(tester, historical);
    await openReview(tester);
    expect(find.textContaining('历史注册记录'), findsWidgets);
    expect(historical.operation, isNull);
    expect(historical.journal.reads, 0);
    expect(find.byKey(const Key('execution-recheck')), findsNothing);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
  });

  testWidgets('blocked storage has explicit local recovery without granting a mutation', (tester) async {
    final f = ReviewWidgetFixture();
    f.journal.blocked = true;
    await mountReview(tester, f);
    expect(f.data.requests, hasLength(1));
    f.data.requests.clear();
    await openReview(tester);
    expect(f.data.requests, isEmpty);
    expect(find.byKey(const Key('execution-restore-operation')), findsOneWidget);
    expect(find.byKey(const Key('execution-recheck')), findsNothing);
    final before = f.data.requests.length;
    f.journal.blocked = false;
    await pressReview(tester, 'execution-restore-operation');
    expect(f.data.requests, hasLength(before));
    expect(f.posts, isEmpty);
    expect(find.byKey(const Key('execution-recheck')), findsNothing);
    await pressReview(tester, 'execution-refresh-detail');
    expect(find.byKey(const Key('execution-recheck')), findsOneWidget);
  });

  testWidgets('failed first detail has explicit retry that joins the real coordinator', (tester) async {
    final f = ReviewWidgetFixture();
    var failDetail = true;
    f.data.handler = (request) async {
      if (failDetail && request.method == 'GET' && request.url.path.endsWith('/$executionId')) {
        return f.data.response({'errorCode': 'REQUEST_FAILED'}, status: 503);
      }
      return f.serve(request);
    };
    await mountReview(tester, f);
    await openReview(tester);
    expect(f.operation, isNotNull);
    expect(f.operation!.initialized, isTrue);
    expect(f.operation!.error, isNotNull);
    expect(find.textContaining('最新详情尚未核对完成'), findsOneWidget);
    expect(find.text('重新核对详情'), findsOneWidget);
    expect(find.byKey(const Key('execution-recheck')), findsNothing);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    failDetail = false;
    await pressReview(tester, 'execution-refresh-detail');
    expect(f.operation, isNotNull);
    expect(f.operation!.initialized, isTrue);
    expect(find.byKey(const Key('execution-recheck')), findsOneWidget);
    expect(f.posts, isEmpty);
  });

  testWidgets('observed event revision survives failed timeline reload and reopening the task', (tester) async {
    final f = ReviewWidgetFixture();
    var eventsFail = false;
    f.data.handler = (request) async {
      if (request.url.path.endsWith('/events')) {
        return eventsFail ? f.data.response({'errorCode': 'REQUEST_FAILED'}, status: 503)
            : f.data.response({'items': [f.data.event(revision: 2,
                state: 'NEEDS_REVIEW', reason: 'DEVICE_NON_COMPLIANT')], 'nextCursor': null});
      }
      return f.serve(request);
    };
    await mountReview(tester, f);
    await openReview(tester);
    expect(f.operation!.canRecheck, isTrue);
    await pressReview(tester, 'execution-refresh-timeline');
    expect(f.list.events.single.revision, 2);
    expect(f.operation!.canRecheck, isFalse);
    expect(f.operation!.canCancel, isFalse);
    eventsFail = true;
    await pressReview(tester, 'execution-refresh-timeline');
    expect(f.list.events, isEmpty);
    expect(f.list.eventError, isNotNull);
    expect(f.operation!.canRecheck, isFalse);
    expect(f.operation!.canCancel, isFalse);
    await pressReview(tester, 'execution-back');
    await openReview(tester);
    expect(f.operation!.selected!.revision, 1);
    expect(f.operation!.canRecheck, isFalse);
    expect(f.operation!.canCancel, isFalse);
    expect(find.textContaining('时间线已有更新'), findsOneWidget);
    expect(f.posts, isEmpty);
  });

  testWidgets('320px and doubled text keep full wording actions focus and close reachable', (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = ReviewWidgetFixture(deviceName: '学习平板' * 25);
    await mountReview(tester, f, scale: 2);
    await openReview(tester);
    expect(tester.takeException(), isNull);
    final label = tester.widget<Text>(find.text('学习平板' * 25));
    expect(label.maxLines, isNull);
    expect(label.overflow, isNot(TextOverflow.ellipsis));
    await pressReview(tester, 'execution-recheck');
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const Key('execution-confirm-recheck')));
    expect(find.byKey(const Key('execution-confirm-recheck')).hitTestable(), findsOneWidget);
    await pressReview(tester, 'execution-dismiss-recheck');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(FocusManager.instance.primaryFocus, isNotNull);
    await pressReview(tester, 'execution-close');
    expect(f.closeCalls, 1);
    expect(f.posts, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
