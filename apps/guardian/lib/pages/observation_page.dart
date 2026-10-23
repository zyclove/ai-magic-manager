import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/observation.dart';
import '../core/permission_observation.dart';
import '../core/session.dart';
import '../ui/dialog_access.dart';
import '../ui/observation_editor.dart';
import '../ui/observation_view.dart';
import '../ui/owned_dialog_route.dart';
import '../ui/permission_observation_panel.dart';
import 'device_subflow_scope.dart';

/// Device-detail entry. Capture workspace/device/registration before any await.
Future<void> openDeviceObservation(
    BuildContext context, Session session, Json device) async {
  if (!context.mounted) return;
  if (!session.authenticated ||
      session.tenant?['id'] is! String ||
      session.profile?['subject'] is! String ||
      !canReadObservation(session.role)) {
    throw const ApiFailure(403, 'SCOPE_DENIED');
  }
  if (ModalRoute.of(context)?.isCurrent == false) return;
  final root = session.root;
  final parent = DialogAccessBinding(context);
  final scope = DeviceSubflowScope(session,
      permitted: () => context.mounted && parent.permitted() &&
          canReadObservation(session.role));
  OwnedDialogRoute<void>? observationRoute;
  bool current() => scope.current &&
      (observationRoute == null || observationRoute!.available);
  final changes = Listenable.merge([scope, parent.changes]);
  try {
    if (!context.mounted || !current()) return;
    if (device['registrationId'] is! String) {
      late final OwnedDialogRoute<void> route;
      route = OwnedDialogRoute<void>(
          context: context,
          builder: (_) => AnimatedBuilder(
              animation: changes,
              builder: (_, __) => current()
                  ? AlertDialog(
                      title: const Text('设备尚未注册'),
                      content: const Text('完成设备配对后才能查看或设置观察授权。'),
                      actions: [
                        TextButton(onPressed: route.finish,
                            child: const Text('关闭'))
                      ])
                  : _observationScopeLost(route)));
      observationRoute = route;
      await presentOwnedDialog(context, route);
      return;
    }
    final repository = ObservationRepository(
        api: scope.api.scoped(current),
        root: root,
        deviceId: device['id'] as String,
        registrationId: device['registrationId'] as String,
        current: current);
    late final OwnedDialogRoute<void> route;
    route = OwnedDialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AnimatedBuilder(
            animation: changes,
            builder: (_, __) => current()
                ? _ObservationDialog(
                    route: route,
                    repository: repository,
                    scope: scope,
                    accessChanges: changes,
                    session: session,
                    deviceName: device['displayName'] as String? ?? '设备',
                    deviceState: device['state'] as String? ?? 'UNKNOWN')
                : _observationScopeLost(route)));
    observationRoute = route;
    await presentOwnedDialog(context, route);
  } finally {
    scope.dispose();
    parent.dispose();
  }
}

Widget _observationScopeLost(OwnedDialogRoute<void> route) => AlertDialog(
    title: const Text('工作空间已变化'),
    content: const Text('已隐藏当前设备数据。请关闭窗口，在新的工作空间重新打开。'),
    actions: [
      TextButton(onPressed: route.finish, child: const Text('关闭'))
    ]);

class _ObservationDialog extends StatefulWidget {
  final OwnedDialogRoute<void> route;
  final ObservationRepository repository;
  final DeviceSubflowScope scope;
  final Listenable accessChanges;
  final Session session;
  final String deviceName, deviceState;
  const _ObservationDialog(
      {required this.route,
      required this.repository,
      required this.scope,
      required this.accessChanges,
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
  OwnedDialogRoute<Json>? editor;
  final cursors = <String?>[null];
  bool get current => mounted && widget.route.available &&
      widget.scope.current && widget.repository.current();
  @override
  void initState() {
    super.initState();
    load();
  }

  void closeEditor() {
    final route = editor;
    editor = null;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => route.finish());
    }
  }

  void close() {
    closeEditor();
    widget.route.finish();
  }

  Future<void> load({String? cursor, bool reset = true}) async {
    if (!current) return;
    closeEditor();
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
      snapshot = null;
    });
    try {
      final value = await widget.repository.load(cursor: cursor);
      if (!current || request != generation) return;
      setState(() {
        snapshot = value;
        if (reset) {
          cursors.clear();
          cursors.add(null);
        }
      });
    } catch (failure) {
      if (current && request == generation) setState(() => error = failure);
    } finally {
      if (current && request == generation) setState(() => busy = false);
    }
  }

  Future<void> edit() async {
    if (!current || busy || editor != null || !widget.route.isCurrent) return;
    final session = widget.session;
    final repository = widget.repository;
    final deviceState = widget.deviceState;
    final before = snapshot?.settings;
    if (before == null || !canEditObservation(session.role, deviceState)) return;
    final revision = generation;
    final key = requestId();
    final access = DialogAccessBinding(context,
        accessChanges: widget.accessChanges, hasAccess: () => current);
    OwnedDialogRoute<Json>? ownedRoute;
    bool childCurrent() {
      final route = ownedRoute;
      return route != null && current && access.permitted() &&
          revision == generation && identical(editor, route) && route.available;
    }
    var refresh = false;
    try {
      if (!access.permitted()) return;
      final route = OwnedDialogRoute<Json>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ObservationEditor(
              before: before,
              accessChanges: Listenable.merge([widget.accessChanges, access.changes]),
              hasAccess: childCurrent,
              reauth: () {
                if (childCurrent()) session.login(stepUp: true);
              },
              onSubmit: (body) async {
                if (!childCurrent()) {
                  throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                }
                if (!canEditObservation(session.role, deviceState)) {
                  throw const ApiFailure(403, 'SCOPE_DENIED');
                }
                // Clear reports before a consent mutation, including unknown outcomes.
                setState(() => snapshot = null);
                await repository.update(before, body, key);
              }));
      ownedRoute = route;
      editor = route;
      final result = await presentOwnedDialog(context, route);
      refresh = result?['refresh'] == true && current && access.permitted() &&
          revision == generation && identical(editor, route);
    } finally {
      if (identical(editor, ownedRoute)) editor = null;
      access.dispose();
    }
    if (refresh && current && revision == generation) await load();
  }

  @override
  void dispose() {
    generation++;
    closeEditor();
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
                              canEdit: current && canEditObservation(
                                  widget.session.role, widget.deviceState),
                              refresh: () => load(),
                              edit: edit,
                              reauth: () {
                                if (current) widget.session.login(stepUp: true);
                              },
                              previous: cursors.length > 1
                                  ? () {
                                      if (!current || busy || cursors.length <= 1) return;
                                      cursors.removeLast();
                                      load(cursor: cursors.last, reset: false);
                                    }
                                  : null,
                              next: snapshot?.nextCursor == null
                                  ? null
                                  : () {
                                      if (!current || busy || snapshot?.nextCursor == null) return;
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
                                canEdit: current && canEditObservation(
                                    widget.session.role, widget.deviceState),
                                inventoryEnabled:
                                    snapshot?.settings.inventoryEnabled,
                                reauth: () {
                                  if (current) widget.session.login(stepUp: true);
                                })
                          ]
                        ]))),
            const Divider(),
            Align(
                alignment: Alignment.centerRight,
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextButton(onPressed: close, child: const Text('关闭')))),
          ])));
}
