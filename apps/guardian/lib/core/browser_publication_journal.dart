import 'dart:async';
import 'package:idb_shim/idb.dart' as idb;
import 'package:idb_shim/idb_client_native.dart' as native;

import 'api.dart';
import 'policy_publication.dart';
import 'publication_journal.dart';

/// Each call owns its connection. The durable UNKNOWN record, capacity check,
/// and attempt fence share one readwrite transaction across all browser tabs.
/// Storage failures never grant submission and never fall back to memory.
class BrowserPublicationJournal implements PublicationJournal {
  static const defaultDatabaseName = 'ai-manager.guardian.publications.v1';
  static const _store = 'pending';
  static const _wait = Duration(seconds: 5);
  final String databaseName;

  BrowserPublicationJournal({this.databaseName = defaultDatabaseName});

  static const _storageFailure =
      ApiFailure(503, 'PUBLICATION_STORAGE_UNAVAILABLE');
  static const _changed = ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
  static const _invalidRecord =
      ApiFailure(409, 'INVALID_POLICY_PUBLICATION_RECORD');

  // Owner keys contain only base64url. Opaque policy IDs prohibit controls, so
  // this delimiter is unambiguous and the range includes exactly one owner.
  String _key(PublicationOwner owner, String policyId) =>
      '${owner.key}\u0000$policyId';

  // The leading ! is outside base64url owner keys. Terminal fences share the
  // same physical store/transaction, but never occupy pending capacity.
  String _terminalKey(PublicationIntent intent) =>
      '!terminal\u0000${_key(intent.owner, intent.policyId)}\u0000'
      '${publicationRequestDigest(intent)}';

  Future<PublicationTerminalMarker?> _getTerminal(
      idb.ObjectStore store, PublicationIntent intent) async {
    final key = _terminalKey(intent);
    final raw = await store.getObject(key);
    if (raw == null && await store.count(key) == 0) return null;
    if (raw is! String) throw _invalidRecord;
    return PublicationTerminalMarker.decode(raw, intent: intent);
  }

  PublicationPending _terminalRecord(PublicationIntent intent,
      PublicationTerminalMarker marker, {int attempt = 1}) =>
      PublicationPending(intent: intent, phase: marker.reason.phase,
          attempt: attempt, confirmedSuccess: marker.confirmedSuccess);

  @override
  Future<PublicationPending?> read(PublicationOwner owner, String policyId) {
    if (!isPublicationOpaqueId(policyId)) {
      return Future.error(
          const ApiFailure(400, 'INVALID_POLICY_PUBLICATION_INTENT'));
    }
    return _withDatabase((database) => _read(database, owner, policyId));
  }

  @override
  Future<PublicationReservation> reserve(PublicationIntent intent) async {
    final next = PublicationPending(intent: intent);
    final encoded = next.encode();
    return _withDatabase((database) async {
      final reservation =
          await _transaction(database, 'readwrite', (store) async {
        final marker = await _getTerminal(store, intent);
        final current = await _get(store, intent.owner, intent.policyId);
        if (current != null) {
          if (marker != null && current.intent.idempotencyKey == intent.idempotencyKey) {
            throw _invalidRecord;
          }
          return PublicationReservation(record: current, maySubmit: false);
        }
        if (marker != null) {
          return PublicationReservation(record: _terminalRecord(intent, marker), maySubmit: false);
        }
        final count = await store.count(idb.KeyRange.bound(
            '${intent.owner.key}\u0000',
            '${intent.owner.key}\u0001',
            false,
            true));
        if (count >= publicationMaximumPending) {
          throw const ApiFailure(409, 'PUBLICATION_PENDING_CAPACITY');
        }
        await store.add(encoded, _key(intent.owner, intent.policyId));
        return PublicationReservation(record: next, maySubmit: true);
      });
      return _verifyReservation(database, reservation);
    });
  }

  @override
  Future<PublicationReservation> claimRetry(PublicationPending expected) =>
      _withDatabase((database) async {
        final intent = expected.intent;
        final reservation =
            await _transaction(database, 'readwrite', (store) async {
          final marker = await _getTerminal(store, intent);
          final current = await _get(store, intent.owner, intent.policyId);
          if (marker != null) {
            if (current != null) {
              if (current.intent.idempotencyKey == intent.idempotencyKey) throw _invalidRecord;
              return PublicationReservation(record: current, maySubmit: false);
            }
            return PublicationReservation(record: _terminalRecord(intent, marker,
                attempt: expected.attempt), maySubmit: false);
          }
          if (current == null) throw _changed;
          if (current != expected ||
              expected.phase != PublicationPhase.reauthenticationRequired) {
            return PublicationReservation(record: current, maySubmit: false);
          }
          if (expected.attempt >= publicationMaximumSafeInteger) {
            throw const ApiFailure(409, 'PUBLICATION_ATTEMPT_EXHAUSTED');
          }
          final next =
              PublicationPending(intent: intent, attempt: expected.attempt + 1);
          await store.put(next.encode(), _key(intent.owner, intent.policyId));
          return PublicationReservation(record: next, maySubmit: true);
        });
        return _verifyReservation(database, reservation);
      });

  @override
  Future<PublicationPending> markReauthenticationRequired(
          PublicationPending expected) =>
      _withDatabase((database) async {
        final intent = expected.intent;
        final next = await _transaction(database, 'readwrite', (store) async {
          final current = await _get(store, intent.owner, intent.policyId);
          if (current != expected ||
              expected.phase != PublicationPhase.unknown) {
            throw _changed;
          }
          final denied = PublicationPending(
              intent: intent,
              phase: PublicationPhase.reauthenticationRequired,
              attempt: expected.attempt);
          await store.put(denied.encode(), _key(intent.owner, intent.policyId));
          return denied;
        });
        if (await _read(database, intent.owner, intent.policyId) != next) {
          throw _changed;
        }
        return next;
      });

  @override
  Future<PublicationPending> markResultTerminalIfSame(
      PublicationPending expected, PublicationTerminalReason reason,
      {bool confirmedSuccess = false, bool Function()? isCurrent}) => _withDatabase((database) async {
    void ensureCurrent() {
      if (isCurrent?.call() == false) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
    ensureCurrent();
    final intent = expected.intent;
    var next = PublicationPending(intent: intent, phase: reason.phase,
        attempt: expected.attempt,
        confirmedSuccess: confirmedSuccess || expected.confirmedSuccess);
    await _transaction(database, 'readwrite', (store) async {
      final current = await _get(store, intent.owner, intent.policyId);
      final marker = await _getTerminal(store, intent);
      ensureCurrent();
      if (marker != null) {
        if (current != null) throw _changed;
        final mergedReason = marker.reason == PublicationTerminalReason.erased ||
            reason == PublicationTerminalReason.erased
            ? PublicationTerminalReason.erased : PublicationTerminalReason.expired;
        next = PublicationPending(intent: intent, phase: mergedReason.phase,
            attempt: expected.attempt,
            confirmedSuccess: marker.confirmedSuccess || next.confirmedSuccess);
        if (marker.reason != mergedReason || marker.confirmedSuccess != next.confirmedSuccess) {
          // A late trusted receipt can only strengthen the saved fact. It never
          // restores any payload or reopens the acknowledged original request.
          final strengthened = PublicationTerminalMarker(ownerKey: marker.ownerKey,
              policyId: marker.policyId, requestDigest: marker.requestDigest,
              reason: mergedReason, acknowledgedAt: marker.acknowledgedAt,
              confirmedSuccess: next.confirmedSuccess);
          await store.put(strengthened.encode(), _terminalKey(intent));
          ensureCurrent();
        }
        return;
      }
      if (current == next) return;
      if (current != null && current.phase.terminal &&
          current.intent == expected.intent && current.attempt == expected.attempt) {
        final phase = current.phase == PublicationPhase.resultErased ||
            reason == PublicationTerminalReason.erased
            ? PublicationPhase.resultErased : PublicationPhase.resultExpired;
        next = PublicationPending(intent: intent, phase: phase,
            attempt: expected.attempt,
            confirmedSuccess: current.confirmedSuccess || next.confirmedSuccess);
        await store.put(next.encode(), _key(intent.owner, intent.policyId));
        ensureCurrent();
        return;
      }
      if (current != expected || expected.phase.terminal) throw _changed;
      await store.put(next.encode(), _key(intent.owner, intent.policyId));
      ensureCurrent();
    });
    await _transaction(database, 'readonly', (store) async {
      final current = await _get(store, intent.owner, intent.policyId);
      final marker = await _getTerminal(store, intent);
      ensureCurrent();
      if (marker != null && current == null && marker.reason.phase == next.phase &&
          (!next.confirmedSuccess || marker.confirmedSuccess)) return;
      if (current != next || marker != null) throw _changed;
    });
    return next;
  });

  @override
  Future<PublicationTerminalMarker> acknowledgeTerminalIfSame(
      PublicationPending expected,
      {required int acknowledgedAt, bool Function()? isCurrent}) =>
      _withDatabase((database) async {
    void ensureCurrent() {
      if (isCurrent?.call() == false) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
    ensureCurrent();
    if (!expected.phase.terminal) throw _changed;
    final intent = expected.intent;
    final reason = expected.phase == PublicationPhase.resultExpired
        ? PublicationTerminalReason.expired : PublicationTerminalReason.erased;
    final marker = await _transaction(database, 'readwrite', (store) async {
      final current = await _get(store, intent.owner, intent.policyId);
      final existing = await _getTerminal(store, intent);
      ensureCurrent();
      if (existing != null) {
        if (current != null || existing.reason != reason ||
            (expected.confirmedSuccess && !existing.confirmedSuccess)) throw _changed;
        return existing;
      }
      if (current != expected) throw _changed;
      final next = PublicationTerminalMarker(ownerKey: intent.owner.key,
          policyId: intent.policyId,
          requestDigest: publicationRequestDigest(intent), reason: reason,
          acknowledgedAt: acknowledgedAt,
          confirmedSuccess: expected.confirmedSuccess);
      await store.add(next.encode(), _terminalKey(intent));
      ensureCurrent();
      await store.delete(_key(intent.owner, intent.policyId));
      ensureCurrent();
      return next;
    });
    // Read both sides in one transaction. Another tab's new pending must remain
    // visible; an old acknowledgement cannot erase or claim it is an empty slot.
    await _transaction(database, 'readonly', (store) async {
      final pending = await _get(store, intent.owner, intent.policyId);
      final committed = await _getTerminal(store, intent);
      ensureCurrent();
      if (pending != null || committed != marker) throw _changed;
    });
    return marker;
  });

  @override
  Future<bool> removeIfSame(PublicationPending expected) =>
      _remove(expected, false);

  @override
  Future<bool> cancelNotSubmitted(PublicationPending expected) =>
      _remove(expected, true);

  Future<bool> _remove(
          PublicationPending expected, bool requireReauthentication) =>
      _withDatabase((database) async {
        final intent = expected.intent;
        final removed =
            await _transaction(database, 'readwrite', (store) async {
          final current = await _get(store, intent.owner, intent.policyId);
          if (current != expected ||
              expected.phase.terminal ||
              (requireReauthentication &&
                  expected.phase != PublicationPhase.reauthenticationRequired)) {
            return false;
          }
          await store.delete(_key(intent.owner, intent.policyId));
          return true;
        });
        // A concurrent new reservation must remain visible and must not be
        // mistaken for an empty slot by a successful cancellation handoff.
        final current = await _read(database, intent.owner, intent.policyId);
        return removed && current == null;
      });

  Future<PublicationReservation> _verifyReservation(
      idb.Database database, PublicationReservation reservation) async {
    final intent = reservation.record.intent;
    if (reservation.record.phase.terminal) {
      return _transaction(database, 'readonly', (store) async {
        final committed = await _get(store, intent.owner, intent.policyId);
        final marker = await _getTerminal(store, intent);
        if (committed != null) {
          if (marker != null && committed.intent.idempotencyKey == intent.idempotencyKey) {
            throw _invalidRecord;
          }
          return PublicationReservation(record: committed, maySubmit: false);
        }
        if (marker == null || marker.reason.phase != reservation.record.phase) throw _changed;
        return PublicationReservation(record: _terminalRecord(intent, marker,
            attempt: reservation.record.attempt), maySubmit: false);
      });
    }
    final committed = await _read(database, intent.owner, intent.policyId);
    if (committed == null) throw _changed;
    return PublicationReservation(
        record: committed,
        maySubmit: reservation.maySubmit && committed == reservation.record);
  }

  Future<PublicationPending?> _read(
          idb.Database database, PublicationOwner owner, String policyId) =>
      _transaction(
          database, 'readonly', (store) => _get(store, owner, policyId));

  Future<PublicationPending?> _get(
      idb.ObjectStore store, PublicationOwner owner, String policyId) async {
    final key = _key(owner, policyId);
    final raw = await store.getObject(key);
    if (raw == null && await store.count(key) == 0) return null;
    if (raw is! String) throw _invalidRecord;
    return PublicationPending.decode(raw, owner: owner, policyId: policyId);
  }

  Future<T> _withDatabase<T>(Future<T> Function(idb.Database) action) async {
    idb.Database? database;
    StreamSubscription<idb.VersionChangeEvent>? changes;
    try {
      database = await _open();
      final opened = database;
      changes = opened.onVersionChange.listen((_) => opened.close());
      if (opened.version != 1 ||
          opened.objectStoreNames.length != 1 ||
          opened.objectStoreNames.single != _store) throw _storageFailure;
      return await action(opened);
    } on ApiFailure {
      rethrow;
    } catch (_) {
      // Do not expose browser exceptions, persisted content or other actors.
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
                  final database = event.database;
                  database.createObjectStore(_store);
                } catch (_) {
                  try {
                    event.transaction.abort();
                  } catch (_) {/* Already aborted. */}
                  reject();
                }
              })
          .then<void>((database) {
        timer.cancel();
        if (abandoned || ready.isCompleted) {
          // An open request cannot be cancelled through this SDK. Its late
          // connection is still ours and must not block future database work.
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
    // This settled Future always completes with a value. Register all event
    // handlers before issuing a request, so aborts cannot become unhandled
    // asynchronous errors while the request Future is still being awaited.
    final terminal = Completer<bool>();
    void settle(bool committed) {
      if (!terminal.isCompleted) terminal.complete(committed);
    }

    // idb_shim exposes only completed/abort, not DOM transaction streams.
    // Attach both handlers immediately before issuing any store request.
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
        // Only requests belonging to this transaction may be awaited here.
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
