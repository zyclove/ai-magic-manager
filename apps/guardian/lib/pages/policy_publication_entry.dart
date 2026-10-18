import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/policy_publication.dart';
import '../core/policy_publication_repository.dart';
import '../core/publication_journal.dart';
import '../ui/owned_dialog_route.dart';
import '../ui/policy_publication_controller.dart';
import '../ui/policy_publication_dialog.dart';

/// Local recovery failure must explain why publishing is paused, without
/// exposing stored payloads or reducing it to a generic input error.
class PublicationLocalRecoveryUnavailable implements Exception {
  const PublicationLocalRecoveryUnavailable();

  @override
  String toString() => '本地记录暂不能核对，保存已暂停。请重新打开后重试。';
}

/// Owns one publication dialog and its closing animation. The parent owns the
/// authority scope from before its first await; this entry never captures a new
/// session scope or closes the borrowed HTTP client.
Future<bool> showPolicyPublication(
  BuildContext context, {
  required PublicationRequests repository,
  required PublicationJournal journal,
  required PublicationIntent intent,
  PublicationPending? pending,
  Json? preview,
  Map<String, String> names = const {},
  String? selectionSummary,
  required bool Function() parentCurrent,
  Listenable? accessChanges,
  Future<void> Function()? preflight,
  required VoidCallback reauthenticate,
}) async {
  final parentRoute = ModalRoute.of(context);
  if (!context.mounted ||
      parentRoute == null ||
      !parentRoute.isActive ||
      !parentCurrent()) {
    throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  var viewLive = true, finishing = false, routeInstalled = false;
  var reauthRequested = false, repreviewRequested = false;
  late final OwnedDialogRoute<void> route;

  bool parentAuthorized() =>
      context.mounted && parentRoute.isActive && parentCurrent();
  bool current() =>
      viewLive &&
      !finishing &&
      parentAuthorized() &&
      (!routeInstalled || route.isActive);

  // The constructor checks current synchronously. Before push there is no
  // installed child route, so routeInstalled must still be false here.
  late final PolicyPublicationController controller;
  controller = PolicyPublicationController(
      repository: repository,
      journal: journal,
      intent: intent,
      pending: pending,
      current: current,
      accessChanges: accessChanges,
      preflight: preflight == null
          ? null
          : () async {
              if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
              // Another tab can win reserve and make the controller adopt a different
              // original intent. Never check that intent against this journey's new
              // group selection; controller/repository still guard its actual TTL and
              // the server rechecks the original immutable snapshot.
              if (controller.intent == intent) await preflight();
            });

  unawaited(parentRoute.popped.then<void>((_) {
    // Clear the private view when its parent actually leaves. Keep the child's
    // own close action available; this callback never operates the Navigator.
    if (viewLive && !finishing) controller.invalidate();
  }));

  bool ownRouteCurrent() =>
      routeInstalled &&
      viewLive &&
      !finishing &&
      route.available &&
      route.isCurrent;

  void close() {
    // Closing a revoked view is allowed, but a captured parent callback cannot
    // close an independent dialog which now covers this one.
    if (!ownRouteCurrent() || controller.busy) return;
    finishing = true;
    viewLive = false;
    controller.invalidate();
    route.finish();
  }

  try {
    route = OwnedDialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PolicyPublicationDialog(
            controller: controller,
            preview: preview,
            names: names,
            selectionSummary: selectionSummary,
            onClose: close,
            reauthenticate: () {
              if (!ownRouteCurrent() ||
                  !parentAuthorized() ||
                  controller.busy ||
                  !controller.hasAccess ||
                  !controller.needsReauth) return;
              reauthRequested = true;
              close();
            },
            onRepreview: () {
              // The dialog has already awaited exact not-submitted cancellation
              // when needed. Unknown pending records can never take this path.
              if (!ownRouteCurrent() ||
                  !parentAuthorized() ||
                  controller.busy ||
                  !controller.hasAccess ||
                  controller.pending != null ||
                  !controller.canRepreview) return;
              repreviewRequested = true;
              close();
            }));
    unawaited(route.popped.then<void>((_) {
      // A successful system pop must never request another Navigator pop.
      viewLive = false;
      finishing = true;
      controller.invalidate();
    }));
    final popped = Navigator.of(context, rootNavigator: true).push<void>(route);
    routeInstalled = true;
    await popped;
    await route.completed;
    viewLive = false;
    finishing = true;
    controller.invalidate();
    if (!parentAuthorized() || !parentRoute.isCurrent) return false;
    if (reauthRequested) {
      reauthenticate();
      return false;
    }
    return repreviewRequested;
  } finally {
    viewLive = false;
    finishing = true;
    controller.dispose();
  }
}
