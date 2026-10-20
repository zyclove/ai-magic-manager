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

const _execution = Key('managed-binding-executions');
const _evidence = Key('managed-binding-application-evidence');

/// Only the external child body is synthetic. Binding parsing, HTTP, parent
/// widget, OwnedDialogRoute, busy state and lifetime notifications are real.
class _Child {
  final String kind;
  final ManagedAgentBinding binding;
  final bool? readOnly;
  final bool Function() parentCurrent;
  final Listenable parentChanges;
  final observations = <bool>[];
  late final OwnedDialogRoute<void> route;
  Future<void>? completion;
  bool finished = false;

  _Child(this.kind, this.binding, this.readOnly,
      this.parentCurrent, this.parentChanges) {
    parentChanges.addListener(changed);
    changed();
  }

  void changed() => observations.add(parentCurrent());
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
    if (closed) return;
    closed = true;
    delegate.close();
  }
}

class _Harness {
  final AgentBindingFixture fixture;
  final children = <_Child>[];
  late final client = _BorrowedClient(fixture.client);
  late final api = Api(() async => client,
      baseUrl: 'https://execution-binding.invalid/api/v1');
  late final originalRepository = freshRepository();
  late ManagedAgentBindingRepository repository = originalRepository;
  late BuildContext rootContext;
  late BuildContext bindingContext;
  late StateSetter rebuild;
  late OwnedDialogRoute<void> parent;
  Future<void>? parentCompletion;
  bool parentFinished = false;
  bool writable;

  _Harness(this.fixture, {this.writable = true});

  ManagedAgentBindingRepository freshRepository() =>
      ManagedAgentBindingRepository(
          api: api,
          tenantId: bindingTenant,
          enrollmentId: bindingEnrollment,
          subjectId: bindingSubject,
          current: () => fixture.current);

  int get reads =>
      fixture.requests.where((request) => request.method == 'GET').length;
  Iterable<http.Request> get posts =>
      fixture.requests.where((request) => request.method == 'POST');

  Future<void> openExecution(ManagedAgentBinding binding,
      {required bool readOnly,
      required bool Function() parentCurrent,
      required Listenable parentChanges}) =>
      openChild('execution', binding, readOnly, parentCurrent, parentChanges);

  Future<void> openEvidence(ManagedAgentBinding binding,
      {required bool Function() parentCurrent,
      required Listenable parentChanges,
      required VoidCallback onParentRefresh}) =>
      openChild('evidence', binding, null, parentCurrent, parentChanges);

  Future<void> openChild(String kind, ManagedAgentBinding binding,
      bool? readOnly, bool Function() current, Listenable changes) {
    final child = _Child(kind, binding, readOnly, current, changes);
    children.add(child);
    child.route = OwnedDialogRoute<void>(
        context: bindingContext,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
            title: Text('$kind child'),
            content: const Text('Synthetic child body; real parent lifetime'),
            actions: [
              TextButton(
                  onPressed: () => child.route.finish(),
                  child: const Text('返回关联'))
            ]));
    child.completion =
        presentOwnedDialog<void>(bindingContext, child.route).then((_) {
      child.finished = true;
    });
    return child.completion!;
  }

  Widget bindingWidget() => StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return ManagedAgentBindingDialog(
            repository: repository,
            writable: writable,
            reauthenticate: () {},
            now: () => fixture.instant,
            onExecutions: openExecution,
            onApplicationEvidence: openEvidence);
      });
}

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 8; index++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<_Harness> _mount(WidgetTester tester,
    {AgentBindingFixture? fixture, bool writable = true}) async {
  final actual = fixture ?? AgentBindingFixture();
  if (fixture == null) {
    actual.binding = actual.record(state: 'VERIFIED', version: 3);
  }
  final h = _Harness(actual, writable: writable);
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    h.client.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Builder(builder: (context) {
        h.rootContext = context;
        return const Scaffold(body: Text('binding lifetime host'));
      })));
  h.parent = OwnedDialogRoute<void>(
      context: h.rootContext,
      barrierDismissible: false,
      builder: (context) {
        h.bindingContext = context;
        return h.bindingWidget();
      });
  h.parentCompletion =
      presentOwnedDialog<void>(h.rootContext, h.parent).then((_) {
    h.parentFinished = true;
  });
  await _frames(tester);
  expect(h.reads, 1);
  expect(h.posts, isEmpty);
  expect(tester.takeException(), isNull);
  return h;
}

Finder _button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

VoidCallback _callback(WidgetTester tester, Finder target) {
  expect(target, findsOneWidget);
  final callback = tester.widget<ButtonStyleButton>(target).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await _frames(tester);
}

Future<void> _finishChild(WidgetTester tester, _Child child) async {
  child.route.finish();
  await _frames(tester);
  expect(child.finished, isTrue);
  expect(child.route.isActive, isFalse);
  if (child.finished) await child.completion;
  expect(child.parentCurrent(), isFalse);
}

Future<void> _dispose(WidgetTester tester, _Harness h) async {
  for (final child in h.children.reversed) {
    await _finishChild(tester, child);
  }
  h.parent.finish();
  await _frames(tester);
  expect(h.parentFinished, isTrue);
  expect(h.parent.isActive, isFalse);
  if (h.parentFinished) await h.parentCompletion;
  await tester.pumpWidget(const SizedBox.shrink());
  await _frames(tester);
  for (final child in h.children) {
    child.stopObserving();
  }
  expect(h.client.closed, isFalse,
      reason: 'The product borrows the client; the test owns its close.');
  h.client.close();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('execution child captures current binding eligibility once',
      (tester) async {
    for (final scenario in [
      'eligible', 'readonly', 'unready', 'PENDING', 'REVOKED', 'EXPIRED',
      'missing-proof'
    ]) {
      final fixture = AgentBindingFixture();
      fixture.binding = fixture.record(
          state: const {'PENDING', 'REVOKED', 'EXPIRED'}.contains(scenario)
              ? scenario : 'VERIFIED',
          version: 3);
      if (scenario == 'unready') fixture.ready = false;
      if (scenario == 'missing-proof') {
        fixture.binding = {...fixture.binding!, 'verifiedAt': null};
      }
      final h = await _mount(tester,
          fixture: fixture, writable: scenario != 'readonly');
      try {
        if (scenario == 'missing-proof') {
          expect(find.byKey(_execution), findsNothing);
          expect(find.byKey(_evidence), findsNothing);
          expect(find.textContaining('返回资料与当前注册记录不一致'), findsOneWidget);
          expect(h.children, isEmpty);
        } else {
          await _tap(tester, find.byKey(_execution));
          final child = h.children.single;
          expect(child.kind, 'execution');
          expect(child.binding.id, bindingId);
          expect(child.binding.deviceId, bindingDevice);
          expect(child.binding.registrationId, bindingRegistration);
          expect(child.binding.version, 3);
          expect(child.readOnly, scenario != 'eligible', reason: scenario);
          expect(child.parentCurrent(), isTrue, reason: scenario);
          expect(h.parent.isActive, isTrue);
          expect(h.parent.isCurrent, isFalse,
              reason: 'Own child coverage does not revoke the parent.');
          if (scenario == 'readonly') {
            h.rebuild(() => h.writable = true);
            await _frames(tester);
            expect(child.parentCurrent(), isFalse);
            expect(child.readOnly, isTrue,
                reason: 'An existing read-only child never upgrades.');
          }
        }
        expect(h.reads, 1, reason: scenario);
        expect(h.posts, isEmpty, reason: scenario);
      } finally {
        await _dispose(tester, h);
      }
    }
  });

  testWidgets('accepted binding refresh never revives an old execution entry',
      (tester) async {
    for (final dimension in [
      'version', 'state', 'verifiedAt', 'ready', 'id', 'device', 'registration',
      'ABA'
    ]) {
      final h = await _mount(tester);
      try {
        final original = Map<String, dynamic>.of(h.fixture.binding!);
        final oldOpen = _callback(tester, find.byKey(_execution));
        final changed = Map<String, dynamic>.of(original);
        switch (dimension) {
          case 'version':
          case 'ABA':
            changed['version'] = 4;
            break;
          case 'state':
            changed['state'] = 'REVOKED';
            break;
          case 'verifiedAt':
            changed['verifiedAt'] = (original['verifiedAt'] as int) - 1;
            break;
          case 'ready':
            h.fixture.ready = false;
            break;
          case 'id':
            changed['id'] = '99999999-9999-4999-8999-999999999999';
            break;
          case 'device':
            changed['deviceId'] = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
            break;
          case 'registration':
            changed['registrationId'] = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
            break;
        }
        h.fixture.binding = changed;
        await _tap(tester, _button('刷新记录'));
        if (dimension == 'ABA') {
          h.fixture.binding = original;
          await _tap(tester, _button('刷新记录'));
        }
        final before = h.reads;
        oldOpen();
        await _frames(tester);
        expect(h.children, isEmpty, reason: dimension);
        expect(h.reads, before, reason: dimension);
        await _tap(tester, find.byKey(_execution));
        final child = h.children.single;
        final expected = dimension == 'ABA' ? original : changed;
        expect(child.binding.id, expected['id'], reason: dimension);
        expect(child.binding.deviceId, expected['deviceId'], reason: dimension);
        expect(child.binding.registrationId, expected['registrationId'],
            reason: dimension);
        expect(child.binding.version, expected['version'], reason: dimension);
        expect(child.binding.state, expected['state'], reason: dimension);
        expect(child.binding.verifiedAt, expected['verifiedAt'],
            reason: dimension);
        expect(child.readOnly, dimension == 'state' || dimension == 'ready',
            reason: dimension);
        expect(child.parentCurrent(), isTrue, reason: dimension);
        expect(h.reads, before, reason: dimension);
        expect(h.posts, isEmpty, reason: dimension);
      } finally {
        await _dispose(tester, h);
      }
    }
  });

  testWidgets('observed host replacement permanently revokes execution lifetime',
      (tester) async {
    for (final dimension in ['writable', 'repository']) {
      final h = await _mount(tester);
      try {
        final oldOpen = _callback(tester, find.byKey(_execution));
        await _tap(tester, find.byKey(_execution));
        final child = h.children.single;
        expect(child.parentCurrent(), isTrue);
        final replacement = h.freshRepository();
        h.rebuild(() {
          if (dimension == 'writable') {
            h.writable = false;
          } else {
            h.repository = replacement;
          }
        });
        await _frames(tester);
        expect(child.observations, contains(false), reason: dimension);
        expect(child.parentCurrent(), isFalse, reason: dimension);
        h.rebuild(() {
          h.writable = true;
          h.repository = h.originalRepository;
        });
        await _frames(tester);
        expect(child.parentCurrent(), isFalse, reason: dimension);
        expect(h.reads, 1, reason: 'No implicit GET after $dimension ABA.');
        await _finishChild(tester, child);
        oldOpen();
        await _frames(tester);
        expect(h.children, hasLength(1), reason: dimension);
        if (dimension == 'repository') {
          expect(find.byKey(_execution), findsNothing);
          await _tap(tester, _button('刷新记录'));
          expect(h.reads, 2);
        }
        await _tap(tester, find.byKey(_execution));
        expect(h.children, hasLength(2));
        expect(h.children.last.parentCurrent(), isTrue);
        expect(child.parentCurrent(), isFalse);
        expect(h.client.closed, isFalse);
        expect(h.posts, isEmpty);
      } finally {
        await _dispose(tester, h);
      }
    }
  });

  testWidgets('execution and application evidence share one exclusive child slot',
      (tester) async {
    for (final first in ['execution', 'evidence']) {
      final h = await _mount(tester);
      try {
        await _tap(tester, _button('撤销此关联'));
        final revoke = _callback(tester, _button('确认撤销'));
        final refresh = _callback(tester, _button('刷新记录'));
        final execution = _callback(tester, find.byKey(_execution));
        final evidence = _callback(tester, find.byKey(_evidence));
        (first == 'execution' ? execution : evidence)();
        await _frames(tester);
        final child = h.children.single;
        expect(child.kind, first);
        expect(child.parentCurrent(), isTrue);
        execution();
        evidence();
        refresh();
        revoke();
        await _frames(tester);
        expect(h.children, hasLength(1));
        expect(h.reads, 1);
        expect(h.posts, isEmpty);
        expect(child.parentCurrent(), isTrue);
        await _finishChild(tester, child);
        await _tap(tester,
            find.byKey(first == 'execution' ? _evidence : _execution));
        expect(h.children, hasLength(2));
        expect(h.children.last.kind,
            first == 'execution' ? 'evidence' : 'execution');
        expect(h.children.last.parentCurrent(), isTrue);
        expect(child.parentCurrent(), isFalse);
        expect(h.reads, 1);
        expect(h.posts, isEmpty);
      } finally {
        await _dispose(tester, h);
      }
    }
  });

  testWidgets('captured parent completion cannot remove an execution child',
      (tester) async {
    final h = await _mount(tester);
    try {
      final oldComplete = _callback(tester, _button('完成'));
      await _tap(tester, find.byKey(_execution));
      final child = h.children.single;
      oldComplete();
      await _frames(tester);
      expect(h.children, hasLength(1));
      expect(child.finished, isFalse);
      expect(child.route.isCurrent, isTrue);
      expect(h.parentFinished, isFalse);
      expect(h.parent.isActive, isTrue);
      expect(child.parentCurrent(), isTrue);
      expect(h.reads, 1);
      expect(h.posts, isEmpty);
    } finally {
      await _dispose(tester, h);
    }
  });

  testWidgets(
      'parent removal revokes execution lifetime before borrowed resources release',
      (tester) async {
    final h = await _mount(tester);
    try {
      final oldOpen = _callback(tester, find.byKey(_execution));
      await _tap(tester, find.byKey(_execution));
      final child = h.children.single;
      expect(child.observations.last, isTrue);
      h.parent.finish(); // Exact covered parent; never pop the current child.
      await _frames(tester);
      expect(h.parentFinished, isTrue);
      expect(h.parent.isActive, isFalse);
      expect(child.route.isCurrent, isTrue);
      expect(child.observations, contains(false));
      expect(child.parentCurrent(), isFalse);
      expect(h.client.closed, isFalse);
      oldOpen();
      await _frames(tester);
      expect(h.children, hasLength(1));
      expect(h.reads, 1);
      expect(h.posts, isEmpty);
      await _finishChild(tester, child);
      expect(child.parentCurrent(), isFalse);
      expect(h.client.closed, isFalse);
      expect(h.reads, 1);
    } finally {
      await _dispose(tester, h);
    }
  });
}
