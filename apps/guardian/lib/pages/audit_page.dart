import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/audit.dart';
import '../core/audit_exports.dart';
import '../core/session.dart';
import '../ui/audit_view.dart';
import '../ui/design.dart';
import '../ui/export_create_dialog.dart';

class AuditExplorerPage extends StatefulWidget {
  final Session session;
  const AuditExplorerPage({super.key, required this.session});
  @override
  State<AuditExplorerPage> createState() => _AuditExplorerPageState();
}

class _AuditExplorerPageState extends State<AuditExplorerPage> {
  late final String root, role;
  late final AuditRepository repository;
  bool current() =>
      widget.session.authenticated &&
      widget.session.tenant != null &&
      widget.session.root == root &&
      widget.session.role == role &&
      auditRoles.contains(role);
  @override
  void initState() {
    super.initState();
    root = widget.session.root;
    role = widget.session.role;
    repository =
        AuditRepository(api: widget.session.api, root: root, current: current);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.session,
      builder: (_, __) => current()
          ? AuditView(
              repository: repository,
              accessChanges: widget.session,
              onExport: (query) async {
                final job = await showDialog<AuditExportJob>(
                    context: context,
                    barrierDismissible: false,
                    builder: (dialogContext) => ExportCreateDialog(
                        repository: AuditExportRepository(
                            api: widget.session.api,
                            root: root,
                            current: current),
                        query: query,
                        accessChanges: widget.session,
                        onReauth: () => widget.session.login(stepUp: true),
                        onCreated: (job) =>
                            Navigator.of(dialogContext).pop(job)));
                if (job != null && context.mounted && current()) {
                  context.go('/exports');
                }
              })
          : const Panel(
              child: EmptyView('工作空间或权限已变化', '已隐藏旧记录，请重新打开当前工作空间的审计日志。')));
}
