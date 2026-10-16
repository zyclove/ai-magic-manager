import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/commercial_catalog_repository.dart';
import 'package:guardian/core/permission_observation.dart';
import 'package:guardian/pages/commercial_catalog_editor.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/notifications_view.dart';
import 'package:guardian/ui/permission_observation_panel.dart';
import 'package:guardian/ui/usage_report_jobs_view.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'notifications_test.dart' as inbox
    show at, jsonResponse, notice, noticeId, repository, request;
import 'usage_report_jobs_test.dart' as jobs
    show jobFixture, repository, response;
import 'usage_reports_test.dart' as reports show now, target;

Widget _host(GlobalKey<NavigatorState> navigator, Widget child) => MaterialApp(
      navigatorKey: navigator,
      theme: consoleTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Future<void> _mount(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(child);
  await tester.pumpAndSettle();
}

// Include covered routes so an extra prompt cannot hide behind the top prompt.
Finder _prompt(String title) => find.text(title, skipOffstage: false);

ButtonStyleButton _button(WidgetTester tester, String label) =>
    tester.widget<ButtonStyleButton>(find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    ));

Future<void> _promptFrames(WidgetTester tester) async {
  // A correct lock may animate a busy indicator beneath the pending prompt.
  // Advance the dialog transition without waiting for that operation to settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _disposeHost(
    WidgetTester tester, GlobalKey<NavigatorState> navigator) async {
  try {
    // Also dismiss duplicate prompts on the expected RED path. Their awaiting
    // production callbacks must finish before their widgets are disposed.
    navigator.currentState?.popUntil((route) => route.isFirst);
    await _promptFrames(tester);
  } finally {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  }
}

void _finishPending(List<Completer<http.Response>> pending) {
  for (final request in pending) {
    if (!request.isCompleted) {
      request
          .complete(jobs.response({'errorCode': 'UNAVAILABLE'}, status: 503));
    }
  }
}

void main() {
  testWidgets(
      'queued catalog save callbacks open one review and cancellation unlocks editing',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    var writes = 0;
    final repository = CommercialCatalogRepository(
      api: Api(() async => MockClient((request) async {
            writes++;
            return http.Response('{"errorCode":"UNAVAILABLE"}', 503);
          })),
      current: () => true,
    );
    try {
      await _mount(
          tester,
          _host(
              navigator,
              Builder(
                  builder: (context) => TextButton(
                        onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => CommercialCatalogEditor(
                                repository: repository)),
                        child: const Text('打开目录编辑器'),
                      ))));
      await tester.tap(find.text('打开目录编辑器'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'ORG_PILOT');
      final callback = _button(tester, '创建草稿').onPressed!;
      callback();
      callback();
      await _promptFrames(tester);

      expect(_prompt('核对新草稿'), findsOneWidget);
      expect(writes, 0);
      await tester.tap(find.text('返回修改'));
      await _promptFrames(tester);
      expect(_prompt('核对新草稿'), findsNothing);
      expect(find.text('创建报价草稿'), findsOneWidget);
      expect(_button(tester, '创建草稿').onPressed, isNotNull);

      await tester.enterText(find.byType(TextFormField).first, 'ORG_REVISED');
      await tester.tap(find.text('创建草稿'));
      await _promptFrames(tester);
      expect(_prompt('核对新草稿'), findsOneWidget);
      expect(find.text('新值：ORG_REVISED'), findsOneWidget);
      await tester.tap(find.text('返回修改'));
      await _promptFrames(tester);
      expect(_prompt('核对新草稿'), findsNothing);
      expect(writes, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeHost(tester, navigator);
    }
  });

  for (final enabled in [false, true]) {
    testWidgets(
        'queued permission consent callbacks open one reason prompt: enabled=$enabled',
        (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      var writes = 0;
      final repository = PermissionObservationRepository(
        api: Api(() async => MockClient((request) async {
              if (request.method != 'GET') {
                writes++;
                return http.Response('{"errorCode":"UNAVAILABLE"}', 503);
              }
              return inbox.jsonResponse({
                'deviceId': reports.target.deviceId,
                'registrationId': reports.target.registrationId,
                'version': enabled ? 1 : 0,
                'enabled': enabled,
                'updatedAt': enabled ? inbox.at : null,
              });
            })),
        root: '/tenants/${reports.target.subjectId}',
        deviceId: reports.target.deviceId,
        registrationId: reports.target.registrationId,
        current: () => true,
      );
      final action = enabled ? '撤回授权' : '开启授权';
      final title = enabled ? '撤回应用权限观察' : '开启应用权限观察';
      try {
        await _mount(
            tester,
            _host(
                navigator,
                PermissionObservationPanel(
                  repository: repository,
                  canEdit: true,
                  inventoryEnabled: false,
                  reauth: () {},
                )));
        final callback = _button(tester, action).onPressed!;
        callback();
        callback();
        await _promptFrames(tester);

        expect(_prompt(title), findsOneWidget);
        expect(writes, 0);
        await tester.tap(find.text('取消'));
        await _promptFrames(tester);
        expect(_prompt(title), findsNothing);
        expect(find.text(enabled ? '已开启' : '默认关闭'), findsOneWidget);
        expect(_button(tester, action).onPressed, isNotNull);

        await tester.tap(find.text(action));
        await _promptFrames(tester);
        expect(_prompt(title), findsOneWidget);
        await tester.tap(find.text('取消'));
        await _promptFrames(tester);
        expect(_prompt(title), findsNothing);
        expect(writes, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await _disposeHost(tester, navigator);
      }
    });
  }

  testWidgets(
      'queued report cancellation callbacks open one confirmation and can be cancelled once',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    var cancellations = 0;
    final repository = jobs.repository((request) {
      if (request.method == 'POST') {
        cancellations++;
        return jobs.response({'errorCode': 'UNAVAILABLE'}, status: 503);
      }
      return jobs.response({
        'items': [jobs.jobFixture()],
        'nextCursor': null,
      });
    });
    try {
      await _mount(
          tester,
          _host(
              navigator,
              UsageReportJobsView(
                repository: repository,
                resolveTarget: (_) async => reports.target,
                clock: () => reports.now + 2000,
              )));
      final callback = _button(tester, '取消任务').onPressed!;
      callback();
      callback();
      await _promptFrames(tester);

      expect(_prompt('取消这份报表任务？'), findsOneWidget);
      expect(cancellations, 0);
      await tester.tap(find.text('保留任务'));
      await _promptFrames(tester);
      expect(_prompt('取消这份报表任务？'), findsNothing);
      expect(find.text('报表任务'), findsOneWidget);
      expect(_button(tester, '取消任务').onPressed, isNotNull);

      await tester.tap(find.text('取消任务'));
      await _promptFrames(tester);
      expect(_prompt('取消这份报表任务？'), findsOneWidget);
      await tester.tap(find.text('保留任务'));
      await _promptFrames(tester);
      expect(_prompt('取消这份报表任务？'), findsNothing);
      expect(cancellations, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await _disposeHost(tester, navigator);
    }
  });

  for (final action in ['将本页标为已读', '查看当前申请']) {
    testWidgets(
        'queued notification $action callbacks send one pending receipt',
        (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final pending = <Completer<http.Response>>[];
      final paths = <String>[];
      final opened = <String>[];
      var read = false, cleaningUp = false;
      final repository = inbox.repository((request) {
        if (request.method == 'PUT' || request.method == 'POST') {
          paths.add(request.url.path);
          if (cleaningUp) return jobs.response({}, status: 503);
          final receipt = Completer<http.Response>();
          pending.add(receipt);
          return receipt.future;
        }
        if (request.url.path.endsWith('/unread-count')) {
          return inbox.jsonResponse({'count': read ? 0 : 1, 'capped': false});
        }
        return inbox.jsonResponse({
          'items': [inbox.notice(readAt: read ? inbox.at : null)],
          'nextCursor': null,
        });
      });
      try {
        await _mount(
            tester,
            _host(
                navigator,
                NotificationsView(
                  repository: repository,
                  onOpen: (id) async {
                    opened.add(id);
                  },
                )));
        final callback = _button(tester, action).onPressed!;
        callback();
        callback();
        await tester.pump();

        expect(paths, hasLength(1));
        expect(
            paths.single,
            endsWith(
                '/tenants/${inbox.request}/notifications/${inbox.noticeId}/read'));
        expect(pending, hasLength(1));
        expect(opened, isEmpty);
        read = true;
        pending.single.complete(inbox.jsonResponse({
          'id': inbox.noticeId,
          'readAt': inbox.at,
        }));
        await tester.pumpAndSettle();
        expect(find.text('0 条未读'), findsOneWidget);
        expect(opened, action == '查看当前申请' ? [inbox.request] : <String>[]);
        if (action == '将本页标为已读') {
          expect(find.text('已将 1 条通知标为已读，仅影响你的账号。'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      } finally {
        cleaningUp = true;
        _finishPending(pending);
        await _promptFrames(tester);
        await _disposeHost(tester, navigator);
      }
    });
  }

  testWidgets('queued callbacks open an already read notification only once',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final pendingOpen = Completer<void>();
    final opened = <String>[];
    var writes = 0;
    final repository = inbox.repository((request) {
      if (request.method != 'GET') {
        writes++;
        return jobs.response({}, status: 503);
      }
      return inbox.jsonResponse(request.url.path.endsWith('/unread-count')
          ? {'count': 0, 'capped': false}
          : {
              'items': [inbox.notice(readAt: inbox.at)],
              'nextCursor': null,
            });
    });
    try {
      await _mount(
          tester,
          _host(
              navigator,
              NotificationsView(
                repository: repository,
                onOpen: (id) {
                  opened.add(id);
                  return pendingOpen.future;
                },
              )));
      final callback = _button(tester, '查看当前申请').onPressed!;
      callback();
      callback();
      expect(opened, [inbox.request]);
      expect(writes, 0);
      pendingOpen.complete();
      await tester.pumpAndSettle();
      expect(_button(tester, '查看当前申请').onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    } finally {
      if (!pendingOpen.isCompleted) pendingOpen.complete();
      await _promptFrames(tester);
      await _disposeHost(tester, navigator);
    }
  });

  testWidgets('notification failure unlocks one queued retry with the same id',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final pending = <Completer<http.Response>>[];
    final paths = <String>[];
    var read = false, cleaningUp = false;
    final repository = inbox.repository((request) {
      if (request.method == 'PUT' || request.method == 'POST') {
        paths.add(request.url.path);
        if (cleaningUp) return jobs.response({}, status: 503);
        final receipt = Completer<http.Response>();
        pending.add(receipt);
        return receipt.future;
      }
      return inbox.jsonResponse(request.url.path.endsWith('/unread-count')
          ? {'count': read ? 0 : 1, 'capped': false}
          : {
              'items': [inbox.notice(readAt: read ? inbox.at : null)],
              'nextCursor': null,
            });
    });
    try {
      await _mount(
          tester,
          _host(navigator,
              NotificationsView(repository: repository, onOpen: (_) async {})));
      await tester.tap(find.text('将本页标为已读'));
      await tester.pump();
      expect(pending, hasLength(1));
      pending.single
          .complete(jobs.response({'errorCode': 'UNAVAILABLE'}, status: 503));
      await tester.pumpAndSettle();
      final retry = _button(tester, '重试').onPressed!;
      retry();
      retry();
      await tester.pump();

      expect(paths, hasLength(2));
      expect(paths[1], paths[0]);
      expect(pending, hasLength(2));
      read = true;
      pending.last.complete(inbox.jsonResponse({
        'id': inbox.noticeId,
        'readAt': inbox.at,
      }));
      await tester.pumpAndSettle();
      expect(find.text('0 条未读'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(find.text('已将 1 条通知标为已读，仅影响你的账号。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      cleaningUp = true;
      _finishPending(pending);
      await _promptFrames(tester);
      await _disposeHost(tester, navigator);
    }
  });
}
