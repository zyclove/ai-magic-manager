import 'package:flutter/material.dart';

/// Completes and removes only this dialog, even when another dialog covers it.
class OwnedDialogRoute<T> extends DialogRoute<T> {
  bool _finished = false;

  OwnedDialogRoute(
      {required super.context,
      required super.builder,
      super.barrierDismissible = true,
      super.useSafeArea = true})
      : super(
            themes: InheritedTheme.capture(
                from: context,
                to: Navigator.of(context, rootNavigator: true).context));

  bool get available => !_finished && isActive && navigator != null;

  void finish([T? result]) {
    final owner = navigator;
    if (!available || owner == null) return;
    if (isCurrent) {
      owner.pop<T>(result);
    } else {
      // Flutter 3.22 removeRoute does not complete Route.popped.
      didComplete(result);
      owner.removeRoute(this);
    }
  }

  @override
  void didComplete(T? result) {
    if (_finished) return;
    _finished = true;
    super.didComplete(result);
  }

  @override
  void dispose() {
    if (!_finished) didComplete(null);
    super.dispose();
  }
}

Future<T?> presentOwnedDialog<T>(
    BuildContext context, OwnedDialogRoute<T> route) async {
  final result =
      await Navigator.of(context, rootNavigator: true).push<T>(route);
  // Preserve popped's result; covered removal has no TransitionRoute result.
  await route.completed;
  return result;
}
