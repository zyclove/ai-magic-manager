import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/managed_agent_binding_dialog.dart';
import 'managed_agent_binding_fixtures.dart';

Future<void> settleBinding(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

Future<void> mountBinding(WidgetTester tester, AgentBindingFixture fixture,
    {bool writable = true, double width = 900, double scale = 1}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Builder(
          builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                  body: ManagedAgentBindingDialog(
                      repository: fixture.repository,
                      writable: writable,
                      reauthenticate: () {},
                      now: () => fixture.instant))))));
  await settleBinding(tester);
}

void main() {
  testWidgets('select create wait verify and confirm revoke in one dialog',
      (tester) async {
    final f = AgentBindingFixture();
    await mountBinding(tester, f);
    expect(find.text('学习平板'), findsOneWidget);
    await tester.tap(find.text('开始关联'));
    await settleBinding(tester);
    expect(f.createCount, 1);
    expect(find.text('等待儿童端反馈'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.ancestor(
                of: find.text('稍候再核验'),
                matching: find.byWidgetPredicate((w) => w is FilledButton)))
            .onPressed,
        isNull);
    f.instant = f.instant.add(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('核验设备反馈'));
    await settleBinding(tester);
    expect(f.verifyCount, 1);
    expect(find.text('等待儿童端反馈'), findsOneWidget);
    f.proofReady = true;
    f.instant = f.instant.add(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('核验设备反馈'));
    await settleBinding(tester);
    expect(find.text('儿童端身份已核验'), findsOneWidget);
    await tester.tap(find.text('撤销此关联'));
    await settleBinding(tester);
    expect(f.revokeCount, 0);
    await tester.tap(find.text('确认撤销'));
    await settleBinding(tester);
    expect(f.revokeCount, 1);
    expect(find.text('本地关联已撤销'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'uncertain create retries the original request after checking current result',
      (tester) async {
    final f = AgentBindingFixture()..failCreateOnce = true;
    await mountBinding(tester, f);
    await tester.tap(find.text('开始关联'));
    await settleBinding(tester);
    expect(find.text('查询当前结果'), findsOneWidget);
    await tester.tap(find.text('查询当前结果'));
    await settleBinding(tester);
    await tester.tap(find.text('重试原请求'));
    await settleBinding(tester);
    final posts = f.requests.where((r) => r.method == 'POST').toList();
    expect(posts.length, 2);
    expect(posts.first.headers['Idempotency-Key'],
        posts.last.headers['Idempotency-Key']);
    expect(find.text('等待儿童端反馈'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('lost success is recovered by reading without another create',
      (tester) async {
    final f = AgentBindingFixture()
      ..failCreateOnce = true
      ..commitBeforeFailure = true;
    await mountBinding(tester, f);
    await tester.tap(find.text('开始关联'));
    await settleBinding(tester);
    await tester.tap(find.text('查询当前结果'));
    await settleBinding(tester);
    expect(f.createCount, 1);
    expect(find.text('等待儿童端反馈'), findsOneWidget);
    expect(find.text('重试原请求'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'refresh failure disables stale creation and preserves visible information',
      (tester) async {
    final f = AgentBindingFixture();
    await mountBinding(tester, f);
    f.failRead = true;
    await tester.tap(find.text('刷新记录'));
    await settleBinding(tester);
    expect(find.text('学习平板'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始关联'))
            .onPressed,
        isNull);
    expect(f.createCount, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('missing release setup is explained and cannot submit',
      (tester) async {
    final f = AgentBindingFixture()..ready = false;
    await mountBinding(tester, f);
    expect(find.textContaining('儿童端发布版本尚未完成'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始关联'))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'empty candidates give pairing instructions instead of an empty picker',
      (tester) async {
    final f = AgentBindingFixture()..empty = true;
    await mountBinding(tester, f);
    expect(find.textContaining('请先完成这位学生的儿童端配对与激活'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('expiry disables verification and offers an explicit new request',
      (tester) async {
    final f = AgentBindingFixture();
    f.binding = f.record();
    f.instant = f.instant.add(const Duration(minutes: 11));
    await mountBinding(tester, f);
    expect(find.text('关联请求已到期'), findsOneWidget);
    expect(find.text('核验设备反馈'), findsNothing);
    expect(find.text('重新发起关联'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('read-only small-screen large-text layout has no overflow',
      (tester) async {
    final f = AgentBindingFixture();
    f.binding = f.record(state: 'VERIFIED', version: 2);
    await mountBinding(tester, f, writable: false, width: 320, scale: 2);
    expect(find.text('撤销此关联'), findsNothing);
    expect(find.text('开始关联'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
