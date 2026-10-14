import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../core/diagnostic_repository.dart';
import '../ui/diagnostic_preview_view.dart';
import 'device_subflow_scope.dart';

bool canReadDiagnostics(String role) =>
    const {'OWNER', 'GUARDIAN', 'ORG_ADMIN'}.contains(role);

Future<void> openDeviceDiagnostic(
    BuildContext context, Session session, Json device) async {
  final tenant = session.tenant?['id'], actor = session.profile?['subject'];
  final role = session.role,
      deviceId = device['id'],
      registration = device['registrationId'];
  if (!session.authenticated || !canReadDiagnostics(role)) {
    throw const ApiFailure(403, 'SCOPE_DENIED');
  }
  if (tenant is! String ||
      actor is! String ||
      deviceId is! String ||
      registration is! String) {
    throw const ApiFailure(502, 'INVALID_DIAGNOSTIC_RESPONSE');
  }
  final scope = DeviceSubflowScope(session,
      permitted: () => canReadDiagnostics(session.role));
  bool current() => scope.current;
  try {
  final repository = DiagnosticRepository(
      api: scope.api,
      tenantId: tenant,
      deviceId: deviceId,
      registrationId: registration,
      current: current);
  if (!context.mounted || !current()) return;
  await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
          child: SizedBox(
              width: 780,
              height: MediaQuery.sizeOf(dialogContext).height * .86,
              child: DiagnosticPreviewView(
                  load: repository.load,
                  current: current,
                  accessChanges: scope,
                  onReauth: () {
                    if (current()) session.login(stepUp: true);
                  },
                  onClose: () => Navigator.of(dialogContext).pop()))));
  } finally {
    scope.dispose();
  }
}
