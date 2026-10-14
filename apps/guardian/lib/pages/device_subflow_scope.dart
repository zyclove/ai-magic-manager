import 'package:flutter/foundation.dart';
import '../core/api.dart';
import '../core/session.dart';

/// One device journey owns this capture until its dialog or page is disposed.
/// Listen synchronously so an away-and-back change between frames stays lost.
class DeviceSubflowScope extends ChangeNotifier {
  final Session session;
  final int generation;
  final Object? actorId, tenantId;
  final String role;
  final bool Function() _permitted;
  late final Api api;
  bool _lost = false, _disposed = false;

  DeviceSubflowScope(this.session, {required bool Function() permitted})
      : generation = session.scopeGeneration,
        actorId = session.profile?['subject'],
        tenantId = session.tenant?['id'],
        role = session.role,
        _permitted = permitted {
    _lost = !_matches();
    api = session.api.scoped(() => current);
    session.addListener(_sessionChanged);
  }

  bool _matches() =>
      session.authenticated &&
      session.scopeGeneration == generation &&
      session.profile?['subject'] == actorId &&
      session.tenant?['id'] == tenantId &&
      session.role == role &&
      _permitted();

  bool get current {
    if (_disposed || _lost) return false;
    if (!_matches()) _lost = true;
    return !_lost;
  }

  void _sessionChanged() {
    if (_disposed) return;
    if (!current) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    session.removeListener(_sessionChanged);
    super.dispose();
  }
}
