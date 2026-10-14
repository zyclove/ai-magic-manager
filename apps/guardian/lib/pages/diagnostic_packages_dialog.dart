import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../core/support.dart';
import '../core/diagnostic_package.dart';
import '../core/diagnostic_package_repository.dart';
import '../core/browser_json_download.dart';
import '../ui/diagnostic_packages_view.dart';
import 'device_subflow_scope.dart';

Future<void> openDiagnosticPackages(BuildContext context, Session session,
    {bool received = false, Json? device, SupportGrant? grant}) async {
  final actor = session.profile?['subject'],
      tenant = session.tenant?['id'];
  final eligible = session.profile?['canCreateTenant'] == true;
  if (!session.authenticated ||
      actor is! String ||
      (received ? !eligible : (!session.canWrite || tenant is! String))) {
    throw const ApiFailure(403, 'SCOPE_DENIED');
  }
  DiagnosticPackageDraft? target;
  if (received && grant != null) {
    if (grant.recipientActorId != actor ||
        !grant.withinTerm(DateTime.now().millisecondsSinceEpoch)) {
      throw const ApiFailure(403, 'SCOPE_DENIED');
    }
    target = DiagnosticPackageDraft.received(grant);
  } else if (!received && device != null) {
    if (device['state'] != 'ACTIVE') {
      throw const ApiFailure(409, 'DEVICE_NOT_ACTIVE');
    }
    target = DiagnosticPackageDraft.admin(
        deviceId: supportId(device['id']),
        registrationId: supportId(device['registrationId']),
        deviceVersion: supportInteger(device['version']));
  }
  final scope = DeviceSubflowScope(session,
      permitted: () =>
      (session.profile?['canCreateTenant'] == true) == eligible &&
      (received ? eligible : session.canWrite));
  bool current() => scope.current;
  try {
  final repository = DiagnosticPackageRepository(
      api: scope.api,
      actor: actor,
      tenant: tenant is String ? tenant : null,
      received: received,
      current: current);
  if (!context.mounted || !current()) return;
  await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          child: SizedBox(
              width: 800,
              height: MediaQuery.sizeOf(dialogContext).height * .9,
              child: DiagnosticPackagesView(
                  repository: repository,
                  current: current,
                  accessChanges: scope,
                  target: target,
                  targetLabel: device?['displayName'] is String
                      ? device!['displayName'] as String
                      : received
                          ? '授权设备'
                          : '当前设备',
                  onClose: () => Navigator.of(dialogContext).pop(),
                  onReauth: () {
                    if (current()) session.login(stepUp: true);
                  },
                  save: saveBrowserJson))));
  } finally {
    scope.dispose();
  }
}
