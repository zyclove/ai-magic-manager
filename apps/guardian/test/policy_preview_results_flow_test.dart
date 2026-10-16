@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'policy_target_picker_test.dart' show reply;
import 'policy_preview_flow_test.dart'
    show PreviewSession, startFlow, selectGroup, closeResult, previewFor;
import 'policy_target_picker_test.dart' show settle;

void main() {
  testWidgets('device checks can be expanded separately', (tester) async {
    final session = PreviewSession(groups: true);
    final flow = await startFlow(tester, session);
    await selectGroup(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    final first = find.widgetWithText(ExpansionTile, '班级平板 group-1');
    final second = find.widgetWithText(ExpansionTile, '班级平板 group-2');
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(find.text('域名访问'), findsNothing);
    await tester.ensureVisible(first);
    await tester.tap(first);
    await settle(tester);
    expect(find.text('域名访问'), findsOneWidget);
    await tester.ensureVisible(second);
    await tester.tap(second);
    await settle(tester);
    expect(find.text('域名访问'), findsNWidgets(2));
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
    expect(tester.takeException(), isNull);
  });

  testWidgets('summary counts compiled device checks instead of source rules',
      (tester) async {
    final session = PreviewSession(groups: true);
    session.respond = (request) async {
      final preview = previewFor(request);
      final targets = preview['targets'] as List;
      final secondRules = (targets[1] as Json)['rules'] as List;
      (secondRules[1] as Json)['status'] = 'UNSUPPORTED';
      (secondRules[1] as Json)['reasonCode'] = 'MANAGED_REGISTRATION_REQUIRED';
      return reply(preview);
    };
    final flow = await startFlow(tester, session);
    await selectGroup(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    // Three source rules compile to two checks for each of the two devices.
    expect(find.text('2 台设备'), findsOneWidget);
    expect(find.text('4 项检查'), findsOneWidget);
    expect(find.text('受限 1 项'), findsOneWidget);
    expect(find.text('待核验 3 项'), findsOneWidget);
    expect(find.text('支持条件满足 0 项'), findsOneWidget);
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
  });

  testWidgets(
      'future rule states remain unverified and never display execution success',
      (tester) async {
    final session = PreviewSession(groups: true);
    session.respond = (request) async {
      final preview = previewFor(request);
      final targets = preview['targets'] as List;
      ((targets.first as Json)['rules'] as List).first['status'] =
          'FUTURE_STATE';
      ((targets.first as Json)['rules'] as List).first['reasonCode'] =
          'FUTURE_REASON';
      return reply(preview);
    };
    final flow = await startFlow(tester, session);
    await selectGroup(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(find.text('待核验 4 项'), findsOneWidget);
    final first = find.widgetWithText(ExpansionTile, '班级平板 group-1');
    await tester.ensureVisible(first);
    await tester.tap(first);
    await settle(tester);
    expect(find.text('检查状态待确认'), findsOneWidget);
    expect(find.text('已生效'), findsNothing);
    expect(find.text('支持执行'), findsNothing);
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
  });

  testWidgets('scope renewal hides expanded device checks and all save actions',
      (tester) async {
    final session = PreviewSession(groups: true);
    final flow = await startFlow(tester, session);
    await selectGroup(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    final first = find.widgetWithText(ExpansionTile, '班级平板 group-1');
    await tester.ensureVisible(first);
    await tester.tap(first);
    await settle(tester);
    expect(find.text('域名访问'), findsOneWidget);
    session.renewScope();
    await settle(tester);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    expect(find.text('域名访问'), findsNothing);
    expect(find.text('仅保存配置'), findsNothing);
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
  });

  testWidgets(
      'compiler contract boundary keeps supported checks pending execution',
      (tester) async {
    final session = PreviewSession(groups: true);
    session.respond = (request) async {
      final preview = previewFor(request);
      for (final target in preview['targets'] as List) {
        target['rules'] = (target['rules'] as List)
            .where((rule) => rule['kind'] == 'DOMAIN_ACCESS')
            .toList();
      }
      final rule = ((preview['targets'] as List).first['rules'] as List).single;
      rule['status'] = 'SUPPORTED_PENDING';
      rule['reasonCode'] = 'AWAITING_EXECUTION';
      preview['snapshot']['sourceRules'] =
          (preview['snapshot']['sourceRules'] as List)
              .where((rule) => rule['kind'] == 'DOMAIN_ACCESS')
              .toList();
      preview['snapshot']['applications'] = <Json>[];
      return reply(preview);
    };
    final flow = await startFlow(tester, session);
    await selectGroup(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(find.text('2 项检查'), findsOneWidget);
    expect(find.text('支持条件满足 1 项'), findsOneWidget);
    expect(find.text('待核验 1 项'), findsOneWidget);
    final first = find.widgetWithText(ExpansionTile, '班级平板 group-1');
    await tester.ensureVisible(first);
    await tester.tap(first);
    await settle(tester);
    expect(find.text('支持条件满足 · 尚未执行'), findsOneWidget);
    expect(find.text('已生效'), findsNothing);
    expect(find.text('支持执行'), findsNothing);
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
  });

  testWidgets('empty device checks do not imply a successful check',
      (tester) async {
    final session = PreviewSession(groups: true);
    session.respond = (request) async {
      final preview = previewFor(request);
      (preview['targets'] as List).first['rules'] = <Json>[];
      return reply(preview);
    };
    final flow = await startFlow(tester, session);
    await selectGroup(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(find.text('2 项检查'), findsOneWidget);
    final first = find.widgetWithText(ExpansionTile, '班级平板 group-1');
    await tester.ensureVisible(first);
    await tester.tap(first);
    await settle(tester);
    expect(find.text('此设备没有检查项'), findsOneWidget);
    expect(find.text('全部通过'), findsNothing);
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
  });

  testWidgets('expired previews cannot enter save confirmation',
      (tester) async {
    final session = PreviewSession(groups: true);
    session.respond = (request) async {
      final preview = previewFor(request);
      preview['expiresAt'] = DateTime.now().millisecondsSinceEpoch - 1000;
      return reply(preview);
    };
    final flow = await startFlow(tester, session);
    await selectGroup(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(find.text('预览已过期，请关闭后重新预览。'), findsOneWidget);
    await tester.tap(find.text('仅保存配置'));
    await settle(tester);
    expect(find.text('发布配置'), findsNothing);
    expect(find.text('此预览已过期，请关闭窗口后重新预览。'), findsOneWidget);
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview expiry during confirmation prevents publication',
      (tester) async {
    final session = PreviewSession(groups: true);
    var deadline = 0;
    session.respond = (request) async {
      final preview = previewFor(request);
      deadline = DateTime.now().millisecondsSinceEpoch + 2000;
      preview['expiresAt'] = deadline;
      return reply(preview);
    };
    final flow = await startFlow(tester, session);
    await selectGroup(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    await tester.tap(find.text('仅保存配置'));
    await settle(tester);
    expect(find.text('发布配置'), findsNWidgets(2));
    await tester.runAsync(() async {
      final remaining = deadline - DateTime.now().millisecondsSinceEpoch;
      if (remaining >= 0) {
        await Future<void>.delayed(Duration(milliseconds: remaining + 50));
      }
    });
    await tester.tap(find.widgetWithText(FilledButton, '发布配置'));
    await settle(tester);
    expect(find.text('此预览已过期，请关闭窗口后重新预览。'), findsOneWidget);
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full result dialog works on a narrow screen with large text',
      (tester) async {
    final session = PreviewSession(groups: true);
    final flow = await startFlow(tester, session, width: 390, scale: 2);
    await selectGroup(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(find.text('2 台设备'), findsOneWidget);
    final first = find.text('班级平板 group-1');
    await tester.ensureVisible(first);
    await tester.tap(first);
    await settle(tester);
    expect(find.text('域名访问'), findsOneWidget);
    await tester.ensureVisible(find.text('域名访问'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
  });
}
