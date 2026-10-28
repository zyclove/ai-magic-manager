import 'package:flutter/material.dart';
import 'design.dart';
import 'owned_dialog_route.dart';

class DialogAccessBinding {
  final BuildContext context;
  final ModalRoute<dynamic>? parent;
  final Listenable? accessChanges;
  final bool Function()? hasAccess;
  final _changed = ValueNotifier<bool>(false);
  Listenable get changes => _changed;
  bool live = true, allowed = true, parentClosed = false;
  bool _revocationQueued = false, _revocationPublished = false;
  bool _listening = false;

  DialogAccessBinding(this.context, {this.accessChanges, this.hasAccess})
      : parent = ModalRoute.of(context) {
    _observeAccess();
    if (allowed && accessChanges != null) {
      accessChanges!.addListener(_observeAccess);
      _listening = true;
    }
    parent?.popped.then<void>((_) => _parentFinished());
    // Raw removeRoute does not complete popped on every supported Flutter SDK.
    parent?.completed.then<void>((_) => _parentFinished());
  }

  void _parentFinished() {
    if (!live) return;
    parentClosed = true;
    _observeAccess();
  }

  bool permitted() {
    if (!live ||
        !context.mounted ||
        parentClosed ||
        (parent != null && !parent!.isActive) ||
        (parent is OwnedDialogRoute<dynamic> &&
            !(parent as OwnedDialogRoute<dynamic>).available) ||
        (hasAccess != null && !hasAccess!())) allowed = false;
    if (!allowed) _scheduleRevocation();
    return allowed;
  }

  void _scheduleRevocation() {
    if (!live || _revocationQueued || _revocationPublished) return;
    _revocationQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revocationQueued = false;
      if (!live || _revocationPublished) return;
      _revocationPublished = true;
      _changed.value = true;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _observeAccess() {
    permitted();
  }

  void dispose() {
    live = false;
    if (_listening) {
      _listening = false;
      accessChanges!.removeListener(_observeAccess);
    }
    _changed.dispose();
  }
}

Future<void> scopedDetailsDialog(
    BuildContext context, String title, Map<String, dynamic> values,
    {List<DetailAction> actions = const [],
    VoidCallback? reauth,
    Listenable? accessChanges,
    bool Function()? hasAccess,
    Widget? extraContent,
    bool closeOnAccessLost = false}) async {
  if (!context.mounted || hasAccess?.call() == false) return;
  final access = DialogAccessBinding(context,
      accessChanges: accessChanges, hasAccess: hasAccess);
  try {
    if (!access.permitted()) return;
    await actionDetails(context, title, values,
        actions: actions,
        reauth: reauth == null
            ? null
            : () {
                if (access.permitted()) reauth();
              },
        accessChanges: access.changes,
        hasAccess: access.permitted,
        extraContent: extraContent,
        closeOnAccessLost: closeOnAccessLost);
  } finally {
    access.dispose();
  }
}
