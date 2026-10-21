@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:guardian/core/audit.dart';
import 'package:guardian/pages/audit_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/export_create_dialog.dart';
import 'package:http/http.dart' as http;

import 'audit_exports_test.dart' show job, now, response;
import 'device_management_entry_test.dart' show EntrySession, settleReads;

class _Fixture {
  final pending = Completer<http.Response>();
  int creates = 0;
  late final session = EntrySession((request) async {
    if (request.method == 'GET' &&
        request.url.path.endsWith('/audit-events/search')) {
      return response({'items': [], 'nextCursor': null});
    }
    if (request.method == 'POST' &&
        request.url.path.endsWith('/audit-exports')) {
      creates++;
      return pending.future;
    }
    throw StateError('Unexpected audit fixture request.');
  });
  late final router = GoRouter(
      initialLocation: '/audit',
      overridePlatformDefaultLocation: true,
      routes: [
        GoRoute(
            path: '/audit',
            builder: (_, __) => Scaffold(
                body: SingleChildScrollView(
                    child: AuditExplorerPage(
                        session: session,
                        initialQuery: const AuditQuery(
                            from: now - 60000, to: now))))),
        GoRoute(
            path: '/exports',
            builder: (_, __) =>
                const Scaffold(body: Text('导出任务页')))
      ]);

  Future<BuildContext> open(WidgetTester tester) async {
    addTearDown(() async {
      if (!pending.isCompleted) pending.complete(response(job(), 202));
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      session.transport.close();
      session.dispose();
    });
    await tester.pumpWidget(MaterialApp.router(
        theme: consoleTheme(), routerConfig: router));
    await settleReads(tester);
    final context = tester.element(find.byType(AuditExplorerPage));
    await tester.ensureVisible(find.text('导出当前结果'));
    await tester.tap(find.text('导出当前结果'));
    await settleReads(tester);
    await tester.tap(find.text('生成导出'));
    await _flushWithoutTime(tester);
    expect(creates, 1);
    return context;
  }
}

Future<void> _flushWithoutTime(WidgetTester tester) async {
  // Deliver browser HTTP events without advancing the dialog's reverse clock.
  for (var frame = 0; frame < 6; frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}

DialogRoute<void> _cover(BuildContext context) {
  final route = DialogRoute<void>(
      context: context,
      builder: (_) => const AlertDialog(title: Text('独立通知')));
  unawaited(Navigator.of(context, rootNavigator: true).push<void>(route));
  return route;
}

void main() {
  testWidgets('covered export success preserves the cover and audit location',
      (tester) async {
    final fixture = _Fixture();
    final context = await fixture.open(tester);
    final cover = _cover(context);
    await settleReads(tester);

    fixture.pending.complete(response(job(), 202));
    await settleReads(tester);
    expect(cover.isCurrent, isTrue);
    expect(find.text('独立通知'), findsOneWidget);
    expect(fixture.router.routeInformationProvider.value.uri.path, '/audit');
    expect(find.byType(ExportCreateDialog, skipOffstage: false), findsNothing);

    cover.navigator!.pop();
    await settleReads(tester);
    expect(find.byType(AuditExplorerPage), findsOneWidget);
    expect(fixture.router.routeInformationProvider.value.uri.path, '/audit');
    expect(fixture.creates, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('current export success opens the export jobs page',
      (tester) async {
    final fixture = _Fixture();
    await fixture.open(tester);
    fixture.pending.complete(response(job(), 202));
    await settleReads(tester);

    expect(fixture.router.routeInformationProvider.value.uri.path, '/exports');
    expect(find.text('导出任务页'), findsOneWidget);
    expect(find.byType(ExportCreateDialog), findsNothing);
    expect(fixture.creates, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('covered success cannot redirect when the cover closes at completion',
      (tester) async {
    final fixture = _Fixture();
    final context = await fixture.open(tester);
    final route = ModalRoute.of(
        tester.element(find.byType(ExportCreateDialog)))!;
    final cover = _cover(context);
    await settleReads(tester);
    // Close the cover before presentOwnedDialog resumes from route.completed.
    unawaited(route.popped.then<void>((_) => cover.navigator!.pop()));

    fixture.pending.complete(response(job(), 202));
    await settleReads(tester);
    expect(cover.isActive, isFalse);
    expect(find.byType(ExportCreateDialog, skipOffstage: false), findsNothing);
    expect(find.byType(AuditExplorerPage), findsOneWidget);
    expect(fixture.router.routeInformationProvider.value.uri.path, '/audit');
    expect(fixture.creates, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cover during export closing prevents the late redirect',
      (tester) async {
    final fixture = _Fixture();
    final context = await fixture.open(tester);
    final route = ModalRoute.of(
        tester.element(find.byType(ExportCreateDialog)))!;

    fixture.pending.complete(response(job(), 202));
    await _flushWithoutTime(tester);
    expect(route.animation!.status, AnimationStatus.reverse);
    expect(fixture.router.routeInformationProvider.value.uri.path, '/audit');
    final cover = _cover(context);
    await settleReads(tester);

    expect(cover.isCurrent, isTrue);
    expect(find.text('独立通知'), findsOneWidget);
    expect(fixture.router.routeInformationProvider.value.uri.path, '/audit');
    expect(find.byType(ExportCreateDialog, skipOffstage: false), findsNothing);
    cover.navigator!.pop();
    await settleReads(tester);
    expect(find.byType(AuditExplorerPage), findsOneWidget);
    expect(fixture.router.routeInformationProvider.value.uri.path, '/audit');
    expect(fixture.creates, 1);
    expect(tester.takeException(), isNull);
  });
}
