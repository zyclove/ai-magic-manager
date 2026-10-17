import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_agent_binding.dart';
import 'package:guardian/core/managed_agent_binding_repository.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/managed_agent_binding_dialog.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:http/http.dart' as http;

import 'managed_agent_binding_fixtures.dart';

const _entry = Key('managed-binding-application-evidence');

/// Only the external child journey is held by a synthetic future. The parent
/// dialog, repository, current binding DTO and HTTP parsing are production code.
class _ChildInvocation {
  final ManagedAgentBinding binding;
  final bool Function() parentCurrent;
  final Listenable parentChanges;
  final VoidCallback onParentRefresh;
  final completed = Completer<void>();
  final observations = <bool>[];

  _ChildInvocation(this.binding,
      {required this.parentCurrent,
      required this.parentChanges,
      required this.onParentRefresh}) {
    parentChanges.addListener(changed);
    changed();
  }

  void changed() => observations.add(parentCurrent());
  void finish() {
    if (!completed.isCompleted) {
      completed.complete();
    }
  }

  void stopObserving() => parentChanges.removeListener(changed);
}

class _BorrowedClient extends http.BaseClient {
  final http.Client delegate;
  bool closed = false;
  _BorrowedClient(this.delegate);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      delegate.send(request);

  @override
  void close() {
    closed = true;
    delegate.close();
  }
}

class _Harness {
  final AgentBindingFixture fixture;
  final children = <_ChildInvocation>[];
  late final client = _BorrowedClient(fixture.client);
  late final repository = ManagedAgentBindingRepository(
      api: Api(() async => client,
          baseUrl: 'https://binding-hook.invalid/api/v1'),
      tenantId: bindingTenant,
      enrollmentId: bindingEnrollment,
      subjectId: bindingSubject,
      current: () => fixture.current);

  _Harness(this.fixture);

  Future<void> open(ManagedAgentBinding binding,
      {required bool Function() parentCurrent,
      required Listenable parentChanges,
      required VoidCallback onParentRefresh}) {
    final child = _ChildInvocation(binding,
        parentCurrent: parentCurrent,
        parentChanges: parentChanges,
        onParentRefresh: onParentRefresh);
    children.add(child);
    return child.completed.future;
  }

  int get reads => fixture.requests.where((r) => r.method == 'GET').length;
}

Future<void> _settle(WidgetTester tester) async {
  for (var index = 0; index < 8; index++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<_Harness> _mount(WidgetTester tester,
    {AgentBindingFixture? fixture,
    bool writable = true,
    bool includeCallback = true}) async {
  final actual = fixture ?? AgentBindingFixture();
  if (fixture == null) {
    actual.binding = actual.record(state: 'VERIFIED', version: 3);
  }
  final harness = _Harness(actual);
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: ManagedAgentBindingDialog(
              repository: harness.repository,
              writable: writable,
              reauthenticate: () {},
              now: () => actual.instant,
              onApplicationEvidence: includeCallback ? harness.open : null))));
  addTearDown(() async {
    for (final child in harness.children) {
      child.finish();
    }
    await _settle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    for (final child in harness.children) {
      child.stopObserving();
    }
    harness.client.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await _settle(tester);
  return harness;
}

Finder _button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

VoidCallback _callback(WidgetTester tester, Finder finder) {
  expect(finder, findsOneWidget);
  final callback = tester.widget<ButtonStyleButton>(finder).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _settle(tester);
}

/// The external child is a real owned Flutter dialog route. Its minimal content
/// is synthetic; parent binding, repository, network parsing, busy state and
/// close callbacks remain production code.
class _BindingRouteHarness {
  final _Harness network;
  final navigator = GlobalKey<NavigatorState>();
  late BuildContext rootContext;
  late BuildContext bindingContext;
  late OwnedDialogRoute<void> parentRoute;
  OwnedDialogRoute<void>? childRoute;
  OwnedDialogRoute<void>? noticeRoute;
  Future<void>? parentCompletion;
  Future<void>? childCompletion;
  Future<void>? noticeCompletion;
  bool parentFinished = false;
  bool childFinished = false;
  bool noticeFinished = false;
  int childOpenCount = 0;
  bool Function()? childCurrent;

  _BindingRouteHarness(this.network);

  Future<void> openChild(ManagedAgentBinding binding,
      {required bool Function() parentCurrent,
      required Listenable parentChanges,
      required VoidCallback onParentRefresh}) {
    childOpenCount++;
    childCurrent = parentCurrent;
    childRoute = OwnedDialogRoute<void>(
        context: bindingContext,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
                title: const Text('应用核验子窗口'),
                content: const Text('路由回归专用合成内容'),
                actions: [
                  TextButton(
                      onPressed: () => childRoute!.finish(),
                      child: const Text('返回关联')),
                ]));
    childCompletion =
        presentOwnedDialog<void>(bindingContext, childRoute!).then((_) {
      childFinished = true;
    });
    return childCompletion!;
  }

  void coverWithIndependentNotice() {
    noticeRoute = OwnedDialogRoute<void>(
        context: rootContext,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
                title: const Text('独立提醒窗口'),
                content: const Text('此提醒不属于父关联关闭操作'),
                actions: [
                  TextButton(
                      onPressed: () => noticeRoute!.finish(),
                      child: const Text('关闭独立提醒')),
                ]));
    noticeCompletion =
        presentOwnedDialog<void>(rootContext, noticeRoute!).then((_) {
      noticeFinished = true;
    });
  }
}

Future<_BindingRouteHarness> _mountBindingRoutes(WidgetTester tester,
    {required String state}) async {
  final fixture = AgentBindingFixture();
  fixture.binding = fixture.record(state: state, version: 3);
  final h = _BindingRouteHarness(_Harness(fixture));
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(
      navigatorKey: h.navigator,
      theme: consoleTheme(),
      home: Builder(builder: (context) {
        h.rootContext = context;
        return const Scaffold(body: Text('父关联路由测试宿主'));
      })));
  h.parentRoute = OwnedDialogRoute<void>(
      context: h.rootContext,
      barrierDismissible: false,
      builder: (context) {
        h.bindingContext = context;
        return ManagedAgentBindingDialog(
            repository: h.network.repository,
            writable: true,
            reauthenticate: () {},
            now: () => fixture.instant,
            onApplicationEvidence: h.openChild);
      });
  // Only synchronous fallbacks belong to package:test teardown. All route
  // futures and frames are drained in the widget body's finally block.
  addTearDown(() {
    h.network.client.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  h.parentCompletion =
      presentOwnedDialog<void>(h.rootContext, h.parentRoute).then((_) {
    h.parentFinished = true;
  });
  await _settle(tester);
  return h;
}

Future<void> _finishOwnedBindingRoute(
    WidgetTester tester,
    OwnedDialogRoute<void>? route,
    Future<void>? completion,
    bool Function() finished,
    String label) async {
  if (route == null) return;
  route.finish();
  await _settle(tester);
  if (!finished() && route.isActive && route.navigator?.mounted == true) {
    // Test-owned cleanup may remove this exact fixture route if a PopScope
    // rejected its ordinary finish. Never pop whichever unrelated route is top.
    route.navigator!.removeRoute(route);
    await _settle(tester);
  }
  if (!finished() || route.isActive) {
    throw StateError(
        'Fixture route did not finish after bounded frames: $label');
  }
  // The completion flag is set by this very future's final synchronous
  // callback. No unresolved route future is awaited during fixture cleanup.
  if (completion != null) await completion;
}

Future<void> _finishBindingRoutes(
    WidgetTester tester, _BindingRouteHarness h) async {
  await _finishOwnedBindingRoute(tester, h.noticeRoute, h.noticeCompletion,
      () => h.noticeFinished, 'notice');
  await _finishOwnedBindingRoute(
      tester, h.childRoute, h.childCompletion, () => h.childFinished, 'child');
  await _finishOwnedBindingRoute(tester, h.parentRoute, h.parentCompletion,
      () => h.parentFinished, 'parent');
  await tester.pumpWidget(const SizedBox.shrink());
  await _settle(tester);
}

void _staleParentCloseCases() {
  testWidgets(
      'captured parent completion cannot close an active application child',
      (tester) async {
    final h = await _mountBindingRoutes(tester, state: 'VERIFIED');
    try {
      expect(find.text('儿童端身份已核验'), findsOneWidget);
      final oldComplete = _callback(tester, _button('完成'));
      await _tap(tester, find.byKey(_entry));
      expect(find.text('应用核验子窗口'), findsOneWidget);
      expect(h.childOpenCount, 1);
      expect(h.childRoute!.isCurrent, isTrue);
      expect(h.parentRoute.isActive, isTrue);
      expect(h.childFinished, isFalse);
      expect(h.childCurrent!(), isTrue);
      final parentButton = find.ancestor(
          of: find.text('完成', skipOffstage: false),
          matching: find.byWidgetPredicate(
              (widget) => widget is ButtonStyleButton,
              skipOffstage: false));
      expect(tester.widget<ButtonStyleButton>(parentButton).onPressed, isNull,
          reason:
              'The rebuilt parent is busy; the old closure must recheck it.');

      oldComplete();
      await _settle(tester);

      expect(find.text('应用核验子窗口'), findsOneWidget,
          reason:
              'An old parent completion does not own the active child route.');
      expect(h.childRoute!.isCurrent, isTrue);
      expect(h.childFinished, isFalse);
      expect(h.parentFinished, isFalse);
      expect(h.parentRoute.isActive, isTrue);
      expect(h.childCurrent!(), isTrue);
      expect(h.network.reads, 1);
      expect(
          h.network.fixture.requests.where((r) => r.method == 'POST'), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await _finishBindingRoutes(tester, h);
    }
  });

  testWidgets(
      'captured parent close cannot close an independent covering notice',
      (tester) async {
    final h = await _mountBindingRoutes(tester, state: 'PENDING');
    try {
      expect(find.text('等待儿童端反馈'), findsOneWidget);
      final oldClose = _callback(tester, _button('关闭'));
      h.coverWithIndependentNotice();
      await _settle(tester);
      expect(find.text('独立提醒窗口'), findsOneWidget);
      expect(h.noticeRoute!.isCurrent, isTrue);
      expect(h.parentRoute.isActive, isTrue);
      expect(h.noticeFinished, isFalse);
      final parentButton = find.ancestor(
          of: find.text('关闭', skipOffstage: false),
          matching: find.byWidgetPredicate(
              (widget) => widget is ButtonStyleButton,
              skipOffstage: false));
      expect(
          tester.widget<ButtonStyleButton>(parentButton).onPressed, isNotNull,
          reason:
              'No child operation is busy; this specifically checks route ownership.');

      oldClose();
      await _settle(tester);

      expect(find.text('独立提醒窗口'), findsOneWidget,
          reason: 'The parent close callback cannot pop an unrelated notice.');
      expect(h.noticeRoute!.isCurrent, isTrue);
      expect(h.noticeFinished, isFalse);
      expect(h.parentFinished, isFalse);
      expect(h.parentRoute.isActive, isTrue);
      expect(h.childOpenCount, 0);
      expect(h.network.reads, 1);
      expect(
          h.network.fixture.requests.where((r) => r.method == 'POST'), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await _finishBindingRoutes(tester, h);
    }
  });
}

void main() {
  _staleParentCloseCases();
  testWidgets('eligible manager opens the exact verified binding context',
      (tester) async {
    final h = await _mount(tester);
    expect(find.text('儿童端身份已核验'), findsOneWidget);
    await _tap(tester, find.byKey(_entry));
    expect(h.children, hasLength(1));
    final child = h.children.single;
    expect(child.binding.id, bindingId);
    expect(child.binding.deviceId, bindingDevice);
    expect(child.binding.registrationId, bindingRegistration);
    expect(child.binding.version, 3);
    expect(child.binding.state, 'VERIFIED');
    expect(child.binding.verifiedAt, isNotNull);
    expect(child.parentCurrent(), isTrue,
        reason:
            'The child remains current while its parent is deliberately busy.');
    expect(h.fixture.requests.map((request) => request.method), ['GET']);
  });

  testWidgets(
      'read only pending unready and missing proof never expose the entry',
      (tester) async {
    for (final scenario in [
      'readonly',
      'pending',
      'unready',
      'missing-proof'
    ]) {
      final f = AgentBindingFixture();
      f.binding = f.record(
          state: scenario == 'pending' ? 'PENDING' : 'VERIFIED', version: 3);
      if (scenario == 'unready') {
        f.ready = false;
      }
      if (scenario == 'missing-proof') {
        f.binding = {...f.binding!, 'verifiedAt': null};
      }
      final h =
          await _mount(tester, fixture: f, writable: scenario != 'readonly');
      expect(find.text('关联儿童端'), findsOneWidget);
      expect(find.byKey(_entry), findsNothing, reason: scenario);
      expect(h.children, isEmpty, reason: scenario);
      expect(h.fixture.requests.where((request) => request.method == 'POST'),
          isEmpty,
          reason: scenario);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
    }
  });

  testWidgets('host without a callback does not advertise an unavailable entry',
      (tester) async {
    final h = await _mount(tester, includeCallback: false);
    expect(find.text('儿童端身份已核验'), findsOneWidget);
    expect(find.byKey(_entry), findsNothing);
    expect(h.children, isEmpty);
    expect(h.reads, 1);
  });

  testWidgets(
      'active child blocks repeated open parent refresh and captured revoke',
      (tester) async {
    final h = await _mount(tester);
    await _tap(tester, _button('撤销此关联'));
    final revoke = _callback(tester, _button('确认撤销'));
    final refresh = _callback(tester, _button('刷新记录'));
    final open = _callback(tester, find.byKey(_entry));
    open();
    await _settle(tester);
    expect(h.children, hasLength(1));
    open();
    refresh();
    revoke();
    await _settle(tester);
    expect(h.children, hasLength(1));
    expect(h.reads, 1);
    expect(h.fixture.revokeCount, 0);
    expect(h.children.single.parentCurrent(), isTrue);
    expect(tester.widget<ButtonStyleButton>(_button('刷新记录')).onPressed, isNull);
    h.children.single.finish();
    await _settle(tester);
    expect(
        tester.widget<ButtonStyleButton>(_button('刷新记录')).onPressed, isNotNull);
  });

  testWidgets(
      'a captured old entry cannot reopen after a parent version refresh',
      (tester) async {
    final h = await _mount(tester);
    final oldOpen = _callback(tester, find.byKey(_entry));
    oldOpen();
    await _settle(tester);
    final child = h.children.single;
    child.finish();
    await _settle(tester);
    expect(child.parentCurrent(), isFalse,
        reason: 'A finished child lifetime is permanently lost.');
    h.fixture.binding = h.fixture.record(state: 'VERIFIED', version: 4);
    await _tap(tester, _button('刷新记录'));
    oldOpen();
    await _settle(tester);
    expect(h.children, hasLength(1));
    expect(child.parentCurrent(), isFalse);
    await _tap(tester, find.byKey(_entry));
    expect(h.children, hasLength(2));
    expect(h.children.last.binding.version, 4);
    expect(h.children.last.parentCurrent(), isTrue);
  });

  testWidgets(
      'observed parent loss cannot revive a child after the predicate returns',
      (tester) async {
    final h = await _mount(tester);
    await _tap(tester, find.byKey(_entry));
    final child = h.children.single;
    expect(child.parentCurrent(), isTrue);
    h.fixture.current = false;
    expect(child.parentCurrent(), isFalse);
    h.fixture.current = true;
    expect(child.parentCurrent(), isFalse);
    child.onParentRefresh();
    child.finish();
    await _settle(tester);
    expect(h.reads, 1,
        reason:
            'A stale child cannot request a parent refresh in a restored scope.');
    expect(h.fixture.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  testWidgets(
      'explicit refresh intent waits for child completion and coalesces to one GET',
      (tester) async {
    final h = await _mount(tester);
    await _tap(tester, find.byKey(_entry));
    final child = h.children.single;
    h.fixture.binding = h.fixture.record(state: 'VERIFIED', version: 4);
    child.onParentRefresh();
    child.onParentRefresh();
    await _settle(tester);
    expect(h.reads, 1,
        reason:
            'The child still owns its fixed binding version until it closes.');
    expect(child.binding.version, 3);
    child.finish();
    await _settle(tester);
    expect(h.reads, 2);
    expect(child.parentCurrent(), isFalse);
    expect(h.fixture.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(
        tester.widget<ButtonStyleButton>(_button('刷新记录')).onPressed, isNotNull);
    await _tap(tester, find.byKey(_entry));
    expect(h.children.last.binding.version, 4,
        reason: 'A new version requires a new explicit entry action.');
  });

  testWidgets(
      'ordinary child close does not silently reload or replace the binding',
      (tester) async {
    final h = await _mount(tester);
    await _tap(tester, find.byKey(_entry));
    final child = h.children.single;
    h.fixture.binding = h.fixture.record(state: 'VERIFIED', version: 4);
    child.finish();
    await _settle(tester);
    expect(h.reads, 1);
    await _tap(tester, find.byKey(_entry));
    expect(h.children, hasLength(2));
    expect(h.children.last.binding.version, 3);
    expect(h.children.last.parentCurrent(), isTrue);
  });

  testWidgets(
      'parent disposal notifies child before releasing a borrowed client',
      (tester) async {
    final h = await _mount(tester);
    await _tap(tester, find.byKey(_entry));
    final child = h.children.single;
    expect(child.observations.last, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    expect(child.observations, contains(false));
    expect(child.parentCurrent(), isFalse);
    expect(h.client.closed, isFalse);
    child.onParentRefresh();
    child.finish();
    await _settle(tester);
    expect(h.reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'captured entry after parent disposal cannot start a child or request',
      (tester) async {
    final h = await _mount(tester);
    final open = _callback(tester, find.byKey(_entry));
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    open();
    await _settle(tester);
    expect(h.children, isEmpty);
    expect(h.reads, 1);
    expect(h.client.closed, isFalse);
    expect(tester.takeException(), isNull);
  });
}
