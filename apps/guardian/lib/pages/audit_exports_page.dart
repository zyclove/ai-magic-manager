// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/audit.dart';
import '../core/audit_exports.dart';
import '../core/session.dart';
import '../ui/audit_exports_view.dart';
import '../ui/design.dart';

class AuditExportsPage extends StatefulWidget {
  final Session session;
  const AuditExportsPage({super.key, required this.session});
  @override
  State<AuditExportsPage> createState() => _AuditExportsPageState();
}

class _AuditExportsPageState extends State<AuditExportsPage> {
  late final String root, role;
  late final AuditExportRepository repository;
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
    repository = AuditExportRepository(
        api: widget.session.api, root: root, current: current);
  }

  Future<void> save(Uint8List bytes, String name) async {
    repository.ensureCurrent();
    final url = html.Url.createObjectUrlFromBlob(
        html.Blob([bytes], 'application/json'));
    final anchor = html.AnchorElement(href: url)
      ..download = name
      ..style.display = 'none';
    try {
      html.document.body!.append(anchor);
      anchor.click();
    } finally {
      anchor.remove();
      Future<void>.delayed(
          const Duration(seconds: 30), () => html.Url.revokeObjectUrl(url));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.session,
      builder: (_, __) => current()
          ? AuditExportsView(
              repository: repository,
              saveFile: save,
              onReauth: () => widget.session.login(stepUp: true),
              onAudit: () => context.go('/audit'),
              accessChanges: widget.session)
          : const Panel(child: EmptyView('工作空间或权限已变化', '已隐藏旧任务，请重新打开导出任务。')));
}
