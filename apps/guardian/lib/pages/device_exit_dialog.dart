import 'package:flutter/material.dart';
import 'package:device_operations/device_operations.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../ui/dialog_access.dart';
import '../ui/owned_dialog_route.dart';
import 'device_subflow_scope.dart';

Future<void> openDeviceExit(
    BuildContext context, Session session, Json device) async {
  await openDeviceExitChanged(context, session, device);
}

/// True asks the caller to review the list after a write was handed to the
/// exit client. It is not evidence of transport dispatch or server execution.
Future<bool> openDeviceExitChanged(
    BuildContext context, Session session, Json device,
    {Listenable? accessChanges, bool Function()? hasAccess}) async {
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
  if (!context.mounted || hasAccess?.call() == false) return false;
  final target = ExitScope(
      actorId: actor,
      tenantId: tenant,
      deviceId: id,
      registrationId: registration,
      role: role);
  final access = DialogAccessBinding(context,
      accessChanges: accessChanges, hasAccess: hasAccess);
  final scope = DeviceSubflowScope(session,
      permitted: () =>
          const {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR'}
              .contains(session.role) && access.permitted());
  final changes = Listenable.merge([
    scope,
    access.changes,
    if (accessChanges != null) accessChanges,
  ]);
  final name = device['displayName'] is String
      ? device['displayName'] as String
      : '当前设备';
  var attempted = false;
  late final OwnedDialogRoute<void> route;
  void observe() {
    if (!scope.current && route.available) route.finish();
  }

  try {
    if (!scope.current) return false;
    route = OwnedDialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AnimatedBuilder(
            animation: changes,
            builder: (_, __) => scope.current
                ? _DeviceExitDialog(
                    session: session,
                    scope: scope,
                    changes: changes,
                    route: route,
                    target: target,
                    deviceName: name,
                    onWriteAttempt: () => attempted = true)
                : const SizedBox.shrink()));
    changes.addListener(observe);
    await presentOwnedDialog(context, route);
    return attempted;
  } finally {
    changes.removeListener(observe);
    scope.dispose();
    access.dispose();
  }
}

/// Observe only explicit confirm/cancel calls. Existing journal entries and
/// read-only history, preview and status requests do not count as new attempts.
class _ReviewExitGateway implements ExitGateway {
  final ExitGateway inner;
  final bool Function() hasAccess;
  final VoidCallback onWriteAttempt;
  _ReviewExitGateway(this.inner,
      {required this.hasAccess, required this.onWriteAttempt});

  void _beforeWrite() {
    if (!hasAccess()) {
      throw const ExitFailure('SCOPE_DENIED', '当前窗口已失效，请重新打开设备操作。');
    }
    onWriteAttempt();
  }

  @override
  Future<DeviceSnapshot> device(ExitScope scope) => inner.device(scope);
  @override
  Future<ExitPreview> preview(ExitScope scope, int deviceVersion) =>
      inner.preview(scope, deviceVersion);
  @override
  Future<ExitOperation> operation(ExitScope scope, String operationId) =>
      inner.operation(scope, operationId);
  @override
  Future<List<ExitOperation>> operations(ExitScope scope) =>
      inner.operations(scope);

  @override
  Future<ExitOperation> confirm(ExitScope scope,
      {required String previewId,
      required String previewHash,
      required int deviceVersion,
      required String key}) {
    _beforeWrite();
    return inner.confirm(scope,
        previewId: previewId,
        previewHash: previewHash,
        deviceVersion: deviceVersion,
        key: key);
  }

  @override
  Future<ExitOperation> cancel(ExitScope scope,
      {required String operationId,
      required int version,
      required String key}) {
    _beforeWrite();
    return inner.cancel(scope,
        operationId: operationId, version: version, key: key);
  }
}

class _DeviceExitDialog extends StatefulWidget {
  final Session session;
  final DeviceSubflowScope scope;
  final Listenable changes;
  final OwnedDialogRoute<void> route;
  final ExitScope target;
  final String deviceName;
  final VoidCallback onWriteAttempt;
  const _DeviceExitDialog(
      {required this.session,
      required this.scope,
      required this.changes,
      required this.route,
      required this.target,
      required this.deviceName,
      required this.onWriteAttempt});
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
        gateway: _ReviewExitGateway(
            DeviceOperationsClient(
                apiRoot: Uri.parse(widget.scope.api.baseUrl),
                clientFactory: widget.scope.api.scoped(
                    () => widget.route.available && widget.scope.current).client,
                allowLoopbackHttp: const bool.fromEnvironment('ALLOW_LOCAL_HTTP',
                    defaultValue: true)),
            hasAccess: () => widget.route.available && widget.scope.current,
            onWriteAttempt: widget.onWriteAttempt),
        journal: PreferencesExitJournal());
    widget.changes.addListener(checkScope);
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
    widget.changes.removeListener(checkScope);
    if (!scopeLost) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => scopeLost || !widget.scope.current
      ? const SizedBox.shrink()
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
                                    if (widget.route.available &&
                                        widget.route.isCurrent &&
                                        widget.scope.current) {
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
                                      : () {
                                          if (widget.route.available &&
                                              widget.route.isCurrent &&
                                              widget.scope.current &&
                                              !controller.busy) {
                                            widget.route.finish();
                                          }
                                        },
                                  child: const Text('关闭')))),
                    ])),
              )));
}
