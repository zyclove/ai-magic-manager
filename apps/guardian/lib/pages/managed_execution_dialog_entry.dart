import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/managed_execution.dart';
import '../core/managed_execution_repository.dart';
import '../core/session.dart';
import '../ui/managed_execution_controller.dart';
import '../ui/managed_execution_dialog.dart';
import 'device_subflow_scope.dart';

/// A single immutable device/registration target in the originating session.
/// Association-based access is read-only; device details may grant management.
Future<void> openManagedExecutions(BuildContext context, Session session,
    {required String deviceId,
    required String registrationId,
    required String deviceName,
    required bool Function() current,
    Listenable? targetChanges,
    bool readOnly = false}) async {
  if (!session.authenticated) {
    throw const ApiFailure(401, 'UNAUTHENTICATED');
  }
  if (!canReadManagedExecutions(session.role)) {
    throw const ApiFailure(403, 'ACCESS_DENIED');
  }
  final tenantId = session.tenant?['id'];
  if (!context.mounted || tenantId is! String || !current()) {
    throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }
  var live = true;
  final scope = DeviceSubflowScope(session,
      permitted: () =>
          live &&
          context.mounted &&
          current() &&
          canReadManagedExecutions(session.role));
  ManagedExecutionController? owned;
  // Observe parent loss before the first route builder starts listening.
  // Querying scope.current permanently latches an away-and-back change.
  void targetChanged() {
    if (!scope.current) {
      owned?.checkScope();
    }
  }

  targetChanges?.addListener(targetChanged);
  try {
    if (!scope.current) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    final controller = ManagedExecutionController(
        repository: ManagedExecutionRepository(
            api: scope.api,
            tenantId: tenantId,
            deviceId: deviceId,
            registrationId: registrationId,
            writable: !readOnly && canManageManagedExecutions(scope.role),
            current: () => live && scope.current),
        registrationId: registrationId);
    owned = controller;
    final changes =
        Listenable.merge([scope, if (targetChanges != null) targetChanges]);
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (inner) => ManagedExecutionDialog(
            controller: controller,
            deviceName: deviceName,
            accessChanges: changes,
            onClose: () {
              if (inner.mounted && ModalRoute.of(inner)?.isCurrent == true) {
                Navigator.of(inner).pop();
              }
            },
            onReauth: () {
              if (!controller.hasAccess || !scope.current) return;
              live = false;
              controller.checkScope();
              session.login(stepUp: true);
            }));
    await navigator.push(route);
    // Hide private content during the closing animation before disposing it.
    live = false;
    controller.checkScope();
    await route.completed;
  } finally {
    live = false;
    targetChanges?.removeListener(targetChanged);
    owned?.dispose();
    scope.dispose();
  }
}
