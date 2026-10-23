@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/application_classification.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/ui/application_classification_dialog.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:guardian/ui/resource_page.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'application_classification_test.dart'
    show classificationFixture, classificationIdentity;
import 'workspace_recovery_browser_test.dart' as workspace;

const _a = '81111111-1111-4111-8111-111111111111';
const _b = '82222222-2222-4222-8222-222222222222';
const _app = '83333333-3333-4333-8333-333333333333';
const _name = '分类范围测试应用';

Json _application() => {
      'id': _app,
      'displayName': _name,
      'platform': 'ANDROID',
      'profile': 'PRIMARY',
      'packageName': 'org.example.reader',
      'signingDigests': ['a' * 64],
      'evidenceStatus': 'UNVERIFIED',
    };

http.Response _reply(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

http.Response _classification({String category = 'UNCLASSIFIED', int version = 0}) =>
    _reply(classificationFixture(category: category, version: version));

Matcher get _scopeLost => isA<ApiFailure>()
    .having((failure) => failure.code, 'code', 'WORKSPACE_CHANGED');
Matcher get _selectionFailed => isA<ApiFailure>()
    .having((failure) => failure.code, 'code', 'SELECTION_FAILED');

// Keep production initialize, loadTenants, selectTenant, authentication ownership
// and generation. Only HTTP/identity facts and the starting list are synthetic.
class _SelectionSession extends workspace.FixtureSession {
  _SelectionSession(super.handle);
  void seed() {
    tenants = [
      {'id': _a, 'name': '空间A', 'kind': 'FAMILY'},
      {'id': _b, 'name': '空间B', 'kind': 'FAMILY'},
    ];
    tenant = tenants.first;
    role = 'OWNER';
    notifyListeners();
  }
}

Future<_SelectionSession> _session(WidgetTester tester,
    Future<http.Response> Function(http.Request) handle) async {
  final session = _SelectionSession(handle);
  await session.authenticate();
  session.seed();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await workspace.flushReads(tester);
    await session.release();
  });
  return session;
}

http.Response _normal(http.Request request) {
  if (request.url.path.endsWith('/membership')) return _reply({'role': 'OWNER'});
  if (request.url.path.endsWith('/classification')) return _classification();
  if (request.url.path.endsWith('/applications')) {
    return _reply({'items': [_application()], 'nextCursor': null});
  }
  throw StateError('Unexpected fixture request: ${request.method} ${request.url.path}');
}

class _Invocation {
  bool completed = false;
  Object? failure;
  _Invocation(Future<dynamic> operation) {
    unawaited(operation.then<void>((_) { completed = true; },
        onError: (Object error, StackTrace _) {
      failure = error;
      completed = true;
    }));
  }
}

Future<ConsoleActions> _mount(WidgetTester tester, Session session,
    {bool applications = false}) async {
  late ConsoleActions actions;
  await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
      value: session,
      child: MaterialApp(theme: consoleTheme(), home: Builder(builder: (context) {
        actions = ConsoleActions(context, session);
        return Scaffold(body: applications
            ? const SingleChildScrollView(child: ConsolePages(section: 'applications'))
            : const Text('分类宿主页'));
      }))));
  await workspace.flushReads(tester);
  return actions;
}

ApplicationClassificationDialog _dialog(WidgetTester tester) => tester
    .widget<ApplicationClassificationDialog>(find.byType(ApplicationClassificationDialog));

Future<void> Function() _load(WidgetTester tester) {
  final dynamic state = tester.state(find.byType(ApplicationClassificationDialog));
  return state.load as Future<void> Function();
}

Future<void> Function() _save(WidgetTester tester) {
  final dynamic state = tester.state(find.byType(ApplicationClassificationDialog));
  return state.save as Future<void> Function();
}

VoidCallback _classificationEntry(WidgetTester tester) => tester
    .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '查看与设置分类'))
    .onPressed!;

ValueChanged<String?> _choose(WidgetTester tester) => tester
    .widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('classification-category')))
    .onChanged!;

Future<void> _cover(WidgetTester tester) async {
  final context = tester.element(find.byType(ApplicationClassificationDialog));
  unawaited(showDialog<void>(context: context,
      builder: (_) => const AlertDialog(title: Text('后续覆盖窗口'))));
  await workspace.flushReads(tester);
}

void main() {
  testWidgets('already pending real workspace reload invalidates classification '
      'GET when selectTenant advances only generation', (tester) async {
    final tenants = Completer<http.Response>();
    final membership = Completer<http.Response>();
    final read = Completer<http.Response>();
    final session = await _session(tester, (request) async {
      if (request.url.path == '/api/v1/tenants') return tenants.future;
      if (request.url.path == '/api/v1/tenants/$_a/membership') return membership.future;
      if (request.url.path.endsWith('/classification')) return read.future;
      return _normal(request);
    });
    addTearDown(() {
      if (!tenants.isCompleted) tenants.complete(_reply({'items': session.tenants, 'nextCursor': null}));
      if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
      if (!read.isCompleted) read.complete(_classification());
    });
    final actions = await _mount(tester, session);
    // This starts before the modal. A late existing loadTenants is a production
    // route to selectTenant; no picker interaction through a modal is claimed.
    final reload = session.loadTenants(preferredTenantId: _a);
    final rejected = expectLater(reload, throwsA(_selectionFailed));
    await workspace.flushReads(tester);
    final opening = _Invocation(actions.applicationClassification(_application()));
    await workspace.flushReads(tester);
    final old = _dialog(tester).repository;
    final load = _load(tester);
    final save = _save(tester);
    final generation = session.scopeGeneration;
    final root = session.root;
    tenants.complete(_reply({'items': session.tenants, 'nextCursor': null}));
    await workspace.flushReads(tester);
    expect(session.scopeGeneration, generation + 1);
    expect(session.root, root);
    expect(session.role, 'OWNER');
    expect(old.current(), isFalse);
    expect(find.byType(ApplicationClassificationDialog), findsNothing);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    read.complete(_classification(category: 'TOOLS', version: 1));
    membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
    await workspace.flushReads(tester);
    await rejected;
    expect(session.root, root);
    expect(session.role, 'OWNER');
    final dispatched = session.requests.length;
    await load();
    await save();
    await expectLater(old.load(), throwsA(_scopeLost));
    final before = ApplicationClassification.parse(classificationFixture(), classificationIdentity);
    await expectLater(old.save(before, 'EDUCATION', 'held-key'), throwsA(_scopeLost));
    expect(session.requests, hasLength(dispatched));
    expect(find.text('实用工具'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('old application row and details entry cannot create a new '
      'classification journey after a real selection starts or fails', (tester) async {
    final membership = Completer<http.Response>();
    final session = await _session(tester, (request) async {
      if (request.url.path == '/api/v1/tenants/$_b/membership') return membership.future;
      return _normal(request);
    });
    addTearDown(() {
      if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
    });
    await _mount(tester, session, applications: true);
    final row = tester.widget<ResourcePage>(find.byType(ResourcePage)).onOpen!;
    final opening = _Invocation(row(_application()));
    await workspace.flushReads(tester);
    final entry = _classificationEntry(tester);
    final selecting = session.selectTenant(session.tenants.last);
    final rejected = expectLater(selecting, throwsA(_selectionFailed));
    expect(session.tenant!['id'], _a);
    expect(session.role, 'OWNER');
    await row(_application());
    entry();
    await workspace.flushReads(tester);
    expect(find.byType(ApplicationClassificationDialog), findsNothing);
    membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
    await workspace.flushReads(tester);
    await rejected;
    await row(_application());
    entry();
    await workspace.flushReads(tester);
    expect(session.requests.where((r) => r.path.endsWith('/classification')), isEmpty);
    expect(find.byType(ApplicationClassificationDialog), findsNothing);
    // Close the redacted details route so its entry scope finishes normally.
    await tester.tap(find.text('关闭').last);
    await workspace.flushReads(tester);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    final dispatched = session.requests.length;
    await row(_application());
    entry();
    await workspace.flushReads(tester);
    expect(session.requests, hasLength(dispatched),
        reason: 'A disposed originating context must not be looked up or rebound.');
    expect(tester.takeException(), isNull);
  });

  testWidgets('late PUT and retained callbacks cannot mutate or pop a covering '
      'route after real generation loss', (tester) async {
    final membership = Completer<http.Response>();
    final write = Completer<http.Response>();
    final writes = <http.Request>[];
    final session = await _session(tester, (request) async {
      if (request.url.path == '/api/v1/tenants/$_b/membership') return membership.future;
      if (request.method == 'PUT') { writes.add(request); return write.future; }
      return _normal(request);
    });
    addTearDown(() {
      if (!write.isCompleted) write.complete(_classification(category: 'EDUCATION', version: 1));
      if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
    });
    final actions = await _mount(tester, session);
    final opening = _Invocation(actions.applicationClassification(_application()));
    await workspace.flushReads(tester);
    final choose = _choose(tester);
    final load = _load(tester);
    final save = _save(tester);
    final close = tester.widget<TextButton>(find.widgetWithText(TextButton, '关闭')).onPressed!;
    choose('EDUCATION');
    await tester.pump();
    final saving = save();
    await workspace.flushReads(tester);
    expect(writes, hasLength(1));
    await _cover(tester);
    final selecting = session.selectTenant(session.tenants.last);
    final rejected = expectLater(selecting, throwsA(_selectionFailed));
    expect(session.tenant!['id'], _a);
    expect(session.role, 'OWNER');
    await workspace.flushReads(tester);
    write.complete(_classification(category: 'EDUCATION', version: 1));
    membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
    await workspace.flushReads(tester);
    await rejected;
    await saving;
    final dispatched = session.requests.length;
    choose('TOOLS');
    await load();
    await save();
    close();
    await workspace.flushReads(tester);
    expect(session.requests, hasLength(dispatched));
    expect(writes, hasLength(1));
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(find.byType(ApplicationClassificationDialog), findsNothing);
    expect(opening.completed, isTrue,
        reason: 'Covered removal must complete the owned route, not strand the entry.');
    expect(opening.failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful covered save finishes its own classification route '
      'and leaves the later dialog open', (tester) async {
    final write = Completer<http.Response>();
    final session = await _session(tester, (request) async => request.method == 'PUT'
        ? write.future : _normal(request));
    addTearDown(() {
      if (!write.isCompleted) write.complete(_classification(category: 'EDUCATION', version: 1));
    });
    final actions = await _mount(tester, session);
    final opening = _Invocation(actions.applicationClassification(_application()));
    await workspace.flushReads(tester);
    _choose(tester)('EDUCATION');
    await tester.pump();
    final saving = _save(tester)();
    await workspace.flushReads(tester);
    await _cover(tester);
    write.complete(_classification(category: 'EDUCATION', version: 1));
    await workspace.flushReads(tester);
    await saving;
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(find.byType(ApplicationClassificationDialog), findsNothing);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the covered application details owner revokes its child '
      'classification without a Session change', (tester) async {
    final read = Completer<http.Response>();
    final session = await _session(tester, (request) async =>
        request.url.path.endsWith('/classification') ? read.future : _normal(request));
    addTearDown(() { if (!read.isCompleted) read.complete(_classification()); });
    await _mount(tester, session, applications: true);
    final row = tester.widget<ResourcePage>(find.byType(ResourcePage)).onOpen!;
    final opening = _Invocation(row(_application()));
    await workspace.flushReads(tester);
    final entry = _classificationEntry(tester);
    final route = ModalRoute.of(tester.element(find.text(_name).last));
    expect(route, isA<OwnedDialogRoute<void>>());
    entry();
    await workspace.flushReads(tester);
    final old = _dialog(tester).repository;
    final load = _load(tester);
    final generation = session.scopeGeneration;
    await _cover(tester);
    (route! as OwnedDialogRoute<void>).finish();
    expect(old.current(), isFalse);
    read.complete(_classification(category: 'TOOLS', version: 1));
    await workspace.flushReads(tester);
    await load();
    entry();
    await workspace.flushReads(tester);
    expect(session.scopeGeneration, generation);
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(find.byType(ApplicationClassificationDialog), findsNothing);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing classification without saving keeps its application '
      'details parent open', (tester) async {
    final session = await _session(tester, (request) async => _normal(request));
    await _mount(tester, session, applications: true);
    final row = tester.widget<ResourcePage>(find.byType(ResourcePage)).onOpen!;
    final opening = _Invocation(row(_application()));
    await workspace.flushReads(tester);
    final parent = ModalRoute.of(tester.element(find.descendant(
        of: find.byType(AlertDialog), matching: find.text(_name))));
    expect(parent, isA<OwnedDialogRoute<void>>());
    _classificationEntry(tester)();
    await workspace.flushReads(tester);
    expect(find.byType(ApplicationClassificationDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '关闭').last);
    await workspace.flushReads(tester);
    expect(find.byType(ApplicationClassificationDialog), findsNothing);
    expect(find.text('查看与设置分类'), findsOneWidget);
    expect((parent! as OwnedDialogRoute<void>).available, isTrue);
    expect(opening.completed, isFalse,
        reason: 'Cancelling the child must not finish the application details.');
    expect(session.requests.where((r) => r.method == 'PUT'), isEmpty);
    await tester.tap(find.widgetWithText(TextButton, '关闭').last);
    await workspace.flushReads(tester);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful classification save completes only its original '
      'application details while a later dialog covers both', (tester) async {
    final write = Completer<http.Response>();
    final writes = <http.Request>[];
    final session = await _session(tester, (request) async {
      if (request.method == 'PUT') { writes.add(request); return write.future; }
      return _normal(request);
    });
    addTearDown(() {
      if (!write.isCompleted) write.complete(_classification(category: 'EDUCATION', version: 1));
    });
    await _mount(tester, session, applications: true);
    final row = tester.widget<ResourcePage>(find.byType(ResourcePage)).onOpen!;
    final opening = _Invocation(row(_application()));
    await workspace.flushReads(tester);
    final parent = ModalRoute.of(tester.element(find.descendant(
        of: find.byType(AlertDialog), matching: find.text(_name))));
    expect(parent, isA<OwnedDialogRoute<void>>());
    _classificationEntry(tester)();
    await workspace.flushReads(tester);
    _choose(tester)('EDUCATION');
    await tester.pump();
    final saving = _save(tester)();
    await workspace.flushReads(tester);
    expect(writes, hasLength(1));
    await _cover(tester);
    write.complete(_classification(category: 'EDUCATION', version: 1));
    await workspace.flushReads(tester);
    await saving;
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(find.byType(ApplicationClassificationDialog), findsNothing);
    expect((parent! as OwnedDialogRoute<void>).available, isFalse);
    expect(opening.completed, isTrue,
        reason: 'A successful current save completes the captured parent only.');
    expect(opening.failure, isNull);
    expect(writes.single.headers['if-match'], '"0"');
    expect(jsonDecode(writes.single.body), {'category': 'EDUCATION'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal fresh classification retry preserves category, version '
      'and idempotency key', (tester) async {
    final writes = <http.Request>[];
    final session = await _session(tester, (request) async {
      if (request.method == 'PUT') {
        writes.add(request);
        return writes.length == 1
            ? _reply({'errorCode': 'TEMPORARY_FAILURE'}, 503)
            : _classification(category: 'EDUCATION', version: 1);
      }
      return _normal(request);
    });
    final actions = await _mount(tester, session);
    final opening = _Invocation(actions.applicationClassification(_application()));
    await workspace.flushReads(tester);
    _choose(tester)('EDUCATION');
    await tester.pump();
    await tester.tap(find.text('保存分类'));
    await workspace.flushReads(tester);
    expect(find.textContaining('上次修改结果尚未确认'), findsOneWidget);
    expect(tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('classification-category'))).onChanged, isNull);
    await tester.tap(find.text('重试相同修改'));
    await workspace.flushReads(tester);
    expect(writes, hasLength(2));
    expect(writes.first.body, writes.last.body);
    expect(jsonDecode(writes.last.body), {'category': 'EDUCATION'});
    expect(writes.first.headers['if-match'], '"0"');
    expect(writes.last.headers['if-match'], '"0"');
    expect(writes.first.headers['idempotency-key'], isNotEmpty);
    expect(writes.last.headers['idempotency-key'], writes.first.headers['idempotency-key']);
    expect(find.byType(ApplicationClassificationDialog), findsNothing);
    expect(opening.completed, isTrue);
    expect(opening.failure, isNull);
    expect(tester.takeException(), isNull);
  });
}
