@TestOn('browser')
library;

import 'dart:async';
import 'package:flutter/material.dart' hide Flow;
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:http/http.dart' as http;
import 'policy_preview_flow_test.dart'
    show PreviewSession, Flow, startFlow, selectGroup, closeResult, flush;
import 'policy_target_picker_test.dart' show reply, settle;

Json _publication() => {
      'id': 'publication-a',
      'versionId': 'version-a',
      'sequence': 1,
      'mode': 'CONFIGURE_ONLY',
      'state': 'CONFIGURED_NOT_ENFORCED',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };

Future<Flow> _openPreview(WidgetTester tester, PreviewSession session) async {
  final flow = await startFlow(tester, session);
  await selectGroup(tester);
  await tester.tap(find.text('预览这些设备'));
  await settle(tester);
  return flow;
}

Future<void> _confirmSave(WidgetTester tester) async {
  await tester.tap(find.text('仅保存配置'));
  await settle(tester);
  await tester.tap(find.widgetWithText(FilledButton, '发布配置'));
}

void main() {
  testWidgets('cancelling save keeps the expanded preview and its selection',
      (tester) async {
    final session = PreviewSession(groups: true);
    final flow = await _openPreview(tester, session);
    await tester.ensureVisible(find.text('班级平板 group-1'));
    await tester.tap(find.text('班级平板 group-1'));
    await settle(tester);
    expect(find.text('域名访问'), findsOneWidget);
    await tester.tap(find.text('仅保存配置'));
    await settle(tester);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(find.text('发布前预览'), findsOneWidget);
    expect(find.text('2 台设备'), findsOneWidget);
    expect(find.text('域名访问'), findsOneWidget);
    expect(flow.completed, isFalse);
    expect(session.previews, hasLength(1));
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a successful configuration fixture closes only its own preview',
      (tester) async {
    final session = PreviewSession(groups: true);
    session.intercept = (request) async {
      if (request.method == 'POST' &&
          request.url.path.endsWith('/publications')) {
        session.publications.add(request);
        return reply(_publication());
      }
      return null;
    };
    final flow = await _openPreview(tester, session);
    await _confirmSave(tester);
    // Route disposal starts the following GET; advance its real async turn.
    await settle(tester);
    await settle(tester);
    expect(find.text('发布结果'), findsOneWidget);
    expect(session.publications, hasLength(1));
    await tester.tap(find.text('关闭').last);
    await settle(tester);
    expect(find.text('发布前预览'), findsNothing);
    expect(flow.completed, isTrue);
    await flow.done;
    expect(flow.failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late save success never closes a covering notice',
      (tester) async {
    final pending = Completer<http.Response>();
    final session = PreviewSession(groups: true);
    session.intercept = (request) async {
      if (request.method == 'POST' &&
          request.url.path.endsWith('/publications')) {
        session.publications.add(request);
        return pending.future;
      }
      return null;
    };
    final flow = await _openPreview(tester, session);
    await _confirmSave(tester);
    await flush(tester);
    expect(session.publications, hasLength(1));
    final notice = showDialog<void>(
      context: flow.context,
      builder: (context) => AlertDialog(
        title: const Text('另一条通知'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭通知')),
        ],
      ),
    );
    await settle(tester);
    pending.complete(reply(_publication()));
    await settle(tester);
    expect(find.text('发布结果'), findsOneWidget);
    await tester.tap(find.text('关闭').last);
    await settle(tester);
    expect(find.text('另一条通知'), findsOneWidget);
    expect(flow.completed, isFalse);
    await tester.tap(find.text('关闭通知'));
    await settle(tester);
    await notice;
    expect(find.text('发布前预览'), findsOneWidget);
    await closeResult(tester, flow);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued save callbacks open only one confirmation',
      (tester) async {
    final session = PreviewSession(groups: true);
    final flow = await _openPreview(tester, session);
    final button = tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '仅保存配置'));
    // Two already queued callbacks can arrive before the disabled-button frame.
    button.onPressed!();
    button.onPressed!();
    await settle(tester);
    expect(find.text('发布配置'), findsNWidgets(2));
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(find.text('发布前预览'), findsOneWidget);
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
    expect(tester.takeException(), isNull);
  });
}
