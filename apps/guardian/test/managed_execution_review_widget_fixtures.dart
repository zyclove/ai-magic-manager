import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/execution_operation_journal.dart';
import 'package:guardian/core/managed_execution.dart';
import 'package:guardian/core/managed_execution_review.dart';
import 'package:guardian/core/managed_execution_review_repository.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/managed_execution_controller.dart';
import 'package:guardian/ui/managed_execution_dialog.dart';
import 'package:guardian/ui/managed_execution_review_controller.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:http/http.dart' as http;

import 'managed_execution_fixtures.dart';

/// Test boundary only. Real repository, bounded HTTP parsing and real
/// controllers remain in use. This is not an IndexedDB durability test.
class ReviewMemoryJournal implements ExecutionOperationJournal {
  ExecutionOperationPending? record;
  int reads = 0, reserves = 0, receipts = 0, progress = 0, zeroSend = 0;
  bool blocked = false;
  Completer<void>? reserveEntered, reserveRelease;
  @override
  Future<ExecutionOperationPending?> read(
      ExecutionOperationOwner owner, String id) async {
    reads++;
    if (blocked) {
      throw const ApiFailure(503, 'EXECUTION_OPERATION_STORAGE_UNAVAILABLE');
    }
    return record;
  }

  @override
  Future<ExecutionOperationReservation> reserve(
      ExecutionOperationIntent intent) async {
    reserves++;
    if (record != null) {
      return ExecutionOperationReservation(record: record!, maySubmit: false);
    }
    record = ExecutionOperationPending(intent: intent);
    if (reserveEntered != null && !reserveEntered!.isCompleted) {
      reserveEntered!.complete();
    }
    await reserveRelease?.future;
    return ExecutionOperationReservation(record: record!, maySubmit: true);
  }

  @override
  Future<ExecutionOperationReservation> replaceRejected(
      ExecutionOperationPending expected,
      ExecutionOperationIntent intent) async {
    if (record != expected ||
        expected.phase != ExecutionOperationPhase.rejectedNotApplied) {
      throw const ApiFailure(409, 'EXECUTION_OPERATION_PENDING_CHANGED');
    }
    record = null;
    return reserve(intent);
  }

  @override
  Future<ExecutionOperationPending> markRejected(
      ExecutionOperationDenied proof) async {
    if (record != proof.record) {
      throw const ApiFailure(409, 'EXECUTION_OPERATION_PENDING_CHANGED');
    }
    return record = ExecutionOperationPending(
        intent: proof.record.intent,
        phase: ExecutionOperationPhase.rejectedNotApplied,
        refusalCode: proof.failure.code);
  }

  bool remove(ExecutionOperationPending expected) {
    if (record != expected) return false;
    record = null;
    return true;
  }

  @override
  Future<bool> removeAfterVerifiedReceipt(
      ExecutionOperationPending expected, ManagedExecution response) async {
    receipts++;
    return remove(expected);
  }

  @override
  Future<bool> removeAfterObservedProgress(
      ExecutionOperationPending expected, ManagedExecution response) async {
    progress++;
    return remove(expected);
  }

  @override
  Future<bool> removeAfterControllerProvedNeverDispatched(
      ExecutionOperationPending expected) async {
    zeroSend++;
    return remove(expected);
  }
}

class ReviewWidgetFixture {
  ReviewWidgetFixture({this.writable = true, this.deviceName = '学习平板'}) {
    task = data.record(state: 'NEEDS_REVIEW', reason: 'DEVICE_NON_COMPLIANT');
    data.handler = serve;
  }
  final bool writable;
  final String deviceName;
  final data = ExecutionFixture();
  final journal = ReviewMemoryJournal();
  final changes = ValueNotifier<int>(0);
  late Json task;
  String eligibilityReason = 'ELIGIBLE';
  int? denialStatus;
  String? denialCode;
  bool interruptPost = false;
  Completer<http.Response>? postRelease;
  ManagedExecutionReviewController? operation;
  OwnedDialogRoute<void>? route;
  int closeCalls = 0, reauthCalls = 0, sequence = 0;
  late final list = ManagedExecutionController(
      repository: data.repository(writable: writable),
      registrationId: executionRegistration);
  ExecutionOperationOwner get owner => ExecutionOperationOwner(
      actorId: 'widget-review-owner',
      tenantId: executionTenant,
      apiBaseUrl: data.api.baseUrl,
      issuer: 'https://identity.invalid/realms/test');
  List<http.Request> get posts =>
      data.requests.where((r) => r.method == 'POST').toList();
  Json eligibility(Json selected) => {
        for (final key in [
          'id',
          'publicationId',
          'deviceId',
          'registrationId',
          'revision'
        ])
          key: selected[key],
        'allowed': eligibilityReason == 'ELIGIBLE',
        'reason': eligibilityReason,
      };
  ExecutionOperationPending pending() => ExecutionOperationPending(
      intent: ExecutionOperationIntent(
          owner: owner,
          task: ManagedExecution.parse(task, deviceId: executionDevice),
          kind: ExecutionOperationKind.recheckDevice,
          operationId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          createdAt: 100));
  Future<http.Response> serve(http.Request request) async {
    if (request.method == 'POST') {
      if (postRelease != null) return postRelease!.future;
      if (interruptPost) {
        throw http.ClientException('synthetic interrupted response');
      }
      if (denialStatus != null) {
        return data.response({'errorCode': denialCode}, status: denialStatus!);
      }
      final recheck = request.url.path.endsWith('/recheck-device');
      task = data.record(
          state: recheck ? 'WAITING_DEVICE' : 'NEEDS_REVIEW',
          reason: recheck
              ? 'MANUAL_DEVICE_RECHECK_REQUESTED'
              : 'CANCELLATION_REQUIRES_REVIEW',
          revision: task['revision'] + 1,
          updatedAt: 200,
          cancelled: !recheck);
      return data.response(task);
    }
    if (request.url.path.endsWith('/review-eligibility')) {
      return data.response(eligibility(task));
    }
    if (request.url.path.endsWith('/events')) {
      return data.response({
        'items': [
          data.event(
              state: task['state'],
              reason: task['reason'],
              revision: task['revision'])
        ],
        'nextCursor': null
      });
    }
    if (request.url.path.endsWith('/$executionId')) return data.response(task);
    return data.response({
      'items': [task],
      'nextCursor': null
    });
  }

  ManagedExecutionReviewController makeReview(ManagedExecution selected,
      bool Function() current, int Function() latestEventRevision) {
    operation = ManagedExecutionReviewController(
        requests: ManagedExecutionReviewRepository(
            api: data.api,
            owner: owner,
            deviceId: executionDevice,
            registrationId: executionRegistration,
            writable: writable,
            current: () => data.current),
        journal: journal,
        selected: selected,
        viewCurrent: current,
        operationId: () =>
            'aaaaaaaa-aaaa-4aaa-8aaa-${(++sequence).toRadixString(16).padLeft(12, '0')}',
        now: () => 100,
        latestEventRevision: latestEventRevision,
        onProgress: (_) {});
    return operation!;
  }

  Widget dialog() => ManagedExecutionDialog(
      controller: list,
      reviewFactory: writable ? makeReview : null,
      deviceName: deviceName,
      accessChanges: changes,
      onClose: () {
        closeCalls++;
        route?.finish();
      },
      onReauth: () {
        if (operation?.requestStepUp() == true) {
          reauthCalls++;
          route?.finish();
        }
      });
  Widget app({double scale = 1, bool ownedRoute = false}) => MaterialApp(
      theme: consoleTheme(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Scaffold(
          body: ownedRoute
              ? Builder(
                  builder: (context) => FilledButton(
                      key: const Key('open-owned-review'),
                      onPressed: () {
                        route = OwnedDialogRoute<void>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => dialog());
                        unawaited(presentOwnedDialog(context, route!));
                      },
                      child: const Text('打开执行记录')))
              : dialog()));
  void release() {
    if (postRelease != null && !postRelease!.isCompleted) {
      postRelease!.complete(data.response(task));
    }
    if (journal.reserveRelease != null && !journal.reserveRelease!.isCompleted) {
      journal.reserveRelease!.complete();
    }
    list.dispose();
    changes.dispose();
    data.client.close();
  }
}

Future<void> flushReview(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> pressReview(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await flushReview(tester);
}

Future<void> mountReview(WidgetTester tester, ReviewWidgetFixture fixture,
    {double scale = 1, bool ownedRoute = false}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.release();
  });
  await tester.pumpWidget(fixture.app(scale: scale, ownedRoute: ownedRoute));
  if (ownedRoute) await pressReview(tester, 'open-owned-review');
  await flushReview(tester);
}

Future<void> openReview(WidgetTester tester) =>
    pressReview(tester, 'execution-open-$executionId');
