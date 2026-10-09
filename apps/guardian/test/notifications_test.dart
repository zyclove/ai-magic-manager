import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/notifications.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/notifications_view.dart';
import 'package:guardian/ui/notification_shortcut.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const noticeId = 'ffffffff-1111-1111-1111-111111111111';
const secondId = 'eeeeeeee-1111-1111-1111-111111111111';
const request = '11111111-1111-1111-1111-111111111111';
const at = 1791504000000;
Json notice(
        {String id = noticeId,
        String state = 'APPROVED_PENDING_DELIVERY',
        int? readAt}) =>
    {
      'id': id,
      'requestId': request,
      'subjectId': request,
      'deviceId': request,
      'requestVersion': 1,
      'state': state,
      'occurredAt': at,
      'readAt': readAt,
    };
http.Response jsonResponse(Object value) =>
    http.Response(jsonEncode(value), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
NotificationRepository repository(
        FutureOr<http.Response> Function(http.Request) handle,
        {bool Function()? current}) =>
    NotificationRepository(
        api: Api(() async => MockClient((r) async => handle(r))),
        root: '/tenants/$request',
        current: current ?? () => true);
Widget host(NotificationRepository repo,
        {Future<void> Function(String)? open}) =>
    MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: NotificationsView(
                    repository: repo, onOpen: open ?? (_) async {}))));

void main() {
  test('all real approval states have supported notification copy', () {
    for (final state in [
      'PENDING',
      'APPROVED_PENDING_DELIVERY',
      'DENIED',
      'CANCELLED',
      'EXPIRED',
      'REVOKED',
      'INVALIDATED'
    ]) {
      final value = InboxNotice.parse(notice(state: state));
      expect(value.title, isNot('申请状态已更新'));
      expect(value.description, isNot(contains('已解锁')));
    }
  });
  testWidgets('page read retry preserves exact IDs and blocks duplicate clicks',
      (tester) async {
    final writes = <Object?>[];
    final pending = Completer<http.Response>();
    var firstWrite = true, read = false;
    final repo = repository((r) {
      if (r.method == 'POST') {
        writes.add(jsonDecode(r.body)['ids']);
        if (firstWrite) {
          firstWrite = false;
          return pending.future;
        }
        read = true;
        return jsonResponse({
          'items': [
            {'id': noticeId, 'readAt': at},
            {'id': secondId, 'readAt': at}
          ]
        });
      }
      if (r.url.path.endsWith('/unread-count')) {
        return jsonResponse({'count': read ? 0 : 2, 'capped': false});
      }
      return jsonResponse({
        'items': [
          notice(readAt: read ? at : null),
          notice(id: secondId, state: 'PENDING', readAt: read ? at : null)
        ],
        'nextCursor': null
      });
    });
    await tester.pumpWidget(host(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('将本页标为已读'));
    await tester.pump();
    final button = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('将本页标为已读'),
        matching: find.byWidgetPredicate((w) => w is OutlinedButton)));
    expect(button.onPressed, isNull);
    expect(writes, hasLength(1));
    pending.complete(http.Response('{"errorCode":"UNAVAILABLE"}', 503));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(writes, [
      [noticeId, secondId],
      [noticeId, secondId]
    ]);
    expect(find.text('0 条未读'), findsOneWidget);
    expect(find.textContaining('仅影响你的账号'), findsOneWidget);
  });
  testWidgets(
      'pagination and filter reset use server cursors without duplicating rows',
      (tester) async {
    final queries = <Map<String, String>>[];
    final repo = repository((r) {
      if (r.url.path.endsWith('/unread-count')) {
        return jsonResponse({'count': 2, 'capped': false});
      }
      queries.add(r.url.queryParameters);
      final second = r.url.queryParameters['cursor'] != null;
      return jsonResponse({
        'items': [
          notice(
              id: second ? secondId : noticeId,
              state: second ? 'REVOKED' : 'PENDING')
        ],
        'nextCursor': second ? null : 'cursor2'
      });
    });
    await tester.pumpWidget(host(repo));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('下一页'));
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(find.text('访问授权已撤回'), findsOneWidget);
    expect(find.text('新的访问申请'), findsNothing);
    expect(queries.last['cursor'], 'cursor2');
    await tester.ensureVisible(find.text('未读'));
    await tester.tap(find.text('未读'));
    await tester.pumpAndSettle();
    expect(queries.last['cursor'], isNull);
    expect(queries.last['unreadOnly'], 'true');
    expect(find.text('新的访问申请'), findsOneWidget);
  });
  testWidgets('replacement workspace hides rows and ignores earlier response',
      (tester) async {
    final old = Completer<http.Response>();
    final oldRepo = repository((r) => r.url.path.endsWith('/unread-count')
        ? jsonResponse({'count': 1, 'capped': false})
        : old.future);
    final newRepo = repository((r) => jsonResponse(
        r.url.path.endsWith('/unread-count')
            ? {'count': 0, 'capped': false}
            : {'items': [], 'nextCursor': null}));
    await tester.pumpWidget(host(oldRepo));
    await tester.pump();
    await tester.pumpWidget(host(newRepo));
    await tester.pumpAndSettle();
    old.complete(jsonResponse({
      'items': [notice()],
      'nextCursor': null
    }));
    await tester.pumpAndSettle();
    expect(find.text('访问申请已批准'), findsNothing);
    expect(find.text('暂时没有通知'), findsOneWidget);
  });
  testWidgets(
      'unread shortcut updates after read and does not call outage zero',
      (tester) async {
    var count = 2, fail = false;
    final repo = repository((r) {
      if (r.method == 'PUT') {
        count = 0;
        return jsonResponse({'id': noticeId, 'readAt': at});
      }
      if (fail) return http.Response('{}', 503);
      return jsonResponse({'count': count, 'capped': false});
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NotificationShortcut(repository: repo, onOpen: () {}))));
    await tester.pumpAndSettle();
    expect(find.byTooltip('通知中心，2 条未读'), findsOneWidget);
    await repo.markRead([noticeId]);
    await tester.pumpAndSettle();
    expect(find.byTooltip('通知中心，0 条未读'), findsOneWidget);
    fail = true;
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.byTooltip('通知中心，未读数量暂不可用'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  test(
      'notice contract rejects private, unknown or inconsistent response fields',
      () {
    expect(InboxNotice.parse(notice()).title, '访问申请已批准');
    for (final row in [
      {...notice(), 'reason': 'private'},
      {...notice(), 'state': 'UNLOCKED'},
      {...notice(), 'requestVersion': -1},
      {...notice(), 'readAt': 'today'},
      {...notice(), 'requestId': '../other'},
    ]) {
      expect(() => InboxNotice.parse(row), throwsA(isA<ApiFailure>()));
    }
    expect(
        () => InboxPage.parse({
              'items': [notice(), notice()],
              'nextCursor': null
            }),
        throwsA(isA<ApiFailure>()));
    expect(
        () => InboxPage.parse({
              'items': [notice(readAt: at)],
              'nextCursor': null
            }, unreadOnly: true),
        throwsA(isA<ApiFailure>()));
    expect(() => InboxCount.parse({'count': 1, 'capped': true}),
        throwsA(isA<ApiFailure>()));
  });
  test('late workspace responses and later writes are rejected', () async {
    var current = true;
    var calls = 0;
    final pending = Completer<http.Response>();
    final repo = repository((r) {
      calls++;
      return pending.future;
    }, current: () => current);
    final future = repo.count();
    await Future<void>.delayed(Duration.zero);
    current = false;
    pending.complete(jsonResponse({'count': 1, 'capped': false}));
    await expectLater(
        future,
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'WORKSPACE_CHANGED')));
    await expectLater(repo.markRead([noticeId]), throwsA(isA<ApiFailure>()));
    expect(calls, 1);
  });
  test('read receipts must acknowledge exactly the selected IDs', () async {
    final repo = repository((r) => jsonResponse({
          'items': [
            {'id': noticeId, 'readAt': at}
          ]
        }));
    await expectLater(
        repo.markRead([noticeId, secondId]), throwsA(isA<ApiFailure>()));
    await expectLater(
        repo.markRead([noticeId, noticeId]), throwsA(isA<ApiFailure>()));
  });
  testWidgets(
      'inbox shows historical fact, unread count and current-detail entry',
      (tester) async {
    final writes = <String>[];
    String? opened;
    var read = false;
    final repo = repository((r) {
      if (r.method == 'PUT') {
        writes.add(r.url.path);
        read = true;
        return jsonResponse({'id': noticeId, 'readAt': at});
      }
      if (r.url.path.endsWith('/unread-count')) {
        return jsonResponse({'count': read ? 0 : 1, 'capped': false});
      }
      return jsonResponse({
        'items': [notice(readAt: read ? at : null)],
        'nextCursor': null
      });
    });
    await tester.pumpWidget(host(repo, open: (id) async {
      opened = id;
    }));
    await tester.pumpAndSettle();
    expect(find.text('通知中心'), findsOneWidget);
    expect(find.text('1 条未读'), findsOneWidget);
    expect(find.text('访问申请已批准'), findsOneWidget);
    expect(find.textContaining('设备是否生效'), findsOneWidget);
    await tester.ensureVisible(find.text('查看当前申请'));
    await tester.tap(find.text('查看当前申请'));
    await tester.pumpAndSettle();
    expect(opened, request);
    expect(writes, hasLength(1));
    expect(find.text('0 条未读'), findsOneWidget);
  });
  testWidgets(
      'mobile unread filter supports empty state and retry after outage',
      (tester) async {
    tester.view.reset();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var fail = true;
    final repo = repository((r) {
      if (fail) return http.Response('{"errorCode":"UNAVAILABLE"}', 503);
      if (r.url.path.endsWith('/unread-count')) {
        return jsonResponse({'count': 0, 'capped': false});
      }
      return jsonResponse({'items': [], 'nextCursor': null});
    });
    await tester.pumpWidget(host(repo));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未读'));
    await tester.pumpAndSettle();
    expect(find.text('未读通知已处理完'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
