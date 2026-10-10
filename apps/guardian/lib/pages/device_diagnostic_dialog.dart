import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../core/diagnostic_repository.dart';
import '../ui/diagnostic_preview_view.dart';

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
  bool current() =>
      session.authenticated &&
      session.tenant?['id'] == tenant &&
      session.profile?['subject'] == actor &&
      session.role == role &&
      canReadDiagnostics(session.role);
  final repository = DiagnosticRepository(
      api: session.api,
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
                  accessChanges: session,
                  onReauth: () => session.login(stepUp: true),
                  onClose: () => Navigator.of(dialogContext).pop()))));
}
