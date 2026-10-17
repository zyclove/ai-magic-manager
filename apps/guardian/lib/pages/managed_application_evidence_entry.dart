import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/managed_agent_binding.dart';
import '../core/managed_application_evidence.dart';
import '../core/session.dart';
import '../ui/managed_application_evidence_controller.dart';
import '../ui/managed_application_evidence_dialog.dart';
import '../ui/owned_dialog_route.dart';
import 'device_subflow_scope.dart';

bool _canRead(Session session) =>
    session.authenticated &&
    session.tenant?['kind'] == 'ORGANIZATION' &&
    const {'OWNER', 'ORG_ADMIN'}.contains(session.role);

/// One fixed binding in its parent's current identity and authorization scope.
/// The shared HTTP client is borrowed; closing never replays a refresh request.
Future<void> showManagedApplicationEvidence(
  BuildContext context,
  Session session,
  ManagedAgentBinding binding, {
  required bool Function() parentCurrent,
  Listenable? parentChanges,
  VoidCallback? onParentRefresh,
}) async {
  if (!session.authenticated) {
    throw const ApiFailure(401, 'UNAUTHENTICATED');
  }
  if (!_canRead(session)) {
    throw const ApiFailure(403, 'ACCESS_DENIED');
  }
  final tenant = session.tenant?['id'];
  if (!context.mounted ||
      tenant is! String ||
      !isAgentBindingId(tenant) ||
      !parentCurrent() ||
      binding.state != 'VERIFIED' ||
      binding.verifiedAt == null) {
    throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  // Scope observation outlives the closing animation. The request view is
  // revoked at once; an explicit handoff is rechecked when the route completes.
  var journeyLive = true, viewLive = true, finishing = false;
  var refreshRequested = false, reauthRequested = false;
  final scope = DeviceSubflowScope(session,
      permitted: () =>
          journeyLive &&
          context.mounted &&
          parentCurrent() &&
          _canRead(session));
  ManagedApplicationEvidenceController? owned;

  void parentChanged() {
    // Reading scope.current synchronously permanently observes an ABA change,
    // even before the first route frame or during the closing transition.
    if (!scope.current) {
      refreshRequested = false;
      reauthRequested = false;
      owned?.invalidate();
    }
  }

  parentChanges?.addListener(parentChanged);
  try {
    if (!scope.current) {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
    final changes =
        Listenable.merge([scope, if (parentChanges != null) parentChanges]);
    final controller = ManagedApplicationEvidenceController(
        repository: ManagedApplicationEvidenceRepository(
            api: scope.api,
            tenantId: tenant,
            binding: binding,
            current: () => journeyLive && scope.current,
            // The controller's scoped repository owns the denial transition.
            onDenied: (_) {}),
        current: () => viewLive && scope.current,
        accessChanges: changes);
    owned = controller;
    late final OwnedDialogRoute<void> route;

    bool mayHandoff() =>
        viewLive &&
        !finishing &&
        route.available &&
        route.isCurrent &&
        scope.current &&
        controller.hasAccess;

    void close() {
      if (finishing) {
        return;
      }
      finishing = true;
      viewLive = false;
      controller.invalidate();
      route.finish();
    }

    route = OwnedDialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ManagedApplicationEvidenceDialog(
            controller: controller,
            onClose: close,
            reauthenticate: () {
              if (!mayHandoff() || controller.busy || !controller.needsReauth) {
                return;
              }
              reauthRequested = true;
              close();
            },
            onParentRefresh: onParentRefresh == null
                ? null
                : () {
                    if (!mayHandoff() ||
                        controller.busy ||
                        !controller.needsParentRefresh) {
                      return;
                    }
                    refreshRequested = true;
                    close();
                  }));
    // Also close request permission for keyboard/back navigation as soon as
    // popped settles, before waiting for the route's reverse animation.
    unawaited(route.popped.then<void>((_) {
      viewLive = false;
      controller.invalidate();
    }));
    await presentOwnedDialog(context, route);
    viewLive = false;
    controller.invalidate();
    if (context.mounted && scope.current) {
      if (refreshRequested) {
        onParentRefresh?.call();
      } else if (reauthRequested) {
        session.login(stepUp: true);
      }
    }
  } finally {
    viewLive = false;
    journeyLive = false;
    parentChanges?.removeListener(parentChanged);
    owned?.dispose();
    scope.dispose();
  }
}
