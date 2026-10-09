import 'package:child/core/access.dart';
import 'package:child/ui/access_section.dart';
import 'package:child/ui/design.dart';
import 'package:device_access/device_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../packages/device_access/test/fixtures.dart' as grants;

void main() {
  ChildAccessEntry entry(AccessEntryState state,
          {bool review = false, bool pending = false}) =>
      ChildAccessEntry(
          AccessJournalEntry(
              VerifiedAccessWindow.internal(
                  'not-a-real-jws-for-ui-only', grants.envelope()),
              state,
              pendingAcknowledgement: pending),
          '阅读练习',
          requiresReview: review);
  Future<void> show(WidgetTester tester, ChildAccessSnapshot view,
      {String? error,
      bool available = true,
      VoidCallback? sync,
      double scale = 1}) async {
    await tester.pumpWidget(MaterialApp(
        theme: childTheme(),
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        home: Scaffold(
            body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: AccessSection(
                        view: view,
                        errorCode: error,
                        available: available,
                        synchronize: sync))))));
  }

  testWidgets(
      'offline stored state explains original deadline and never claims apps unlocked',
      (tester) async {
    await show(
        tester,
        ChildAccessSnapshot(
            contextReady: true,
            entries: [entry(AccessEntryState.stored, pending: true)],
            pendingReceipts: 1));
    expect(find.text('临时访问'), findsOneWidget);
    expect(find.text('阅读练习'), findsOneWidget);
    expect(find.textContaining('等待服务确认'), findsWidgets);
    expect(find.textContaining('尚未在线核对'), findsWidgets);
    await tester.tap(find.text('阅读练习'));
    await tester.pumpAndSettle();
    expect(find.text('原截止时间'), findsOneWidget);
    expect(find.textContaining('不会自动延长'), findsWidgets);
    expect(find.textContaining('not-a-real-jws'), findsNothing);
    expect(find.text('立即打开应用'), findsNothing);
  });
  testWidgets('review, expiry and removal display explicit distinct states',
      (tester) async {
    for (final value in [
      (AccessEntryState.stored, true, '需要重新核对'),
      (AccessEntryState.expired, false, '已到期'),
      (AccessEntryState.removed, false, '已撤回')
    ]) {
      await show(
          tester,
          ChildAccessSnapshot(
              contextReady: true,
              entries: [entry(value.$1, review: value.$2)]));
      expect(find.text(value.$3), findsOneWidget);
    }
  });
  testWidgets(
      'narrow large text, disabled action and remote enter work without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var calls = 0;
    await show(tester, const ChildAccessSnapshot(),
        scale: 2, available: false, sync: () => calls++);
    await tester.scrollUntilVisible(find.text('同步临时访问'), 200);
    await tester.tap(find.text('同步临时访问'));
    expect(calls, 0);
    expect(tester.takeException(), isNull);
    await show(tester, const ChildAccessSnapshot(), sync: () => calls++);
    await tester.scrollUntilVisible(find.text('同步临时访问'), 200);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'large history is progressively displayed and errors use fixed copy',
      (tester) async {
    await show(
        tester,
        ChildAccessSnapshot(
            contextReady: true,
            entries: List.generate(12, (_) => entry(AccessEntryState.expired))),
        error: 'untrusted-copy');
    expect(find.text('阅读练习'), findsNWidgets(8));
    expect(find.text('untrusted-copy'), findsNothing);
    await tester.scrollUntilVisible(find.text('显示更多记录'), 300);
    await tester.tap(find.text('显示更多记录'));
    await tester.pump();
    expect(find.text('阅读练习'), findsNWidgets(12));
  });
}
