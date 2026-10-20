import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/policy_publication.dart';
import 'package:guardian/core/policy_publication_repository.dart';
import 'package:guardian/pages/policy_publication_entry.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:guardian/ui/policy_preview_results.dart';
import 'package:guardian/ui/policy_publication_controller.dart';
import 'package:guardian/ui/policy_publication_dialog.dart';

import 'fixtures/policy_preview_fixture_data.dart';
import 'policy_publication_controller_fixtures.dart';

// New entry controls only. They have not been formatted, compiled or executed;
// the parent-removal/captured-action cases intentionally exercise a suspected
// unnotified-redaction defect in the current unchanged production controller.
const _privatePreview = '本次发布的私有设备选择';

PublicationIntent _intent({bool expired = false}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return PublicationIntent(
      owner: publicationOwner(),
      policyId: 'policy-a',
      revision: 7,
      previewId: '11111111-1111-4111-8111-111111111111',
      previewHash: 'a' * 64,
      previewExpiresAt: now + (expired ? -1000 : 600000),
      createdAt: now - 60000,
      idempotencyKey: '22222222-2222-4222-8222-222222222222');
}

class _Harness {
  final access = PublicationTestAccess();
  final journal = PublicationTestJournal();
  final transport = PublicationTestTransport();
  final PublicationIntent intent;
  final PublicationPending? pending;
  late BuildContext rootContext;
  late OwnedDialogRoute<void> parent;
  PolicyPublicationController? controller;
  ModalRoute<dynamic>? publicationRoute;
  Future<PublicationDialogResult>? flow;
  bool completed = false, coverCompleted = false;
  PublicationDialogResult? result;
  Object? failure;
  int authentications = 0;
  bool? parentCurrentAtAuthentication, publicationActiveAtAuthentication;

  _Harness({this.pending, PublicationIntent? intent})
      : intent = pending?.intent ?? intent ?? _intent() {
    journal.record = pending;
  }

  void open(BuildContext context) {
    flow = showPolicyPublication(context,
        repository: PublicationTestRequests(transport),
        journal: journal,
        intent: intent,
        pending: pending,
        preview: pending == null
            ? policyPreviewFixture({
                'deviceIds': ['tablet-a']
              })
            : null,
        names: const {'tablet-a': '私有课堂平板'},
        selectionSummary: _privatePreview,
        parentCurrent: () => access.current,
        accessChanges: access,
        reauthenticate: () {
          authentications++;
          parentCurrentAtAuthentication = parent.isCurrent;
          publicationActiveAtAuthentication = publicationRoute?.isActive;
        });
    unawaited(flow!.then<void>((value) {
      completed = true;
      result = value;
    }, onError: (Object error, StackTrace _) {
      completed = true;
      failure = error;
    }));
  }
}

Future<void> _frames(WidgetTester tester, [int count = 12]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _open(WidgetTester tester, _Harness harness) async {
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: Builder(builder: (context) {
        harness.rootContext = context;
        return const Text('工作台');
      }))));
  harness.parent = OwnedDialogRoute<void>(
      context: harness.rootContext,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
              title: const Text('策略父窗口'),
              content: const Text('父窗口内容'),
              actions: [
                TextButton(
                    onPressed: () => harness.open(context),
                    child: const Text('打开发布')),
              ]));
  unawaited(presentOwnedDialog(harness.rootContext, harness.parent));
  await _frames(tester);
  await tester.tap(find.text('打开发布'));
  await _frames(tester);
  final view = find.byType(PolicyPublicationDialog);
  expect(view, findsOneWidget);
  harness.controller = tester.widget<PolicyPublicationDialog>(view).controller;
  harness.publicationRoute = ModalRoute.of(tester.element(view));
}

VoidCallback _primary(WidgetTester tester, String label) {
  final button = find.widgetWithText(FilledButton, label);
  expect(button, findsOneWidget);
  final action = tester.widget<FilledButton>(button).onPressed;
  expect(action, isNotNull);
  return action!;
}

Future<void> _cover(WidgetTester tester, _Harness harness) async {
  unawaited(showDialog<void>(
      context: harness.rootContext,
      builder: (context) => AlertDialog(title: const Text('独立通知'), actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭通知')),
          ])).then<void>((_) => harness.coverCompleted = true));
  await _frames(tester);
}

Future<void> _unmount(WidgetTester tester, _Harness harness,
    {VoidCallback? afterUnmount}) async {
  // Complete the widget and controller lifetime before Flutter's timer check;
  // never await an unresolved route or HTTP future in a late tearDown hook.
  await tester.pumpWidget(const SizedBox.shrink());
  harness.controller?.dispose();
  afterUnmount?.call();
  await _frames(tester, 4);
  harness.access.dispose();
}

void main() {
  for (final removal in ['complete-owned-parent', 'remove-parent-directly']) {
    testWidgets('$removal before queued action redacts the private preview',
        (tester) async {
      final harness = _Harness();
      try {
        await _open(tester, harness);
        expect(find.text(_privatePreview), findsOneWidget);
        final queued = _primary(tester, '仅保存配置');
        // These are actual Navigator/OwnedDialogRoute operations. In
        // particular, do not yield a microtask/pump before the captured action:
        // its access getter can revoke without notifying before popped.then.
        if (removal == 'complete-owned-parent') {
          harness.parent.finish();
        } else {
          harness.parent.navigator!.removeRoute(harness.parent);
        }
        queued();
        expect(harness.transport.posts, isEmpty);
        expect(harness.transport.lookups, isEmpty);
        await _frames(tester);
        expect(find.text(_privatePreview), findsNothing);
        expect(find.byType(PolicyPreviewResults, skipOffstage: false),
            findsNothing);
        expect(find.text('工作空间或权限已变化'), findsOneWidget);
        expect(harness.transport.posts, isEmpty);
        expect(harness.transport.lookups, isEmpty);
        expect(find.text('关闭'), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await _frames(tester);
        expect(harness.completed, isTrue);
        expect(harness.result?.reason, PublicationExitReason.closed);
        expect(harness.failure, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester, harness);
      }
    });
  }

  testWidgets('authority ABA before a frame permanently revokes queued actions',
      (tester) async {
    final harness = _Harness();
    try {
      await _open(tester, harness);
      final queued = _primary(tester, '仅保存配置');
      harness.access.awayAndBack();
      queued();
      expect(harness.transport.posts, isEmpty);
      expect(harness.transport.lookups, isEmpty);
      await _frames(tester);
      expect(find.text(_privatePreview), findsNothing);
      expect(find.text('工作空间或权限已变化'), findsOneWidget);
      queued();
      await _frames(tester, 2);
      expect(harness.transport.posts, isEmpty);
      expect(harness.transport.lookups, isEmpty);
      expect(harness.authentications, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, harness);
    }
  });

  testWidgets(
      'late receipt under a notice updates only the original child route',
      (tester) async {
    final record = PublicationPending(intent: _intent());
    final harness = _Harness(pending: record);
    final response = Completer<PublicationReceipt?>();
    harness.transport.lookup = (_) => response.future;
    try {
      await _open(tester, harness);
      final originalRoute = harness.publicationRoute;
      final query = _primary(tester, '查询发布结果');
      query();
      await _frames(tester, 2);
      expect(harness.transport.lookups, hasLength(1));
      await _cover(tester, harness);
      query();
      response.complete(publicationReceipt());
      await _frames(tester);
      expect(find.text('独立通知'), findsOneWidget);
      expect(harness.coverCompleted, isFalse);
      expect(originalRoute?.isCurrent, isFalse);
      expect(harness.controller?.phase, PublicationViewPhase.recorded);
      expect(harness.completed, isFalse);
      expect(harness.transport.posts, isEmpty);
      expect(harness.transport.lookups, [record]);
      await tester.tap(find.text('关闭通知'));
      await _frames(tester);
      expect(find.text('配置已保存 · 未执行'), findsOneWidget);
      expect(
          ModalRoute.of(tester.element(find.byType(PolicyPublicationDialog))),
          same(originalRoute));
      await tester.tap(find.text('关闭'));
      await _frames(tester);
      expect(harness.completed, isTrue);
      expect(harness.parent.isCurrent, isTrue);
      expect(find.text('策略父窗口'), findsOneWidget);
      expect(harness.failure, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, harness, afterUnmount: () {
        if (!response.isCompleted) response.complete(publicationReceipt());
      });
    }
  });

  testWidgets('reauthentication handoff waits for its own closing transition',
      (tester) async {
    final harness = _Harness();
    harness.transport.publish = (record) async {
      throw PublicationReauthenticationRequired(record);
    };
    try {
      await _open(tester, harness);
      _primary(tester, '仅保存配置')();
      await _frames(tester);
      _primary(tester, '发布配置')();
      await _frames(tester);
      final authenticate = _primary(tester, '完成安全验证');
      authenticate();
      expect(harness.authentications, 0,
          reason: 'Authentication must wait for the owned route.completed.');
      await _frames(tester);
      expect(harness.authentications, 1);
      expect(harness.parentCurrentAtAuthentication, isTrue);
      expect(harness.publicationActiveAtAuthentication, isFalse);
      expect(harness.journal.record?.phase,
          PublicationPhase.reauthenticationRequired);
      expect(harness.transport.posts, hasLength(1));
      expect(harness.transport.lookups, isEmpty);
      authenticate();
      await _frames(tester, 2);
      expect(harness.authentications, 1);
      expect(harness.completed, isTrue);
      expect(harness.result?.reason, PublicationExitReason.closed);
      expect(harness.failure, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, harness);
    }
  });

  testWidgets('expired UNKNOWN recovery allows original GET but no repreview',
      (tester) async {
    final record = PublicationPending(intent: _intent(expired: true));
    final harness = _Harness(pending: record);
    harness.transport.lookup = (_) async => publicationReceipt();
    try {
      await _open(tester, harness);
      expect(find.text('重新预览'), findsNothing);
      expect(harness.transport.lookups, isEmpty);
      _primary(tester, '查询发布结果')();
      await _frames(tester);
      expect(harness.transport.lookups, [record]);
      expect(harness.transport.posts, isEmpty);
      expect(find.text('配置已保存 · 未执行'), findsOneWidget);
      expect(harness.journal.cancels, 0);
      expect(harness.failure, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, harness);
    }
  });

  testWidgets('expired known rejection is cancelled exactly before repreview',
      (tester) async {
    final record = PublicationPending(
        intent: _intent(expired: true),
        phase: PublicationPhase.reauthenticationRequired);
    final harness = _Harness(pending: record);
    try {
      await _open(tester, harness);
      expect(find.text('查询发布结果'), findsNothing);
      _primary(tester, '重新预览')();
      await _frames(tester);
      expect(harness.journal.cancels, 1);
      expect(harness.journal.record, isNull);
      expect(harness.transport.posts, isEmpty);
      expect(harness.transport.lookups, isEmpty);
      expect(harness.completed, isTrue);
      expect(harness.result?.reason, PublicationExitReason.repreview);
      expect(harness.parent.isCurrent, isTrue);
      expect(harness.failure, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, harness);
    }
  });
}
