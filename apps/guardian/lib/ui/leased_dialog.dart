import 'package:flutter/material.dart';

import 'dialog_access.dart';
import 'owned_dialog_route.dart';

/// Each dialog has a lease on the caller's original route and access scope.
Future<T?> leasedDialog<T>(BuildContext context,
    {required Listenable accessChanges,
    required bool Function() hasAccess,
    required Widget Function(
            BuildContext, OwnedDialogRoute<T>, DialogAccessBinding)
        builder}) async {
  if (!context.mounted || !hasAccess()) return null;
  final access = DialogAccessBinding(context,
      accessChanges: accessChanges, hasAccess: hasAccess);
  var live = true;
  late final OwnedDialogRoute<T> route;
  void observe() {
    if (live && !access.permitted() && route.available) route.finish();
  }

  try {
    if (!access.permitted()) return null;
    route = OwnedDialogRoute<T>(
        context: context,
        barrierDismissible: false,
        builder: (dialog) => AnimatedBuilder(
            animation: Listenable.merge([accessChanges, access.changes]),
            builder: (_, __) => access.permitted()
                ? builder(dialog, route, access)
                : const SizedBox.shrink()));
    accessChanges.addListener(observe);
    access.changes.addListener(observe);
    access.parent?.popped.then((_) {
      if (live) observe();
    });
    final parent = access.parent;
    if (parent != null) {
      // Raw removeRoute does not complete popped on the supported Flutter SDK.
      parent.completed.then((_) {
        if (live) observe();
      });
    }
    final value = await presentOwnedDialog(context, route);
    return access.permitted() ? value : null;
  } finally {
    live = false;
    accessChanges.removeListener(observe);
    access.changes.removeListener(observe);
    access.dispose();
  }
}
