import 'package:device_cleanup/device_cleanup.dart';
import 'package:device_identity/device_identity.dart';
import '../platform/cleanup_executor.dart';
import '../platform/secret_store.dart';
import 'environment.dart';

/// Invoked before the child session opens any local cache. It never treats an
/// ordinary API 401 as a cleanup command: the server must supply a signed,
/// bound AGENT_CLEANUP document through the independent original-key channel.
class ChildCleanupRunner {
  final ChildEnvironment environment;
  final DeviceIdentityManager identity;
  final AndroidIdentityStore secureStore;
  final bool Function() ownersClosed;
  final int Function() nowMillis;

  ChildCleanupRunner(
      {required this.environment,
      required this.identity,
      required this.secureStore,
      required this.ownersClosed,
      required this.nowMillis});

  Future<CleanupRunStage?> runOnce() async {
    if (!ownersClosed()) {
      throw const CleanupFailure('CLEANUP_NOT_QUIESCENT');
    }
    DeviceIdentityView view;
    try {
      view = await identity.view();
    } on DeviceIdentityFailure catch (failure) {
      if (failure.code == 'IDENTITY_NOT_FOUND') return null;
      rethrow;
    }
    if (view.deviceId == null ||
        view.registrationId == null ||
        view.phase == IdentityPhase.awaitingConfirmation) return null;

    final pending = await identity.cleanupPendingBinding();
    if (pending != null) {
      final recoveryScope = CleanupScope(pending.tenantId, pending.deviceId,
          pending.registrationId, pending.keyThumbprint);
      if (await CleanupReceiptJournal.finalKeyRemovalReady(
          scope: recoveryScope,
          commandHash: pending.commandHash,
          store: AndroidCleanupRecordStore(recoveryScope))) {
        await identity.finishAgentCleanup(
            tenantId: pending.tenantId,
            deviceId: pending.deviceId,
            registrationId: pending.registrationId,
            keyThumbprint: pending.keyThumbprint,
            commandHash: pending.commandHash);
        return CleanupRunStage.keyRemoved;
      }
    }

    final proof = await identity.cleanupProof(action: 'READ');
    final scope = CleanupScope(view.tenantId, view.deviceId!,
        view.registrationId!, proof.keyThumbprint);
    final client = CleanupCommandClient(
        scope: scope,
        apiRoot: environment.apiRoot,
        allowLoopbackHttp: environment.allowLoopbackHttp,
        timeout: const Duration(seconds: 4),
        nowMillis: nowMillis,
        proofFactory: (action, operationId) =>
            identity.cleanupProof(action: action, operationId: operationId));
    try {
      return await CleanupCoordinator(
              client: client,
              journal: CleanupReceiptJournal(
                  scope: scope,
                  store: AndroidCleanupRecordStore(scope),
                  nowMillis: nowMillis),
              executor: AndroidAgentCleanupExecutor(
                  identity: identity,
                  secureStore: secureStore,
                  ownersClosed: ownersClosed))
          .runOnce();
    } on CleanupFailure catch (failure) {
      if (failure.code == 'CLEANUP_NOT_AVAILABLE' &&
          view.phase != IdentityPhase.cleanupPending &&
          !view.cloudAuthenticationBlocked) {
        return null;
      }
      rethrow;
    } finally {
      client.close();
    }
  }
}
