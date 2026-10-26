@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/scoped_overview_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _summary(int count,
        {int pending = 0, int? help, int? connections}) => http.Response(
    jsonEncode({
      'subjectCount': count,
      'pendingRequestCount': pending,
      if (help != null) 'openHelpRequestCount': help,
      if (connections != null) 'connectionCheckCount': connections,
      'recentActivity': <Object>[],
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'});

// Keep production permission mapping and API scope checks; replace only identity
// state, the HTTP transport and the browser-redirecting login leaf.
class _OverviewSession extends Session {
  final Api _fixtureApi;
  bool signedIn = true;
  int fixtureGeneration = 1;

  _OverviewSession(FutureOr<http.Response> Function(http.Request) handle)
      : _fixtureApi = Api(() async => MockClient((request) async {
              expect(request.method, 'GET');
              return handle(request);
            })) {
    profile = {'subject': 'teacher-a', 'name': '教师'};
    tenant = {'id': 'tenant-a', 'name': '测试机构', 'kind': 'ORGANIZATION'};
    role = 'TEACHER';
  }

  @override
  Api get api => _fixtureApi;
  @override
  bool get authenticated => signedIn;
  @override
  int get scopeGeneration => fixtureGeneration;
  @override
  void login({bool stepUp = false}) {}

  void change({String? actor, String? nextRole, int? generation}) {
    if (actor != null) profile = {...profile!, 'subject': actor};
    if (nextRole != null) role = nextRole;
    if (generation != null) fixtureGeneration = generation;
    notifyListeners();
  }
}

class _Host {
  final ValueNotifier<_OverviewSession> selected;
  final List<_OverviewSession> sessions;
  late final GoRouter router;

  _Host(_OverviewSession session)
      : selected = ValueNotifier(session),
        sessions = [session] {
    router = GoRouter(initialLocation: '/', routes: [
      GoRoute(
          path: '/',
          builder: (_, state) => Scaffold(
              body: SingleChildScrollView(
                  child: ValueListenableBuilder<_OverviewSession>(
                      valueListenable: selected,
                      builder: (_, session, child) => ScopedOverviewPage(
                          key: const ValueKey('same-overview'),
                          session: session))))),
      GoRoute(
          path: '/subjects',
          builder: (_, state) => const Scaffold(body: Text('档案目的页'))),
      GoRoute(
          path: '/help-requests',
          builder: (_, state) => const Scaffold(body: Text('授权求助目的页'))),
      GoRoute(
          path: '/elsewhere',
          builder: (_, state) => const Scaffold(body: Text('另一页面'))),
    ]);
  }

  void replace(_OverviewSession session) {
    sessions.add(session);
    selected.value = session;
  }
}

Future<void> _flush(WidgetTester tester) async {
  // Streamed browser responses use the real event queue as well as frame time.
  for (var frame = 0; frame < 6; frame++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _settle(WidgetTester tester) async {
  await _flush(tester);
  await tester.pumpAndSettle();
}

Future<_Host> _mount(WidgetTester tester, _OverviewSession session,
    {List<Completer<http.Response>> pending = const [],
    double textScale = 1}) async {
  final host = _Host(session);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final response in pending) {
      if (!response.isCompleted) response.complete(_summary(0));
    }
    await _flush(tester);
    host.router.dispose();
    host.selected.dispose();
    for (final session in host.sessions) {
      session.dispose();
    }
  });
  await tester.pumpWidget(MaterialApp.router(
      theme: consoleTheme(),
      routerConfig: host.router,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!)));
  await _flush(tester);
  return host;
}

Finder _button<T extends ButtonStyleButton>(String text) => find.ancestor(
    of: find.text(text),
    matching: find.byWidgetPredicate((widget) => widget is T));

VoidCallback _refresh(WidgetTester tester) => tester
    .widget<TextButton>(_button<TextButton>('刷新状态'))
    .onPressed!;

VoidCallback _navigate(WidgetTester tester) => tester
    .widget<OutlinedButton>(_button<OutlinedButton>('我的档案'))
    .onPressed!;

void main() {
  testWidgets('teacher next step opens authorized help and retires its old route callback',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var reads = 0;
    final session = _OverviewSession((request) {
      reads++;
      expect(request.url.path, endsWith('/tenants/tenant-a/overview'));
      return _summary(4, pending: 3, help: 2, connections: 1);
    });
    final host = await _mount(tester, session, textScale: 1.5);
    await _settle(tester);
    final next = find.byKey(const Key('scoped-overview-next-action'));
    expect(next, findsOneWidget);
    expect(find.textContaining('上次读取完成：'), findsOneWidget);
    expect(reads, 1, reason: 'The next step reuses the authorized overview.');
    final held = tester.widget<FilledButton>(next).onPressed!;
    await tester.ensureVisible(next);
    await tester.tap(next);
    await _settle(tester);
    expect(host.router.routeInformationProvider.value.uri.path, '/help-requests');
    expect(find.text('授权求助目的页'), findsOneWidget);
    host.router.go('/elsewhere');
    await _settle(tester);
    held();
    await _settle(tester);
    expect(host.router.routeInformationProvider.value.uri.path, '/elsewhere');
    expect(find.text('另一页面'), findsOneWidget);
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-tenant same-role account ABA discards a late summary',
      (tester) async {
    final response = Completer<http.Response>();
    var reads = 0;
    final session = _OverviewSession((_) {
      reads++;
      return response.future;
    });
    await _mount(tester, session, pending: [response]);
    expect(reads, 1);
    session.change(actor: 'teacher-b');
    session.change(actor: 'teacher-a');
    response.complete(_summary(137));
    await _settle(tester);
    expect(find.text('137'), findsNothing);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'generation changes and role ABA hide loaded data and held callbacks',
      (tester) async {
    for (final generationChange in [false, true]) {
      var reads = 0;
      final session = _OverviewSession((_) {
        reads++;
        return _summary(137);
      });
      final host = await _mount(tester, session);
      await _settle(tester);
      final refresh = _refresh(tester), navigate = _navigate(tester);
      expect(find.text('137'), findsOneWidget);
      if (generationChange) {
        session.change(generation: 2);
        session.change(generation: 3);
      } else {
        session.change(nextRole: 'AUDITOR');
        session.change(nextRole: 'TEACHER');
      }
      refresh();
      navigate();
      await _settle(tester);
      expect(find.text('137'), findsNothing);
      expect(find.text('工作空间或权限已变化'), findsOneWidget);
      expect(host.router.routeInformationProvider.value.uri.path, '/');
      expect(reads, 1);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'refresh deduplicates clicks and preserves a readable summary after 500',
      (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final response = Completer<http.Response>();
    var reads = 0;
    final session = _OverviewSession((_) => switch (++reads) {
          1 => http.Response('{"errorCode":"TEMPORARY_FAILURE"}', 500),
          2 => _summary(137),
          3 => response.future,
          _ => _summary(246),
        });
    await _mount(tester, session, pending: [response], textScale: 1.6);
    await _settle(tester);
    expect(_button<OutlinedButton>('我的档案'), findsOneWidget);
    expect(_button<OutlinedButton>('我的设备'), findsOneWidget);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await _settle(tester);
    final refresh = _refresh(tester);
    refresh();
    refresh();
    await _flush(tester);
    expect(reads, 3);
    expect(find.text('137'), findsOneWidget);
    expect(find.text('正在刷新…'), findsOneWidget);
    response.complete(http.Response('{"errorCode":"TEMPORARY_FAILURE"}', 500));
    await _settle(tester);
    expect(find.text('137'), findsOneWidget);
    expect(find.text('以下为上次成功读取的数据，当前状态尚未更新。'), findsOneWidget);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await _settle(tester);
    expect(reads, 4);
    expect(find.text('246'), findsOneWidget);
    expect(find.text('137'), findsNothing);
    expect(find.text('以下为上次成功读取的数据，当前状态尚未更新。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a replacement session with the same page key rejects the old response',
      (tester) async {
    final oldResponse = Completer<http.Response>();
    var oldReads = 0, newReads = 0;
    final oldSession = _OverviewSession((_) {
      oldReads++;
      return oldResponse.future;
    });
    final nextSession = _OverviewSession((_) {
      newReads++;
      return _summary(246);
    });
    final host = await _mount(tester, oldSession, pending: [oldResponse]);
    host.replace(nextSession);
    await _flush(tester);
    await _settle(tester);
    expect(find.text('246'), findsOneWidget);
    oldResponse.complete(_summary(137));
    await _settle(tester);
    expect(find.text('137'), findsNothing);
    expect(find.text('246'), findsOneWidget);
    expect(oldReads, 1);
    expect(newReads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'leaving the overview invalidates held refresh and navigation callbacks',
      (tester) async {
    var reads = 0;
    final session = _OverviewSession((_) {
      reads++;
      return _summary(137);
    });
    final host = await _mount(tester, session);
    await _settle(tester);
    final refresh = _refresh(tester), navigate = _navigate(tester);
    host.router.go('/elsewhere');
    await _settle(tester);
    refresh();
    navigate();
    await _settle(tester);
    expect(reads, 1);
    expect(find.text('另一页面'), findsOneWidget);
    expect(host.router.routeInformationProvider.value.uri.path, '/elsewhere');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '403 hides loaded data and invalidates the retained refresh callback',
      (tester) async {
    var reads = 0;
    final session = _OverviewSession((_) => ++reads == 1
        ? _summary(137)
        : http.Response('{"errorCode":"SCOPE_DENIED"}', 403));
    await _mount(tester, session);
    await _settle(tester);
    final refresh = _refresh(tester);
    refresh();
    await _settle(tester);
    expect(find.text('137'), findsNothing);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    refresh();
    await _settle(tester);
    expect(reads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'unauthenticated and writing roles never request a scoped overview',
      (tester) async {
    for (final signedIn in [false, true]) {
      var reads = 0;
      final session = _OverviewSession((_) {
        reads++;
        return _summary(137);
      })
        ..signedIn = signedIn
        ..role = signedIn ? 'OWNER' : 'TEACHER';
      await _mount(tester, session);
      await _settle(tester);
      expect(reads, 0);
      expect(find.text('137'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
