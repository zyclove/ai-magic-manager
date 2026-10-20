@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/managed_android_page.dart';
import 'package:guardian/ui/managed_agent_binding_dialog.dart';
import 'package:guardian/ui/managed_execution_dialog.dart';
import 'package:http/http.dart' as http;

import 'managed_agent_binding_fixtures.dart';
import 'managed_enrollment_page_test.dart' as enrollment;
import 'managed_execution_fixtures.dart' as execution;

const _taskId = '88888888-8888-4888-8888-888888888888';
const _publicationId = '99999999-9999-4999-8999-999999999999';
const _historicalRegistration = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _entry = Key('managed-binding-executions');
const _recheck = Key('execution-recheck');
const _confirm = Key('execution-confirm-recheck');

/// Reuse the real page's existing Session/HTTP seam. Only actor notification is
/// added here; production page, binding callback, execution host, scope and
/// operation coordinator are never replaced or called around the page route.
class _EntrySession extends enrollment.EnrollmentSession {
  _EntrySession(
      {required super.actorRole,
      required String actorId,
      required Future<http.Response?> Function(http.Request) extra})
      : super(bound: true, extra: extra) {
    profile = {...profile!, 'subject': actorId};
    rows = [enrollment.row(state: 'VERIFIED', version: 2)];
  }

  void changeActor(String value) {
    profile = {...profile!, 'subject': value};
    notifyListeners();
  }
}

class _Journey {
  final String role;
  final bool historical;
  final binding = AgentBindingFixture();
  final executions = execution.ExecutionFixture();
  late final String actor;
  late final _EntrySession session;

  _Journey(
      {this.role = 'OWNER',
      this.historical = false,
      String bindingState = 'VERIFIED'}) {
    // The ordinary browser journal remains real. A distinct account namespace
    // avoids retaining a slot from another test without clearing browser data.
    actor = 'institution-entry-${role.toLowerCase()}-'
        '${DateTime.now().microsecondsSinceEpoch}';
    binding.binding = binding.record(state: bindingState, version: 2);
    session = _EntrySession(actorRole: role, actorId: actor, extra: handle);
  }

  String get executionRoot =>
      '/api/v1/tenants/${enrollment.tenantId}/managed-android/executions';

  Json get task => {
        ...executions.record(
            state: 'NEEDS_REVIEW', reason: 'DEVICE_NON_COMPLIANT'),
        'id': _taskId,
        'publicationId': _publicationId,
        'deviceId': bindingDevice,
        'registrationId':
            historical ? _historicalRegistration : bindingRegistration,
      };

  List<http.Request> get executionRequests => session.requests
      .where((request) => request.url.path.startsWith(executionRoot))
      .toList();
  List<http.Request> get eligibilityReads => executionRequests
      .where((request) =>
          request.method == 'GET' &&
          request.url.path.endsWith('/$_taskId/review-eligibility'))
      .toList();
  List<http.Request> get mutations =>
      session.requests.where((request) => request.method == 'POST').toList();

  Future<http.Response?> handle(http.Request request) async {
    if (request.url.path.contains('/agent-bindings')) {
      return binding.handle(request);
    }
    final path = request.url.path;
    if (!path.startsWith(executionRoot)) return null;
    if (request.method != 'GET') {
      // No test accepts a confirmation or authorizes a mutation. Keep an
      // accidental write observable as a business assertion, not a fake throw.
      return enrollment.reply({'errorCode': 'WORKSPACE_CHANGED'}, status: 409);
    }
    if (path == executionRoot) {
      return enrollment.reply({'items': [task], 'nextCursor': null});
    }
    if (path == '$executionRoot/$_taskId/review-eligibility') {
      final selected = task;
      return enrollment.reply({
        for (final key in [
          'id',
          'publicationId',
          'deviceId',
          'registrationId',
          'revision'
        ])
          key: selected[key],
        'allowed': true,
        'reason': 'ELIGIBLE',
      });
    }
    if (path == '$executionRoot/$_taskId/events') {
      return enrollment.reply({
        'items': [
          executions.event(
              state: 'NEEDS_REVIEW', reason: 'DEVICE_NON_COMPLIANT')
        ],
        'nextCursor': null,
      });
    }
    if (path == '$executionRoot/$_taskId') {
      return enrollment.reply(task);
    }
    return enrollment.reply({'errorCode': 'RESOURCE_NOT_FOUND'}, status: 404);
  }

  Future<void> mount(WidgetTester tester) async {
    await enrollment.mount(tester, session);
    expect(find.byType(ManagedAndroidPage), findsOneWidget);
  }

  Future<void> openAssociation(WidgetTester tester) async {
    final label = role == 'AUDITOR' ? '查看儿童端关联' : '关联儿童端';
    final target = find.text(label);
    expect(target, findsOneWidget);
    await tester.ensureVisible(target);
    await tester.tap(target);
    await _frames(tester);
    expect(find.byType(ManagedAgentBindingDialog), findsOneWidget);
    expect(binding.requests, hasLength(1));
    expect(binding.requests.single.method, 'GET');
  }

  Future<void> openTask(WidgetTester tester,
      {bool associationAlreadyOpen = false}) async {
    if (!associationAlreadyOpen) {
      await openAssociation(tester);
    }
    await _press(tester, _entry);
    expect(find.byType(ManagedExecutionDialog), findsOneWidget);
    final listRead = executionRequests
        .where((request) => request.url.path == executionRoot)
        .toList();
    expect(listRead, hasLength(1));
    expect(listRead.single.method, 'GET');
    expect(listRead.single.url.queryParameters['deviceId'], bindingDevice);
    final loaded = tester
        .widget<ManagedExecutionDialog>(find.byType(ManagedExecutionDialog))
        .controller
        .items
        .single;
    expect(loaded.id, _taskId);
    expect(loaded.deviceId, bindingDevice);
    expect(loaded.registrationId,
        historical ? _historicalRegistration : bindingRegistration);
    expect(loaded.state, 'NEEDS_REVIEW');
    await _press(tester, const Key('execution-open-$_taskId'));
    expect(find.byKey(const Key('execution-back')), findsOneWidget);
    expect(find.text('需要复核'), findsWidgets);
    expect(executionRequests.where((request) =>
        request.method == 'GET' &&
        request.url.path == '$executionRoot/$_taskId'), isNotEmpty);
    expect(mutations, isEmpty);
    expect(tester.takeException(), isNull);
  }

  Future<void> dispose(WidgetTester tester) async {
    // Remove every actual page/dialog before widget-test timer invariants run.
    // The parent has its own periodic clock and can be busy behind its child.
    await tester.pumpWidget(const SizedBox.shrink());
    await _frames(tester);
    session.transport.close();
    expect(tester.takeException(), isNull);
  }
}

/// The existing association-page journey uses bounded native turns because its
/// progress indicator stays active while a real child dialog owns the route.
Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 6; index++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _press(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await _frames(tester);
}

void _expectReadOnly(_Journey journey) {
  expect(find.byKey(_recheck), findsNothing);
  expect(find.byKey(const Key('execution-cancel')), findsNothing);
  expect(find.byKey(_confirm), findsNothing);
  expect(journey.eligibilityReads, isEmpty);
  expect(journey.mutations, isEmpty);
}

void main() {
  for (final role in ['OWNER', 'ORG_ADMIN']) {
    testWidgets('institution association $role reaches recheck confirmation',
        (tester) async {
      final journey = _Journey(role: role);
      try {
        await journey.mount(tester);
        await journey.openTask(tester);
        expect(journey.eligibilityReads, hasLength(1),
            reason:
                'ACTUAL_INSTITUTION_ENTRY_RECHECK_ELIGIBILITY_REQUIRED: '
                'the verified current institution association must reach the '
                'existing writable coordinator for its manager.');
        expect(find.byKey(_recheck), findsOneWidget,
            reason: 'ACTUAL_INSTITUTION_ENTRY_RECHECK_ACTION_REQUIRED');
        await _press(tester, _recheck);
        expect(find.text('重新核实设备状态？'), findsOneWidget);
        expect(find.byKey(_confirm).hitTestable(), findsOneWidget);
        expect(journey.mutations, isEmpty,
            reason: 'Entering confirmation alone must never submit.');
        await _press(tester, const Key('execution-dismiss-recheck'));
        expect(find.byKey(_confirm), findsNothing);
        expect(journey.mutations, isEmpty);
      } finally {
        await journey.dispose(tester);
      }
    });
  }

  testWidgets(
      'institution association AUDITOR keeps current execution read only',
      (tester) async {
    final journey = _Journey(role: 'AUDITOR');
    try {
      await journey.mount(tester);
      await journey.openTask(tester);
      _expectReadOnly(journey);
    } finally {
      await journey.dispose(tester);
    }
  });

  testWidgets(
      'institution association pending binding keeps execution read only',
      (tester) async {
    final journey = _Journey(bindingState: 'PENDING');
    try {
      await journey.mount(tester);
      await journey.openTask(tester);
      _expectReadOnly(journey);
    } finally {
      await journey.dispose(tester);
    }
  });

  testWidgets(
      'institution association historical registration keeps execution read only',
      (tester) async {
    final journey = _Journey(historical: true);
    try {
      await journey.mount(tester);
      await journey.openTask(tester);
      expect(find.textContaining('历史注册记录'), findsWidgets);
      _expectReadOnly(journey);
    } finally {
      await journey.dispose(tester);
    }
  });

  testWidgets(
      'institution association disposed old execution entry stays inert after actor changes back',
      (tester) async {
    final journey = _Journey();
    try {
      await journey.mount(tester);
      await journey.openAssociation(tester);
      final oldEntry = tester.widget<OutlinedButton>(find.byKey(_entry)).onPressed;
      expect(oldEntry, isNotNull);
      await journey.openTask(tester, associationAlreadyOpen: true);
      final oldExecution = tester.element(find.byType(ManagedExecutionDialog));
      final before = journey.session.requests.length;
      final generation = journey.session.scopeGeneration;
      journey.session.changeActor('replacement-institution-actor');
      await _frames(tester);
      expect(find.byType(ManagedAgentBindingDialog), findsNothing);
      expect(find.byType(ManagedExecutionDialog), findsOneWidget);
      expect(tester.element(find.byType(ManagedExecutionDialog)),
          same(oldExecution));
      expect(find.byKey(const Key('execution-scope-unavailable')), findsOneWidget);
      expect(find.byKey(const Key('execution-back')), findsNothing);
      expect(find.text('需要复核'), findsNothing);
      expect(find.byKey(_recheck), findsNothing);
      journey.session.changeActor(journey.actor);
      await _frames(tester);
      expect(journey.session.scopeGeneration, generation);
      oldEntry!();
      await _frames(tester);
      expect(find.byType(ManagedExecutionDialog), findsOneWidget);
      expect(tester.element(find.byType(ManagedExecutionDialog)),
          same(oldExecution));
      expect(find.byKey(const Key('execution-scope-unavailable')), findsOneWidget);
      expect(find.byKey(const Key('execution-back')), findsNothing);
      expect(find.text('需要复核'), findsNothing);
      expect(find.byKey(_recheck), findsNothing);
      expect(journey.session.requests, hasLength(before));
      expect(journey.mutations, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await journey.dispose(tester);
    }
  });
}
