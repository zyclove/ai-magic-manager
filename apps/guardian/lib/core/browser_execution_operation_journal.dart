import 'dart:async';
import 'package:idb_shim/idb.dart' as idb;
import 'package:idb_shim/idb_client_native.dart' as native;

import 'api.dart';
import 'execution_operation_journal.dart';
import 'managed_execution.dart';
import 'managed_execution_review.dart';
import 'managed_execution_review_repository.dart';

/// Native durable transactions only. Every call owns and closes its connection;
/// inability to persist never grants a send or falls back to in-memory state.
class BrowserExecutionOperationJournal implements ExecutionOperationJournal {
  static const defaultDatabaseName =
      'ai-manager.guardian.execution-operations.v1';
  static const _store = 'pending';
  static const _wait = Duration(seconds: 5);
  static const _storageFailure =
      ApiFailure(503, 'EXECUTION_OPERATION_STORAGE_UNAVAILABLE');
  static const _changed =
      ApiFailure(409, 'EXECUTION_OPERATION_PENDING_CHANGED');
  static const _invalidRecord =
      ApiFailure(409, 'INVALID_EXECUTION_OPERATION_RECORD');
  final String databaseName;

  BrowserExecutionOperationJournal({this.databaseName = defaultDatabaseName}) {
    if (databaseName != defaultDatabaseName &&
        !RegExp(r'^ai-manager\.test\.execution-operations\.[A-Za-z0-9.-]{1,100}$')
            .hasMatch(databaseName)) {
      throw const ApiFailure(400, 'INVALID_EXECUTION_OPERATION_DATABASE');
    }
  }

  String _key(ExecutionOperationOwner owner, String executionId) =>
      '${owner.key}\u0000$executionId';

  @override
  Future<ExecutionOperationPending?> read(
      ExecutionOperationOwner owner, String executionId) {
    if (!isManagedExecutionId(executionId)) {
      return Future.error(const ApiFailure(400, 'INVALID_EXECUTION_OPERATION'));
    }
    return _withDatabase((database) => _read(database, owner, executionId));
  }

  @override
  Future<ExecutionOperationReservation> reserve(
      ExecutionOperationIntent intent) {
    final next = ExecutionOperationPending(intent: intent);
    final encoded = ExecutionOperationRecordCodec.encode(next);
    return _withDatabase((database) async {
      final result = await _transaction(database, 'readwrite', (store) async {
        final current = await _get(store, intent.owner, intent.task.id);
        if (current != null) {
          return ExecutionOperationReservation(
              record: current, maySubmit: false);
        }
        final count = await store.count(idb.KeyRange.bound(
            '${intent.owner.key}\u0000',
            '${intent.owner.key}\u0001',
            false,
            true));
        if (count >= executionOperationMaximumPending) {
          throw const ApiFailure(409, 'EXECUTION_OPERATION_CAPACITY');
        }
        await store.add(encoded, _key(intent.owner, intent.task.id));
        return ExecutionOperationReservation(record: next, maySubmit: true);
      });
      return _verifyReservation(database, result);
    });
  }

  @override
  Future<ExecutionOperationReservation> replaceRejected(
      ExecutionOperationPending expected,
      ExecutionOperationIntent replacement) {
    final original = expected.intent;
    if (expected.phase != ExecutionOperationPhase.rejectedNotApplied ||
        replacement.owner != original.owner ||
        replacement.task.id != original.task.id ||
        replacement.operationId == original.operationId) throw _changed;
    replacement.task.requireContinuationOf(original.task);
    final next = ExecutionOperationPending(intent: replacement);
    final encoded = ExecutionOperationRecordCodec.encode(next);
    return _withDatabase((database) async {
      final result = await _transaction(database, 'readwrite', (store) async {
        final current = await _get(store, original.owner, original.task.id);
        if (current == null) throw _changed;
        if (current != expected) {
          return ExecutionOperationReservation(
              record: current, maySubmit: false);
        }
        await store.put(encoded, _key(original.owner, original.task.id));
        return ExecutionOperationReservation(record: next, maySubmit: true);
      });
      return _verifyReservation(database, result);
    });
  }

  @override
  Future<ExecutionOperationPending> markRejected(
      ExecutionOperationDenied proof) {
    final expected = proof.record;
    if (expected.phase != ExecutionOperationPhase.unknown ||
        !executionOperationRefusalCodes.contains(proof.failure.code)) {
      throw _changed;
    }
    final next = ExecutionOperationPending(
        intent: expected.intent,
        phase: ExecutionOperationPhase.rejectedNotApplied,
        refusalCode: proof.failure.code);
    final encoded = ExecutionOperationRecordCodec.encode(next);
    return _withDatabase((database) async {
      final intent = expected.intent;
      await _transaction(database, 'readwrite', (store) async {
        if (await _get(store, intent.owner, intent.task.id) != expected) {
          throw _changed;
        }
        await store.put(encoded, _key(intent.owner, intent.task.id));
      });
      if (await _read(database, intent.owner, intent.task.id) != next) {
        throw _changed;
      }
      return next;
    });
  }

  @override
  Future<bool> removeAfterVerifiedReceipt(
      ExecutionOperationPending expected, ManagedExecution response) {
    final original = expected.intent.task;
    response.requireContinuationOf(original);
    final valid = expected.intent.kind == ExecutionOperationKind.recheckDevice
        ? response.state == 'WAITING_DEVICE' &&
            response.reason == 'MANUAL_DEVICE_RECHECK_REQUESTED'
        : (response.state == 'CANCELLED' &&
                response.reason == 'CANCELLED_BEFORE_ASSIGNMENT') ||
            (response.state == 'NEEDS_REVIEW' &&
                response.reason == 'CANCELLATION_REQUIRES_REVIEW');
    if (expected.phase != ExecutionOperationPhase.unknown ||
        response.revision != original.revision + 1 ||
        !valid ||
        response.cancellationRequested !=
            (expected.intent.kind == ExecutionOperationKind.cancel)) {
      throw const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE');
    }
    return _removeExact(expected);
  }

  @override
  Future<bool> removeAfterObservedProgress(
      ExecutionOperationPending expected, ManagedExecution progress) {
    progress.requireContinuationOf(expected.intent.task);
    if (progress.revision <= expected.intent.task.revision) {
      throw const ApiFailure(409, 'EXECUTION_OPERATION_PROGRESS_NOT_AHEAD');
    }
    // This boolean reports only exact local cleanup. No request attribution.
    return _removeExact(expected);
  }

  @override
  Future<bool> removeAfterControllerProvedNeverDispatched(
      ExecutionOperationPending expected) {
    if (expected.phase != ExecutionOperationPhase.unknown) throw _changed;
    // The journal cannot recreate the live controller's causal latch. This
    // explicitly named seam is not invoked by reads, recovery or error handlers.
    return _removeExact(expected);
  }

  Future<bool> _removeExact(ExecutionOperationPending expected) =>
      _withDatabase((database) async {
        final intent = expected.intent;
        final removed =
            await _transaction(database, 'readwrite', (store) async {
          if (await _get(store, intent.owner, intent.task.id) != expected) {
            return false;
          }
          await store.delete(_key(intent.owner, intent.task.id));
          return true;
        });
        return removed &&
            await _read(database, intent.owner, intent.task.id) == null;
      });

  Future<ExecutionOperationReservation> _verifyReservation(
      idb.Database database, ExecutionOperationReservation result) async {
    final intent = result.record.intent;
    final committed = await _read(database, intent.owner, intent.task.id);
    if (committed == null) throw _changed;
    return ExecutionOperationReservation(
        record: committed,
        maySubmit: result.maySubmit && committed == result.record);
  }

  Future<ExecutionOperationPending?> _read(idb.Database database,
          ExecutionOperationOwner owner, String executionId) =>
      _transaction(
          database, 'readonly', (store) => _get(store, owner, executionId));

  Future<ExecutionOperationPending?> _get(idb.ObjectStore store,
      ExecutionOperationOwner owner, String executionId) async {
    final key = _key(owner, executionId);
    final raw = await store.getObject(key);
    if (raw == null && await store.count(key) == 0) return null;
    if (raw is! String) throw _invalidRecord;
    return ExecutionOperationRecordCodec.decode(raw,
        owner: owner, executionId: executionId);
  }

  Future<T> _withDatabase<T>(Future<T> Function(idb.Database) action) async {
    idb.Database? database;
    StreamSubscription<idb.VersionChangeEvent>? changes;
    var invalidated = false;
    try {
      database = await _open();
      final opened = database;
      void invalidate() {
        // close() alone permits an already active transaction to complete.
        // Once invalidated, this call can never grant a dispatch or cleanup.
        invalidated = true;
        try {
          opened.close();
        } catch (_) {/* Remains permanently invalid. */}
      }

      changes = opened.onVersionChange
          .listen((_) => invalidate(), onError: (Object _) => invalidate());
      if (opened.version != 1 ||
          opened.objectStoreNames.length != 1 ||
          opened.objectStoreNames.single != _store) throw _storageFailure;
      final result = await action(opened);
      if (invalidated) throw _storageFailure;
      return result;
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw _storageFailure;
    } finally {
      database?.close();
      await changes?.cancel();
    }
  }

  Future<idb.Database> _open() {
    final idb.IdbFactory factory;
    try {
      if (!native.idbFactoryWebSupported) return Future.error(_storageFailure);
      factory = native.idbFactoryWeb;
      if (!factory.persistent) return Future.error(_storageFailure);
    } catch (_) {
      return Future.error(_storageFailure);
    }
    final ready = Completer<idb.Database>();
    var abandoned = false;
    late final Timer timer;
    void reject() {
      timer.cancel();
      abandoned = true;
      if (!ready.isCompleted) ready.completeError(_storageFailure);
    }

    timer = Timer(_wait, reject);
    try {
      factory
          .open(databaseName,
              version: 1,
              onBlocked: (_) => reject(),
              onUpgradeNeeded: (event) {
                try {
                  if (abandoned || event.oldVersion != 0) {
                    event.transaction.abort();
                    reject();
                    return;
                  }
                  event.database.createObjectStore(_store);
                } catch (_) {
                  try {
                    event.transaction.abort();
                  } catch (_) {/* Already terminal. */}
                  reject();
                }
              })
          .then<void>((database) {
        timer.cancel();
        if (abandoned || ready.isCompleted) {
          database.close();
        } else {
          ready.complete(database);
        }
      }, onError: (Object _) {
        timer.cancel();
        reject();
      });
    } catch (_) {
      timer.cancel();
      reject();
    }
    return ready.future;
  }

  Future<T> _transaction<T>(idb.Database database, String mode,
      Future<T> Function(idb.ObjectStore) action) async {
    final transaction = database.transaction(_store, mode);
    final terminal = Completer<bool>();
    void settle(bool committed) {
      if (!terminal.isCompleted) terminal.complete(committed);
    }

    transaction.completed
        .then<void>((_) => settle(true), onError: (Object _) => settle(false));
    void abort() {
      try {
        transaction.abort();
      } catch (_) {/* Already terminal. */}
      settle(false);
    }

    final work = () async {
      try {
        final store = transaction.objectStore(_store);
        if (store.keyPath != null ||
            store.autoIncrement != false ||
            store.indexNames.isNotEmpty != false) throw _storageFailure;
        // Await only this transaction's native requests, never external I/O.
        final result = await action(store);
        if (!await terminal.future) throw _storageFailure;
        return result;
      } catch (_) {
        abort();
        rethrow;
      }
    }();
    return work.timeout(_wait, onTimeout: () {
      abort();
      throw _storageFailure;
    });
  }
}
