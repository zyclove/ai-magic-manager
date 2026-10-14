import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/observation.dart';
import '../core/permission_observation.dart';
import '../core/session.dart';
import '../ui/observation_editor.dart';
import '../ui/observation_view.dart';
import '../ui/permission_observation_panel.dart';
import 'device_subflow_scope.dart';

/// Device-detail entry. Capture workspace/device/registration before any await.
Future<void> openDeviceObservation(
    BuildContext context, Session session, Json device) async {
  if (!session.authenticated ||
      session.tenant?['id'] is! String ||
      session.profile?['subject'] is! String ||
      !canReadObservation(session.role)) {
    throw const ApiFailure(403, 'SCOPE_DENIED');
  }
  final root = session.root;
  final scope = DeviceSubflowScope(session,
      permitted: () => canReadObservation(session.role));
  bool current() => scope.current;
  try {
  if (device['registrationId'] is! String) {
    if (!context.mounted || !current()) return;
    await showDialog<void>(
        context: context,
        builder: (dialogContext) => AnimatedBuilder(
            animation: scope,
            builder: (_, __) => current()
                ? AlertDialog(
                    title: const Text('设备尚未注册'),
                    content: const Text('完成设备配对后才能查看或设置观察授权。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('关闭'))
                    ])
                : _observationScopeLost(dialogContext)));
    return;
  }
  final repository = ObservationRepository(
      api: scope.api,
      root: root,
      deviceId: device['id'] as String,
      registrationId: device['registrationId'] as String,
      current: current);
  if (!context.mounted || !current()) return;
  await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AnimatedBuilder(
          animation: scope,
          builder: (_, __) {
            if (!current()) {
              return _observationScopeLost(dialogContext);
            }
            return _ObservationDialog(
                repository: repository,
                scope: scope,
                session: session,
                deviceName: device['displayName'] as String? ?? '设备',
                deviceState: device['state'] as String? ?? 'UNKNOWN');
          }));
  } finally {
    scope.dispose();
  }
}

Widget _observationScopeLost(BuildContext context) => AlertDialog(
    title: const Text('工作空间已变化'),
    content: const Text('已隐藏当前设备数据。请关闭窗口，在新的工作空间重新打开。'),
    actions: [
      TextButton(
          onPressed: () => Navigator.pop(context), child: const Text('关闭'))
    ]);

class _ObservationDialog extends StatefulWidget {
  final ObservationRepository repository;
  final DeviceSubflowScope scope;
  final Session session;
  final String deviceName, deviceState;
  const _ObservationDialog(
      {required this.repository,
      required this.scope,
      required this.session,
      required this.deviceName,
      required this.deviceState});
  @override
  State<_ObservationDialog> createState() => _ObservationDialogState();
}

class _ObservationDialogState extends State<_ObservationDialog> {
  ObservationSnapshot? snapshot;
  Object? error;
  bool busy = false;
  int generation = 0;
  final cursors = <String?>[null];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({String? cursor, bool reset = true}) async {
    if (!widget.scope.current) return;
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
      snapshot = null;
    });
    try {
      final value = await widget.repository.load(cursor: cursor);
      if (!mounted || request != generation || !widget.scope.current) return;
      setState(() {
        snapshot = value;
        if (reset) {
          cursors.clear();
          cursors.add(null);
        }
      });
    } catch (failure) {
      if (mounted && request == generation && widget.scope.current) {
        setState(() => error = failure);
      }
    } finally {
      if (mounted && request == generation && widget.scope.current) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> edit() async {
    final scope = widget.scope;
    final session = widget.session;
    final repository = widget.repository;
    final deviceState = widget.deviceState;
    final before = snapshot?.settings;
    if (!scope.current ||
        before == null ||
        busy ||
        !canEditObservation(session.role, deviceState)) return;
    final key = requestId();
    final result = await showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AnimatedBuilder(
          animation: scope,
          builder: (_, __) {
            if (!scope.current) {
              return _observationScopeLost(dialogContext);
            }
            return ObservationEditor(
            before: before,
            reauth: () {
              if (scope.current) session.login(stepUp: true);
            },
            onSubmit: (body) async {
              if (!scope.current) {
                throw const ApiFailure(409, 'WORKSPACE_CHANGED');
              }
              if (!canEditObservation(session.role, deviceState)) {
                throw const ApiFailure(403, 'SCOPE_DENIED');
              }
              // Clear reports before a consent mutation, including unknown outcomes.
              if (mounted) setState(() => snapshot = null);
              await repository.update(before, body, key);
            });
          }));
    if (mounted && scope.current && result?['refresh'] == true) {
      await load();
    }
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
          width: 880,
          height: MediaQuery.sizeOf(context).height * .9,
          child: Column(children: [
            Expanded(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ObservationView(
                              snapshot: snapshot,
                              error: error,
                              busy: busy,
                              deviceName: widget.deviceName,
                              canEdit: widget.scope.current && canEditObservation(
                                  widget.session.role, widget.deviceState),
                              refresh: () => load(),
                              edit: edit,
                              reauth: () {
                                if (widget.scope.current) {
                                  widget.session.login(stepUp: true);
                                }
                              },
                              previous: cursors.length > 1
                                  ? () {
                                      cursors.removeLast();
                                      load(cursor: cursors.last, reset: false);
                                    }
                                  : null,
                              next: snapshot?.nextCursor == null
                                  ? null
                                  : () {
                                      cursors.add(snapshot!.nextCursor);
                                      load(cursor: cursors.last, reset: false);
                                    }),
                          if (const bool.fromEnvironment(
                              'PERMISSION_OBSERVATION_ENABLED')) ...[
                            const SizedBox(height: 24),
                            const Divider(),
                            const SizedBox(height: 24),
                            PermissionObservationPanel(
                                repository: PermissionObservationRepository(
                                    api: widget.repository.api,
                                    root: widget.repository.root,
                                    deviceId: widget.repository.deviceId,
                                    registrationId:
                                        widget.repository.registrationId,
                                    current: widget.repository.current),
                                canEdit: widget.scope.current && canEditObservation(
                                    widget.session.role, widget.deviceState),
                                inventoryEnabled:
                                    snapshot?.settings.inventoryEnabled,
                                reauth: () {
                                  if (widget.scope.current) {
                                    widget.session.login(stepUp: true);
                                  }
                                })
                          ]
                        ]))),
            const Divider(),
            Align(
                alignment: Alignment.centerRight,
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭')))),
          ])));
}
