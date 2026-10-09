import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/observation.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/observation_editor.dart';
import '../ui/observation_view.dart';

/// Device-detail entry. Capture workspace/device/registration before any await.
Future<void> openDeviceObservation(
    BuildContext context, Session session, Json device) async {
  if (!session.authenticated ||
      session.tenant == null ||
      !canReadObservation(session.role)) {
    throw const ApiFailure(403, 'SCOPE_DENIED');
  }
  if (device['registrationId'] is! String) {
    await showDetails(context, '设备尚未注册', {'说明': '完成设备配对后才能查看或设置观察授权。'});
    return;
  }
  final root = session.root;
  bool current() =>
      session.authenticated &&
      session.tenant != null &&
      session.root == root &&
      canReadObservation(session.role);
  final repository = ObservationRepository(
      api: session.api,
      root: root,
      deviceId: device['id'] as String,
      registrationId: device['registrationId'] as String,
      current: current);
  if (!context.mounted) return;
  await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AnimatedBuilder(
          animation: session,
          builder: (_, __) {
            if (!current()) {
              return AlertDialog(
                  title: const Text('工作空间已变化'),
                  content: const Text('已隐藏当前设备数据。请关闭窗口，在新的工作空间重新打开。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'))
                  ]);
            }
            return _ObservationDialog(
                repository: repository,
                session: session,
                deviceName: device['displayName'] as String? ?? '设备',
                deviceState: device['state'] as String? ?? 'UNKNOWN');
          }));
}

class _ObservationDialog extends StatefulWidget {
  final ObservationRepository repository;
  final Session session;
  final String deviceName, deviceState;
  const _ObservationDialog(
      {required this.repository,
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
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
      snapshot = null;
    });
    try {
      final value = await widget.repository.load(cursor: cursor);
      if (!mounted || request != generation) return;
      setState(() {
        snapshot = value;
        if (reset) {
          cursors.clear();
          cursors.add(null);
        }
      });
    } catch (failure) {
      if (mounted && request == generation) setState(() => error = failure);
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  Future<void> edit() async {
    final before = snapshot?.settings;
    if (before == null ||
        busy ||
        !canEditObservation(widget.session.role, widget.deviceState)) return;
    final key = requestId();
    final result = await showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ObservationEditor(
            before: before,
            reauth: () => widget.session.login(stepUp: true),
            onSubmit: (body) async {
              if (!canEditObservation(
                  widget.session.role, widget.deviceState)) {
                throw const ApiFailure(403, 'SCOPE_DENIED');
              }
              // Clear reports before a consent mutation, including unknown outcomes.
              if (mounted) setState(() => snapshot = null);
              await widget.repository.update(before, body, key);
            }));
    if (mounted && result?['refresh'] == true) await load();
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
                    child: ObservationView(
                        snapshot: snapshot,
                        error: error,
                        busy: busy,
                        deviceName: widget.deviceName,
                        canEdit: canEditObservation(
                            widget.session.role, widget.deviceState),
                        refresh: () => load(),
                        edit: edit,
                        reauth: () => widget.session.login(stepUp: true),
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
                              }))),
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
