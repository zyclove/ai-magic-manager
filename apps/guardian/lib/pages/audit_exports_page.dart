// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/audit.dart';
import '../core/audit_exports.dart';
import '../core/session.dart';
import '../ui/audit_exports_view.dart';
import 'device_subflow_scope.dart';
import '../ui/design.dart';

class AuditExportsPage extends StatefulWidget {
  final Session session;
  const AuditExportsPage({super.key, required this.session});
  @override
  State<AuditExportsPage> createState() => _AuditExportsPageState();
}

class _AuditExportsPageState extends State<AuditExportsPage> {
  late final Session sessionOwner;
  late final String root;
  late final DeviceSubflowScope scope;
  late final AuditExportRepository repository;
  bool permitted() =>
      mounted &&
      identical(widget.session, sessionOwner) &&
      sessionOwner.tenant != null &&
      sessionOwner.canOpen('exports') &&
      auditRoles.contains(sessionOwner.role);
  bool current() => mounted && scope.current;
  @override
  void initState() {
    super.initState();
    sessionOwner = widget.session;
    root = sessionOwner.root;
    scope = DeviceSubflowScope(sessionOwner, permitted: permitted);
    repository = AuditExportRepository(
        api: scope.api, root: root, current: current);
  }

  @override
  void dispose() {
    scope.dispose();
    super.dispose();
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
      animation: scope,
      builder: (_, __) => current()
          ? AuditExportsView(
              repository: repository,
              saveFile: save,
              onReauth: () {
                if (current()) sessionOwner.login(stepUp: true);
              },
              onAudit: () {
                if (current()) context.go('/audit');
              },
              accessChanges: scope)
          : const Panel(child: EmptyView('工作空间或权限已变化', '已隐藏旧任务，请重新打开导出任务。')));
}
