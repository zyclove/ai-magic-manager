import 'package:flutter/material.dart';

/// A resource action retains its original owner until its complete flow ends.
class ResourceActionLease extends ChangeNotifier {
  final bool Function() _isCurrent;
  bool _retired = false, _disposed = false;
  bool _notificationQueued = false, _notified = false;
  ResourceActionLease({required bool Function() isCurrent})
      : _isCurrent = isCurrent;

  bool get current {
    if (_disposed || _retired) return false;
    if (!_isCurrent()) retire();
    return !_retired;
  }

  /// Stop old work synchronously; notify dialogs after the current tree update.
  void retire() {
    if (_disposed || _retired) return;
    _retired = true;
    if (_notificationQueued || _notified) return;
    _notificationQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationQueued = false;
      if (_disposed || _notified) return;
      _notified = true;
      notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retired = true;
    super.dispose();
  }
}
