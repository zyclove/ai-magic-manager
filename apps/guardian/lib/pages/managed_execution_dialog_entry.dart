import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/api.dart';
import '../core/browser_execution_operation_journal.dart';
import '../core/execution_operation_journal.dart';
import '../core/managed_execution.dart';
import '../core/managed_execution_repository.dart';
import '../core/managed_execution_review.dart';
import '../core/managed_execution_review_repository.dart';
import '../core/session.dart';
import '../ui/managed_execution_controller.dart';
import '../ui/managed_execution_dialog.dart';
import '../ui/managed_execution_review_controller.dart';
import '../ui/owned_dialog_route.dart';
import 'device_subflow_scope.dart';

/// Captures the initiating account, workspace, role, device/registration and
/// route lifetime before the first asynchronous operation. Nothing replays on
/// return from authentication; a newly opened view recovers its durable slot.
Future<void> openManagedExecutions(BuildContext context, Session session,
    {required String deviceId,
    required String registrationId,
    required String deviceName,
    required bool Function() current,
    Listenable? targetChanges,
    bool readOnly = false,
    ExecutionOperationJournal? journal}) async {
  if (!session.authenticated) throw const ApiFailure(401, 'UNAUTHENTICATED');
  if (!canReadManagedExecutions(session.role)) {
    throw const ApiFailure(403, 'ACCESS_DENIED');
  }
  final tenantId = session.tenant?['id'], actorId = session.profile?['subject'];
  final parentRoute = ModalRoute.of(context);
  if (!context.mounted ||
      parentRoute?.isActive != true ||
      tenantId is! String ||
      actorId is! String ||
      !current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  var journeyLive = true, viewLive = true, finishing = false, installed = false;
  var reauthRequested = false;
  late final OwnedDialogRoute<void> route;
  bool parentAuthorized() =>
      context.mounted && parentRoute!.isActive && current();
  final scope = DeviceSubflowScope(session,
      permitted: () =>
          journeyLive &&
          parentAuthorized() &&
          canReadManagedExecutions(session.role));
  bool viewCurrent() =>
      viewLive && !finishing && scope.current && (!installed || route.isActive);
  ManagedExecutionController? owned;
  ManagedExecutionReviewController? ownedReview;

  void invalidateView() {
    viewLive = false;
    ownedReview?.detach();
    owned?.checkScope();
  }

  void parentChanged() {
    if (!scope.current) {
      reauthRequested = false;
      invalidateView();
    }
  }

  scope.addListener(parentChanged);
  targetChanges?.addListener(parentChanged);
  parentRoute!.popped.then((_) {
    if (journeyLive) {
      reauthRequested = false;
      invalidateView();
    }
  });
  try {
    if (!scope.current) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    final writable = !readOnly && canManageManagedExecutions(scope.role);
    final controller = ManagedExecutionController(
        repository: ManagedExecutionRepository(
            api: scope.api,
            tenantId: tenantId,
            deviceId: deviceId,
            registrationId: registrationId,
            writable: writable,
            current: viewCurrent),
        registrationId: registrationId);
    owned = controller;
    final owner = ExecutionOperationOwner(
        actorId: actorId,
        tenantId: tenantId,
        apiBaseUrl: scope.api.baseUrl,
        issuer: Session.issuer);
    // Browser storage is opened only when a writable current task is selected.
    final operationJournal = journal ?? BrowserExecutionOperationJournal();
    final changes =
        Listenable.merge([scope, if (targetChanges != null) targetChanges]);
    bool ownRouteCurrent() =>
        installed && !finishing && route.available && route.isCurrent;
    void close() {
      if (finishing) return;
      finishing = true;
      invalidateView(); // Permanent detach precedes route removal, even covered.
      route.finish();
    }

    void reauthenticate() {
      if (!ownRouteCurrent() || !viewCurrent() || !parentAuthorized()) return;
      final operation = ownedReview;
      if (controller.needsReauth) {
        operation?.detach();
      } else if (operation != null) {
        if (!operation.requestStepUp()) return;
      } else {
        return;
      }
      reauthRequested = true;
      close();
    }

    ManagedExecutionReviewController makeReview(
        ManagedExecution selected,
        bool Function() selectedViewCurrent,
        int Function() latestEventRevision) {
      if (!writable ||
          selected.registrationId != registrationId ||
          !viewCurrent()) {
        throw const ApiFailure(409, 'WORKSPACE_CHANGED');
      }
      ownedReview?.detach();
      final value = ManagedExecutionReviewController(
          requests: ManagedExecutionReviewRepository(
              api: scope.api,
              owner: owner,
              deviceId: deviceId,
              registrationId: registrationId,
              writable: writable,
              current: () => journeyLive && scope.current),
          journal: operationJournal,
          selected: selected,
          viewCurrent: () => viewCurrent() && selectedViewCurrent(),
          operationId: () => const Uuid().v4(),
          now: () => DateTime.now().millisecondsSinceEpoch,
          latestEventRevision: latestEventRevision,
          onProgress: (_) {
            /* The dialog renders the verified operation projection.
          List and timeline remain explicit reads; no request attribution. */
          });
      ownedReview = value;
      return value;
    }

    route = OwnedDialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ManagedExecutionDialog(
            controller: controller,
            reviewFactory: writable ? makeReview : null,
            deviceName: deviceName,
            accessChanges: changes,
            onClose: close,
            onReauth: reauthenticate));
    final popped = Navigator.of(context, rootNavigator: true).push<void>(route);
    installed = true;
    route.popped.then((_) {
      if (journeyLive) invalidateView();
    });
    await popped;
    invalidateView();
    await route.completed;
    // Keep authority scope alive until the owned transition is fully removed,
    // then recheck the originating route and permanent session generation.
    if (reauthRequested &&
        scope.current &&
        parentAuthorized() &&
        parentRoute.isCurrent) {
      session.login(stepUp: true);
    }
  } finally {
    viewLive = false;
    journeyLive = false;
    reauthRequested = false;
    scope.removeListener(parentChanged);
    targetChanges?.removeListener(parentChanged);
    ownedReview?.detach();
    owned?.dispose();
    scope.dispose();
  }
}
