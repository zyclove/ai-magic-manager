import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_publication.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:guardian/ui/policy_preview_results.dart';
import 'package:guardian/ui/policy_publication_controller.dart';
import 'package:guardian/ui/policy_publication_dialog.dart';

import 'fixtures/policy_preview_fixture_data.dart';
import 'policy_publication_controller_fixtures.dart';

// Initial five controls preceded implementation; the cleanup-busy control was
// added after static review. These supplemental controls are not actual RED.
Future<void> _frames(WidgetTester tester, [int count = 12]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

class _Opened {
  final BuildContext parent;
  final OwnedDialogRoute<void> route;
  _Opened(this.parent, this.route);
}

Future<_Opened> _open(
    WidgetTester tester, PolicyPublicationController controller,
    {ValueNotifier<bool>? revokeDuringBuild,
    VoidCallback? onRevoke,
    double width = 1100,
    double scale = 1}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  late _Opened opened;
  var observedRevoke = false;
  await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Scaffold(body: Builder(builder: (context) {
        Widget button() => TextButton(
            onPressed: () {
              late OwnedDialogRoute<void> route;
              route = OwnedDialogRoute<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => PolicyPublicationDialog(
                      controller: controller,
                      preview: policyPreviewFixture({
                        'deviceIds': ['tablet-a']
                      }),
                      names: const {'tablet-a': '学习平板'},
                      selectionSummary: '手动选择 1 台设备',
                      onClose: route.finish,
                      reauthenticate: () {}));
              opened = _Opened(context, route);
              unawaited(presentOwnedDialog(context, route));
            },
            child: const Text('开始'));
        if (revokeDuringBuild == null) return button();
        return ValueListenableBuilder<bool>(
            valueListenable: revokeDuringBuild,
            builder: (_, value, __) {
              if (value && !observedRevoke) {
                observedRevoke = true;
                onRevoke?.call();
              }
              return button();
            });
      }))));
  await tester.tap(find.text('开始'));
  await _frames(tester);
  return opened;
}

Future<void> _dispose(
    WidgetTester tester, PolicyPublicationController controller,
    {VoidCallback? afterUnmount}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  afterUnmount?.call();
  await _frames(tester, 3);
}

void main() {
  testWidgets(
      'confirmation stays in the same route and preserves preview state',
      (tester) async {
    final fixture = PublicationControllerFixture();
    final controller = fixture.create();
    try {
      final opened = await _open(tester, controller);
      final preview = tester.state(find.byType(PolicyPreviewResults));
      await tester.tap(find.text('仅保存配置'));
      await _frames(tester);
      expect(opened.route.isCurrent, isTrue);
      expect(find.widgetWithText(FilledButton, '发布配置'), findsOneWidget);
      expect(
          tester.state(find.byType(PolicyPreviewResults, skipOffstage: false)),
          same(preview));
      await tester.tap(find.text('取消'));
      await _frames(tester);
      expect(find.text('发布前预览'), findsOneWidget);
      expect(tester.state(find.byType(PolicyPreviewResults)), same(preview));
      expect(fixture.transport.posts, isEmpty);
      expect(fixture.journal.reserves, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, controller);
    }
  });

  testWidgets('unknown is explicit and valid lookup changes only its own route',
      (tester) async {
    final fixture = PublicationControllerFixture();
    fixture.transport.publish = (_) async {
      throw const ApiFailure(0, 'NETWORK_ERROR');
    };
    fixture.transport.lookup = (_) async => publicationReceipt();
    final controller = fixture.create();
    try {
      final opened = await _open(tester, controller);
      await tester.tap(find.text('仅保存配置'));
      await _frames(tester);
      await tester.tap(find.widgetWithText(FilledButton, '发布配置'));
      await _frames(tester);
      expect(find.text('发布结果'), findsNothing);
      expect(
          find.byType(PolicyPreviewResults, skipOffstage: false), findsNothing);
      expect(fixture.transport.lookups, isEmpty);
      await tester.tap(find.text('查询发布结果'));
      await _frames(tester);
      expect(find.text('发布结果'), findsOneWidget);
      expect(find.text('配置已保存 · 未执行'), findsOneWidget);
      expect(opened.route.isCurrent, isTrue);
      expect(fixture.transport.posts, hasLength(1));
      expect(fixture.transport.lookups, hasLength(1));
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, controller);
    }
  });

  testWidgets(
      'cover blocks captured actions while late success stays underneath',
      (tester) async {
    final fixture = PublicationControllerFixture();
    final original = PublicationPending(intent: publicationIntent());
    fixture.journal.record = original;
    final pending = Completer<PublicationReceipt?>();
    fixture.transport.lookup = (_) => pending.future;
    final controller = fixture.create(pending: original);
    try {
      final opened = await _open(tester, controller);
      final query = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '查询发布结果'))
          .onPressed!;
      query();
      await _frames(tester, 2);
      unawaited(showDialog<void>(
          context: opened.parent,
          builder: (context) => AlertDialog(
                  title: const Text('独立通知'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭通知'))
                  ])));
      await _frames(tester);
      query();
      expect(fixture.transport.lookups, hasLength(1));
      pending.complete(publicationReceipt());
      await _frames(tester);
      expect(find.text('独立通知'), findsOneWidget);
      expect(opened.route.isCurrent, isFalse);
      expect(controller.phase, PublicationViewPhase.recorded);
      await tester.tap(find.text('关闭通知'));
      await _frames(tester);
      expect(find.text('配置已保存 · 未执行'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await _frames(tester);
      expect(opened.route.available, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, controller, afterUnmount: () {
        if (!pending.isCompleted) pending.complete(publicationReceipt());
      });
    }
  });

  testWidgets('scope loss during a build redacts without setState during build',
      (tester) async {
    final fixture = PublicationControllerFixture();
    final controller = fixture.create();
    final trigger = ValueNotifier<bool>(false);
    try {
      await _open(tester, controller,
          revokeDuringBuild: trigger, onRevoke: fixture.access.awayAndBack);
      trigger.value = true;
      await _frames(tester);
      expect(controller.hasAccess, isFalse);
      expect(find.text('工作空间或权限已变化'), findsOneWidget);
      expect(
          find.byType(PolicyPreviewResults, skipOffstage: false), findsNothing);
      expect(find.text('仅保存配置'), findsNothing);
      expect(fixture.transport.posts, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, controller);
      trigger.dispose();
    }
  });

  testWidgets('narrow large text retains an explicit reachable recovery action',
      (tester) async {
    final fixture = PublicationControllerFixture();
    final original = PublicationPending(intent: publicationIntent());
    fixture.journal.record = original;
    final controller = fixture.create(pending: original);
    try {
      await _open(tester, controller, width: 320, scale: 2);
      final query = find.widgetWithText(FilledButton, '查询发布结果');
      expect(query, findsOneWidget);
      expect(tester.getRect(query).right, lessThanOrEqualTo(320));
      expect(tester.getRect(query).bottom, lessThanOrEqualTo(1000));
      expect(find.text('关闭'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, controller);
    }
  });

  testWidgets('cleanup query keeps its already confirmed result while busy',
      (tester) async {
    final fixture = PublicationControllerFixture();
    fixture.journal.cleanupSucceeds = false;
    final controller = fixture.create();
    final pending = Completer<PublicationReceipt?>();
    try {
      controller.beginConfirmation();
      await controller.submit();
      expect(controller.phase, PublicationViewPhase.cleanupPending);
      fixture.transport.lookup = (_) => pending.future;
      await _open(tester, controller);
      await tester.tap(find.text('重新核对并清理'));
      await _frames(tester, 2);
      expect(controller.phase, PublicationViewPhase.querying);
      expect(find.text('配置已保存 · 未执行'), findsOneWidget);
      expect(find.text('发布已确认，正在核对并清理本机记录；不会再次发布。'), findsOneWidget);
      expect(find.textContaining('本次保存结果尚未确认'), findsNothing);
      expect(fixture.transport.posts, hasLength(1));
      expect(fixture.transport.lookups, hasLength(1));
      pending.complete(publicationReceipt());
      await _frames(tester);
      expect(controller.phase, PublicationViewPhase.cleanupPending);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, controller, afterUnmount: () {
        if (!pending.isCompleted) pending.complete(publicationReceipt());
      });
    }
  });
}
