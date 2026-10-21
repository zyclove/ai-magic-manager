import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/audit.dart';
import '../core/audit_exports.dart';
import '../core/session.dart';
import '../ui/audit_view.dart';
import '../ui/design.dart';
import '../ui/export_create_dialog.dart';
import '../ui/owned_dialog_route.dart';
import 'device_subflow_scope.dart';

class AuditExplorerPage extends StatefulWidget {
  final Session session;
  final AuditQuery? initialQuery;
  final String? contextNotice;
  final bool Function()? parentCurrent;
  final Listenable? accessChanges;
  final Object? _tenantId, _actorId;
  final String _role;
  final int _generation;
  final bool _initialAuthorized;
  AuditExplorerPage({super.key, required this.session, this.initialQuery,
    this.contextNotice, this.parentCurrent, this.accessChanges})
      : _tenantId = session.tenant?['id'],
        _actorId = session.profile?['subject'],
        _role = session.role,
        _generation = session.scopeGeneration,
        _initialAuthorized = session.authenticated &&
            session.tenant?['id'] is String &&
            auditRoles.contains(session.role) && session.canOpen('audit') &&
            parentCurrent?.call() != false;
  @override
  State<AuditExplorerPage> createState() => _AuditExplorerPageState();
}

class _AuditExplorerPageState extends State<AuditExplorerPage> {
  late final Session sessionOwner;
  String? root;
  AuditRepository? repository;
  DeviceSubflowScope? scope;
  late final Listenable changes;
  bool current() => mounted && scope?.current == true;
  bool permitted() =>
      identical(widget.session, sessionOwner) &&
      widget._initialAuthorized && widget.session.authenticated &&
      widget._tenantId is String &&
      widget.session.tenant?['id'] == widget._tenantId &&
      widget.session.profile?['subject'] == widget._actorId &&
      widget.session.scopeGeneration == widget._generation &&
      widget.session.role == widget._role &&
      auditRoles.contains(widget._role) && widget.session.canOpen('audit') &&
      widget.parentCurrent?.call() != false;
  @override
  void initState() {
    super.initState();
    sessionOwner = widget.session;
    if (!permitted()) {
      changes = Listenable.merge([widget.session, widget.accessChanges]);
      return;
    }
    root = '/tenants/${widget._tenantId}';
    final captured = DeviceSubflowScope(widget.session, permitted: permitted);
    scope = captured;
    changes = Listenable.merge([captured, widget.accessChanges]);
    repository = AuditRepository(api: captured.api, root: root!, current: current);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: changes,
      builder: (_, __) => current()
          ? AuditView(
              repository: repository!,
              accessChanges: changes,
              initialQuery: widget.initialQuery,
              contextNotice: widget.contextNotice,
              onExport: (query) async {
                final parentRoute = ModalRoute.of(context);
                var completedInFront = false;
                late final OwnedDialogRoute<AuditExportJob> route;
                route = OwnedDialogRoute<AuditExportJob>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => ExportCreateDialog(
                        repository: AuditExportRepository(
                            api: scope!.api,
                            root: root!,
                            current: current),
                        query: query,
                        accessChanges: changes,
                        onReauth: () => widget.session.login(stepUp: true),
                        onCreated: (job) {
                          completedInFront = route.isCurrent;
                          route.finish(job);
                        }));
                final job = await presentOwnedDialog(context, route);
                if (job != null && completedInFront &&
                    context.mounted && current() &&
                    parentRoute?.isCurrent == true) {
                  context.go('/exports');
                }
              })
          : const Panel(
              child: EmptyView('工作空间或权限已变化', '已隐藏旧记录，请重新打开当前工作空间的审计日志。')));

  @override
  void dispose() {
    scope?.dispose();
    super.dispose();
  }
}
