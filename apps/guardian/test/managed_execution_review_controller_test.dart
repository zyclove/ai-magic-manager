import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/execution_operation_journal.dart';
import 'package:guardian/core/managed_execution.dart';
import 'package:guardian/core/managed_execution_review.dart';
import 'package:guardian/core/managed_execution_review_repository.dart';
import 'package:guardian/ui/managed_execution_review_controller.dart';
import 'package:http/http.dart' as http;

import 'managed_execution_fixtures.dart';

// Source-only controller tests. HTTP uses the real repository/boundedJson; only
// the durable journal is a controllable test seam, never a production fallback.
void main() {
  late _Fixture fixture;
  setUp(() { fixture = _Fixture(); });
  tearDown(() { fixture.controller.dispose(); fixture.httpFixture.client.close(); });

  test('initialize restores UNKNOWN with no GET or POST', () async {
    fixture.journal.record = fixture.pending();
    await fixture.controller.initialize();
    expect(fixture.httpFixture.requests, isEmpty);
    expect(fixture.controller.resultUnknown, isTrue);
    expect(fixture.controller.canRecheck, isFalse);
    expect(fixture.journal.reads, 1);
  });

  test('explicit same-version query preserves UNKNOWN without attribution', () async {
    final original = fixture.pending();
    fixture.journal.record = original;
    await fixture.controller.initialize();
    await fixture.controller.query();
    expect(fixture.journal.record, original);
    expect(fixture.journal.progressRemovals, 0);
    expect(fixture.httpFixture.requests.map((r) => r.method), ['GET']);
    expect(fixture.controller.resultUnknown, isTrue);
    expect(fixture.controller.notice, isNot(contains('已申请')));
  });

  test('explicit newer query exact-CAS unlocks and only reports progress', () async {
    fixture.journal.record = fixture.pending();
    await fixture.controller.initialize();
    fixture.task = fixture.taskValue(revision: 2);
    await fixture.controller.query();
    expect(fixture.journal.record, isNull);
    expect(fixture.journal.progressRemovals, 1);
    expect(fixture.controller.notice, '任务已有新进展，请查看当前状态。');
    expect(fixture.httpFixture.requests.map((r) => r.method), ['GET']);
  });

  test('fresh detail and eligibility precede confirmation; declining never reserves', () async {
    await fixture.controller.initialize();
    var confirmations = 0;
    await fixture.controller.requestRecheck((selected) async {
      confirmations++;
      expect(selected.revision, fixture.task.revision);
      expect(fixture.httpFixture.requests, hasLength(2));
      expect(fixture.httpFixture.requests.last.url.path, endsWith('/review-eligibility'));
      return false;
    });
    expect(confirmations, 1);
    expect(fixture.journal.reserves, 0);
    expect(fixture.posts, 0);
  });

  test('busy is synchronous and prevents a parallel cancel confirmation', () async {
    await fixture.controller.initialize();
    final entered = Completer<void>(), answer = Completer<bool>();
    final operation = fixture.controller.requestRecheck((_) {
      entered.complete(); return answer.future;
    });
    expect(fixture.controller.busy, isTrue);
    await _reached(entered, operation);
    var secondConfirmation = false;
    await fixture.controller.cancel((_) async { secondConfirmation = true; return true; });
    expect(secondConfirmation, isFalse);
    answer.complete(false);
    await operation;
    expect(fixture.journal.reserves, 0);
    expect(fixture.posts, 0);
  });

  test('direct strict cancel receipt clears exact slot and reports registered only', () async {
    await fixture.controller.initialize();
    await fixture.controller.cancel((_) async => true);
    expect(fixture.posts, 1);
    expect(fixture.journal.receiptRemovals, 1);
    expect(fixture.journal.record, isNull);
    expect(fixture.controller.notice, '已登记取消，请核对设备现状。');
    expect(fixture.httpFixture.requests.last.headers['if-match'], '"1"');
  });

  test('cancel remains available when the recheck eligibility endpoint would fail', () async {
    await fixture.controller.initialize();
    fixture.eligibilityFailure = true;
    await fixture.controller.cancel((_) async => true);
    expect(fixture.posts, 1);
    expect(fixture.httpFixture.requests.map((request) => request.method), ['GET', 'POST']);
    expect(fixture.httpFixture.requests.where((request) =>
        request.url.path.endsWith('/review-eligibility')), isEmpty);
    expect(fixture.journal.record, isNull);
  });

  test('direct strict recheck receipt reports application, never device applied', () async {
    await fixture.controller.initialize();
    await fixture.controller.requestRecheck((_) async => true);
    expect(fixture.posts, 1);
    expect(fixture.journal.receiptRemovals, 1);
    expect(fixture.controller.notice, '已申请重新核实，等待设备反馈。');
    expect(fixture.controller.selected!.state, 'WAITING_DEVICE');
    expect(fixture.controller.selected!.state, isNot('APPLIED'));
  });

  test('detach during confirmation permanently invalidates the old token', () async {
    await fixture.controller.initialize();
    final entered = Completer<void>(), answer = Completer<bool>();
    final operation = fixture.controller.requestRecheck((_) {
      entered.complete(); return answer.future;
    });
    await _reached(entered, operation);
    fixture.controller.detach();
    expect(fixture.controller.selected, isNull);
    answer.complete(true);
    await operation;
    expect(fixture.journal.reserves, 0);
    expect(fixture.posts, 0);
    expect(fixture.controller.hasAccess, isFalse);
  });

  test('late reserve after detach uses only its private zero-send causal cleanup', () async {
    await fixture.controller.initialize();
    fixture.journal.reserveEntered = Completer<void>();
    fixture.journal.reserveRelease = Completer<void>();
    final operation = fixture.controller.requestRecheck((_) async => true);
    await _reached(fixture.journal.reserveEntered!, operation);
    fixture.controller.detach();
    expect(fixture.journal.record, isNotNull);
    fixture.journal.reserveRelease!.complete();
    await operation;
    expect(fixture.posts, 0);
    expect(fixture.journal.zeroSendRemovals, 1);
    expect(fixture.journal.record, isNull);
    expect(fixture.controller.selected, isNull);
  });

  test('scope leaves and returns while reserve waits; old instance never revives', () async {
    await fixture.controller.initialize();
    fixture.journal.reserveEntered = Completer<void>();
    fixture.journal.reserveRelease = Completer<void>();
    final operation = fixture.controller.cancel((_) async => true);
    await _reached(fixture.journal.reserveEntered!, operation);
    fixture.viewIsCurrent = false;
    fixture.controller.checkScope();
    fixture.viewIsCurrent = true;
    fixture.journal.reserveRelease!.complete();
    await operation;
    expect(fixture.posts, 0);
    expect(fixture.journal.zeroSendRemovals, 1);
    expect(fixture.controller.hasAccess, isFalse);
  });

  test('detach after submit call retains UNKNOWN and ignores late 200 UI', () async {
    await fixture.controller.initialize();
    fixture.postEntered = Completer<void>();
    fixture.postRelease = Completer<void>();
    final operation = fixture.controller.requestRecheck((_) async => true);
    await _reached(fixture.postEntered!, operation);
    final progressBeforeDetach = fixture.progress.length;
    fixture.controller.detach();
    fixture.postRelease!.complete();
    await operation;
    expect(fixture.posts, 1);
    expect(fixture.journal.record!.phase, ExecutionOperationPhase.unknown);
    expect(fixture.journal.zeroSendRemovals, 0);
    expect(fixture.journal.receiptRemovals, 0);
    expect(fixture.progress, hasLength(progressBeforeDetach));
    expect(fixture.controller.pending, isNull);
  });

  test('storage failure after write blocks further submit until local restore', () async {
    await fixture.controller.initialize();
    fixture.journal.throwAfterReserve = true;
    await fixture.controller.requestRecheck((_) async => true);
    expect(fixture.posts, 0);
    expect(fixture.journal.record!.phase, ExecutionOperationPhase.unknown);
    expect(fixture.controller.storageBlocked, isTrue);
    final before = fixture.httpFixture.requests.length;
    await fixture.controller.cancel((_) async => true);
    expect(fixture.httpFixture.requests, hasLength(before));
    fixture.journal.throwAfterReserve = false;
    await fixture.controller.restore();
    expect(fixture.httpFixture.requests, hasLength(before));
    expect(fixture.controller.resultUnknown, isTrue);
    expect(fixture.controller.storageBlocked, isFalse);
  });

  test('trusted refusal permits only a newly confirmed explicit replacement', () async {
    await fixture.controller.initialize();
    fixture.denialStatus = 409;
    fixture.denialCode = 'EXECUTION_RECHECK_LEASE_ACTIVE';
    await fixture.controller.requestRecheck((_) async => true);
    final original = fixture.journal.record!;
    expect(original.phase, ExecutionOperationPhase.rejectedNotApplied);
    expect(fixture.journal.rejections, 1);
    fixture.denialStatus = null;
    fixture.denialCode = null;
    await fixture.controller.requestRecheck((_) async => true);
    expect(fixture.posts, 2);
    expect(fixture.journal.replacements, 1);
    expect(fixture.lastSubmitted!.intent.operationId, isNot(original.intent.operationId));
    expect(fixture.journal.record, isNull);
  });

  test('trusted REAUTH produces explicit host request without login or replay', () async {
    await fixture.controller.initialize();
    fixture.denialStatus = 401;
    fixture.denialCode = 'REAUTH_REQUIRED';
    await fixture.controller.requestRecheck((_) async => true);
    expect(fixture.journal.record!.phase, ExecutionOperationPhase.rejectedNotApplied);
    expect(fixture.controller.needsReauth, isTrue);
    expect(fixture.controller.requestStepUp(), isTrue);
    expect(fixture.controller.hasAccess, isFalse);
    expect(fixture.controller.requestStepUp(), isFalse);
    expect(fixture.posts, 1);
  });

  test('synthetic ApiFailure is not a physical refusal and retains UNKNOWN', () async {
    await fixture.controller.initialize();
    fixture.syntheticPostFailure = const ApiFailure(401, 'REAUTH_REQUIRED');
    await fixture.controller.requestRecheck((_) async => true);
    expect(fixture.journal.rejections, 0);
    expect(fixture.journal.record!.phase, ExecutionOperationPhase.unknown);
    expect(fixture.controller.needsReauth, isTrue);
  });

  test('typed 403 hides synchronously before exact old-record CAS', () async {
    await fixture.controller.initialize();
    fixture.denialStatus = 403;
    fixture.denialCode = 'SCOPE_DENIED';
    fixture.journal.onMarkRejected = () {
      expect(fixture.controller.hasAccess, isFalse);
      expect(fixture.controller.selected, isNull);
      expect(fixture.controller.pending, isNull);
    };
    await fixture.controller.cancel((_) async => true);
    expect(fixture.journal.rejections, 1);
    expect(fixture.journal.record!.phase, ExecutionOperationPhase.rejectedNotApplied);
    expect(fixture.controller.hasAccess, isFalse);
  });

  test('already formed refusal finishes old CAS after detach without UI revival', () async {
    await fixture.controller.initialize();
    fixture.denialStatus = 409;
    fixture.denialCode = 'EXECUTION_RECHECK_LEASE_ACTIVE';
    fixture.journal.markEntered = Completer<void>();
    fixture.journal.markRelease = Completer<void>();
    final operation = fixture.controller.requestRecheck((_) async => true);
    await _reached(fixture.journal.markEntered!, operation);
    fixture.controller.detach();
    final priorProgress = fixture.progress.length;
    fixture.journal.markRelease!.complete();
    await operation;
    expect(fixture.journal.record!.phase, ExecutionOperationPhase.rejectedNotApplied);
    expect(fixture.controller.hasAccess, isFalse);
    expect(fixture.controller.pending, isNull);
    expect(fixture.progress, hasLength(priorProgress));
  });

  test('storage uncertainty never suppresses privacy revocation on explicit GET', () async {
    await fixture.controller.initialize();
    fixture.journal.throwAfterReserve = true;
    await fixture.controller.requestRecheck((_) async => true);
    expect(fixture.controller.storageBlocked, isTrue);
    fixture.detailFailure = true;
    await fixture.controller.query();
    expect(fixture.controller.hasAccess, isFalse);
    expect(fixture.controller.selected, isNull);
    expect(fixture.journal.record!.phase, ExecutionOperationPhase.unknown);
    expect(fixture.journal.rejections, 0);
  });

  test('timeline advances during reserve: retire attempt, exact zero-send release', () async {
    await fixture.controller.initialize();
    fixture.journal.reserveEntered = Completer<void>();
    fixture.journal.reserveRelease = Completer<void>();
    final operation = fixture.controller.requestRecheck((_) async => true);
    await _reached(fixture.journal.reserveEntered!, operation);
    fixture.eventRevision = 2;
    fixture.journal.reserveRelease!.complete();
    await operation;
    expect(fixture.posts, 0);
    expect(fixture.journal.zeroSendRemovals, 1);
    expect(fixture.journal.record, isNull);
    expect(fixture.controller.canRecheck, isFalse);
  });

  test('shared slot prevents cancel bypassing another controller recheck', () async {
    await fixture.controller.initialize();
    final other = fixture.newController();
    await other.initialize();
    fixture.postEntered = Completer<void>();
    fixture.postRelease = Completer<void>();
    fixture.journal.secondReserveEntered = Completer<void>();
    final first = fixture.controller.requestRecheck((_) async => true);
    await _reached(fixture.postEntered!, first);
    final second = other.cancel((_) async => true);
    await _reached(fixture.journal.secondReserveEntered!, second);
    await second;
    expect(fixture.posts, 1);
    fixture.postRelease!.complete();
    await first;
    other.dispose();
  });
}

Future<void> _reached(Completer<void> signal, Future<void> operation) async {
  await Future.any<void>([signal.future, operation]);
  expect(signal.isCompleted, isTrue,
      reason: 'The actual boundary was not reached; early return is not scenario proof.');
}

class _Fixture {
  final httpFixture = ExecutionFixture();
  final journal = _ControlledJournal();
  final progress = <ManagedExecution>[];
  final owner = ExecutionOperationOwner(actorId: 'operator', tenantId: executionTenant,
      apiBaseUrl: 'http://execution.invalid/api/v1', issuer: 'http://identity.invalid/realms/manager');
  late ManagedExecution task = taskValue();
  bool viewIsCurrent = true, eligibilityFailure = false, detailFailure = false;
  int eventRevision = 0, sequence = 10, posts = 0;
  int? denialStatus;
  String? denialCode;
  ApiFailure? syntheticPostFailure;
  Completer<void>? postEntered, postRelease;
  ExecutionOperationPending? lastSubmitted;
  late final repository = ManagedExecutionReviewRepository(api: httpFixture.api, owner: owner,
      deviceId: executionDevice, registrationId: executionRegistration,
      writable: true, current: () => httpFixture.current);
  late final controller = newController();

  _Fixture() { httpFixture.handler = handle; }

  ManagedExecution taskValue({int revision = 1}) => ManagedExecution.parse(
      httpFixture.record(state: 'NEEDS_REVIEW', reason: 'DEVICE_NON_COMPLIANT', revision: revision),
      deviceId: executionDevice);

  ExecutionOperationPending pending() => ExecutionOperationPending(intent: ExecutionOperationIntent(
      owner: owner, task: task, kind: ExecutionOperationKind.recheckDevice,
      operationId: 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001', createdAt: 100));

  ManagedExecutionReviewController newController() => ManagedExecutionReviewController(
      requests: repository, journal: journal, selected: task,
      viewCurrent: () => viewIsCurrent,
      operationId: () => 'aaaaaaaa-aaaa-4aaa-8aaa-${(++sequence).toRadixString(16).padLeft(12, '0')}',
      now: () => 100, onProgress: progress.add, latestEventRevision: () => eventRevision);

  Future<http.Response> handle(http.Request request) async {
    if (request.method == 'POST') {
      posts++;
      lastSubmitted = journal.record;
      if (postEntered != null && !postEntered!.isCompleted) {
        postEntered!.complete();
      }
      if (postRelease != null) await postRelease!.future;
      if (syntheticPostFailure != null) throw syntheticPostFailure!;
      if (denialStatus != null) {
        return httpFixture.response({'errorCode': denialCode}, status: denialStatus!);
      }
      final cancel = request.url.path.endsWith('/cancel');
      return httpFixture.response(httpFixture.record(revision: task.revision + 1,
          state: cancel ? 'CANCELLED' : 'WAITING_DEVICE',
          reason: cancel ? 'CANCELLED_BEFORE_ASSIGNMENT' : 'MANUAL_DEVICE_RECHECK_REQUESTED',
          cancelled: cancel));
    }
    if (request.url.path.endsWith('/review-eligibility')) {
      if (eligibilityFailure) {
        return httpFixture.response({'errorCode': 'EMM_UNAVAILABLE'}, status: 503);
      }
      return httpFixture.response({'id': task.id, 'publicationId': task.publicationId,
        'deviceId': task.deviceId, 'registrationId': task.registrationId,
        'revision': task.revision, 'allowed': true, 'reason': 'ELIGIBLE'});
    }
    if (detailFailure) {
      return httpFixture.response({'errorCode': 'SCOPE_DENIED'}, status: 403);
    }
    return httpFixture.response(httpFixture.record(revision: task.revision,
        state: task.state, reason: task.reason, cancelled: task.cancellationRequested));
  }
}

/// Test seam only: explicit async barriers around a full-value slot. Browser
/// atomicity is separately exercised by native journal tests, never this fake.
class _ControlledJournal implements ExecutionOperationJournal {
  ExecutionOperationPending? record;
  int reads = 0, reserves = 0, replacements = 0, rejections = 0;
  int receiptRemovals = 0, progressRemovals = 0, zeroSendRemovals = 0;
  bool throwAfterReserve = false;
  Completer<void>? reserveEntered, reserveRelease, secondReserveEntered;
  Completer<void>? markEntered, markRelease;
  void Function()? onMarkRejected;

  @override
  Future<ExecutionOperationPending?> read(ExecutionOperationOwner owner, String executionId) async {
    reads++;
    return record;
  }
  @override
  Future<ExecutionOperationReservation> reserve(ExecutionOperationIntent intent) async {
    reserves++;
    if (reserves == 2 && secondReserveEntered != null) {
      secondReserveEntered!.complete();
    }
    if (record != null) {
      return ExecutionOperationReservation(record: record!, maySubmit: false);
    }
    final next = ExecutionOperationPending(intent: intent);
    record = next;
    if (reserveEntered != null && !reserveEntered!.isCompleted) {
      reserveEntered!.complete();
    }
    if (reserveRelease != null) await reserveRelease!.future;
    if (throwAfterReserve) {
      throw const ApiFailure(503, 'EXECUTION_OPERATION_STORAGE_UNAVAILABLE');
    }
    return ExecutionOperationReservation(record: next, maySubmit: true);
  }
  @override
  Future<ExecutionOperationReservation> replaceRejected(ExecutionOperationPending expected,
      ExecutionOperationIntent replacement) async {
    replacements++;
    if (record != expected || expected.phase != ExecutionOperationPhase.rejectedNotApplied) {
      throw const ApiFailure(409, 'EXECUTION_OPERATION_PENDING_CHANGED');
    }
    record = ExecutionOperationPending(intent: replacement);
    return ExecutionOperationReservation(record: record!, maySubmit: true);
  }
  @override
  Future<ExecutionOperationPending> markRejected(ExecutionOperationDenied proof) async {
    onMarkRejected?.call();
    if (markEntered != null && !markEntered!.isCompleted) {
      markEntered!.complete();
    }
    if (markRelease != null) await markRelease!.future;
    if (record != proof.record) {
      throw const ApiFailure(409, 'EXECUTION_OPERATION_PENDING_CHANGED');
    }
    rejections++;
    record = ExecutionOperationPending(intent: proof.record.intent,
        phase: ExecutionOperationPhase.rejectedNotApplied, refusalCode: proof.failure.code);
    return record!;
  }
  bool _remove(ExecutionOperationPending expected) {
    if (record != expected) return false;
    record = null;
    return true;
  }
  @override
  Future<bool> removeAfterVerifiedReceipt(ExecutionOperationPending expected, ManagedExecution response) async {
    receiptRemovals++;
    return _remove(expected);
  }
  @override
  Future<bool> removeAfterObservedProgress(ExecutionOperationPending expected, ManagedExecution progress) async {
    progress.requireContinuationOf(expected.intent.task);
    if (progress.revision <= expected.intent.task.revision) {
      throw StateError('Not ahead');
    }
    progressRemovals++;
    return _remove(expected);
  }
  @override
  Future<bool> removeAfterControllerProvedNeverDispatched(ExecutionOperationPending expected) async {
    zeroSendRemovals++;
    return _remove(expected);
  }
}
