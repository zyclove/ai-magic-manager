@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/browser_execution_operation_journal.dart';
import 'package:guardian/core/execution_operation_journal.dart';
import 'package:guardian/core/managed_execution.dart';
import 'package:guardian/core/managed_execution_review.dart';
import 'package:guardian/core/managed_execution_review_repository.dart';
import 'package:idb_shim/idb_client_native.dart' as native;

import 'managed_execution_fixtures.dart';

// Real native transaction test sources; no SDK or browser run has occurred.
void main() {
  late String databaseName;
  late BrowserExecutionOperationJournal first, second;
  final owner = ExecutionOperationOwner(actorId: 'operator', tenantId: executionTenant,
      apiBaseUrl: 'http://execution.invalid/api/v1',
      issuer: 'http://identity.invalid/realms/manager');

  ManagedExecution task({int revision = 1, String id = executionId,
      int updatedAt = 100, bool cancelled = false,
      String state = 'NEEDS_REVIEW', String reason = 'DEVICE_NON_COMPLIANT'}) =>
      ManagedExecution.parse(ExecutionFixture().record(id: id, state: state,
          reason: reason, revision: revision, updatedAt: updatedAt, cancelled: cancelled),
          deviceId: executionDevice);

  ExecutionOperationIntent intent(int sequence, {ExecutionOperationOwner? identity,
      ExecutionOperationKind kind = ExecutionOperationKind.recheckDevice,
      ManagedExecution? selected, int createdAt = 100}) =>
      ExecutionOperationIntent(owner: identity ?? owner, task: selected ?? task(), kind: kind,
          operationId: 'aaaaaaaa-aaaa-4aaa-8aaa-${sequence.toRadixString(16).padLeft(12, '0')}',
          createdAt: createdAt);

  Future<ExecutionOperationDenied> deny(ExecutionOperationPending pending,
      {String code = 'EXECUTION_RECHECK_LEASE_ACTIVE', int status = 409}) async {
    final fixture = ExecutionFixture();
    fixture.handler = (_) async => fixture.response({'errorCode': code}, status: status);
    final repository = ManagedExecutionReviewRepository(api: fixture.api,
        owner: owner, deviceId: executionDevice, registrationId: executionRegistration,
        writable: true, current: () => true);
    try {
      await repository.submit(pending);
      fail('The specified complete POST refusal must be observed.');
    } on ExecutionOperationDenied catch (proof) {
      expect(fixture.requests, hasLength(1));
      expect(fixture.requests.single.method, 'POST');
      expect(proof.record, pending);
      expect(proof.failure.code, code);
      return proof;
    } finally {
      fixture.client.close();
    }
  }

  Future<void> putRaw(Object value) async {
    final database = await native.idbFactoryWeb.open(databaseName);
    try {
      final transaction = database.transaction('pending', 'readwrite');
      final completed = transaction.completed;
      await transaction.objectStore('pending').put(value, '${owner.key}\u0000$executionId');
      await completed;
    } finally {
      database.close();
    }
  }

  Future<Object?> raw() async {
    final database = await native.idbFactoryWeb.open(databaseName);
    try {
      final transaction = database.transaction('pending', 'readonly');
      final completed = transaction.completed;
      final value = await transaction.objectStore('pending').getObject('${owner.key}\u0000$executionId');
      await completed;
      return value;
    } finally {
      database.close();
    }
  }

  setUp(() {
    databaseName = 'ai-manager.test.execution-operations.additional.${DateTime.now().microsecondsSinceEpoch}';
    first = BrowserExecutionOperationJournal(databaseName: databaseName);
    second = BrowserExecutionOperationJournal(databaseName: databaseName);
  });
  tearDown(() async {
    await native.idbFactoryWeb.deleteDatabase(databaseName);
  });

  test('physical HTTP refusal persists and only one explicit replacement wins', () async {
    final original = (await first.reserve(intent(1))).record;
    final rejected = await first.markRejected(await deny(original));
    expect(rejected.phase, ExecutionOperationPhase.rejectedNotApplied);
    expect(rejected.refusalCode, 'EXECUTION_RECHECK_LEASE_ACTIVE');
    expect(await second.read(owner, executionId), rejected);
    expect((await second.reserve(intent(2))).maySubmit, isFalse);
    final results = await Future.wait([
      first.replaceRejected(rejected, intent(3)),
      second.replaceRejected(rejected, intent(4, kind: ExecutionOperationKind.cancel)),
    ]);
    expect(results.where((result) => result.maySubmit), hasLength(1));
    expect(results.first.record, results.last.record);
    expect(results.first.record.phase, ExecutionOperationPhase.unknown);
    expect(results.first.record.refusalCode, isNull);
  });

  test('late refusal proof cannot downgrade the new unknown operation', () async {
    final original = (await first.reserve(intent(1))).record;
    final proof = await deny(original);
    final rejected = await first.markRejected(proof);
    final replacement = await second.replaceRejected(rejected, intent(2));
    await expectLater(() => first.markRejected(proof), throwsA(isA<ApiFailure>()
        .having((failure) => failure.code, 'code', 'EXECUTION_OPERATION_PENDING_CHANGED')));
    expect(await first.read(owner, executionId), replacement.record);
  });

  test('unresolved operation cannot be replaced by a fabricated rejection value', () async {
    final original = (await first.reserve(intent(1))).record;
    final fabricated = ExecutionOperationPending(intent: original.intent,
        phase: ExecutionOperationPhase.rejectedNotApplied, refusalCode: 'REAUTH_REQUIRED');
    expect((await second.replaceRejected(fabricated, intent(2))).maySubmit, isFalse);
    expect(await first.read(owner, executionId), original);
  });

  test('replacement refuses reused operation ID without modifying the rejection', () async {
    final original = (await first.reserve(intent(1))).record;
    final rejected = await first.markRejected(await deny(original));
    await expectLater(() => second.replaceRejected(rejected, original.intent),
        throwsA(isA<ApiFailure>()));
    expect(await second.read(owner, executionId), rejected);
  });

  test('same operation ID with changed complete task cannot clear the slot', () async {
    final original = (await first.reserve(intent(1))).record;
    final changed = ExecutionOperationPending(intent: intent(1, selected: task(updatedAt: 101)));
    expect(changed, isNot(original));
    expect(await second.removeAfterControllerProvedNeverDispatched(changed), isFalse);
    expect(await first.read(owner, executionId), original);
  });

  test('same operation and task but changed intent timestamp cannot clear the slot', () async {
    final original = (await first.reserve(intent(1))).record;
    final changed = ExecutionOperationPending(intent: intent(1, createdAt: 101));
    expect(await second.removeAfterControllerProvedNeverDispatched(changed), isFalse);
    expect(await first.read(owner, executionId), original);
  });

  test('correct cancel receipt removes only its exact record', () async {
    final original = (await first.reserve(intent(1, kind: ExecutionOperationKind.cancel))).record;
    final receipt = task(revision: 2, cancelled: true,
        state: 'CANCELLED', reason: 'CANCELLED_BEFORE_ASSIGNMENT');
    expect(await second.removeAfterVerifiedReceipt(original, receipt), isTrue);
    expect(await first.read(owner, executionId), isNull);
  });

  test('cancel receipt with revision jump is rejected and keeps unknown', () async {
    final original = (await first.reserve(intent(1, kind: ExecutionOperationKind.cancel))).record;
    final receipt = task(revision: 3, cancelled: true,
        state: 'CANCELLED', reason: 'CANCELLED_BEFORE_ASSIGNMENT');
    await expectLater(() => second.removeAfterVerifiedReceipt(original, receipt),
        throwsA(isA<ApiFailure>()));
    expect(await first.read(owner, executionId), original);
  });

  test('same revision changed task cannot be treated as observed progress', () async {
    final original = (await first.reserve(intent(1))).record;
    await expectLater(() => second.removeAfterObservedProgress(original, task(updatedAt: 101)),
        throwsA(isA<ApiFailure>()));
    expect(await first.read(owner, executionId), original);
  });

  test('owner namespace remains isolated at capacity', () async {
    for (var index = 1; index <= executionOperationMaximumPending; index++) {
      final id = '44444444-4444-4444-8444-${index.toRadixString(16).padLeft(12, '0')}';
      await first.reserve(intent(index, selected: task(id: id)));
    }
    final foreign = ExecutionOperationOwner(actorId: 'second-operator', tenantId: executionTenant,
        apiBaseUrl: owner.apiBaseUrl, issuer: owner.issuer);
    expect(await first.read(foreign, executionId), isNull);
    expect((await second.reserve(intent(40, identity: foreign))).maySubmit, isTrue);
    expect(await second.read(owner, executionId), isNull);
  });

  test('corrupt non-string record blocks reserve and is never overwritten', () async {
    await first.reserve(intent(1));
    const corrupt = 42;
    await putRaw(corrupt);
    await expectLater(() => second.reserve(intent(2)), throwsA(isA<ApiFailure>()
        .having((failure) => failure.code, 'code', 'INVALID_EXECUTION_OPERATION_RECORD')));
    expect(await raw(), corrupt);
  });

  test('duplicate JSON keys fail canonical decoding and preserve stored bytes', () async {
    final original = (await first.reserve(intent(1))).record;
    final canonical = ExecutionOperationRecordCodec.encode(original);
    final corrupt = canonical.replaceFirst('{"schema":1,', '{"schema":1,"schema":1,');
    expect(corrupt, isNot(canonical));
    await putRaw(corrupt);
    await expectLater(() => second.read(owner, executionId), throwsA(isA<ApiFailure>()));
    expect(await raw(), corrupt);
  });

  test('noncanonical JSON and inconsistent phase are both refused', () {
    final original = ExecutionOperationPending(intent: intent(1));
    final canonical = ExecutionOperationRecordCodec.encode(original);
    expect(() => ExecutionOperationRecordCodec.decode(' $canonical', owner: owner,
        executionId: executionId), throwsA(isA<ApiFailure>()));
    final invalid = jsonDecode(canonical) as Json;
    invalid['refusalCode'] = 'REAUTH_REQUIRED';
    expect(() => ExecutionOperationRecordCodec.decode(jsonEncode(invalid), owner: owner,
        executionId: executionId), throwsA(isA<ApiFailure>()));
  });

  test('journal cannot target the existing publication database', () {
    expect(() => BrowserExecutionOperationJournal(databaseName: 'ai-manager.guardian.publications.v1'),
        throwsA(isA<ApiFailure>()));
  });

  test('unexpected native schema fails closed without replacing the store', () async {
    final database = await native.idbFactoryWeb.open(databaseName, version: 1,
        onUpgradeNeeded: (event) => event.database.createObjectStore('unexpected'));
    database.close();
    await expectLater(() => first.reserve(intent(1)), throwsA(isA<ApiFailure>()
        .having((failure) => failure.code, 'code', 'EXECUTION_OPERATION_STORAGE_UNAVAILABLE')));
    final reopened = await native.idbFactoryWeb.open(databaseName);
    try {
      expect(reopened.objectStoreNames, ['unexpected']);
    } finally {
      reopened.close();
    }
  });
}
