@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/workbench_view.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'device_management_entry_test.dart' show settleReads;

http.Response _summary([int subjects = 137, int connectionChecks = 0]) => http.Response(
    jsonEncode({
      'subjectCount': subjects,
      'activeDeviceCount': 2,
      'connectionCheckCount': connectionChecks,
      'policyDraftCount': 1,
      'pendingRequestCount': 0,
      'openHelpRequestCount': 0,
      'recentActivity': [
        {
          'id': 'private-activity',
          'action': 'SUBJECT_CREATED',
          'resourceId': 'private-subject',
          'occurredAt': 1791849600000,
        }
      ],
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _DashboardSession extends Session {
  final Api _fixtureApi;
  int fixtureGeneration = 1, reauthCalls = 0;

  _DashboardSession(FutureOr<http.Response> Function(http.Request) handle)
      : _fixtureApi = Api(() async => MockClient((request) async {
              expect(request.method, 'GET');
              expect(request.url.path, endsWith('/tenants/tenant-a/overview'));
              return handle(request);
            })) {
    profile = {'subject': 'adult-a', 'name': '监护人'};
    tenant = {'id': 'tenant-a', 'name': '测试家庭', 'kind': 'FAMILY'};
    role = 'OWNER';
  }

  @override
  Api get api => _fixtureApi;
  @override
  bool get authenticated => true;
  @override
  int get scopeGeneration => fixtureGeneration;
  @override
  void login({bool stepUp = false}) {
    expect(stepUp, isTrue);
    reauthCalls++;
  }

  void advanceGeneration() {
    fixtureGeneration++;
    notifyListeners();
  }
}

class _ActionRecord {
  int starts = 0;
  bool needsReview = true;
  ApiFailure? failure;
}

class _FixtureActions extends ConsoleActions {
  final _ActionRecord record;
  _FixtureActions(super.context, super.s, this.record);

  @override
  Future<bool> subject({Listenable? accessChanges, bool Function()? hasAccess}) async {
    record.starts++;
    final failure = record.failure;
    if (failure != null) throw failure;
    return record.needsReview;
  }
}

class _Host {
  final rebuild = ValueNotifier(0);
  late final GoRouter router;

  _Host(_DashboardSession session, _ActionRecord actions) {
    router = GoRouter(initialLocation: '/', routes: [
      GoRoute(
          path: '/',
          builder: (_, state) => Scaffold(
              body: SingleChildScrollView(
                  child: ValueListenableBuilder<int>(
                      valueListenable: rebuild,
                      builder: (context, value, child) => Dashboard(
                          key: const ValueKey('held-dashboard'),
                          session: session,
                          actions:
                              _FixtureActions(context, session, actions)))))),
      GoRoute(
          path: '/devices',
          builder: (_, state) => const Scaffold(body: Text('设备目的页'))),
      GoRoute(
          path: '/subjects',
          builder: (_, state) => const Scaffold(body: Text('档案目的页'))),
    ]);
  }
}

Future<_Host> _mount(WidgetTester tester, _DashboardSession session,
    _ActionRecord actions) async {
  final host = _Host(session, actions);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    host.router.dispose();
    host.rebuild.dispose();
    session.dispose();
  });
  await tester.pumpWidget(
      MaterialApp.router(theme: consoleTheme(), routerConfig: host.router));
  await settleReads(tester);
  return host;
}

WorkbenchView _view(WidgetTester tester) =>
    tester.widget<WorkbenchView>(find.byType(WorkbenchView));

void _expectHidden() {
  expect(find.text('137'), findsNothing);
  expect(find.text('最近活动'), findsNothing);
  expect(find.textContaining('上次读取完成：'), findsNothing);
}

void main() {
  testWidgets('cancelled subject creation preserves summary errors and resumes an interrupted read',
      (tester) async {
    var reads = 0;
    final pending = Completer<http.Response>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(_summary());
    });
    final actions = _ActionRecord()..needsReview = false;
    final session = _DashboardSession((_) {
      reads++;
      return switch (reads) {
        1 => _summary(137),
        2 => http.Response('{"errorCode":"SERVICE_UNAVAILABLE"}', 503),
        3 => pending.future,
        4 => _summary(291),
        _ => throw StateError('Unexpected extra overview read.'),
      };
    });
    await _mount(tester, session, actions);
    final originalTime = _view(tester).refreshedAt;
    _view(tester).onAddSubject!();
    await settleReads(tester);
    expect(reads, 1);
    expect(_view(tester).summary!.subjectCount, 137);
    expect(_view(tester).refreshedAt, originalTime);
    expect(actions.starts, 1);
    _view(tester).onRefresh();
    await settleReads(tester);
    expect(reads, 2);
    final previousFailure = _view(tester).error;
    expect(previousFailure, isA<ApiFailure>().having((e) => e.status, 'status', 503));
    _view(tester).onAddSubject!();
    await settleReads(tester);
    expect(reads, 2);
    expect(_view(tester).error, same(previousFailure));
    expect(_view(tester).refreshedAt, originalTime);
    _view(tester).onRefresh();
    for (var frame = 0; frame < 6; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(reads, 3);
    expect(_view(tester).refreshing, isTrue);
    _view(tester).onAddSubject!();
    for (var frame = 0; frame < 24 &&
        (_view(tester).refreshing || _view(tester).summary?.subjectCount != 291); frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(reads, 4, reason: 'An interrupted overview read needs one replacement after cancellation.');
    expect(_view(tester).summary!.subjectCount, 291);
    expect(_view(tester).error, isNull);
    expect(actions.starts, 3);
    pending.complete(_summary(999));
    await settleReads(tester);
    expect(_view(tester).summary!.subjectCount, 291);
    expect(reads, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connection next step opens the canonical filtered device route',
      (tester) async {
    var reads = 0;
    final session = _DashboardSession((_) {
      reads++;
      return _summary(137, 2);
    });
    final host = await _mount(tester, session, _ActionRecord());
    final next = find.byKey(const Key('workbench-next-action'));
    expect(next, findsOneWidget);
    await tester.ensureVisible(next);
    await tester.tap(next);
    await settleReads(tester);
    final uri = host.router.routeInformationProvider.value.uri;
    expect(uri.path, '/devices');
    expect(uri.queryParameters, {'connection': 'NEEDS_CHECK'});
    expect(find.text('设备目的页'), findsOneWidget);
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh denial hides private data and revokes held actions',
      (tester) async {
    var reads = 0;
    final actions = _ActionRecord();
    final session = _DashboardSession((_) => ++reads == 1
        ? _summary()
        : http.Response('{"errorCode":"TENANT_ACCESS_DENIED"}', 403));
    final host = await _mount(tester, session, actions);
    final held = _view(tester);
    expect(find.text('137'), findsOneWidget);
    expect(find.text('最近活动'), findsOneWidget);
    expect(find.textContaining('上次读取完成：'), findsOneWidget);
    held.onRefresh();
    await settleReads(tester);
    _expectHidden();
    expect(
        (tester.widget<FailureView>(find.byType(FailureView)).error
                as ApiFailure)
            .status,
        403);
    held.onRefresh();
    held.onAddSubject!();
    held.onOpen('subjects');
    held.onReauth();
    host.rebuild.value++;
    await settleReads(tester);
    expect(reads, 2);
    expect(actions.starts, 0);
    expect(session.reauthCalls, 0);
    expect(host.router.routeInformationProvider.value.uri.path, '/');
    _expectHidden();
    expect(tester.takeException(), isNull);
  });

  testWidgets('recent authentication retains the original dashboard until manual retry',
      (tester) async {
    for (final viaAction in [false, true]) {
      var reads = 0;
      final actions = _ActionRecord();
      if (viaAction) actions.failure = const ApiFailure(401, 'REAUTH_REQUIRED');
      final session = _DashboardSession((_) {
        reads++;
        return !viaAction && reads == 2
            ? http.Response('{"errorCode":"REAUTH_REQUIRED"}', 401)
            : _summary(reads == 1 ? 137 : 291);
      });
      final host = await _mount(tester, session, actions);
      final original = _view(tester);
      final originalSummary = original.summary;
      final originalTime = original.refreshedAt;
      final generation = session.scopeGeneration;
      if (viaAction) {
        original.onAddSubject!();
      } else {
        original.onRefresh();
      }
      await settleReads(tester);
      final failed = _view(tester);
      final failure = failed.error;
      expect(failed.summary, same(originalSummary));
      expect(failed.refreshedAt, originalTime);
      expect(failure, isA<ApiFailure>().having((e) => e.code, 'code', 'REAUTH_REQUIRED'));
      expect(failed.refreshing, isFalse);
      expect(failed.busy, isFalse);
      expect(find.text('137'), findsOneWidget);
      expect(find.text('最近活动'), findsOneWidget);
      expect(find.textContaining('上次读取完成：'), findsOneWidget);
      final expectedReads = viaAction ? 1 : 2;
      final expectedActions = viaAction ? 1 : 0;
      expect(reads, expectedReads);
      expect(actions.starts, expectedActions);
      final reauthenticate = tester.widget<FailureView>(find.byType(FailureView)).reauth!;
      reauthenticate();
      host.rebuild.value++;
      await settleReads(tester);
      expect(session.reauthCalls, 1);
      expect(session.scopeGeneration, generation);
      expect(reads, expectedReads, reason: 'Reauthentication must not silently refresh the overview.');
      expect(actions.starts, expectedActions, reason: 'Reauthentication must not retry a write action.');
      expect(_view(tester).summary, same(originalSummary));
      expect(_view(tester).refreshedAt, originalTime);
      expect(_view(tester).error, same(failure));
      original.onRefresh();
      await settleReads(tester);
      expect(reads, expectedReads + 1);
      expect(_view(tester).summary!.subjectCount, 291);
      expect(_view(tester).error, isNull);
      expect(actions.starts, expectedActions);
      expect(session.scopeGeneration, generation,
          reason: 'A recent-authentication challenge must keep the original read scope.');
      expect(tester.takeException(), isNull, reason: viaAction ? 'action' : 'read');
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReads(tester);
    }
  });

  testWidgets('ordinary 503 retains the last summary and permits a fresh retry',
      (tester) async {
    var reads = 0;
    final session = _DashboardSession((_) {
      reads++;
      return reads == 2
          ? http.Response('{"errorCode":"SERVICE_UNAVAILABLE"}', 503)
          : _summary(reads == 1 ? 137 : 291);
    });
    await _mount(tester, session, _ActionRecord());
    final previousTime = _view(tester).refreshedAt;
    _view(tester).onRefresh();
    await settleReads(tester);
    expect(_view(tester).summary!.subjectCount, 137);
    expect(_view(tester).refreshedAt, previousTime);
    expect((_view(tester).error as ApiFailure).status, 503);
    expect(find.text('最近活动'), findsOneWidget);
    _view(tester).onRefresh();
    await settleReads(tester);
    expect(_view(tester).summary!.subjectCount, 291);
    expect(_view(tester).error, isNull);
    expect(reads, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('action denial removes the summary without starting a refresh',
      (tester) async {
    var reads = 0;
    final session = _DashboardSession((_) {
      reads++;
      return _summary();
    });
    final actions = _ActionRecord()
      ..failure = const ApiFailure(403, 'TENANT_ACCESS_DENIED');
    await _mount(tester, session, actions);
    final held = _view(tester);
    final add = find.byKey(const Key('workbench-add-subject'));
    await tester.ensureVisible(add);
    await tester.tap(add);
    await settleReads(tester);
    _expectHidden();
    expect(actions.starts, 1);
    expect(reads, 1);
    held.onAddSubject!();
    held.onRefresh();
    await settleReads(tester);
    expect(actions.starts, 1);
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'same-context 401 keeps reauthentication but requires a new scope',
      (tester) async {
    var reads = 0;
    final session = _DashboardSession((_) => ++reads == 2
        ? http.Response('{"errorCode":"UNAUTHENTICATED"}', 401)
        : _summary(reads == 1 ? 137 : 291));
    final host = await _mount(tester, session, _ActionRecord());
    _view(tester).onRefresh();
    await settleReads(tester);
    _expectHidden();
    final reauthenticate =
        tester.widget<FailureView>(find.byType(FailureView)).reauth!;
    reauthenticate();
    expect(session.reauthCalls, 1);
    host.rebuild.value++;
    await settleReads(tester);
    expect(reads, 2);
    session.advanceGeneration();
    host.rebuild.value++;
    await settleReads(tester);
    expect(reads, 3);
    expect(_view(tester).summary!.subjectCount, 291);
    reauthenticate();
    expect(session.reauthCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
