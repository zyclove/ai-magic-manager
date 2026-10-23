@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/observation_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/observation_editor.dart';
import 'package:guardian/ui/observation_view.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:http/http.dart' as http;

import 'observation_model_test.dart' show tenant, device, registration;
import 'workspace_recovery_browser_test.dart' as workspace;

const _other = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _tenantId = tenant;
Json _device({bool registered = true}) => {
  'id': device, 'registrationId': registered ? registration : null,
  'displayName': '观察授权测试平板', 'state': 'ACTIVE',
};
http.Response _reply(Object value, [int status = 200]) => http.Response(
    jsonEncode(value), status,
    headers: {'content-type': 'application/json; charset=utf-8'});
Json _settings({int version = 0, bool inventory = false}) => {
  'deviceId': device, 'registrationId': registration, 'version': version,
  'inventoryEnabled': inventory, 'usageEnabled': false,
  'updatedAt': version == 0 ? null : 1791504000000,
};

class _Service {
  final requests = <http.Request>[];
  Future<http.Response?> Function(http.Request)? intercept;
  int version = 0;
  bool inventory = false;
  List<http.Request> get writes => requests.where((r) => r.method == 'PUT').toList();
  List<http.Request> get reads => requests.where((r) =>
      r.method == 'GET' && r.url.path.endsWith('/observation-settings')).toList();
  http.Response save(http.Request request) {
    version++;
    inventory = (jsonDecode(request.body) as Json)['inventoryEnabled'] as bool;
    return _reply(_settings(version: version, inventory: inventory));
  }
  Future<http.Response> call(http.Request request) async {
    requests.add(request);
    final special = await intercept?.call(request);
    if (special != null) return special;
    if (request.url.path.endsWith('/membership')) return _reply({'role': 'OWNER'});
    if (request.url.path.endsWith('/observation-settings')) {
      return request.method == 'PUT' ? save(request) :
          _reply(_settings(version: version, inventory: inventory));
    }
    throw StateError('Unexpected observation fixture request: ${request.url.path}');
  }
}

// Production initialize/loadTenants/selectTenant and authentication ownership
// remain intact. Only HTTP/identity/starting membership and the login leaf are
// synthetic. No actual identity provider or browser navigation is used.
class _Session extends workspace.FixtureSession {
  int stepUps = 0;
  _Session(super.handle);
  void seed() {
    tenants = [
      {'id': _tenantId, 'name': '空间A', 'kind': 'FAMILY'},
      {'id': _other, 'name': '空间B', 'kind': 'FAMILY'},
    ];
    this.tenant = tenants.first;
    role = 'OWNER';
    notifyListeners();
  }
  @override
  void login({bool stepUp = false}) { if (stepUp) stepUps++; }
}

class _Invocation {
  bool completed = false;
  Object? failure;
  Object? result;
  _Invocation(Future<dynamic> operation) {
    unawaited(operation.then<void>((value) { result = value; completed = true; },
        onError: (Object error, StackTrace _) { failure = error; completed = true; }));
  }
}

Future<_Session> _session(WidgetTester tester, _Service service) async {
  final session = _Session(service.call);
  await session.authenticate();
  session.seed();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await workspace.flushReads(tester);
    await session.release();
  });
  return session;
}
Future<BuildContext> _mount(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(MaterialApp(theme: consoleTheme(), home: Builder(
      builder: (context) { captured = context; return const Scaffold(body: Text('观察宿主')); })));
  return captured;
}
Future<_Invocation> _open(WidgetTester tester, Session session,
    {BuildContext? owner, bool registered = true}) async {
  final context = owner ?? await _mount(tester);
  final operation = _Invocation(openDeviceObservation(context, session,
      _device(registered: registered)));
  await workspace.flushReads(tester);
  return operation;
}
ObservationView _view(WidgetTester tester) => tester.widget<ObservationView>(
    find.byType(ObservationView));
Future<void> _edit(WidgetTester tester) async {
  _view(tester).edit!();
  await workspace.flushReads(tester);
  expect(find.byType(ObservationEditor), findsOneWidget);
}
Future<void> _fill(WidgetTester tester) async {
  tester.widget<SwitchListTile>(find.byKey(const Key('observe-inventory'))).onChanged!(true);
  await tester.pump();
  await tester.enterText(find.byKey(const Key('observe-reason')), '  监护人确认清单用途  ');
  tester.widget<CheckboxListTile>(find.byKey(const Key('observe-confirm'))).onChanged!(true);
  await tester.pump();
}
Future<void> Function() _submit(WidgetTester tester) {
  final dynamic state = tester.state(find.byType(ObservationEditor));
  return state.submit as Future<void> Function();
}
VoidCallback _textButton(WidgetTester tester, String text) => tester.widget<TextButton>(
    find.ancestor(of: find.text(text), matching: find.bySubtype<TextButton>()).last).onPressed!;
OwnedDialogRoute<Json> _editorRoute(WidgetTester tester) => ModalRoute.of(
    tester.element(find.byType(ObservationEditor)))! as OwnedDialogRoute<Json>;
Future<void> _cover(WidgetTester tester, Finder owner) async {
  unawaited(showDialog<void>(context: tester.element(owner),
      builder: (_) => const AlertDialog(title: Text('后续覆盖窗口'))));
  await workspace.flushReads(tester);
}
Matcher get _selectionFailed => isA<ApiFailure>().having((e) => e.code, 'code', 'SELECTION_FAILED');

void main() {
  testWidgets('current observation edit keeps confirmation requirements and '
      'refreshes its original detail once after save', (tester) async {
    final service = _Service(); final session = await _session(tester, service);
    await _open(tester, session); await _edit(tester);
    await _submit(tester)(); await tester.pump();
    expect(service.writes, isEmpty);
    expect(find.text('请输入本次授权变更原因'), findsOneWidget);
    tester.widget<SwitchListTile>(find.byKey(const Key('observe-inventory'))).onChanged!(true);
    await tester.enterText(find.byKey(const Key('observe-reason')), '  监护人确认清单用途  ');
    await tester.pump();
    expect(tester.widget<TextFormField>(find.byKey(const Key('observe-reason')))
        .validator!('  监护人确认清单用途  '), isNull);
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('observe-confirm'))).value, isFalse);
    await _submit(tester)(); await tester.pump();
    expect(service.writes, isEmpty); // Valid reason alone must not authorize this change.
    expect(find.text('请输入本次授权变更原因'), findsNothing);
    expect(find.text('请先确认采集范围和撤回影响'), findsOneWidget);
    tester.widget<CheckboxListTile>(find.byKey(const Key('observe-confirm'))).onChanged!(true);
    await tester.pump(); await _submit(tester)();
    await workspace.flushReads(tester);
    expect(service.writes, hasLength(1)); expect(service.reads, hasLength(2));
    expect(jsonDecode(service.writes.single.body), {
      'inventoryEnabled': true, 'usageEnabled': false, 'reason': '监护人确认清单用途'});
    expect(service.writes.single.headers['if-match'], '"0"');
    expect(service.writes.single.headers['idempotency-key'], isNotEmpty);
    expect(find.byType(ObservationEditor), findsNothing);
    expect(_view(tester).snapshot!.settings.version, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('covered save completes only the original editor Future and '
      'refreshes once while preserving the later dialog', (tester) async {
    final service = _Service(); final write = Completer<http.Response>();
    service.intercept = (r) async => r.method == 'PUT' ? write.future : null;
    final session = await _session(tester, service);
    addTearDown(() { if (!write.isCompleted) write.complete(_reply(_settings(version: 1, inventory: true))); });
    await _open(tester, session); await _edit(tester); await _fill(tester);
    final route = _editorRoute(tester); final popped = _Invocation(route.popped);
    final saving = _Invocation(_submit(tester)());
    await workspace.flushReads(tester);
    await _cover(tester, find.byType(ObservationEditor));
    write.complete(service.save(service.writes.single));
    await workspace.flushReads(tester);
    expect(popped.completed, isTrue); expect(popped.result, {'refresh': true});
    expect(saving.completed, isTrue); expect(saving.failure, isNull);
    expect(service.reads, hasLength(2));
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(find.byType(ObservationEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('covered cancel completes its own editor and retained close '
      'cannot remove a later dialog', (tester) async {
    final service = _Service(); final session = await _session(tester, service);
    await _open(tester, session); await _edit(tester);
    final route = _editorRoute(tester); final popped = _Invocation(route.popped);
    final close = _textButton(tester, '取消');
    await _cover(tester, find.byType(ObservationEditor));
    close(); await workspace.flushReads(tester); close();
    expect(popped.completed, isTrue); expect(popped.result, isNull);
    expect(service.writes, isEmpty); expect(service.reads, hasLength(1));
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual close synchronously rejects held submit before the '
      'editor reverse transition has disposed its State', (tester) async {
    final service = _Service(); final session = await _session(tester, service);
    await _open(tester, session); await _edit(tester); await _fill(tester);
    final submit = _submit(tester); final close = _textButton(tester, '取消');
    final route = _editorRoute(tester);
    close();
    expect(route.available, isFalse);
    await submit(); // Deliberately no pump between close and retained callback.
    expect(service.writes, isEmpty);
    await workspace.flushReads(tester);
    expect(service.reads, hasLength(1)); expect(tester.takeException(), isNull);
  });

  testWidgets('current reauthentication works and a closed editor rejects its '
      'held reauth before disposal', (tester) async {
    final service = _Service();
    service.intercept = (r) async => r.method == 'PUT' ? _reply({'errorCode': 'REAUTH_REQUIRED'}, 401) : null;
    final session = await _session(tester, service);
    await _open(tester, session); await _edit(tester); await _fill(tester);
    await _submit(tester)(); await workspace.flushReads(tester);
    final reauth = _textButton(tester, '重新安全验证');
    reauth(); expect(session.stepUps, 1);
    final close = _textButton(tester, '关闭并刷新'); close(); reauth();
    expect(session.stepUps, 1);
    await workspace.flushReads(tester);
    expect(service.writes, hasLength(1)); expect(service.reads, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopened editor has a fresh route and old submit or close '
      'cannot dispatch or finish the new journey', (tester) async {
    final service = _Service(); final session = await _session(tester, service);
    await _open(tester, session); await _edit(tester); await _fill(tester);
    final submit = _submit(tester); final close = _textButton(tester, '取消');
    final old = _editorRoute(tester); close(); await workspace.flushReads(tester);
    await _edit(tester); final fresh = _editorRoute(tester);
    await submit(); close(); await workspace.flushReads(tester);
    expect(identical(old, fresh), isFalse); expect(fresh.available, isTrue);
    expect(service.writes, isEmpty); expect(find.byType(ObservationEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending real reload invalidates late consent PUT and retained '
      'callbacks when selectTenant changes only generation', (tester) async {
    final service = _Service(); final tenants = Completer<http.Response>();
    final membership = Completer<http.Response>(); final write = Completer<http.Response>();
    service.intercept = (r) async {
      if (r.url.path == '/api/v1/tenants') return tenants.future;
      if (r.url.path.endsWith('/membership')) return membership.future;
      if (r.method == 'PUT') return write.future;
      return null;
    };
    final session = await _session(tester, service);
    addTearDown(() {
      if (!tenants.isCompleted) tenants.complete(_reply({'items': session.tenants, 'nextCursor': null}));
      if (!membership.isCompleted) membership.complete(_reply({'role': 'OWNER'}));
      if (!write.isCompleted) write.complete(_reply(_settings(version: 1, inventory: true)));
    });
    final reload = session.loadTenants(preferredTenantId: tenant);
    final rejected = expectLater(reload, throwsA(_selectionFailed));
    final opening = await _open(tester, session); await _edit(tester); await _fill(tester);
    final submit = _submit(tester);
    final editor = tester.widget<ObservationEditor>(find.byType(ObservationEditor));
    final saving = _Invocation(submit()); await workspace.flushReads(tester);
    await _cover(tester, find.byType(ObservationEditor));
    final generation = session.scopeGeneration, root = session.root;
    tenants.complete(_reply({'items': session.tenants, 'nextCursor': null}));
    await workspace.flushReads(tester);
    expect(session.scopeGeneration, generation + 1); expect(session.root, root);
    expect(session.role, 'OWNER');
    final count = service.requests.length;
    await submit(); editor.reauth!();
    write.complete(_reply(_settings(version: 1, inventory: true)));
    membership.complete(_reply({'errorCode': 'SELECTION_FAILED'}, 503));
    await workspace.flushReads(tester); await rejected;
    expect(saving.completed, isTrue); expect(saving.failure, isNull);
    expect(service.requests.length, count); expect(service.reads, hasLength(1));
    expect(session.stepUps, 0); expect(find.text('后续覆盖窗口'), findsOneWidget);
    // The redacted main route remains an owned journey and can finish while covered.
    final close = _textButton(tester, '关闭'); close();
    await workspace.flushReads(tester);
    expect(opening.completed, isTrue); expect(opening.failure, isNull);
    expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('originating parent revocation rejects late GET and held detail '
      'refresh edit and reauth before parent disposal', (tester) async {
    final service = _Service(); final read = Completer<http.Response>();
    service.intercept = (r) async => r.url.path.endsWith('/observation-settings') ? read.future : null;
    final session = await _session(tester, service);
    addTearDown(() { if (!read.isCompleted) read.complete(_reply(_settings())); });
    final context = await _mount(tester); late BuildContext owner;
    final parent = OwnedDialogRoute<void>(context: context, builder: (value) {
      owner = value; return const AlertDialog(title: Text('设备详情父窗口')); });
    final parentOpening = _Invocation(presentOwnedDialog(context, parent));
    await workspace.flushReads(tester);
    final opening = await _open(tester, session, owner: owner);
    final held = _view(tester); parent.finish();
    held.refresh!(); held.edit!(); held.reauth!();
    expect(service.reads, hasLength(1)); expect(session.stepUps, 0);
    read.complete(_reply(_settings())); await workspace.flushReads(tester);
    expect(service.reads, hasLength(1)); // Count after async dispatch/result delivery, too.
    expect(service.writes, isEmpty);
    expect(find.byType(ObservationEditor), findsNothing);
    expect(find.text('工作空间已变化'), findsOneWidget);
    _textButton(tester, '关闭')(); await workspace.flushReads(tester);
    expect(opening.completed, isTrue); expect(parentOpening.completed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finishing the original observation owner revokes its covered '
      'editor immediately and late PUT cannot refresh or remove the cover', (tester) async {
    final service = _Service(); final write = Completer<http.Response>();
    service.intercept = (r) async => r.method == 'PUT' ? write.future : null;
    final session = await _session(tester, service);
    addTearDown(() { if (!write.isCompleted) write.complete(_reply(_settings(version: 1, inventory: true))); });
    final opening = await _open(tester, session);
    final owner = ModalRoute.of(tester.element(find.byType(ObservationView)))! as OwnedDialogRoute<void>;
    await _edit(tester); await _fill(tester);
    final submit = _submit(tester); final editor = tester.widget<ObservationEditor>(find.byType(ObservationEditor));
    final saving = _Invocation(submit()); await workspace.flushReads(tester);
    await _cover(tester, find.byType(ObservationEditor));
    owner.finish(); await submit(); editor.reauth!(); // No pump before old callbacks.
    expect(service.writes, hasLength(1)); expect(session.stepUps, 0);
    write.complete(_reply(_settings(version: 1, inventory: true)));
    await workspace.flushReads(tester);
    expect(opening.completed, isTrue); expect(saving.completed, isTrue);
    expect(service.reads, hasLength(1)); expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(find.byType(ObservationEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('host refresh revokes idle editor submit and reauth before '
      'deferred route finish while keeping current detail usable', (tester) async {
    final service = _Service(); final session = await _session(tester, service);
    final opening = await _open(tester, session);
    final held = _view(tester);
    final owner = ModalRoute.of(tester.element(find.byType(ObservationView)))!
        as OwnedDialogRoute<void>;
    await _edit(tester); await _fill(tester);
    final dynamic state = tester.state(find.byType(ObservationEditor));
    final submit = state.submit as Future<void> Function();
    final reauth = state.reauthenticate as VoidCallback;
    final widget = tester.widget<ObservationEditor>(find.byType(ObservationEditor));
    final route = _editorRoute(tester), popped = _Invocation(_editorRoute(tester).popped);
    final generation = session.scopeGeneration, root = session.root;
    expect(state.busy, isFalse);
    expect(service.reads, hasLength(1));
    held.refresh!(); // Synchronously editor=null and host generation++, finish is post-frame.
    expect(state.mounted, isTrue);
    expect(state.busy, isFalse); // This must exercise ownership, not a busy submission guard.
    expect(route.available, isTrue);
    expect(owner.available, isTrue);
    expect(session.scopeGeneration, generation); expect(session.root, root);
    expect(widget.hasAccess!(), isFalse);
    await submit(); reauth(); widget.reauth!(); // No pump before these old callbacks.
    expect(route.available, isTrue);
    expect(service.writes, isEmpty); expect(session.stepUps, 0);
    await workspace.flushReads(tester);
    expect(popped.completed, isTrue); expect(popped.result, isNull);
    expect(service.reads, hasLength(2)); // Exactly the user's refresh, no stale post-save refresh.
    expect(service.writes, isEmpty); expect(session.stepUps, 0);
    expect(find.byType(ObservationEditor), findsNothing);
    expect(_view(tester).snapshot!.settings.version, 0);
    expect(_view(tester).canEdit, isTrue);
    expect(owner.available, isTrue); expect(opening.completed, isFalse);
    await _edit(tester); // A new current journey remains usable after abandoning only the old one.
    expect(_editorRoute(tester).available, isTrue);
    expect(identical(route, _editorRoute(tester)), isFalse);
    _textButton(tester, '取消')(); await workspace.flushReads(tester);
    expect(service.reads, hasLength(2)); expect(service.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown result retries exact payload original version and '
      'request identity then refreshes current settings once', (tester) async {
    final service = _Service(); var attempts = 0;
    service.intercept = (r) async => r.method == 'PUT' && ++attempts == 1
        ? _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503) : null;
    final session = await _session(tester, service);
    await _open(tester, session); await _edit(tester); await _fill(tester);
    await _submit(tester)(); await workspace.flushReads(tester);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('observe-inventory'))).onChanged, isNull);
    expect(tester.widget<TextFormField>(find.byKey(const Key('observe-reason'))).enabled, isFalse);
    await _submit(tester)(); await workspace.flushReads(tester);
    expect(service.writes, hasLength(2));
    expect(service.writes.first.body, service.writes.last.body);
    expect(service.writes.map((r) => r.headers['if-match']).toSet(), {'"0"'});
    expect(service.writes.first.headers['idempotency-key'], isNotEmpty);
    expect(service.writes.last.headers['idempotency-key'], service.writes.first.headers['idempotency-key']);
    expect(service.reads, hasLength(2)); expect(find.byType(ObservationEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('version conflict remains terminal until close and explicit '
      'fresh settings read without resending the stale edit', (tester) async {
    final service = _Service();
    service.intercept = (r) async => r.method == 'PUT' ? _reply({'errorCode': 'RESOURCE_VERSION_CONFLICT'}, 412) : null;
    final session = await _session(tester, service);
    await _open(tester, session); await _edit(tester); await _fill(tester);
    final submit = _submit(tester); await submit(); await workspace.flushReads(tester);
    await submit(); expect(service.writes, hasLength(1));
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认授权变更')).onPressed, isNull);
    _textButton(tester, '关闭并刷新')(); await workspace.flushReads(tester);
    expect(service.reads, hasLength(2)); expect(find.byType(ObservationEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unregistered owned notice completes its original Future while '
      'covered and old close leaves the later route untouched', (tester) async {
    final service = _Service(); final session = await _session(tester, service);
    final opening = await _open(tester, session, registered: false);
    final close = _textButton(tester, '关闭');
    await _cover(tester, find.byType(AlertDialog)); close();
    await workspace.flushReads(tester); close();
    expect(opening.completed, isTrue); expect(opening.failure, isNull);
    expect(service.requests, isEmpty); expect(find.text('后续覆盖窗口'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
