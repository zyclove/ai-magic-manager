import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'managed_agent_binding_dialog_test.dart'
    show mountBinding, settleBinding;
import 'managed_agent_binding_fixtures.dart';

/// Uses the production repository and dialog with bounded HTTP fixture responses.
class ManyDevicesFixture extends AgentBindingFixture {
  @override
  Json context() => {
        ...super.context(),
        'candidates': {
          'items': [
            for (var i = 1; i <= 6; i++)
              {
                ...device(),
                'id':
                    '44444444-4444-4444-8444-${i.toString().padLeft(12, '0')}',
                'displayName': '学习设备 $i',
              }
          ],
          'nextCursor': null,
        }
      };
}

void main() {
  testWidgets(
      'three steps communicate current progress without granting control',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final f = AgentBindingFixture();
      await mountBinding(tester, f);
      expect(find.text('1 选择设备'), findsOneWidget);
      expect(find.text('2 接收反馈'), findsOneWidget);
      expect(find.text('3 身份核验'), findsOneWidget);
      expect(find.bySemanticsLabel('第 1 步，选择设备，当前步骤'), findsOneWidget);
      await tester.tap(find.text('开始关联'));
      await settleBinding(tester);
      expect(find.bySemanticsLabel('第 1 步，选择设备，已完成'), findsOneWidget);
      expect(find.bySemanticsLabel('第 2 步，接收反馈，当前步骤'), findsOneWidget);
      expect(find.bySemanticsLabel('第 3 步，身份核验，待完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
      'search filters loaded candidates and preserves explicit selection',
      (tester) async {
    final f = ManyDevicesFixture();
    await mountBinding(tester, f);
    final input = find.byType(TextField);
    await tester.enterText(input, '设备 2');
    await tester.pump();
    expect(find.text('学习设备 1'), findsNothing);
    expect(find.text('学习设备 2'), findsOneWidget);
    await tester.tap(find.text('学习设备 2'));
    await tester.pump();
    await tester.enterText(input, '不存在');
    await tester.pump();
    expect(find.textContaining('没有匹配结果'), findsOneWidget);
    expect(find.text('已选：学习设备 2'), findsOneWidget);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    expect(find.text('学习设备 1'), findsOneWidget);
    expect(find.text('已选：学习设备 2'), findsOneWidget);
    expect(
        f.requests.length, 1); // Local filtering causes no additional request.
    expect(f.createCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'countdown reaches expiry without polling or extending the request',
      (tester) async {
    final f = AgentBindingFixture();
    f.binding = f.record();
    f.instant = DateTime.fromMillisecondsSinceEpoch(
        (f.binding!['expiresAt'] as int) - 500);
    await mountBinding(tester, f);
    expect(find.text('剩余 0 分 1 秒'), findsOneWidget);
    f.instant = f.instant.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('关联请求已到期'), findsOneWidget);
    expect(find.text('核验设备反馈'), findsNothing);
    expect(f.requests.length, 1);
    expect(f.verifyCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending verification explains the result and keeps one request',
      (tester) async {
    final f = AgentBindingFixture();
    f.binding = f.record();
    await mountBinding(tester, f);
    await tester.tap(find.text('核验设备反馈'));
    await settleBinding(tester);
    expect(find.textContaining('刚刚核验仍未收到有效反馈'), findsOneWidget);
    expect(f.verifyCount, 1);
    expect(f.createCount, 0);
    expect(find.text('重新发起关联'), findsNothing);
    await tester.tap(find.text('一直在等待？查看排查方法'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保持儿童端在前台'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending guide supports narrow screens and large text',
      (tester) async {
    final f = AgentBindingFixture();
    f.binding = f.record();
    await mountBinding(tester, f, writable: false, width: 320, scale: 2);
    await tester.ensureVisible(find.text('一直在等待？查看排查方法'));
    await tester.tap(find.text('一直在等待？查看排查方法'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('核验设备反馈'), findsNothing);
    expect(f.requests.length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'verified identity has a clear completion action without enforcement claims',
      (tester) async {
    final f = AgentBindingFixture();
    f.binding = f.record(state: 'VERIFIED', version: 2);
    await mountBinding(tester, f);
    expect(
        find.ancestor(
            of: find.text('完成'),
            matching:
                find.byWidgetPredicate((widget) => widget is FilledButton)),
        findsOneWidget);
    expect(find.text('关闭'), findsNothing);
    expect(find.textContaining('需要另行查看设备的执行回执'), findsOneWidget);
    expect(find.text('核验设备反馈'), findsNothing);
    expect(f.requests.length, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
