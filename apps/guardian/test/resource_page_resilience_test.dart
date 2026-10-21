import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/resource_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response page(List<String> names, {String? cursor}) => http.Response(
    jsonEncode({
      'items': [
        for (final name in names) {'id': name, 'name': name}
      ],
      'nextCursor': cursor
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'});

http.Response unavailable() =>
    http.Response('{"errorCode":"REQUEST_FAILED"}', 503);

Api apiFor(FutureOr<http.Response> Function(http.Request) handler) {
  final client = MockClient((request) async => handler(request));
  return Api(() async => client);
}

Widget host(Api api,
        {Key? resourceKey,
        String path = '/records',
        Future<void> Function(Json)? onOpen,
        Future<void> Function()? create,
        bool Function()? isCurrent}) =>
    MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: ResourcePage(
                    key: resourceKey,
                    title: '记录',
                    subtitle: '查看与管理记录',
                    path: path,
                    api: api,
                    columns: [
                      ColumnSpec('名称', (row) => Text(row['name'] as String))
                    ],
                    onOpen: onOpen,
                    create: create,
                    isCurrent: isCurrent))));

Future<void> tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('revoked list scope blocks a GET waiting for authentication',
      (tester) async {
    var generation = 1, sends = 0;
    final authenticated = Completer<http.Client>();
    final api = Api(() => authenticated.future);
    await tester.pumpWidget(host(api, isCurrent: () => generation == 1));
    await tester.pump();
    generation = 2;
    authenticated.complete(MockClient((_) async {
      sends++;
      return page(['private-old']);
    }));
    await tester.pumpAndSettle();
    expect(sends, 0);
    expect(find.text('private-old'), findsNothing);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
  });

  testWidgets('same path and API reload after scope change and ignore old rows',
      (tester) async {
    var generation = 1, reads = 0;
    final lateRefresh = Completer<http.Response>();
    final api = apiFor((_) {
      reads++;
      if (reads == 1) return page(['old-admin-record'], cursor: 'old-next');
      if (reads == 2) return lateRefresh.future;
      return page(['current-teacher-record']);
    });
    Widget scopedHost(int captured) => host(api,
        resourceKey: ValueKey(('same-actor', '/same-tenant', captured)),
        isCurrent: () => generation == captured);
    await tester.pumpWidget(scopedHost(1));
    await tester.pumpAndSettle();
    expect(find.text('old-admin-record'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pump();
    generation = 2;
    await tester.pumpWidget(scopedHost(2));
    await tester.pumpAndSettle();
    expect(find.text('current-teacher-record'), findsOneWidget);
    expect(find.text('old-admin-record'), findsNothing);
    lateRefresh.complete(page(['late-private-record'], cursor: 'late-private'));
    await tester.pumpAndSettle();
    expect(find.text('current-teacher-record'), findsOneWidget);
    expect(find.text('late-private-record'), findsNothing);
    expect(find.text('加载更多'), findsNothing);
    expect(reads, 3);
  });

  testWidgets('an old create callback cannot act after list scope revocation',
      (tester) async {
    var generation = 1, creates = 0;
    final api = apiFor((_) => page(['private-old']));
    await tester.pumpWidget(host(api,
        isCurrent: () => generation == 1,
        create: () async {
          creates++;
        }));
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(find.ancestor(
        of: find.text('新建'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton)));
    generation = 2;
    button.onPressed!();
    await tester.pumpWidget(host(api, isCurrent: () => generation == 1));
    await tester.pumpAndSettle();
    expect(creates, 0);
    expect(find.text('private-old'), findsNothing);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
  });

  testWidgets('workspace changed response removes private rows and cursor',
      (tester) async {
    var reads = 0;
    final api = apiFor((_) => ++reads == 1
        ? page(['private-old'], cursor: 'private-next')
        : http.Response('{"errorCode":"WORKSPACE_CHANGED"}', 409));
    await tester.pumpWidget(host(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('private-old'), findsNothing);
    expect(find.byType(DataTable), findsNothing);
    expect(find.text('加载更多'), findsNothing);
    expect(find.byType(FailureView), findsOneWidget);
  });

  testWidgets('initial failure retries the first page', (tester) async {
    final cursors = <String?>[];
    final api = apiFor((request) {
      cursors.add(request.url.queryParameters['cursor']);
      return cursors.length == 1 ? unavailable() : page(['first']);
    });
    await tester.pumpWidget(host(api));
    await tester.pumpAndSettle();
    expect(find.text('暂无记录'), findsNothing);
    await tap(tester, '重试');
    expect(find.text('first'), findsOneWidget);
    expect(cursors, [null, null]);
  });

  testWidgets('append failure preserves rows and retries the same cursor',
      (tester) async {
    final cursors = <String?>[];
    final api = apiFor((request) {
      cursors.add(request.url.queryParameters['cursor']);
      if (cursors.length == 1) return page(['first'], cursor: 'page-2');
      if (cursors.length == 2) return unavailable();
      return page(['second']);
    });
    await tester.pumpWidget(host(api));
    await tester.pumpAndSettle();
    await tap(tester, '加载更多');
    expect(find.text('first'), findsOneWidget);
    expect(find.text('已加载 1 条'), findsOneWidget);
    expect(find.text('重试加载更多'), findsOneWidget);
    await tap(tester, '重试加载更多');
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(cursors, [null, 'page-2', 'page-2']);
  });

  testWidgets('refresh failure keeps every loaded page and its next cursor',
      (tester) async {
    final cursors = <String?>[];
    final api = apiFor((request) {
      cursors.add(request.url.queryParameters['cursor']);
      return switch (cursors.length) {
        1 => page(['first'], cursor: 'page-2'),
        2 => page(['second'], cursor: 'page-3'),
        3 => unavailable(),
        _ => page(['third'])
      };
    });
    await tester.pumpWidget(host(api));
    await tester.pumpAndSettle();
    await tap(tester, '加载更多');
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(find.text('重新刷新列表'), findsOneWidget);
    await tap(tester, '加载更多');
    expect(find.text('third'), findsOneWidget);
    expect(cursors, [null, 'page-2', null, 'page-3']);
  });

  testWidgets('refresh retry reads the first page instead of appending',
      (tester) async {
    final cursors = <String?>[];
    final api = apiFor((request) {
      cursors.add(request.url.queryParameters['cursor']);
      return switch (cursors.length) {
        1 => page(['old'], cursor: 'page-2'),
        2 => unavailable(),
        _ => page(['fresh'])
      };
    });
    await tester.pumpWidget(host(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    await tap(tester, '重新刷新列表');
    expect(find.text('fresh'), findsOneWidget);
    expect(find.text('old'), findsNothing);
    expect(cursors, [null, null, null]);
  });

  for (final creating in [false, true]) {
    testWidgets('failed ${creating ? 'create' : 'detail'} keeps the list and '
        'offers an explicit first-page refresh', (tester) async {
      final cursors = <String?>[];
      var actions = 0;
      final api = apiFor((request) {
        cursors.add(request.url.queryParameters['cursor']);
        return page(['first'], cursor: 'page-2');
      });
      Future<void> fail() async {
        actions++;
        throw const ApiFailure(0, 'NETWORK_ERROR');
      }

      await tester.pumpWidget(host(api,
          onOpen: creating ? null : (_) => fail(),
          create: creating ? fail : null));
      await tester.pumpAndSettle();
      await tap(tester, creating ? '新建' : '查看详情');
      expect(find.text('first'), findsOneWidget);
      expect(actions, 1);
      expect(cursors, [null]);
      expect(find.text('刷新列表'), findsOneWidget);
      await tap(tester, '刷新列表');
      expect(actions, 1, reason: 'Refresh must not replay an unknown write.');
      expect(cursors, [null, null]);
    });
  }

  testWidgets('successful detail return still refreshes to show edits',
      (tester) async {
    var reads = 0;
    final api = apiFor((_) => page([++reads == 1 ? 'before' : 'after']));
    await tester.pumpWidget(host(api, onOpen: (_) async {}));
    await tester.pumpAndSettle();
    await tap(tester, '查看详情');
    expect(find.text('after'), findsOneWidget);
    expect(find.text('before'), findsNothing);
    expect(reads, 2);
  });

  testWidgets('unmatched search explains its scope and keeps pagination',
      (tester) async {
    var reads = 0;
    final api = apiFor((_) => ++reads == 1
        ? page(['first'], cursor: 'page-2')
        : page(['wanted']));
    await tester.pumpWidget(host(api));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'wanted');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配记录'), findsOneWidget);
    expect(find.text('搜索仅匹配已加载记录，可加载更多后继续查找。'), findsOneWidget);
    await tap(tester, '加载更多');
    expect(find.text('wanted'), findsWidgets);
    expect(find.text('已加载 2 条 · 匹配 1 条'), findsOneWidget);
  });

  testWidgets('append cannot replace an initial request', (tester) async {
    final key = GlobalKey<ResourcePageState>();
    final waiting = Completer<http.Response>();
    var reads = 0;
    final api = apiFor((_) {
      reads++;
      return waiting.future;
    });
    await tester.pumpWidget(host(api, resourceKey: key));
    await tester.pump();
    final append = key.currentState!.load(append: true);
    await tester.pump();
    final readsWhileInitial = reads;
    waiting.complete(page(['first'], cursor: 'page-2'));
    await tester.pumpAndSettle();
    await append;
    expect(readsWhileInitial, 1);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);
  });

  testWidgets('duplicate append is ignored and a refresh isolates late append',
      (tester) async {
    final key = GlobalKey<ResourcePageState>();
    final waiting = Completer<http.Response>();
    final cursors = <String?>[];
    final api = apiFor((request) {
      cursors.add(request.url.queryParameters['cursor']);
      return switch (cursors.length) {
        1 => page(['old'], cursor: 'old-next'),
        2 => waiting.future,
        3 => page(['fresh'], cursor: 'fresh-next'),
        _ => page(['fresh-more'])
      };
    });
    await tester.pumpWidget(host(api, resourceKey: key));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pump();
    await key.currentState!.load(append: true);
    expect(cursors, [null, 'old-next']);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('fresh'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);
    waiting.complete(page(['late-old'], cursor: 'late-next'));
    await tester.pumpAndSettle();
    expect(find.text('late-old'), findsNothing);
    await tap(tester, '加载更多');
    expect(cursors, [null, 'old-next', null, 'fresh-next']);
    expect(find.text('fresh-more'), findsOneWidget);
  });

  for (final changeApi in [false, true]) {
    testWidgets('${changeApi ? 'API' : 'path'} change isolates old page errors',
        (tester) async {
      final key = GlobalKey<ResourcePageState>();
      final waiting = Completer<http.Response>();
      var oldReads = 0;
      final api = apiFor((request) {
        if (request.url.path.endsWith('/new-records')) return page(['new']);
        return ++oldReads == 1
            ? page(['old'], cursor: 'old-next')
            : waiting.future;
      });
      final replacement = changeApi ? apiFor((_) => page(['new'])) : api;
      await tester.pumpWidget(host(api, resourceKey: key));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      await tester.pumpWidget(host(replacement,
          resourceKey: key, path: changeApi ? '/records' : '/new-records'));
      await tester.pumpAndSettle();
      expect(find.text('new'), findsOneWidget);
      expect(find.text('old'), findsNothing);
      waiting.complete(unavailable());
      await tester.pumpAndSettle();
      expect(find.text('new'), findsOneWidget);
      expect(find.byType(FailureView), findsNothing);
      expect(find.text('加载中…'), findsNothing);
    });
  }

  testWidgets('late detail failure cannot leak into a changed resource',
      (tester) async {
    final key = GlobalKey<ResourcePageState>();
    final waiting = Completer<void>();
    final paths = <String>[];
    final api = apiFor((request) {
      paths.add(request.url.path);
      return page([request.url.path.endsWith('/new-records') ? 'new' : 'old']);
    });
    await tester.pumpWidget(host(api,
        resourceKey: key, onOpen: (_) => waiting.future));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看详情'));
    await tester.pump();
    await tester.pumpWidget(host(api,
        resourceKey: key, path: '/new-records', onOpen: (_) async {}));
    await tester.pumpAndSettle();
    waiting.completeError(const ApiFailure(0, 'NETWORK_ERROR'));
    await tester.pumpAndSettle();
    expect(find.text('new'), findsOneWidget);
    expect(find.byType(FailureView), findsNothing);
    expect(paths.length, 2);
    final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '查看详情'));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('pending refresh preserves all visible rows and shows progress',
      (tester) async {
    final waiting = Completer<http.Response>();
    var reads = 0;
    final api = apiFor((_) => switch (++reads) {
          1 => page(['first'], cursor: 'page-2'),
          2 => page(['second']),
          _ => waiting.future
        });
    await tester.pumpWidget(host(api));
    await tester.pumpAndSettle();
    await tap(tester, '加载更多');
    await tester.tap(find.byTooltip('刷新'));
    await tester.pump();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final refresh = tester.widget<IconButton>(find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '刷新'));
    expect(refresh.onPressed, isNull);
    waiting.complete(page(['fresh']));
    await tester.pumpAndSettle();
    expect(find.text('fresh'), findsOneWidget);
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('late detail success cannot refresh a changed resource',
      (tester) async {
    final key = GlobalKey<ResourcePageState>();
    final waiting = Completer<void>();
    final paths = <String>[];
    final api = apiFor((request) {
      paths.add(request.url.path);
      return page([request.url.path.endsWith('/new-records') ? 'new' : 'old']);
    });
    await tester.pumpWidget(host(api,
        resourceKey: key, onOpen: (_) => waiting.future));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看详情'));
    await tester.pump();
    await tester.pumpWidget(host(api,
        resourceKey: key, path: '/new-records', onOpen: (_) async {}));
    await tester.pumpAndSettle();
    waiting.complete();
    await tester.pumpAndSettle();
    expect(find.text('new'), findsOneWidget);
    expect(find.text('old'), findsNothing);
    expect(paths.length, 2,
        reason: 'The old operation must not issue a refresh in the new scope.');
    expect(find.byType(FailureView), findsNothing);
  });

  for (final creating in [false, true]) {
    testWidgets('duplicate ${creating ? 'create' : 'detail'} only opens once',
        (tester) async {
      final waiting = Completer<void>();
      var actions = 0;
      var reads = 0;
      final api = apiFor((_) {
        reads++;
        return page(['first']);
      });
      Future<void> open() {
        actions++;
        return waiting.future;
      }

      await tester.pumpWidget(host(api,
          onOpen: creating ? null : (_) => open(),
          create: creating ? open : null));
      await tester.pumpAndSettle();
      final button = find.text(creating ? '新建' : '查看详情');
      await tester.tap(button);
      await tester.tap(button);
      await tester.pump();
      expect(actions, 1);
      expect(reads, 1);
      expect(find.text('first'), findsOneWidget);
      waiting.complete();
      await tester.pumpAndSettle();
      expect(actions, 1);
      expect(reads, 2, reason: 'The successful operation refreshes once.');
    });
  }

  for (final changeApi in [false, true]) {
    testWidgets('${changeApi ? 'API' : 'path'} change discards old initial '
        'success and its cursor', (tester) async {
      final key = GlobalKey<ResourcePageState>();
      final waiting = Completer<http.Response>();
      final api = apiFor((request) =>
          request.url.path.endsWith('/new-records')
              ? page(['new'])
              : waiting.future);
      final replacement = changeApi ? apiFor((_) => page(['new'])) : api;
      await tester.pumpWidget(host(api, resourceKey: key));
      await tester.pump();
      await tester.pumpWidget(host(replacement,
          resourceKey: key, path: changeApi ? '/records' : '/new-records'));
      await tester.pumpAndSettle();
      expect(find.text('new'), findsOneWidget);
      waiting.complete(page(['private-old'], cursor: 'old-private-cursor'));
      await tester.pumpAndSettle();
      expect(find.text('new'), findsOneWidget);
      expect(find.text('private-old'), findsNothing);
      expect(find.text('加载更多'), findsNothing);
      expect(find.text('已加载 1 条'), findsOneWidget);
      expect(find.byType(FailureView), findsNothing);
    });
  }

  for (final append in [false, true]) {
    for (final status in [401, 403]) {
      testWidgets('${append ? 'append' : 'refresh'} GET $status hides private '
          'rows and discards the cursor', (tester) async {
        final cursors = <String?>[];
        final api = apiFor((request) {
          expect(request.method, 'GET');
          cursors.add(request.url.queryParameters['cursor']);
          return switch (cursors.length) {
            1 => page(['private-before-denied'], cursor: 'private-next'),
            2 => http.Response(
                jsonEncode({
                  'errorCode': status == 401 ? 'UNAUTHENTICATED' : 'SCOPE_DENIED'
                }),
                status),
            _ => page(['authorized-after-retry'])
          };
        });
        await tester.pumpWidget(host(api));
        await tester.pumpAndSettle();
        expect(find.text('private-before-denied'), findsOneWidget);
        if (append) {
          await tap(tester, '加载更多');
        } else {
          await tester.tap(find.byTooltip('刷新'));
          await tester.pumpAndSettle();
        }
        expect(find.text('private-before-denied'), findsNothing);
        expect(find.byType(DataTable), findsNothing);
        expect(find.text('加载更多'), findsNothing);
        expect(find.text('重试加载更多'), findsNothing);
        expect(find.byType(FailureView), findsOneWidget);
        await tap(tester, '重试');
        expect(find.text('authorized-after-retry'), findsOneWidget);
        expect(cursors, [null, append ? 'private-next' : null, null]);
      });
    }
  }

  testWidgets('action MFA 401 preserves rows and the readable next page',
      (tester) async {
    final cursors = <String?>[];
    var actions = 0;
    final api = apiFor((request) {
      cursors.add(request.url.queryParameters['cursor']);
      return cursors.length == 1
          ? page(['first'], cursor: 'page-2')
          : page(['second']);
    });
    await tester.pumpWidget(host(api, onOpen: (_) async {
      actions++;
      throw const ApiFailure(401, 'REAUTH_REQUIRED');
    }));
    await tester.pumpAndSettle();
    await tap(tester, '查看详情');
    expect(find.text('first'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);
    expect(find.byType(FailureView), findsOneWidget);
    expect(actions, 1);
    expect(cursors, [null]);
    await tap(tester, '加载更多');
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(cursors, [null, 'page-2']);
    expect(actions, 1);
  });
}
