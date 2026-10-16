import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/workspace_read_recovery.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/workspace_welcome.dart';

Future<void> mountWelcome(WidgetTester tester,
        {FutureOr<void> Function()? onCreate,
        FutureOr<void> Function()? onJoin,
        FutureOr<void> Function()? onRefresh,
        Object? identity,
        bool Function()? current,
        VoidCallback? onSignOut}) =>
    tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: WorkspaceWelcome(
                    onCreate: onCreate,
                    onJoin: onJoin ?? () {},
                    onRefresh: onRefresh,
                    authenticationIdentity: identity,
                    isCurrent: current,
                    onSignOut: onSignOut)))));

Future<void> tapVisible(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pump();
}

void main() {
  testWidgets('create and invitation remain separate intentional actions',
      (tester) async {
    var creates = 0, joins = 0;
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: WorkspaceWelcome(onCreate: () {
          creates++;
        }, onJoin: () {
          joins++;
        }))));
    await tester.tap(find.text('创建工作空间'));
    expect(creates, 1);
    expect(joins, 0);
    await tester.tap(find.text('使用邀请加入'));
    expect(joins, 1);
    expect(find.text('平台工具'), findsNothing);
  });
  testWidgets('users without creation access only see invitation entry',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: WorkspaceWelcome(onJoin: () {}))));
    expect(find.text('加入你的工作空间'), findsOneWidget);
    expect(find.text('创建工作空间'), findsNothing);
    expect(find.text('使用邀请加入'), findsOneWidget);
  });
  testWidgets(
      'mobile large text keeps actions usable and platform tools secondary',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
                body: SingleChildScrollView(
                    padding: const EdgeInsets.all(18),
                    child: WorkspaceWelcome(
                        onCreate: () {},
                        onJoin: () {},
                        platformTools: [
                          TextButton(
                              onPressed: () {}, child: const Text('产品目录'))
                        ]))))));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('使用邀请加入'));
    expect(find.text('使用邀请加入').hitTestable(), findsOneWidget);
    expect(find.text('平台工具'), findsOneWidget);
  });
  testWidgets(
      'one pending action disables all workspace write and read entries',
      (tester) async {
    final pending = Completer<void>();
    var creates = 0, joins = 0, reads = 0;
    await mountWelcome(tester, onCreate: () {
      creates++;
      return pending.future;
    }, onJoin: () {
      joins++;
    }, onRefresh: () {
      reads++;
    });
    await tapVisible(tester, '创建工作空间');
    await tapVisible(tester, '创建工作空间');
    await tapVisible(tester, '使用邀请加入');
    await tapVisible(tester, '刷新工作空间列表');
    expect(creates, 1);
    expect(joins, 0);
    expect(reads, 0);
    pending.complete();
    await tester.pumpAndSettle();
    await tapVisible(tester, '使用邀请加入');
    expect(joins, 1);
  });
  testWidgets(
      'completed creation survives failed GET retries without another write',
      (tester) async {
    var writes = 0, reads = 0;
    final recovery = WorkspaceReadRecovery(
        completedMessage: '工作空间已创建，工作空间资料暂未加载。',
        error: const ApiFailure(503, 'READ_UNAVAILABLE'),
        isCurrent: () => true,
        reload: () async {
          reads++;
          if (reads == 1) throw const ApiFailure(503, 'READ_STILL_UNAVAILABLE');
        });
    await mountWelcome(tester, onCreate: () async {
      writes++;
      throw recovery;
    });
    await tapVisible(tester, '创建工作空间');
    await tester.pumpAndSettle();
    expect(find.text(recovery.completedMessage), findsOneWidget);
    expect(find.text('无需再次创建或接受邀请。重试只会读取工作空间资料。'), findsOneWidget);
    await tapVisible(tester, '创建工作空间');
    expect(writes, 1);
    await tapVisible(tester, '重试读取');
    await tester.pumpAndSettle();
    expect(find.text(recovery.completedMessage), findsOneWidget);
    expect(reads, 1);
    await tapVisible(tester, '重试读取');
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(writes, 1);
    expect(find.text('工作空间资料已刷新。'), findsOneWidget);
    expect(find.text('重试读取'), findsNothing);
  });
  testWidgets('pending recovery read cannot be dispatched twice',
      (tester) async {
    final pending = Completer<void>();
    var reads = 0;
    final recovery = WorkspaceReadRecovery(
        completedMessage: '已加入工作空间。',
        error: const ApiFailure(503, 'READ_UNAVAILABLE'),
        isCurrent: () => true,
        reload: () {
          reads++;
          return pending.future;
        });
    await mountWelcome(tester, onJoin: () async {
      throw recovery;
    });
    await tapVisible(tester, '使用邀请加入');
    await tester.pumpAndSettle();
    await tapVisible(tester, '重试读取');
    await tapVisible(tester, '重试读取');
    expect(reads, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('重试读取'), findsNothing);
  });
  testWidgets(
      'cancelled dialog completion has no success notice or follow-up read',
      (tester) async {
    var reads = 0;
    await mountWelcome(tester, onCreate: () async {}, onRefresh: () {
      reads++;
    });
    await tapVisible(tester, '创建工作空间');
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(find.byType(WorkspaceReadRecoveryPanel), findsNothing);
    expect(find.text('工作空间资料已刷新。'), findsNothing);
  });
  testWidgets(
      'list refresh errors release busy and keep a visible sign-out exit',
      (tester) async {
    var reads = 0, exits = 0;
    await mountWelcome(tester, onRefresh: () async {
      reads++;
      if (reads == 1) throw const ApiFailure(503, 'READ_UNAVAILABLE');
    }, onSignOut: () {
      exits++;
    });
    await tapVisible(tester, '刷新工作空间列表');
    await tester.pumpAndSettle();
    expect(find.text('工作空间资料暂未加载，请刷新列表重试。'), findsOneWidget);
    await tapVisible(tester, '退出并重新登录');
    expect(exits, 1);
    await tapVisible(tester, '刷新工作空间列表');
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('工作空间资料已刷新。'), findsOneWidget);
  });
  testWidgets(
      'new authentication identity discards late errors and releases its busy state',
      (tester) async {
    final oldRead = Completer<void>();
    final first = Object(), second = Object();
    await mountWelcome(tester, identity: first, onJoin: () => oldRead.future);
    await tapVisible(tester, '使用邀请加入');
    var nextActions = 0;
    await mountWelcome(tester, identity: second, onJoin: () {
      nextActions++;
    });
    oldRead.completeError(const ApiFailure(503, 'OLD_ACCOUNT_READ'));
    await tester.pumpAndSettle();
    expect(find.text('工作空间资料暂未加载，请刷新列表重试。'), findsNothing);
    await tapVisible(tester, '使用邀请加入');
    expect(nextActions, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('invalidated scope cannot retry or invoke old account sign-out',
      (tester) async {
    var live = true, reads = 0, exits = 0;
    final identity = Object();
    final recovery = WorkspaceReadRecovery(
        completedMessage: '原账号已加入。',
        error: const ApiFailure(503, 'READ_UNAVAILABLE'),
        isCurrent: () => live,
        reload: () async {
          reads++;
        });
    await mountWelcome(tester,
        identity: identity,
        current: () => live,
        onJoin: () async {
          throw recovery;
        },
        onSignOut: () {
          exits++;
        });
    await tapVisible(tester, '使用邀请加入');
    await tester.pumpAndSettle();
    final oldRetry = tester
        .widget<FilledButton>(find.ancestor(
            of: find.text('重试读取'),
            matching:
                find.byWidgetPredicate((widget) => widget is FilledButton)))
        .onPressed!;
    final oldExit = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '退出并重新登录'))
        .onPressed!;
    live = false;
    oldRetry();
    oldExit();
    expect(reads, 0);
    expect(exits, 0);
    await mountWelcome(tester, identity: identity, current: () => live);
    expect(find.text('原账号已加入。'), findsNothing);
    expect(find.text('账号会话已变化，请返回当前账号页面。'), findsOneWidget);
  });
  testWidgets('disposing before completion ignores the old asynchronous result',
      (tester) async {
    final pending = Completer<void>();
    await mountWelcome(tester, onJoin: () => pending.future);
    await tapVisible(tester, '使用邀请加入');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.completeError(const ApiFailure(503, 'OLD_READ'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  for (final width in [340.0, 390.0]) {
    testWidgets(
        'recovery actions remain reachable at width $width with large text',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final recovery = WorkspaceReadRecovery(
          completedMessage: '工作空间已创建，工作空间资料暂未加载。',
          error: const ApiFailure(503, 'READ_UNAVAILABLE'),
          reload: () async {},
          isCurrent: () => true);
      await tester.pumpWidget(MaterialApp(
          theme: consoleTheme(),
          home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: Scaffold(
                  body: SingleChildScrollView(
                      padding: const EdgeInsets.all(18),
                      child: WorkspaceWelcome(
                          onJoin: () async {
                            throw recovery;
                          },
                          onSignOut: () {}))))));
      await tapVisible(tester, '使用邀请加入');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('重试读取'));
      expect(find.text('重试读取').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
