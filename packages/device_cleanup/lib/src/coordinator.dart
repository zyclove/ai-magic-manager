import 'journal.dart';
import 'models.dart';
import 'receipt.dart';
import 'transport.dart';
import 'verifier.dart';

/// A platform implementation may delete only this application's policy and
/// usage caches and ordinary business bearer. It must preserve the journal
/// and original registration key until the final server acknowledgement.
/// Both operations must be idempotent across process death and power loss.
abstract interface class AgentCleanupExecutor {
  Future<void> clearOwnData(VerifiedCleanupCommand command);
  Future<void> removeOriginalKey(VerifiedCleanupCommand command);
}

/// Fixed server reason code, never a raw storage or SDK exception message.
class AgentCleanupFailure implements Exception {
  final String reasonCode;
  AgentCleanupFailure(this.reasonCode) {
    if (!const {
      'STORAGE_FAILURE',
      'KEY_UNAVAILABLE',
      'UNSUPPORTED_AGENT',
      'USER_ACTION_REQUIRED'
    }.contains(reasonCode)) {
      throw ArgumentError('Invalid cleanup failure reason');
    }
  }
  @override
  String toString() => 'AgentCleanupFailure($reasonCode)';
}

enum CleanupRunStage {
  localClearFailed,
  keyRemoved,
}

/// One bounded foreground attempt. A failed or unknown network result leaves
/// the durable journal in place for a later run of the same signed command.
/// Calling this requires a real host executor; there is no no-op default.
class CleanupCoordinator {
  final CleanupCommandClient client;
  final CleanupReceiptJournal journal;
  final AgentCleanupExecutor executor;
  bool _busy = false;

  CleanupCoordinator(
      {required this.client, required this.journal, required this.executor});

  Future<CleanupRunStage> runOnce() async {
    if (_busy) throw const CleanupFailure('CLEANUP_ALREADY_RUNNING');
    _busy = true;
    try {
      final command = await client.fetchAndVerify();
      var state = await journal.load(command);

      // A request may have reached the server even when its response was lost.
      // Replay its exact persisted body before advancing to another stage.
      if (state.pending != null) {
        state = await _send(state.pending!);
        if (state.pending != null) {
          throw const CleanupFailure('CLEANUP_RECEIPT_PENDING');
        }
      }
      if (!state.receivedAcknowledged) {
        state =
            await _send(await journal.prepare(CleanupReceiptStage.received));
      }

      if (!state.localDataCleared) {
        try {
          await executor.clearOwnData(command);
        } on AgentCleanupFailure catch (failure) {
          if (state.failureAcknowledged) {
            return CleanupRunStage.localClearFailed;
          }
          await _send(await journal.prepare(CleanupReceiptStage.failed,
              reasonCode: failure.reasonCode));
          return CleanupRunStage.localClearFailed;
        } catch (_) {
          // Never copy native exception text, paths or secret material into a
          // receipt. A partial clear is retried by the idempotent executor.
          if (state.failureAcknowledged) {
            return CleanupRunStage.localClearFailed;
          }
          await _send(await journal.prepare(CleanupReceiptStage.failed,
              reasonCode: 'STORAGE_FAILURE'));
          return CleanupRunStage.localClearFailed;
        }
        await journal.markLocalDataCleared();
        state = journal.view;
      }
      if (!state.cleanupAcknowledged) {
        state = await _send(
            await journal.prepare(CleanupReceiptStage.agentDataCleared));
      }
      if (!state.cleanupAcknowledged) {
        throw const CleanupFailure('CLEANUP_ACK_INVALID');
      }

      // Only an acknowledged local-clear receipt permits key removal. The
      // executor must durably delete the original key and ordinary identity
      // state, but must not claim system unenrollment or whole-device wipe.
      await executor.removeOriginalKey(command);
      return CleanupRunStage.keyRemoved;
    } finally {
      _busy = false;
    }
  }

  Future<CleanupJournalView> _send(CleanupReceipt receipt) async {
    final ack = await client.submitReceipt(receipt);
    return journal.acknowledge(receipt, ack);
  }
}
