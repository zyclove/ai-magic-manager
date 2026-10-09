import 'package:child/core/session.dart';
import 'package:child/ui/design.dart';
import 'package:child/ui/submission_section.dart';
import 'package:device_access/device_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/identity_fixture.dart';
import 'support/submission_fixture.dart';
import 'submission_session_test.dart' show idle;

void main() {
  late IdentityFixture identity;
  late SubmissionFixture receiver;
  late ChildSession session;
  setUp(() async {
    identity = IdentityFixture();
    await identity.activate();
    receiver = SubmissionFixture();
    await receiver.open();
    session = ChildSession(
        identity: identity.identity, submissionFactory: (_) async => receiver);
    await session.initialize();
    await idle(session);
  });
  tearDown(() async {
    session.dispose();
    identity.close();
    await receiver.dispose();
  });
  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: childTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: SubmissionSection(
                        session: session, available: true))))));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).last);
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'new request requires a separate confirmation and preserves entered input',
      (tester) async {
    await show(tester);
    await tap(tester, '申请临时访问');
    await tap(tester, '阅读空间');
    await tester.enterText(find.byKey(const Key('submission-reason')), '完成阅读');
    await tap(tester, '核对申请');
    expect(session.submissions.journal?.pending, isNull);
    expect(find.text('确认申请内容'), findsOneWidget);
    await tap(tester, '提交给监护人');
    expect(
        session
            .submissions.journal!.entries.single.value.requestedWindowSeconds,
        600);
    expect(session.submissions.journal!.entries.single.value.reason, '完成阅读');
    expect(find.text('等待监护人审批'), findsOneWidget);
    expect(find.text('已解锁'), findsNothing);
  });
  testWidgets(
      'unknown outcome has original retry and no discard or new request',
      (tester) async {
    receiver.loseResponse = true;
    await tester.runAsync(() => session
        .createSubmission(SubmissionFixture.input(), applicationName: '阅读空间'));
    await show(tester);
    expect(find.text('结果待确认'), findsOneWidget);
    expect(find.text('放弃本次操作'), findsNothing);
    final button = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '申请临时访问'));
    expect(button.onPressed, isNull);
    await tap(tester, '按原操作重试');
    expect(find.text('确认原操作'), findsOneWidget);
    expect(find.text('完成阅读'), findsOneWidget);
    receiver.loseResponse = false;
    await tap(tester, '确认重试');
    expect(session.submissions.journal!.pending, isNull);
    expect(find.text('等待监护人审批'), findsOneWidget);
  });
  testWidgets('empty filtered options remain pageable', (tester) async {
    receiver.options = [];
    receiver.optionsCursor = SubmissionFixture.policy;
    await tester.runAsync(session.refreshSubmissions);
    await show(tester);
    expect(find.text('当前页暂无可申请应用'), findsOneWidget);
    await tap(tester, '继续查找应用');
    await tap(tester, '申请临时访问');
    expect(find.text('阅读空间'), findsOneWidget);
  });
  testWidgets(
      'background removes private reason from an open form and closes it',
      (tester) async {
    await show(tester);
    await tap(tester, '申请临时访问');
    await tap(tester, '阅读空间');
    await tester.enterText(find.byKey(const Key('submission-reason')), '私人理由');
    await session.setForeground(false);
    await tester.pumpAndSettle();
    expect(find.text('私人理由'), findsNothing);
    expect(find.byKey(const Key('submission-reason')), findsNothing);
    expect(find.text('确认申请内容'), findsNothing);
    expect(session.submissions.journal, isNull);
  });
  testWidgets(
      'detail explains cached status and cancellation needs confirmation',
      (tester) async {
    await tester
        .runAsync(() => session.submissionDetail(SubmissionFixture.request));
    await show(tester);
    await tap(tester, '查看申请');
    await tap(tester, '取消申请');
    expect(session.submissions.journal!.entries.single.value.state, 'PENDING');
    expect(find.text('确认取消这份申请？'), findsOneWidget);
    await tap(tester, '确认取消');
    expect(
        session.submissions.journal!.entries.single.value.state, 'CANCELLED');
    expect(find.text('已取消'), findsOneWidget);
  });
  testWidgets('small screen with enlarged text can confirm without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await show(tester);
    await tap(tester, '申请临时访问');
    await tap(tester, '阅读空间');
    await tap(tester, '核对申请');
    expect(find.text('确认申请内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('invalid duration and empty rule selection cannot submit',
      (tester) async {
    await show(tester);
    await tap(tester, '申请临时访问');
    await tap(tester, '阅读空间');
    await tester.enterText(find.byKey(const Key('submission-minutes')), '61');
    await tap(tester, '核对申请');
    expect(find.text('请输入 1–60 分钟'), findsOneWidget);
    expect(session.submissions.journal?.pending, isNull);
    await tester.enterText(find.byKey(const Key('submission-minutes')), '10');
    await tester.ensureVisible(find.byType(CheckboxListTile).first);
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tap(tester, '核对申请');
    expect(find.text('请选择 1–20 条限制'), findsOneWidget);
    expect(find.text('确认申请内容'), findsNothing);
  });
  testWidgets('keyboard focus can activate the request button', (tester) async {
    await show(tester);
    final button = find.widgetWithText(FilledButton, '申请临时访问');
    await tester.ensureVisible(button);
    tester.widget<FilledButton>(button).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('选择申请应用'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('填写访问申请'), findsOneWidget);
  });
  testWidgets('explicitly rejected intent can be discarded after confirmation',
      (tester) async {
    await tester.runAsync(() async {
      await receiver.journal.prepareCreate(SubmissionFixture.input(),
          key: 'rejected-ui',
          applicationName: '阅读空间',
          now: IdentityFixture.now);
      await receiver.journal.markSending('rejected-ui');
      await receiver.journal.reject('rejected-ui', 'ACCESS_REQUEST_COOLDOWN');
      await session.refreshSubmissions();
    });
    await show(tester);
    expect(find.text('本次操作未提交'), findsOneWidget);
    await tap(tester, '放弃本次操作');
    expect(session.submissions.journal!.pending, isNotNull);
    await tap(tester, '确认放弃');
    expect(session.submissions.journal!.pending, isNull);
    expect(find.text('按原操作重试'), findsNothing);
  });
  testWidgets('detail loses private content after authentication rejection',
      (tester) async {
    await tester
        .runAsync(() => session.submissionDetail(SubmissionFixture.request));
    await show(tester);
    await tap(tester, '查看申请');
    expect(find.text('完成阅读'), findsOneWidget);
    receiver.failure =
        const AccessTransportFailure('DEVICE_UNAUTHENTICATED', status: 401);
    await tester.runAsync(session.refreshSubmissions);
    await tester.pumpAndSettle();
    expect(find.text('完成阅读'), findsNothing);
    expect(find.text('申请详情'), findsNothing);
    expect(find.text('取消申请'), findsNothing);
  });
  testWidgets('application choices expose actionable button semantics',
      (tester) async {
    final handle = tester.ensureSemantics();
    await show(tester);
    await tap(tester, '申请临时访问');
    final node = tester.getSemantics(find.bySemanticsLabel(RegExp('^阅读空间')));
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    handle.dispose();
  });
  testWidgets(
      'optional reason stays consistent after create and detail refresh',
      (tester) async {
    await show(tester);
    await tap(tester, '申请临时访问');
    await tap(tester, '阅读空间');
    await tap(tester, '核对申请');
    await tap(tester, '提交给监护人');
    await tap(tester, '查看申请');
    expect(find.text('未填写'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '取消申请'))
            .onPressed,
        isNotNull);
    await tap(tester, '取消申请');
    await tap(tester, '确认取消');
    expect(
        session.submissions.journal!.entries.single.value.state, 'CANCELLED');
  });
}
