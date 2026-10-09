import 'package:flutter/material.dart';
import 'package:device_operations/device_operations.dart';
import '../core/api.dart';
import '../core/session.dart';

Future<void> openDeviceExit(
        BuildContext context, Session session, Json device) =>
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DeviceExitDialog(session: session, device: device));

class _DeviceExitDialog extends StatefulWidget {
  final Session session;
  final Json device;
  const _DeviceExitDialog({required this.session, required this.device});
  @override
  State<_DeviceExitDialog> createState() => _DeviceExitDialogState();
}

class _DeviceExitDialogState extends State<_DeviceExitDialog> {
  late final ExitController controller;
  late final String scopeIdentity;
  bool scopeLost = false;
  String get currentIdentity =>
      '${widget.session.profile?['subject']}/${widget.session.tenant?['id']}/${widget.session.role}';
  @override
  void initState() {
    super.initState();
    final session = widget.session;
    scopeIdentity = currentIdentity;
    session.addListener(checkScope);
    controller = ExitController(
        scope: ExitScope(
            actorId: session.profile!['subject'],
            tenantId: session.tenant!['id'],
            deviceId: widget.device['id'],
            registrationId: widget.device['registrationId'],
            role: session.role),
        gateway: DeviceOperationsClient(
            apiRoot: Uri.parse(session.api.baseUrl),
            clientFactory: session.authenticatedClient,
            allowLoopbackHttp: const bool.fromEnvironment('ALLOW_LOCAL_HTTP',
                defaultValue: true)),
        journal: PreferencesExitJournal());
    controller.initialize();
  }

  void checkScope() {
    if (!scopeLost && scopeIdentity != currentIdentity) {
      controller.dispose();
      setState(() => scopeLost = true);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(checkScope);
    if (!scopeLost) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => scopeLost
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
                                  deviceName: widget.device['displayName'],
                                  reauthenticate: () async =>
                                      widget.session.login(stepUp: true)))),
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
