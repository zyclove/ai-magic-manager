@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_execution.dart';
import 'package:guardian/core/managed_execution_review.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/managed_execution_dialog_entry.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:http/http.dart' as http;

import 'managed_execution_fixtures.dart';
import 'managed_execution_review_widget_fixtures.dart';

/// Existing managed_execution_host_test retains real Session initialization and
/// generation tests. Here login is intercepted solely to observe handoff order.
class _HostSession extends Session {
  final Api testApi;
  int logins = 0;
  bool? stepUp;
  VoidCallback? beforeLogin;
  _HostSession(this.testApi) {
    profile = {'subject': 'host-review-owner'};
    tenant = {'id': executionTenant, 'kind': 'ORGANIZATION'};
    role = 'OWNER';
  }
  @override
  bool get authenticated => true;
  @override
  Api get api => testApi;
  @override
  void login({bool stepUp = false}) { beforeLogin?.call(); logins++; this.stepUp = stepUp; }
  void roleChanged(String value) { role = value; notifyListeners(); }
}

class _CompletionObserver extends NavigatorObserver {
  bool completed = false;
  Route<dynamic>? owned;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (owned == null && route is OwnedDialogRoute) owned = route;
  }
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (identical(route, owned) && route is TransitionRoute) {
      route.completed.then((_) { completed = true; });
    }
  }
}

Future<BuildContext> _mount(WidgetTester tester, _CompletionObserver observer) async {
  late BuildContext context;
  await tester.pumpWidget(MaterialApp(theme: consoleTheme(), navigatorObservers: [observer],
    home: Scaffold(body: Builder(builder: (value) { context = value; return const Text('设备管理'); }))));
  return context;
}

Future<void> _open(WidgetTester tester, BuildContext context, _HostSession session,
    ReviewWidgetFixture fixture, {bool Function()? current, Listenable? changes}) async {
  unawaited(openManagedExecutions(context, session, deviceId: executionDevice,
    registrationId: executionRegistration, deviceName: '宿主中的学习平板',
    current: current ?? () => true, targetChanges: changes, journal: fixture.journal));
  await flushReview(tester);
  await openReview(tester);
}

void main() {
  testWidgets('explicit MFA waits for owned route completed and never replays POST', (tester) async {
    final f = ReviewWidgetFixture()..denialStatus = 401..denialCode = 'REAUTH_REQUIRED';
    final session = _HostSession(f.data.api);
    final observer = _CompletionObserver();
    final context = await _mount(tester, observer);
    addTearDown(() async { await tester.pumpWidget(const SizedBox.shrink()); session.dispose(); f.release(); });
    session.beforeLogin = () {
      expect(observer.completed, isTrue);
      expect(find.byKey(const Key('execution-dialog')), findsNothing);
      expect(find.byKey(const Key('execution-confirm-recheck')), findsNothing);
    };
    await _open(tester, context, session, f);
    await pressReview(tester, 'execution-recheck');
    await pressReview(tester, 'execution-confirm-recheck');
    expect(session.logins, 0);
    expect(find.text('宿主中的学习平板'), findsNothing);
    expect(f.posts, hasLength(1));
    await pressReview(tester, 'execution-reauth');
    expect(session.logins, 1);
    expect(session.stepUp, isTrue);
    expect(f.posts, hasLength(1));
    expect(f.journal.record!.phase, ExecutionOperationPhase.rejectedNotApplied);
    expect(tester.takeException(), isNull);
  });

  testWidgets('covered retained MFA callback neither closes overlay nor starts login', (tester) async {
    final f = ReviewWidgetFixture()..denialStatus = 401..denialCode = 'REAUTH_REQUIRED';
    final session = _HostSession(f.data.api);
    final observer = _CompletionObserver();
    final context = await _mount(tester, observer);
    addTearDown(() async { await tester.pumpWidget(const SizedBox.shrink()); session.dispose(); f.release(); });
    await _open(tester, context, session, f);
    await pressReview(tester, 'execution-recheck');
    await pressReview(tester, 'execution-confirm-recheck');
    final reauth = tester.widget<FilledButton>(find.byKey(const Key('execution-reauth'))).onPressed!;
    final overlay = OwnedDialogRoute<void>(context: context,
        builder: (_) => const AlertDialog(title: Text('保留其他窗口')));
    unawaited(Navigator.of(context, rootNavigator: true).push(overlay));
    await flushReview(tester);
    reauth();
    await flushReview(tester);
    expect(session.logins, 0);
    expect(find.text('保留其他窗口'), findsOneWidget);
    expect(f.posts, hasLength(1));
    overlay.finish();
    await flushReview(tester);
    await pressReview(tester, 'execution-close');
    expect(session.logins, 0);
  });

  testWidgets('parent loss during MFA close animation suppresses authentication', (tester) async {
    final f = ReviewWidgetFixture()..denialStatus = 401..denialCode = 'REAUTH_REQUIRED';
    final session = _HostSession(f.data.api);
    final observer = _CompletionObserver();
    final context = await _mount(tester, observer);
    final changes = ValueNotifier<int>(0);
    var current = true;
    addTearDown(() async { await tester.pumpWidget(const SizedBox.shrink()); changes.dispose(); session.dispose(); f.release(); });
    await _open(tester, context, session, f, current: () => current, changes: changes);
    await pressReview(tester, 'execution-recheck');
    await pressReview(tester, 'execution-confirm-recheck');
    final reauth = tester.widget<FilledButton>(find.byKey(const Key('execution-reauth'))).onPressed!;
    reauth();
    current = false; changes.value++;
    current = true; changes.value++;
    await flushReview(tester);
    expect(session.logins, 0);
    expect(f.posts, hasLength(1));
    expect(find.byKey(const Key('execution-dialog')), findsNothing);
  });

  testWidgets('host close during POST does not wait and cannot resurrect on late 200', (tester) async {
    final f = ReviewWidgetFixture()..postRelease = Completer<http.Response>();
    final session = _HostSession(f.data.api);
    final observer = _CompletionObserver();
    final context = await _mount(tester, observer);
    addTearDown(() async { await tester.pumpWidget(const SizedBox.shrink()); session.dispose(); f.release(); });
    await _open(tester, context, session, f);
    await pressReview(tester, 'execution-recheck');
    await pressReview(tester, 'execution-confirm-recheck');
    expect(f.posts, hasLength(1));
    await pressReview(tester, 'execution-close');
    expect(find.byKey(const Key('execution-dialog')), findsNothing);
    expect(f.journal.record!.phase, ExecutionOperationPhase.unknown);
    f.postRelease!.complete(f.data.response(f.data.record(state: 'WAITING_DEVICE',
      reason: 'MANUAL_DEVICE_RECHECK_REQUESTED', revision: 2, updatedAt: 200)));
    await flushReview(tester);
    expect(f.journal.record!.phase, ExecutionOperationPhase.unknown);
    expect(f.journal.receipts, 0);
    expect(session.logins, 0);
    expect(find.byKey(const Key('execution-dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopened same owner UNKNOWN has only explicit query after local recovery', (tester) async {
    final f = ReviewWidgetFixture();
    final session = _HostSession(f.data.api);
    final observer = _CompletionObserver();
    final context = await _mount(tester, observer);
    addTearDown(() async { await tester.pumpWidget(const SizedBox.shrink()); session.dispose(); f.release(); });
    final selected = ManagedExecution.parse(f.task, deviceId: executionDevice);
    f.journal.record = ExecutionOperationPending(intent: ExecutionOperationIntent(
      owner: ExecutionOperationOwner(actorId: 'host-review-owner', tenantId: executionTenant,
          apiBaseUrl: f.data.api.baseUrl, issuer: Session.issuer), task: selected,
      kind: ExecutionOperationKind.cancel, operationId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', createdAt: 100));
    await _open(tester, context, session, f);
    expect(find.byKey(const Key('execution-check-result')), findsOneWidget);
    expect(find.byKey(const Key('execution-recheck')), findsNothing);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    expect(f.data.requests.where((r) => r.url.path.endsWith('/review-eligibility')), isEmpty);
    expect(f.posts, isEmpty);
    await pressReview(tester, 'execution-close');
    expect(f.journal.record, isNotNull);
  });
}
