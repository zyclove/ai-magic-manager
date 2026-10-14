import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../core/support.dart';
import '../core/support_repository.dart';
import '../ui/design.dart';
import '../ui/support_center_view.dart';
import '../ui/support_grant_view.dart';
import 'diagnostic_packages_dialog.dart';
import 'device_subflow_scope.dart';

class SupportWorkspacePage extends StatefulWidget {
  final Session session;
  const SupportWorkspacePage(this.session, {super.key});
  @override
  State<SupportWorkspacePage> createState() => _SupportWorkspacePageState();
}

class _SupportWorkspacePageState extends State<SupportWorkspacePage> {
  late DeviceSubflowScope scope;

  void capture() {
    final session = widget.session;
    final receive = session.profile?['canCreateTenant'] == true;
    scope = DeviceSubflowScope(session,
        permitted: () =>
            (session.profile?['canCreateTenant'] == true) == receive &&
            (receive || session.canWrite));
  }

  @override
  void initState() {
    super.initState();
    capture();
  }

  @override
  void didUpdateWidget(covariant SupportWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      scope.dispose();
      capture();
    }
  }

  @override
  void dispose() {
    scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final actor = session.profile?['subject'],
        tenant = session.tenant?['id'],
        role = session.role;
    final receive = session.profile?['canCreateTenant'] == true,
        admin = session.canWrite && tenant is String;
    if (actor is! String || !session.authenticated || (!receive && !admin)) {
      return const Panel(child: Text('当前账号未具备支持协作所需资格。请联系账号管理员。'));
    }
    final captured = scope;
    bool current() => captured.current;
    final repository = SupportRepository(
        api: captured.api,
        actor: actor,
        tenant: tenant is String ? tenant : null,
        current: current);
    return SupportCenterView(
        key: ValueKey((captured.generation, actor, tenant, role, receive)),
        repository: repository,
        current: current,
        accessChanges: captured,
        canAdmin: admin,
        canReceive: receive,
        onOpenGrantPackages: (grant) {
          if (current()) {
            openDiagnosticPackages(context, session, received: true, grant: grant);
          }
        },
        onOpenReceivedPackages: () {
          if (current()) openDiagnosticPackages(context, session, received: true);
        },
        onOpenAdminPackages: () {
          if (current()) openDiagnosticPackages(context, session);
        },
        onReauth: () {
          if (current()) session.login(stepUp: true);
        },
        onOpenDevices: () {
          if (current()) context.go('/devices');
        });
  }
}

Future<void> openSupportGrant(
    BuildContext context, Session session, Json device) async {
  final actor = session.profile?['subject'],
      tenant = session.tenant?['id'];
  if (!session.authenticated || !session.canWrite) {
    throw const ApiFailure(403, 'SCOPE_DENIED');
  }
  if (device['state'] != 'ACTIVE') {
    throw const ApiFailure(409, 'DEVICE_NOT_ACTIVE');
  }
  if (actor is! String || tenant is! String) invalidSupport();
  final id = supportId(device['id']),
      registration = supportId(device['registrationId']),
      version = supportInteger(device['version']);
  final scope = DeviceSubflowScope(session, permitted: () => session.canWrite);
  bool current() => scope.current;
  try {
  final repository = SupportRepository(
      api: scope.api, actor: actor, tenant: tenant, current: current);
  if (!context.mounted || !current()) return;
  await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
          child: SizedBox(
              width: 740,
              height: MediaQuery.sizeOf(dialogContext).height * .9,
              child: SupportGrantView(
                  repository: repository,
                  deviceId: id,
                  registrationId: registration,
                  deviceVersion: version,
                  deviceName: device['displayName'] is String
                      ? device['displayName'] as String
                      : '当前设备',
                  current: current,
                  accessChanges: scope,
                  onClose: () => Navigator.of(dialogContext).pop(),
                  onReauth: () {
                    if (current()) session.login(stepUp: true);
                  }))));
  } finally {
    scope.dispose();
  }
}
