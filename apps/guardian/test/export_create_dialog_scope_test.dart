import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/audit.dart';
import 'package:guardian/core/audit_exports.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/export_create_dialog.dart';
import 'package:http/http.dart' as http;
import 'audit_exports_test.dart' show job, now, repository, response;

Future<void> openExportDialog(
    WidgetTester tester, AuditExportRepository repository,
    {Listenable? accessChanges,
    required ValueChanged<AuditExportJob> onCreated,
    VoidCallback? onReauth,
    VoidCallback? onClosed}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    await showDialog<void>(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => ExportCreateDialog(
                            repository: repository,
                            query: const AuditQuery(
                                from: now - 60000, to: now),
                            accessChanges: accessChanges,
                            onCreated: onCreated,
                            onReauth: onReauth ?? () {}));
                    onClosed?.call();
                  },
                  child: const Text('打开导出窗口'))))));
  await tester.tap(find.text('打开导出窗口'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('current busy export stays open and rejects a duplicate submit',
      (tester) async {
    final pending = Completer<http.Response>();
    var requests = 0, created = 0, closed = 0;
    final repo = repository((_) {
      requests++;
      return pending.future;
    });
    await openExportDialog(tester, repo,
        onCreated: (_) => created++, onClosed: () => closed++);
    final submit = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '生成导出'))
        .onPressed!;
    await tester.tap(find.text('生成导出'));
    await tester.pump();
    submit();
    await tester.pump();
    expect(requests, 1);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
            .onPressed,
        isNull);
    await Navigator.of(tester.element(find.byType(ExportCreateDialog)))
        .maybePop();
    await tester.pump();
    expect(find.byType(ExportCreateDialog), findsOneWidget);
    expect(closed, 0);
    expect(created, 0);

    pending.complete(response(job(), 202));
    await tester.pumpAndSettle();
    expect(created, 1);
    expect(requests, 1);
    expect(find.text('导出任务已创建。'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(closed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalidated pending export closes before its request completes',
      (tester) async {
    final pending = Completer<http.Response>();
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    var active = true;
    var requests = 0, created = 0, closed = 0;
    final repo = repository((_) {
      requests++;
      return pending.future;
    }, current: () => active);
    await openExportDialog(tester, repo,
        accessChanges: changes,
        onCreated: (_) => created++,
        onClosed: () => closed++);
    await tester.tap(find.text('生成导出'));
    await tester.pump();
    active = false;
    changes.notifyListeners();
    await tester.pump();
    expect(find.text('工作空间或权限已变化，请关闭窗口后重新操作。'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
            .onPressed,
        isNotNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(ExportCreateDialog), findsNothing);
    expect(closed, 1);
    expect(pending.isCompleted, isFalse);

    pending.complete(response(job(), 202));
    await tester.pumpAndSettle();
    expect(created, 0);
    expect(requests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('access ABA cannot revive a late export result or submit action',
      (tester) async {
    final pending = Completer<http.Response>();
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    var active = true;
    var requests = 0, created = 0;
    final repo = repository((_) {
      requests++;
      return pending.future;
    }, current: () => active);
    await openExportDialog(tester, repo,
        accessChanges: changes, onCreated: (_) => created++);
    final staleSubmit = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '生成导出'))
        .onPressed!;
    await tester.tap(find.text('生成导出'));
    await tester.pump();
    active = false;
    changes.notifyListeners();
    active = true;
    changes.notifyListeners();
    await tester.pump();
    expect(find.text('工作空间或权限已变化，请关闭窗口后重新操作。'), findsOneWidget);

    pending.complete(response(job(), 202));
    await tester.pumpAndSettle();
    staleSubmit();
    await tester.pump();
    expect(created, 0);
    expect(requests, 1);
    expect(find.text('导出任务已创建。'), findsNothing);
    expect(find.text('生成导出'), findsNothing);
    expect(find.text('重试生成'), findsNothing);
    expect(find.text('工作空间或权限已变化，请关闭窗口后重新操作。'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('MFA stays explicit and a lost scope rejects its stale callback',
      (tester) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    var active = true;
    var requests = 0, reauthentications = 0, created = 0;
    final repo = repository((_) {
      requests++;
      return response({'errorCode': 'REAUTH_REQUIRED'}, 401);
    }, current: () => active);
    await openExportDialog(tester, repo,
        accessChanges: changes,
        onCreated: (_) => created++,
        onReauth: () => reauthentications++);
    await tester.tap(find.text('生成导出'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(reauthentications, 0);
    final staleReauth = tester
        .widget<TextButton>(find
            .ancestor(
                of: find.text('重新安全验证'),
                matching: find.byWidgetPredicate((widget) => widget is TextButton))
            .first)
        .onPressed!;
    await tester.tap(find.text('重新安全验证'));
    await tester.pump();
    expect(reauthentications, 1);
    expect(requests, 1);
    expect(created, 0);
    active = false;
    changes.notifyListeners();
    active = true;
    changes.notifyListeners();
    await tester.pump();
    staleReauth();
    await tester.pump();
    expect(reauthentications, 1);
    expect(requests, 1);
    expect(created, 0);
    expect(find.text('重新安全验证'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
