import 'package:device_operations/device_operations.dart';
import 'package:flutter/material.dart';

import '../core/parent_api.dart';
import '../core/parent_session.dart';

/// Reuses the preview, confirmation and recovery controller also used by the
/// Web console. This operation only requests this agent's own cleanup.
Future<void> openParentDeviceExit(
        BuildContext context, ParentSession session, Json device) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DeviceExitDialog(session: session, device: device),
    );

class _DeviceExitDialog extends StatefulWidget {
  final ParentSession session;
  final Json device;
  const _DeviceExitDialog({required this.session, required this.device});

  @override
  State<_DeviceExitDialog> createState() => _DeviceExitDialogState();
}

class _DeviceExitDialogState extends State<_DeviceExitDialog> {
  late final ExitController controller;
  late final String identity;
  bool scopeLost = false;

  String get currentIdentity =>
      '${widget.session.profile?['subject']}/${widget.session.tenant?['id']}/${widget.session.role}';

  @override
  void initState() {
    super.initState();
    final session = widget.session;
    identity = currentIdentity;
    session.addListener(_checkScope);
    controller = ExitController(
      scope: ExitScope(
          actorId: session.profile!['subject'] as String,
          tenantId: session.tenant!['id'] as String,
          deviceId: widget.device['id'] as String,
          registrationId: widget.device['registrationId'] as String,
          role: session.role),
      gateway: DeviceOperationsClient(
        apiRoot: Uri.parse(ParentConfig.apiUrl),
        clientFactory: session.authenticatedClient,
      ),
      journal: PreferencesExitJournal(),
    );
    controller.initialize();
  }

  void _checkScope() {
    if (!scopeLost && identity != currentIdentity) {
      controller.dispose();
      if (mounted) setState(() => scopeLost = true);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_checkScope);
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
                child: const Text('关闭')),
          ],
        )
      : AnimatedBuilder(
          animation: controller,
          builder: (context, _) => PopScope(
            canPop: !controller.busy,
            child: Dialog(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: 650,
                    maxHeight: MediaQuery.sizeOf(context).height * .9),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: SingleChildScrollView(
                      child: DeviceExitPanel(
                        controller: controller,
                        deviceName:
                            widget.device['displayName'] as String? ?? '设备',
                        reauthenticate: () async {
                          if (!await widget.session.reauthenticate()) {
                            throw const ParentApiException(
                                401, 'REAUTH_REQUIRED');
                          }
                        },
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                          onPressed: controller.busy
                              ? null
                              : () => Navigator.pop(context),
                          child: const Text('关闭')),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
}
