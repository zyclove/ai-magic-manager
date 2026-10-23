@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/report_job_resume.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/core/usage_report_jobs.dart';
import 'package:guardian/core/usage_reports.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/pages/usage_reports_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:guardian/ui/usage_report_device_picker.dart';
import 'package:guardian/ui/usage_report_job_dialog.dart';
import 'package:guardian/ui/usage_report_jobs_view.dart';
import 'package:guardian/ui/usage_reports_view.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'usage_reports_test.dart' show device, registration, subject, reportFixture;
import 'workspace_recovery_browser_test.dart' as workspace;

const _a = '91111111-1111-4111-8111-111111111111';
const _b = '92222222-2222-4222-8222-222222222222';
const _class = '93333333-3333-4333-8333-333333333333';
const _jobId = '94444444-4444-4444-8444-444444444444';
const _requestKey = 'abcdef0123456789abcdef0123456789abcdef0123456789';
final _now = DateTime.now().millisecondsSinceEpoch;
const _target = UsageReportTarget(device, registration, subject, '测试平板');

http.Response _reply(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

Json _device() => {
      'id': device,
      'registrationId': registration,
      'subjectId': subject,
      'displayName': '测试平板',
      'platform': 'ANDROID',
      'state': 'ACTIVE',
    };
Json _page(List<Object> values) => {'items': values, 'nextCursor': null};
UsageReportJobDraft _draft() => UsageReportJobDraft(
    deviceIds: [device], from: _now - 3600000, to: _now,
    timeZone: 'UTC', period: 'DAY');
UsageReportQuery _query() => UsageReportQuery(
    targets: [_target], from: _now - 3600000, to: _now,
    timeZone: 'UTC', period: 'DAY');

Json _emptyReport({int? from, int? requestedTo, String zone = 'UTC',
    String period = 'DAY', Json? scope}) {
  final start = from ?? _now - 3600000;
  final requested = requestedTo ?? _now;
  final generated = DateTime.now().millisecondsSinceEpoch;
  final end = requested < generated ? requested : generated;
  final result = reportFixture();
  result.addAll({
    'generatedAt': generated, 'from': start, 'to': end,
    'requestedTo': requested, 'timeZone': zone, 'period': period,
    'scope': scope ?? {'kind': 'DEVICES', 'id': null, 'version': null},
  });
  (result['devices'][0] as Json).addAll({
    'displayName': '测试平板', 'status': 'NO_DATA', 'sourceBatchCount': 0,
    'sourceTimeZones': [], 'applications': [], 'latestObservedAt': null,
    'latestReceivedAt': null, 'queryCoverageMillis': 0,
    'uncoveredQueryMillis': end - start,
    'retentionFrom': generated - 30 * 86400000,
    'configurationState': {
      'checkedAt': generated, 'evidenceStatus': 'DELIVERY_ONLY_NOT_EXECUTION',
      'configurations': [],
    },
  });
  return result;
}

http.Response _report(http.Request request) {
  final q = request.url.queryParameters;
  return _reply(_emptyReport(
      from: int.parse(q['from']!), requestedTo: int.parse(q['to']!),
      zone: q['timeZone']!, period: q['period']!,
      scope: {'kind': q['scopeKind'], 'id': q['scopeId'],
        'version': q['scopeVersion'] == null ? null : int.parse(q['scopeVersion']!)}));
}

Json _job({String state = 'QUEUED', UsageReportJobDraft? draft, Json? payload}) {
  final selection = draft ?? _draft();
  final created = payload?['generatedAt'] as int? ??
      DateTime.now().millisecondsSinceEpoch;
  final body = selection.body;
  final bytes = payload == null ? 0 : utf8.encode(jsonEncode(payload)).length;
  return {
    'id': _jobId, 'state': state, 'createdAt': created, 'updatedAt': created,
    'expiresAt': created + 86400000, 'totalDevices': 1,
    'completedDevices': state == 'READY' ? 1 : 0,
    'byteCount': state == 'READY' ? bytes : 0, 'failureCode': null,
    'selection': {...body, 'to': selection.to < created ? selection.to : created},
    'parts': [{
      'ordinal': 0, 'deviceId': device, 'registrationId': registration,
      'subjectId': subject, 'authorizationVersion': 1, 'usageEnabled': true,
      'byteCount': state == 'READY' ? bytes : null,
      'generatedAt': state == 'READY' ? created : null,
    }],
  };
}

// Production initialize/loadTenants/selectTenant/generation/auth ownership are
// retained. HTTP and the signed-in identity are synthetic; no OAuth provider is
// contacted. The reauth leaf records the exact resume without browser navigation.
class _SelectionSession extends workspace.FixtureSession {
  final resumes = <ReportJobResume>[];
  int stepUps = 0;
  _SelectionSession(super.handle);
  void seed({bool organization = false}) {
    tenants = [
      {'id': _a, 'name': '空间 A', 'kind': organization ? 'ORGANIZATION' : 'FAMILY',
        'timeZone': 'UTC'},
      {'id': _b, 'name': '空间 B', 'kind': 'FAMILY', 'timeZone': 'UTC'},
    ];
    tenant = tenants.first;
    role = 'OWNER';
    notifyListeners();
  }
  @override
  void login({bool stepUp = false}) { if (stepUp) stepUps++; }
  @override
  void reauthenticateReport(ReportJobResume resume) { resumes.add(resume); }
}

Future<_SelectionSession> _session(WidgetTester tester,
    Future<http.Response> Function(http.Request) handle,
    {bool organization = false}) async {
  final session = _SelectionSession(handle);
  await session.authenticate();
  session.seed(organization: organization);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await workspace.flushReads(tester);
    await session.release();
  });
  return session;
}

http.Response _normal(http.Request request) {
  final path = request.url.path;
  if (path.endsWith('/membership')) return _reply({'role': 'OWNER'});
  if (path.endsWith('/usage-reports')) return _report(request);
  if (path.endsWith('/devices/$device')) return _reply(_device());
  if (path.endsWith('/devices')) return _reply(_page([_device()]));
  if (path.endsWith('/subjects')) return _reply(_page([{'id': subject, 'nickname': '儿童'}]));
  if (path.endsWith('/classes/$_class/students')) {
    return _reply(_page([{'id': subject, 'archived': false}]));
  }
  if (path.endsWith('/classes/$_class')) {
    return _reply({'id': _class, 'name': '一班', 'state': 'ACTIVE', 'version': 7});
  }
  if (path.endsWith('/classes')) {
    return _reply(_page([{'id': _class, 'name': '一班', 'state': 'ACTIVE', 'version': 7}]));
  }
  if (path.endsWith('/usage-report-jobs')) return _reply(_page([]));
  if (path.endsWith('/wellbeing-insight')) {
    return _reply({
      'schemaVersion': 1, 'tenantId': _a, 'deviceId': device,
      'registrationId': registration, 'timeZone': 'UTC',
      'generatedAt': _now, 'from': _now - 7 * 86400000, 'to': _now - 1000,
      'queryCoverageMillis': 0, 'status': 'NO_DATA',
      'evidenceStatus': 'AGENT_REPORTED_UNVERIFIED', 'suggestions': [],
    });
  }
  throw StateError('Unexpected report fixture request: ${request.method} $path');
}

class _Host {
  final ValueNotifier<Session> session;
  final visible = ValueNotifier(true);
  late final GoRouter router;
  _Host(Session initial, {bool console = false}) : session = ValueNotifier(initial) {
    router = GoRouter(initialLocation: '/reports', routes: [
      GoRoute(path: '/reports', builder: (_, __) => Scaffold(
          body: SingleChildScrollView(child: ValueListenableBuilder<bool>(
              valueListenable: visible, builder: (_, shown, __) => shown
                  ? ValueListenableBuilder<Session>(valueListenable: session,
                      builder: (_, current, __) => console
                          ? ChangeNotifierProvider<Session>.value(value: current,
                              child: const ConsolePages(section: 'reports'))
                          : UsageReportsPage(key: const ValueKey('fixed-report-host'),
                              session: current))
                  : const Text('报表已离页'))))),
      GoRoute(path: '/policies', builder: (_, __) => const Scaffold(body: Text('规则目的页'))),
      GoRoute(path: '/devices', builder: (_, __) => const Scaffold(body: Text('设备目的页'))),
    ]);
  }
}

Future<_Host> _mount(WidgetTester tester, Session session, {bool console = false}) async {
  final host = _Host(session, console: console);
  await tester.pumpWidget(MaterialApp.router(theme: consoleTheme(), routerConfig: host.router));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    host.router.dispose();
    host.session.dispose();
    host.visible.dispose();
  });
  await workspace.flushReads(tester);
  return host;
}

UsageReportsView _view(WidgetTester tester) =>
    tester.widget<UsageReportsView>(find.byType(UsageReportsView));
UsageReportJobsView _jobs(WidgetTester tester) =>
    tester.widget<UsageReportJobsView>(find.byType(UsageReportJobsView));
dynamic _viewState(WidgetTester tester) => tester.state(find.byType(UsageReportsView));
dynamic _jobsState(WidgetTester tester) => tester.state(find.byType(UsageReportJobsView));

class _Invocation {
  bool completed = false;
  Object? failure;
  _Invocation(Future<dynamic> operation) {
    unawaited(operation.then<void>((_) { completed = true; },
        onError: (Object error, StackTrace _) { completed = true; failure = error; }));
  }
}

// Start real transport work without blocking the test's async/frame drain.
Future<void> _submitAndFlush(
    WidgetTester tester, Future<void> Function() submit) async {
  final invocation = _Invocation(submit());
  await workspace.flushReads(tester);
  expect(invocation.completed, isTrue);
  expect(invocation.failure, isNull);
}

Future<void> _cover(WidgetTester tester, Finder owner) async {
  unawaited(showDialog<void>(context: tester.element(owner),
      builder: (_) => const AlertDialog(title: Text('后续覆盖窗口'))));
  await workspace.flushReads(tester);
}

VoidCallback _textAction(WidgetTester tester, String text) => tester
    .widget<TextButton>(find.ancestor(of: find.text(text),
        matching: find.byWidgetPredicate((widget) => widget is TextButton)))
    .onPressed!;

Matcher get _lost => isA<ApiFailure>().having((value) => value.code, 'code', 'WORKSPACE_CHANGED');
Matcher get _selectionFailed => isA<ApiFailure>().having((value) => value.code, 'code', 'SELECTION_FAILED');

void main() {
  testWidgets('pending real workspace reload rejects late report options and '
      'retained page actions when only generation has changed', (tester) async {
    final tenants = Completer<http.Response>();
    final membership = Completer<http.Response>();
    final devices = Completer<http.Response>();
    final session = await _session(tester, (request) async {
      if (request.url.path == '/api/v1/tenants') return tenants.future;
      if (request.url.path == '/api/v1/tenants/$_a/membership') return membership.future;
      if (request.url.path.endsWith('/devices')) return devices.future;
      return _normal(request);
    }, organization: true);
    addTearDown(() {
      if (!tenants.isCompleted) tenants.complete(_reply(_page(session.tenants)));
      if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
      if (!devices.isCompleted) devices.complete(_reply(_page([_device()])));
    });
    // An existing reload starts before opening this page. Its late response
    // reaches production selectTenant without clicking through any modal.
    final reload = session.loadTenants(preferredTenantId: _a);
    final rejected = expectLater(reload, throwsA(_selectionFailed));
    await _mount(tester, session);
    final held = _view(tester);
    final oldGeneration = session.scopeGeneration, oldRoot = session.root;
    tenants.complete(_reply(_page(session.tenants)));
    await workspace.flushReads(tester);
    expect(session.scopeGeneration, oldGeneration + 1);
    expect(session.root, oldRoot);
    expect(session.role, 'OWNER');
    expect(held.repository.current(), isFalse);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    devices.complete(_reply(_page([_device()])));
    membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
    await workspace.flushReads(tester);
    await rejected;
    final count = session.requests.length;
    await expectLater(held.loadTargets(), throwsA(_lost));
    await expectLater(held.loadScopes!(), throwsA(_lost));
    await expectLater(held.resolveScope!(UsageReportScope(
        kind: 'CLASS', id: _class, version: 7, label: '一班')), throwsA(_lost));
    await expectLater(held.repository.load(_query()), throwsA(_lost));
    await expectLater(held.loadInsight!(device, registration), throwsA(_lost));
    held.onBackground!(_draft());
    held.onJobs!();
    held.onReviewRules!();
    held.onCheckDevice!();
    held.reauth!();
    await workspace.flushReads(tester);
    expect(session.requests, hasLength(count));
    expect(session.stepUps, 0);
    expect(session.resumes, isEmpty);
    expect(find.textContaining('当前选中'), findsNothing);
    expect(find.byType(UsageReportJobDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late synchronous result and retained filter callbacks cannot '
      'restore a report after real selection failure', (tester) async {
    final membership = Completer<http.Response>();
    final result = Completer<http.Response>();
    http.Request? query;
    final session = await _session(tester, (request) async {
      if (request.url.path == '/api/v1/tenants/$_b/membership') return membership.future;
      if (request.url.path.endsWith('/usage-reports')) { query = request; return result.future; }
      return _normal(request);
    });
    addTearDown(() {
      if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
      if (!result.isCompleted && query != null) result.complete(_report(query!));
    });
    await _mount(tester, session);
    final held = _view(tester);
    final dynamic state = _viewState(tester);
    final Future<void> Function() refresh = state.loadOptions as Future<void> Function();
    final zone = tester.widget<DropdownButtonFormField<String>>(
        find.byWidgetPredicate((widget) => widget is DropdownButtonFormField<String> &&
            widget.decoration.labelText == '日期与分组时区')).onChanged!;
    final loading = _Invocation(state.run() as Future<void>);
    await workspace.flushReads(tester);
    expect(query, isNotNull);
    final generation = session.scopeGeneration, root = session.root;
    final selecting = session.selectTenant(session.tenants.last);
    final rejected = expectLater(selecting, throwsA(_selectionFailed));
    expect(session.scopeGeneration, generation + 1);
    expect(session.root, root);
    expect(held.repository.current(), isFalse);
    result.complete(_report(query!));
    membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
    await workspace.flushReads(tester);
    await rejected;
    expect(loading.completed, isTrue);
    expect(loading.failure, isNull);
    final count = session.requests.length;
    await refresh();
    zone('Asia/Shanghai');
    expect(session.requests, hasLength(count));
    expect(find.text('暂无使用数据'), findsNothing);
    expect(find.byKey(const Key('usage-report-category')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final loss in ['selection', 'dispose']) {
    testWidgets('late create result and retained submit, close and reauth stay '
        'owned after $loss under a covering route', (tester) async {
      final membership = Completer<http.Response>();
      final created = Completer<http.Response>();
      http.Request? post;
      final session = await _session(tester, (request) async {
        if (request.url.path == '/api/v1/tenants/$_b/membership') return membership.future;
        if (request.method == 'POST' && request.url.path.endsWith('/usage-report-jobs')) {
          post = request; return created.future;
        }
        return _normal(request);
      });
      addTearDown(() {
        if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
        if (!created.isCompleted) created.complete(_reply(_job(), 202));
      });
      final host = await _mount(tester, session);
      final dynamic page = tester.state(find.byType(UsageReportsPage));
      final opening = _Invocation(page.createJob(_draft()) as Future<void>);
      await workspace.flushReads(tester);
      final dialog = tester.widget<UsageReportJobDialog>(find.byType(UsageReportJobDialog));
      final dynamic dialogState = tester.state(find.byType(UsageReportJobDialog));
      final Future<void> Function() submit = dialogState.submit as Future<void> Function();
      final close = _textAction(tester, '关闭');
      final submitting = _Invocation(submit());
      await workspace.flushReads(tester);
      expect(post, isNotNull);
      await _cover(tester, find.byType(UsageReportJobDialog));
      Future<void>? rejected;
      if (loss == 'selection') {
        final root = session.root, generation = session.scopeGeneration;
        final selecting = session.selectTenant(session.tenants.last);
        rejected = expectLater(selecting, throwsA(_selectionFailed));
        expect(session.root, root);
        expect(session.scopeGeneration, generation + 1);
        expect(dialog.repository.current(), isFalse);
        membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
      } else {
        host.visible.value = false;
      }
      await workspace.flushReads(tester);
      created.complete(_reply(_job(), 202));
      await workspace.flushReads(tester);
      if (rejected != null) await rejected;
      expect(opening.completed, isTrue);
      expect(opening.failure, isNull);
      expect(submitting.completed, isTrue);
      expect(submitting.failure, isNull);
      final count = session.requests.length;
      await submit();
      close();
      dialog.onCreated(UsageReportJob.parse(_job()));
      dialog.onReauth!(_draft(), 'retained-request-key');
      await expectLater(dialog.repository.create(_draft(), 'retained-key'), throwsA(_lost));
      await workspace.flushReads(tester);
      expect(session.requests, hasLength(count));
      expect(session.resumes, isEmpty);
      expect(find.text('后续覆盖窗口'), findsOneWidget);
      expect(find.byType(UsageReportJobDialog), findsNothing);
      expect(find.byType(UsageReportJobsView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('successful covered creation completes only its own route and '
      'shows current jobs once', (tester) async {
    final created = Completer<http.Response>();
    int posts = 0;
    final session = await _session(tester, (request) async {
      if (request.method == 'POST') { posts++; return created.future; }
      return _normal(request);
    });
    addTearDown(() { if (!created.isCompleted) created.complete(_reply(_job(), 202)); });
    await _mount(tester, session);
    final dynamic page = tester.state(find.byType(UsageReportsPage));
    final opening = _Invocation(page.createJob(_draft()) as Future<void>);
    await workspace.flushReads(tester);
    final dynamic dialog = tester.state(find.byType(UsageReportJobDialog));
    final submit = dialog.submit as Future<void> Function();
    final submitting = _Invocation(submit());
    await workspace.flushReads(tester);
    await _cover(tester, find.byType(UsageReportJobDialog));
    created.complete(_reply(_job(), 202));
    await workspace.flushReads(tester);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    expect(submitting.completed, isTrue);
    expect(posts, 1);
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(find.byType(UsageReportJobDialog), findsNothing);
    expect(find.byType(UsageReportJobsView, skipOffstage: false), findsOneWidget);
    await submit();
    expect(posts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a covered create dialog cancels only that draft and '
      'keeps the query page and covering window', (tester) async {
    final session = await _session(tester, (request) async => _normal(request));
    await _mount(tester, session);
    final dynamic page = tester.state(find.byType(UsageReportsPage));
    final opening = _Invocation(page.createJob(_draft()) as Future<void>);
    await workspace.flushReads(tester);
    final dynamic dialogState = tester.state(find.byType(UsageReportJobDialog));
    final submit = dialogState.submit as Future<void> Function();
    final close = _textAction(tester, '关闭');
    await _cover(tester, find.byType(UsageReportJobDialog));
    final beforeClose = session.requests.length;
    close();
    expect(dialogState.mounted, isTrue);
    await submit(); // Intentionally before pump/dispose, while covered removal settles.
    expect(session.requests, hasLength(beforeClose));
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    await workspace.flushReads(tester);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(find.byType(UsageReportsView, skipOffstage: false), findsOneWidget);
    expect(find.byType(UsageReportJobsView, skipOffstage: false), findsNothing);
    expect(session.requests.where((request) => request.method == 'POST'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a current create route rejects held submit during '
      'its reverse transition before any pump or disposal', (tester) async {
    int posts = 0;
    final session = await _session(tester, (request) async {
      if (request.method == 'POST') { posts++; return _reply(_job(), 202); }
      return _normal(request);
    });
    await _mount(tester, session);
    final dynamic page = tester.state(find.byType(UsageReportsPage));
    final opening = _Invocation(page.createJob(_draft()) as Future<void>);
    await workspace.flushReads(tester);
    final dialogWidget = tester.widget<UsageReportJobDialog>(find.byType(UsageReportJobDialog));
    final dynamic state = tester.state(find.byType(UsageReportJobDialog));
    final submit = state.submit as Future<void> Function();
    final route = ModalRoute.of(tester.element(find.byType(UsageReportJobDialog)))
        as OwnedDialogRoute<UsageReportJob>;
    expect(route.isCurrent, isTrue);
    expect(dialogWidget.repository.current(), isTrue);
    _textAction(tester, '关闭')();
    expect(route.available, isFalse);
    expect(state.mounted, isTrue);
    await submit(); // No pump: a valid page repository must not revive this draft.
    expect(posts, 0);
    expect(state.mounted, isTrue);
    expect(opening.completed, isFalse);
    await workspace.flushReads(tester);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    expect(find.byType(UsageReportJobDialog), findsNothing);
    expect(find.byType(UsageReportsView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('host foreground ABA rejects held create submit before deferred '
      'route finish without revoking the shared page repository', (tester) async {
    int posts = 0;
    final session = await _session(tester, (request) async {
      if (request.method == 'POST') { posts++; return _reply(_job(), 202); }
      return _normal(request);
    });
    await _mount(tester, session);
    final dynamic page = tester.state(find.byType(UsageReportsPage));
    final opening = _Invocation(page.createJob(_draft()) as Future<void>);
    await workspace.flushReads(tester);
    final dialogWidget = tester.widget<UsageReportJobDialog>(find.byType(UsageReportJobDialog));
    final dynamic state = tester.state(find.byType(UsageReportJobDialog));
    final submit = state.submit as Future<void> Function();
    final route = ModalRoute.of(tester.element(find.byType(UsageReportJobDialog)))
        as OwnedDialogRoute<UsageReportJob>;
    final generation = session.scopeGeneration, root = session.root;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    // Both lifecycle callbacks run synchronously. The post-frame owner finish
    // has not run: route and shared repository still exist, but page.dialog is null.
    expect(session.scopeGeneration, generation);
    expect(session.root, root);
    expect(route.available, isTrue);
    expect(state.mounted, isTrue);
    expect(dialogWidget.repository.current(), isTrue);
    expect(dialogWidget.hasAccess!(), isFalse);
    await submit(); // Intentionally no pump between ABA and the stale dispatch.
    expect(posts, 0);
    expect(route.available, isTrue);
    await workspace.flushReads(tester);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    expect(find.byType(UsageReportJobDialog), findsNothing);
    expect(find.byType(UsageReportJobsView), findsNothing);
    expect(find.byType(UsageReportsView), findsOneWidget);
    // Abandoning one draft does not close/invalidate the page's shared transport.
    final value = await session.api.send('GET', '/tenants/$_a/devices/$device');
    expect(value['id'], device);
    expect(tester.takeException(), isNull);
  });

  testWidgets('standalone void dialog permits a covered retry but rejects held '
      'submit immediately after its own close completes the route', (tester) async {
    int posts = 0, created = 0;
    final session = await _session(tester, (request) async {
      if (request.method == 'POST') {
        posts++;
        return _reply({'errorCode': 'NETWORK_ERROR'}, 503);
      }
      return _normal(request);
    });
    await _mount(tester, session);
    final parent = _view(tester).repository;
    final repository = UsageReportJobRepository(api: parent.api,
        root: parent.root, current: parent.current);
    final context = tester.element(find.byType(UsageReportsView));
    final route = OwnedDialogRoute<void>(context: context,
        builder: (_) => UsageReportJobDialog(repository: repository,
            draft: _draft(), requestKey: _requestKey, onCreated: (_) { created++; }));
    final opening = _Invocation(presentOwnedDialog(context, route));
    await workspace.flushReads(tester);
    final dynamic state = tester.state(find.byType(UsageReportJobDialog));
    final submit = state.submit as Future<void> Function();
    final close = _textAction(tester, '关闭');
    await _cover(tester, find.byType(UsageReportJobDialog));
    expect(route.isCurrent, isFalse);
    expect(route.available, isTrue);
    await _submitAndFlush(tester, submit);
    expect(posts, 1); // Covered standalone<void> is valid; isCurrent must not block it.
    expect(created, 0);
    expect(repository.current(), isTrue);
    close();
    expect(route.available, isFalse);
    expect(state.mounted, isTrue);
    await submit(); // No host hasAccess predicate: the own-route guard must reject.
    expect(posts, 1);
    await workspace.flushReads(tester);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(find.byType(UsageReportJobDialog), findsNothing);
    expect(repository.current(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('current create retry retains the exact draft and idempotency key '
      'and reauth receives the same resume without invented If-Match', (tester) async {
    final posts = <http.Request>[];
    final session = await _session(tester, (request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/usage-report-jobs')) {
        posts.add(request);
        return posts.length == 1
            ? _reply({'errorCode': 'REAUTH_REQUIRED'}, 428)
            : _reply(_job(draft: UsageReportJobDraft.parse(jsonDecode(request.body))), 202);
      }
      return _normal(request);
    });
    await _mount(tester, session);
    final dynamic page = tester.state(find.byType(UsageReportsPage));
    final draft = _draft();
    final opening = _Invocation(page.createJob(draft, requestKey: _requestKey) as Future<void>);
    await workspace.flushReads(tester);
    final dynamic state = tester.state(find.byType(UsageReportJobDialog));
    await _submitAndFlush(tester, state.submit as Future<void> Function());
    final dialog = tester.widget<UsageReportJobDialog>(find.byType(UsageReportJobDialog));
    dialog.onReauth!(draft, _requestKey);
    expect(session.resumes, hasLength(1));
    expect(session.resumes.single.draft.body, draft.body);
    expect(session.resumes.single.requestKey, _requestKey);
    await _submitAndFlush(tester, state.submit as Future<void> Function());
    expect(posts, hasLength(2));
    expect(posts.map((request) => request.body).toSet(), {jsonEncode(draft.body)});
    expect(posts.map((request) => request.headers['idempotency-key']).toSet(), {_requestKey});
    expect(posts.every((request) => !request.headers.containsKey('if-match')), isTrue);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    expect(find.byType(UsageReportJobsView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('class roster resolution does not dispatch its second request '
      'after real generation-only invalidation', (tester) async {
    final students = Completer<http.Response>();
    final membership = Completer<http.Response>();
    int classReads = 0;
    final session = await _session(tester, (request) async {
      if (request.url.path.endsWith('/students')) return students.future;
      if (request.url.path.endsWith('/classes/$_class')) classReads++;
      if (request.url.path == '/api/v1/tenants/$_b/membership') return membership.future;
      return _normal(request);
    }, organization: true);
    addTearDown(() {
      if (!students.isCompleted) students.complete(_reply(_page([{'id': subject}])));
      if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
    });
    await _mount(tester, session);
    final held = _view(tester);
    final resolving = held.resolveScope!(UsageReportScope(
        kind: 'CLASS', id: _class, version: 7, label: '一班'));
    final denied = expectLater(resolving, throwsA(_lost));
    await workspace.flushReads(tester);
    final selecting = session.selectTenant(session.tenants.last);
    final rejected = expectLater(selecting, throwsA(_selectionFailed));
    expect(held.repository.current(), isFalse);
    students.complete(_reply(_page([{'id': subject}])));
    membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
    await workspace.flushReads(tester);
    await denied;
    await rejected;
    expect(classReads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late job list, result bytes and browser export guard reject old '
      'workspace without closing the shared transport', (tester) async {
    final list = Completer<http.Response>();
    final result = Completer<http.Response>();
    final membership = Completer<http.Response>();
    final payload = _emptyReport();
    final metadata = _job(state: 'READY', payload: payload);
    int partReads = 0, deliveredBytes = 0;
    final session = await _session(tester, (request) async {
      if (request.url.path.endsWith('/parts/0')) { partReads++; return result.future; }
      if (request.url.path.endsWith('/usage-report-jobs')) return list.future;
      if (request.url.path == '/api/v1/tenants/$_b/membership') return membership.future;
      return _normal(request);
    });
    addTearDown(() {
      if (!list.isCompleted) list.complete(_reply(_page([metadata])));
      if (!result.isCompleted) result.complete(_reply(payload));
      if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
    });
    await _mount(tester, session);
    _view(tester).onJobs!();
    await workspace.flushReads(tester);
    final held = _jobs(tester);
    final dynamic state = _jobsState(tester);
    final Future<void> Function({bool quiet}) refresh = state.load as Future<void> Function({bool quiet});
    final job = UsageReportJob.parse(metadata);
    final exporting = held.repository.download(job, job.parts.single, _target)
        .then<void>((_) { deliveredBytes++; });
    final deniedExport = expectLater(exporting, throwsA(_lost));
    await workspace.flushReads(tester);
    expect(partReads, 1);
    final selecting = session.selectTenant(session.tenants.last);
    final rejected = expectLater(selecting, throwsA(_selectionFailed));
    expect(held.repository.current(), isFalse);
    list.complete(_reply(_page([metadata])));
    result.complete(_reply(payload));
    membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
    await workspace.flushReads(tester);
    await deniedExport;
    await rejected;
    final count = session.requests.length;
    await refresh();
    held.onQuery!();
    held.reauth!();
    // This is the real host download callback. Its guard fails before creating
    // any Blob/anchor; no browser file is generated by this negative test.
    await expectLater(held.saveFile!(Uint8List(0), 'must-not-save.json'), throwsA(_lost));
    expect(session.requests, hasLength(count));
    expect(deliveredBytes, 0);
    expect(session.stepUps, 0);
    expect(find.text('已生成'), findsNothing);
    expect(find.text('已保存的设备报表'), findsNothing);
    final shared = await session.api.send('GET', '/tenants/$_a/devices/$device');
    expect(shared['id'], device);
    expect(tester.takeException(), isNull);
  });

  for (final action in ['result', 'cancel']) {
    testWidgets('covered job $action dialog completes its own Future; old '
        'callbacks cannot dispatch or pop the later route', (tester) async {
      final payload = _emptyReport();
      final metadata = _job(state: 'READY', payload: payload);
      final session = await _session(tester, (request) async {
        if (request.url.path.endsWith('/usage-report-jobs')) return _reply(_page([metadata]));
        return _normal(request);
      });
      await _mount(tester, session);
      _view(tester).onJobs!();
      await workspace.flushReads(tester);
      final dynamic state = _jobsState(tester);
      final job = UsageReportJob.parse(metadata);
      final operation = _Invocation((action == 'result'
          ? state.chooseResult(job) : state.cancel(job)) as Future<void>);
      await workspace.flushReads(tester);
      final title = action == 'result' ? '选择结果设备' : '取消这份报表任务？';
      final Finder dialog = find.ancestor(of: find.text(title), matching: find.byType(AlertDialog));
      VoidCallback? selected;
      ValueChanged<String>? search;
      if (action == 'result') {
        selected = tester.widget<ListTile>(find.descendant(of: dialog, matching: find.byType(ListTile))).onTap!;
        search = tester.widget<TextField>(find.descendant(of: dialog, matching: find.byType(TextField))).onChanged!;
      } else {
        selected = tester.widget<FilledButton>(find.descendant(of: dialog, matching: find.byType(FilledButton))).onPressed!;
      }
      final close = _textAction(tester, action == 'result' ? '关闭' : '保留任务');
      await _cover(tester, dialog);
      close();
      await workspace.flushReads(tester);
      expect(operation.completed, isTrue);
      expect(operation.failure, isNull);
      final count = session.requests.length;
      selected();
      search?.call('旧的搜索');
      close();
      await workspace.flushReads(tester);
      expect(session.requests, hasLength(count));
      expect(find.text('后续覆盖窗口'), findsOneWidget);
      expect(find.text(title), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('device picker completion and retained controls stay scoped after '
      'its covered owner is disposed', (tester) async {
    final session = await _session(tester, (request) async => _normal(request));
    final host = await _mount(tester, session);
    final dynamic state = _viewState(tester);
    final picking = _Invocation(state.chooseDevices() as Future<void>);
    await workspace.flushReads(tester);
    final picker = find.byType(UsageReportDevicePicker);
    final search = tester.widget<TextField>(find.descendant(of: picker, matching: find.byType(TextField))).onChanged!;
    final checked = tester.widget<CheckboxListTile>(find.descendant(of: picker, matching: find.byType(CheckboxListTile))).onChanged!;
    final confirm = tester.widget<FilledButton>(find.descendant(of: picker, matching: find.byType(FilledButton))).onPressed!;
    await _cover(tester, picker);
    host.visible.value = false;
    await workspace.flushReads(tester);
    expect(picking.completed, isTrue);
    expect(picking.failure, isNull);
    search('旧的设备');
    checked(false);
    confirm();
    await workspace.flushReads(tester);
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(find.byType(UsageReportDevicePicker), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('official date picker saves its selection through the owning '
      'route and permits a fresh next selection', (tester) async {
    final session = await _session(tester, (request) async => _normal(request));
    await _mount(tester, session);
    final dynamic state = _viewState(tester);
    final picking = _Invocation(state.chooseDates() as Future<void>);
    await workspace.flushReads(tester);
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    await tester.tap(find.text('应用日期'));
    await workspace.flushReads(tester);
    expect(picking.completed, isTrue);
    expect(picking.failure, isNull);
    expect(find.byType(DateRangePickerDialog), findsNothing);
    final next = _Invocation(state.chooseDates() as Future<void>);
    await workspace.flushReads(tester);
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop();
    await workspace.flushReads(tester);
    expect(next.completed, isTrue);
    expect(next.failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('covered official date picker completes when its report owner '
      'leaves without removing the covering window', (tester) async {
    final session = await _session(tester, (request) async => _normal(request));
    final host = await _mount(tester, session);
    final dynamic state = _viewState(tester);
    final picking = _Invocation(state.chooseDates() as Future<void>);
    await workspace.flushReads(tester);
    await _cover(tester, find.byType(DateRangePickerDialog));
    host.visible.value = false;
    await workspace.flushReads(tester);
    expect(picking.completed, isTrue);
    expect(picking.failure, isNull);
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(find.byType(DateRangePickerDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late insight and retained insight button cannot restore private '
      'advice after real workspace selection invalidates its device card', (tester) async {
    final insight = Completer<http.Response>();
    final membership = Completer<http.Response>();
    http.Request? insightRequest;
    final session = await _session(tester, (request) async {
      if (request.url.path.endsWith('/wellbeing-insight')) {
        insightRequest = request;
        return insight.future;
      }
      if (request.url.path == '/api/v1/tenants/$_b/membership') return membership.future;
      return _normal(request);
    });
    addTearDown(() {
      if (!insight.isCompleted && insightRequest != null) insight.complete(_normal(insightRequest!));
      if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
    });
    await _mount(tester, session);
    await _viewState(tester).run();
    await workspace.flushReads(tester);
    final button = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('生成复核建议'), matching: find.bySubtype<OutlinedButton>()));
    final held = button.onPressed!;
    held();
    await workspace.flushReads(tester);
    expect(insightRequest, isNotNull);
    final selecting = session.selectTenant(session.tenants.last);
    final rejected = expectLater(selecting, throwsA(_selectionFailed));
    insight.complete(_normal(insightRequest!));
    membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
    await workspace.flushReads(tester);
    await rejected;
    final count = session.requests.length;
    held();
    await workspace.flushReads(tester);
    expect(session.requests, hasLength(count));
    expect(find.text('近七日使用复核建议'), findsNothing);
    expect(find.textContaining('近七个完整自然日没有可用记录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('current ready job opens validated results, filters locally, '
      'returns exact JSON bytes and cancels through the existing contract', (tester) async {
    final payload = _emptyReport();
    var metadata = _job(state: 'READY', payload: payload);
    final cancellationRequests = <http.Request>[];
    int partReads = 0;
    final session = await _session(tester, (request) async {
      if (request.url.path.endsWith('/parts/0')) { partReads++; return _reply(payload); }
      if (request.url.path.endsWith('/$_jobId/cancel')) {
        cancellationRequests.add(request);
        metadata = _job(state: 'CANCELLED');
        return _reply(metadata);
      }
      if (request.url.path.endsWith('/usage-report-jobs')) return _reply(_page([metadata]));
      if (request.url.path.endsWith('/$_jobId')) return _reply(metadata);
      return _normal(request);
    });
    await _mount(tester, session);
    _view(tester).onJobs!();
    await workspace.flushReads(tester);
    final held = _jobs(tester);
    final dynamic state = _jobsState(tester);
    final job = UsageReportJob.parse(metadata);
    final choosing = _Invocation(state.chooseResult(job) as Future<void>);
    await workspace.flushReads(tester);
    final tile = tester.widget<ListTile>(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(ListTile)));
    tile.onTap!();
    await workspace.flushReads(tester);
    expect(choosing.completed, isTrue);
    expect(choosing.failure, isNull);
    expect(find.text('已保存的设备报表'), findsOneWidget);
    expect(partReads, 1);
    final beforeFilter = session.requests.length;
    final filter = tester.widget<DropdownButtonFormField<String>>(
        find.byWidgetPredicate((widget) => widget is DropdownButtonFormField<String> &&
            widget.decoration.labelText == '结果内应用类别')).onChanged!;
    filter('EDUCATION');
    await workspace.flushReads(tester);
    expect(session.requests, hasLength(beforeFilter));
    final bytes = await held.repository.download(job, job.parts.single, _target);
    expect(jsonDecode(utf8.decode(bytes)), payload);
    expect(partReads, 2);
    final cancelling = _Invocation(state.cancel(job) as Future<void>);
    await workspace.flushReads(tester);
    final confirm = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认取消'));
    confirm.onPressed!();
    await workspace.flushReads(tester);
    expect(cancelling.completed, isTrue);
    expect(cancelling.failure, isNull);
    expect(cancellationRequests, hasLength(1));
    expect(cancellationRequests.single.method, 'POST');
    expect(cancellationRequests.single.headers.containsKey('if-match'), isFalse);
    expect(find.text('已取消'), findsOneWidget);
    expect(find.text('已保存的设备报表'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixed host fails closed for replacement Session; console key '
      'gives the fresh Session its own page state', (tester) async {
    final first = await _session(tester, (request) async => _normal(request));
    final second = await _session(tester, (request) async => _normal(request));
    final host = await _mount(tester, first);
    final old = _view(tester);
    host.session.value = second;
    await workspace.flushReads(tester);
    expect(old.repository.current(), isFalse);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    // Mount the production ConsolePages host to verify its Session identity key.
    final console = await _mount(tester, first, console: true);
    final originalState = tester.state(find.byType(UsageReportsPage));
    final original = _view(tester);
    console.session.value = second;
    await workspace.flushReads(tester);
    expect(identical(tester.state(find.byType(UsageReportsPage)), originalState), isFalse);
    expect(original.repository.current(), isFalse);
    expect(_view(tester).repository.current(), isTrue);
    expect(find.text('生成报表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('current workspace keeps query refresh, class version, local '
      'category filter, jobs mode and rule/device navigation usable', (tester) async {
    final queries = <http.Request>[];
    final session = await _session(tester, (request) async {
      if (request.url.path.endsWith('/usage-reports')) queries.add(request);
      return _normal(request);
    }, organization: true);
    final host = await _mount(tester, session);
    final dynamic state = _viewState(tester);
    await state.chooseScope('CLASS:$_class');
    await workspace.flushReads(tester);
    await state.run();
    await workspace.flushReads(tester);
    expect(queries, hasLength(1));
    expect(queries.single.url.queryParameters['scopeVersion'], '7');
    expect(queries.single.url.queryParameters['scopeKind'], 'CLASS');
    expect(queries.single.headers.containsKey('if-match'), isFalse);
    expect(find.text('暂无使用数据'), findsOneWidget);
    final category = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('usage-report-category'))).onChanged!;
    category('EDUCATION');
    await workspace.flushReads(tester);
    expect(queries, hasLength(1));
    final held = _view(tester);
    held.onJobs!();
    await workspace.flushReads(tester);
    final jobs = _jobs(tester);
    final beforeRefresh = session.requests.length;
    await _jobsState(tester).load();
    await workspace.flushReads(tester);
    expect(session.requests.length, beforeRefresh + 1);
    jobs.onQuery!();
    await workspace.flushReads(tester);
    final fresh = _view(tester);
    fresh.onReviewRules!();
    await workspace.flushReads(tester);
    expect(find.text('规则目的页'), findsOneWidget);
    host.router.go('/reports');
    await workspace.flushReads(tester);
    _view(tester).onCheckDevice!();
    await workspace.flushReads(tester);
    expect(find.text('设备目的页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
