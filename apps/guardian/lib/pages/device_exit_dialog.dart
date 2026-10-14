import 'package:flutter/material.dart';
import 'package:device_operations/device_operations.dart';
import '../core/api.dart';
import '../core/session.dart';
import 'device_subflow_scope.dart';

Future<void> openDeviceExit(
        BuildContext context, Session session, Json device) async {
  final actor = session.profile?['subject'], tenant = session.tenant?['id'];
  final role = session.role;
  if (!session.authenticated ||
      actor is! String ||
      tenant is! String ||
      !const {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR'}.contains(role)) {
    throw const ApiFailure(403, 'SCOPE_DENIED');
  }
  final id = device['id'], registration = device['registrationId'];
  if (id is! String || registration is! String) {
    throw const ApiFailure(502, 'INVALID_RESPONSE');
  }
  final target = ExitScope(
      actorId: actor,
      tenantId: tenant,
      deviceId: id,
      registrationId: registration,
      role: role);
  final scope = DeviceSubflowScope(session,
      permitted: () =>
          const {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR'}.contains(session.role));
  final name = device['displayName'] is String
      ? device['displayName'] as String
      : '当前设备';
  try {
    if (!context.mounted || !scope.current) return;
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DeviceExitDialog(
            session: session, scope: scope, target: target, deviceName: name));
  } finally {
    scope.dispose();
  }
}

class _DeviceExitDialog extends StatefulWidget {
  final Session session;
  final DeviceSubflowScope scope;
  final ExitScope target;
  final String deviceName;
  const _DeviceExitDialog(
      {required this.session,
      required this.scope,
      required this.target,
      required this.deviceName});
  @override
  State<_DeviceExitDialog> createState() => _DeviceExitDialogState();
}

class _DeviceExitDialogState extends State<_DeviceExitDialog> {
  late final ExitController controller;
  bool scopeLost = false;
  @override
  void initState() {
    super.initState();
    controller = ExitController(
        scope: widget.target,
        gateway: DeviceOperationsClient(
            apiRoot: Uri.parse(widget.scope.api.baseUrl),
            clientFactory: widget.scope.api.client,
            allowLoopbackHttp: const bool.fromEnvironment('ALLOW_LOCAL_HTTP',
                defaultValue: true)),
        journal: PreferencesExitJournal());
    widget.scope.addListener(checkScope);
    scopeLost = !widget.scope.current;
    if (scopeLost) {
      controller.dispose();
    } else {
      controller.initialize();
    }
  }

  void checkScope() {
    if (mounted && !scopeLost && !widget.scope.current) {
      controller.dispose();
      setState(() => scopeLost = true);
    }
  }

  @override
  void dispose() {
    widget.scope.removeListener(checkScope);
    if (!scopeLost) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => scopeLost || !widget.scope.current
      ? AlertDialog(
          title: const Text('账户或工作空间已变更'),
          content: const Text('请关闭此窗口，从当前工作空间重新打开设备操作。'),
          actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'))
            ])
      : AnimatedBuilder(
          animation: controller,
          builder: (context, _) => PopScope(
              canPop: !controller.busy,
              child: Dialog(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 740),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(
                          child: SingleChildScrollView(
                              child: DeviceExitPanel(
                                  controller: controller,
                                  deviceName: widget.deviceName,
                                  reauthenticate: () async {
                                    if (widget.scope.current) {
                                      widget.session.login(stepUp: true);
                                    }
                                  }))),
                      Padding(
                          padding: const EdgeInsets.all(16),
                          child: Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                  onPressed: controller.busy
                                      ? null
                                      : () => Navigator.pop(context),
                                  child: const Text('关闭')))),
                    ])),
              )));
}
