@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_native.dart' as native;
import 'package:guardian/core/api.dart';
import 'package:guardian/core/browser_execution_operation_journal.dart';
import 'package:guardian/core/execution_operation_journal.dart';
import 'package:guardian/core/managed_execution.dart';
import 'package:guardian/core/managed_execution_review.dart';

import 'managed_execution_fixtures.dart';

// These are source-only native transaction cases. They have not been executed.
void main() {
  late String databaseName;
  late BrowserExecutionOperationJournal first, second;
  final owner = ExecutionOperationOwner(
      actorId: 'operator',
      tenantId: executionTenant,
      apiBaseUrl: 'http://execution.invalid/api/v1',
      issuer: 'http://identity.invalid/realms/manager');

  ManagedExecution task({int revision = 1, String id = executionId}) =>
      ManagedExecution.parse(
          ExecutionFixture().record(
              id: id,
              state: 'NEEDS_REVIEW',
              reason: 'DEVICE_NON_COMPLIANT',
              revision: revision),
          deviceId: executionDevice);

  ExecutionOperationIntent intent(int sequence,
          {ExecutionOperationKind kind = ExecutionOperationKind.recheckDevice,
          ManagedExecution? selected}) =>
      ExecutionOperationIntent(
          owner: owner,
          task: selected ?? task(),
          kind: kind,
          operationId:
              'aaaaaaaa-aaaa-4aaa-8aaa-${sequence.toRadixString(16).padLeft(12, '0')}',
          createdAt: 100);

  setUp(() {
    databaseName =
        'ai-manager.test.execution-operations.${DateTime.now().microsecondsSinceEpoch}';
    first = BrowserExecutionOperationJournal(databaseName: databaseName);
    second = BrowserExecutionOperationJournal(databaseName: databaseName);
  });
  tearDown(() async {
    // Only the database named by this test is deleted. Production has no clear API.
    await native.idbFactoryWeb.deleteDatabase(databaseName);
  });

  test('two native connections reserve one shared cancel and recheck slot',
      () async {
    final results = await Future.wait([
      first.reserve(intent(1)),
      second.reserve(intent(2, kind: ExecutionOperationKind.cancel)),
    ]);
    expect(results.where((r) => r.maySubmit), hasLength(1));
    expect(results[0].record, results[1].record);
    expect(results.singleWhere((r) => r.maySubmit).record.phase,
        ExecutionOperationPhase.unknown);
  });

  test('new connection restores exact unknown without granting another send',
      () async {
    final reserved = await first.reserve(intent(1));
    final restored = await second.read(owner, executionId);
    expect(restored, reserved.record);
    expect(restored, isNot(same(reserved.record)));
    expect((await second.reserve(intent(2))).maySubmit, isFalse);
  });

  test('all twenty unresolved slots remain while a new slot is refused',
      () async {
    for (var index = 1; index <= 20; index++) {
      final id =
          '44444444-4444-4444-8444-${index.toRadixString(16).padLeft(12, '0')}';
      expect(
          (await first.reserve(intent(index, selected: task(id: id))))
              .maySubmit,
          isTrue);
    }
    await expectLater(
        first.reserve(intent(21)),
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'EXECUTION_OPERATION_CAPACITY')));
    const id = '44444444-4444-4444-8444-000000000001';
    expect(await second.read(owner, id), isNotNull);
  });

  test('same revision progress cannot remove an unresolved original', () async {
    final expected = (await first.reserve(intent(1))).record;
    await expectLater(() => first.removeAfterObservedProgress(expected, task()),
        throwsA(isA<ApiFailure>()));
    expect(await second.read(owner, executionId), expected);
  });

  test('higher revision unlocks by exact CAS and makes no acceptance claim',
      () async {
    final expected = (await first.reserve(intent(1))).record;
    expect(
        await second.removeAfterObservedProgress(expected, task(revision: 2)),
        isTrue);
    expect(await first.read(owner, executionId), isNull);
  });

  test('late zero-dispatch cleanup cannot delete a newer operation', () async {
    final old = (await first.reserve(intent(1))).record;
    expect(await first.removeAfterControllerProvedNeverDispatched(old), isTrue);
    final next = (await second.reserve(intent(2))).record;
    expect(
        await first.removeAfterControllerProvedNeverDispatched(old), isFalse);
    expect(await first.read(owner, executionId), next);
  });

  test('codec preserves every original value and rejects changed namespace',
      () {
    final original = ExecutionOperationPending(intent: intent(1));
    final text = ExecutionOperationRecordCodec.encode(original);
    expect(
        ExecutionOperationRecordCodec.decode(text,
            owner: owner, executionId: executionId),
        original);
    final foreign = ExecutionOperationOwner(
        actorId: 'another',
        tenantId: executionTenant,
        apiBaseUrl: owner.apiBaseUrl,
        issuer: owner.issuer);
    expect(
        () => ExecutionOperationRecordCodec.decode(text,
            owner: foreign, executionId: executionId),
        throwsA(isA<ApiFailure>()));
  });
}
